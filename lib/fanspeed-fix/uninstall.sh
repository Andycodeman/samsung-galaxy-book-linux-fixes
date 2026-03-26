#!/bin/bash
# =============================================================================
# Samsung Galaxy Book — Fan Speed Fix — Uninstall
# =============================================================================
# Self-contained. Run as root: sudo bash uninstall.sh
# =============================================================================

set -e

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Please run as root: sudo bash uninstall.sh"
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BLUE}══ $* ${NC}"; }

# ── Distro / initramfs detection ──────────────────────────────────────────────
detect_distro() {
    [[ -f /etc/os-release ]] || error "Cannot detect distro — /etc/os-release not found"
    source /etc/os-release
    local id="${ID,,}" like="${ID_LIKE:-}"; like="${like,,}"
    if [[ "$id" == "fedora" ]]; then DISTRO="fedora"
    elif [[ "$id" == "ubuntu" || "$like" == *"ubuntu"* || "$id" == "debian" || "$like" == *"debian"* ]]; then DISTRO="ubuntu"
    elif [[ "$id" == "arch" || "$like" == *"arch"* ]]; then DISTRO="arch"
    else error "Unsupported distro: $PRETTY_NAME"
    fi

    if [[ "$DISTRO" == "arch" ]]; then INITRAMFS_TOOL="mkinitcpio"
    elif command -v dracut &>/dev/null && ! command -v update-initramfs &>/dev/null; then INITRAMFS_TOOL="dracut"
    elif command -v update-initramfs &>/dev/null; then INITRAMFS_TOOL="initramfs-tools"
    elif command -v dracut &>/dev/null; then INITRAMFS_TOOL="dracut"
    else error "Could not detect initramfs tool"
    fi
}

set_dsdt_paths() {
    if [[ "$INITRAMFS_TOOL" == "initramfs-tools" ]]; then
        DSDT_OVERRIDE_DIR="/etc/initramfs-tools"; DSDT_OVERRIDE_AML="${DSDT_OVERRIDE_DIR}/DSDT.aml"
        DSDT_DRACUT_CONF=""; DSDT_MKINITCPIO_HOOK=""; DSDT_MKINITCPIO_INSTALL=""; DSDT_MKINITCPIO_CONF=""
    elif [[ "$INITRAMFS_TOOL" == "mkinitcpio" ]]; then
        DSDT_OVERRIDE_DIR="/etc/acpi_override"; DSDT_OVERRIDE_AML="${DSDT_OVERRIDE_DIR}/dsdt_fixed.aml"
        DSDT_DRACUT_CONF=""
        DSDT_MKINITCPIO_HOOK="/etc/initcpio/hooks/acpi_override"
        DSDT_MKINITCPIO_INSTALL="/etc/initcpio/install/acpi_override"
        DSDT_MKINITCPIO_CONF="/etc/mkinitcpio.conf.d/acpi_override.conf"
    else
        DSDT_OVERRIDE_DIR="/etc/acpi_override"; DSDT_OVERRIDE_AML="${DSDT_OVERRIDE_DIR}/dsdt_fixed.aml"
        DSDT_DRACUT_CONF="/etc/dracut.conf.d/acpi.conf"
        DSDT_MKINITCPIO_HOOK=""; DSDT_MKINITCPIO_INSTALL=""; DSDT_MKINITCPIO_CONF=""
    fi
}


detect_distro
set_dsdt_paths

FAN_MONITOR_SVC="samsung-galaxybook-fan-monitor.service"
FAN_CHECK_SCRIPT="/usr/local/bin/samsung-galaxybook-fan-monitor.sh"
FAN_CLEANUP="/usr/local/bin/samsung-galaxybook-fan-cleanup.sh"

echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Uninstalling: Fan Speed Fix                      ║"
echo "╚════════════════════════════════════════════════════════════╝"

step "Fan Step 1: Removing DSDT override file"
[[ -f "$DSDT_OVERRIDE_AML" ]] && rm -f "$DSDT_OVERRIDE_AML" && info "Removed $DSDT_OVERRIDE_AML"
if [[ "$INITRAMFS_TOOL" != "initramfs-tools" ]] && \
   [[ -d "$DSDT_OVERRIDE_DIR" ]] && \
   [[ -z "$(ls -A "$DSDT_OVERRIDE_DIR" 2>/dev/null)" ]]; then
    rmdir "$DSDT_OVERRIDE_DIR" && info "Removed empty directory $DSDT_OVERRIDE_DIR"
fi

step "Fan Step 2: Removing initramfs config"
if [[ "$INITRAMFS_TOOL" == "mkinitcpio" ]]; then
    [[ -n "$DSDT_MKINITCPIO_HOOK"    ]] && rm -f "$DSDT_MKINITCPIO_HOOK"    && info "Removed $DSDT_MKINITCPIO_HOOK"
    [[ -n "$DSDT_MKINITCPIO_INSTALL" ]] && rm -f "$DSDT_MKINITCPIO_INSTALL" && info "Removed $DSDT_MKINITCPIO_INSTALL"
    [[ -n "$DSDT_MKINITCPIO_CONF"    ]] && rm -f "$DSDT_MKINITCPIO_CONF"    && info "Removed $DSDT_MKINITCPIO_CONF"
elif [[ -n "$DSDT_DRACUT_CONF" ]] && [[ -f "$DSDT_DRACUT_CONF" ]]; then
    rm -f "$DSDT_DRACUT_CONF" && info "Removed $DSDT_DRACUT_CONF"
fi

step "Fan Step 3: Removing firmware DSDT hash"
rm -f /var/lib/samsung-galaxybook/dsdt-firmware.sha256 && info "Firmware DSDT hash removed"

step "Fan Step 4: Disabling fan monitor service"
systemctl disable "$FAN_MONITOR_SVC" 2>/dev/null || true
rm -f "/etc/systemd/system/${FAN_MONITOR_SVC}" && info "Removed monitor service" || true
rm -f "$FAN_CHECK_SCRIPT" && info "Removed $FAN_CHECK_SCRIPT" || true
rm -f "$FAN_CLEANUP"      && info "Removed $FAN_CLEANUP"      || true
systemctl daemon-reload 2>/dev/null || true

info "✓ Fan speed fix uninstalled — reboot required"
