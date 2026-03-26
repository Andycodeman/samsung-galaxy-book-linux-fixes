#!/bin/bash
# =============================================================================
# Samsung Galaxy Book — Fingerprint Fix (libfprint sdcp-v2) — Uninstall
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

# ── Distro detection ──────────────────────────────────────────────────────────
detect_distro() {
    [[ -f /etc/os-release ]] || error "Cannot detect distro — /etc/os-release not found"
    source /etc/os-release
    local id="${ID,,}" like="${ID_LIKE:-}"; like="${like,,}"
    if [[ "$id" == "fedora" ]]; then DISTRO="fedora"
    elif [[ "$id" == "ubuntu" || "$like" == *"ubuntu"* || "$id" == "debian" || "$like" == *"debian"* ]]; then DISTRO="ubuntu"
    elif [[ "$id" == "arch" || "$like" == *"arch"* ]]; then DISTRO="arch"
    else error "Unsupported distro: $PRETTY_NAME"
    fi
}

detect_distro

FPRINT_MARKER="/etc/samsung-galaxybook-libfprint-sdcp-v2.installed"
FPRINT_HASH_FILE="/var/lib/samsung-galaxybook/libfprint.sha256"
FPRINT_MONITOR_SVC="samsung-galaxybook-fprint-monitor.service"
FPRINT_CHECK_SCRIPT="/usr/local/bin/samsung-galaxybook-fprint-monitor.sh"
FPRINT_LIBFPRINT_CLEANUP="/usr/local/bin/samsung-galaxybook-libfprint-cleanup.sh"

echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Uninstalling: Fingerprint Fix                    ║"
echo "╚════════════════════════════════════════════════════════════╝"

step "Fingerprint Step 1: Disabling fingerprint monitor service"
systemctl disable "$FPRINT_MONITOR_SVC" 2>/dev/null || true
rm -f "/etc/systemd/system/${FPRINT_MONITOR_SVC}" && info "Removed monitor service" || true
systemctl daemon-reload 2>/dev/null || true

step "Fingerprint Step 2: Removing monitor script and cleanup helper"
rm -f "$FPRINT_CHECK_SCRIPT"      && info "Removed $FPRINT_CHECK_SCRIPT"      || true
rm -f "$FPRINT_LIBFPRINT_CLEANUP" && info "Removed $FPRINT_LIBFPRINT_CLEANUP" || true

step "Fingerprint Step 3: Removing state files"
rm -f "$FPRINT_MARKER"    && info "Removed installation marker"
rm -f "$FPRINT_HASH_FILE" && info "Removed libfprint hash file"
if [[ -f /usr/share/pam-configs/samsung-galaxybook-fingerprint ]]; then
    rm -f /usr/share/pam-configs/samsung-galaxybook-fingerprint
    DEBIAN_FRONTEND=noninteractive pam-auth-update --force --package 2>/dev/null || true
    info "Removed fingerprint PAM profile"
fi
if [[ -d /var/lib/samsung-galaxybook ]] && \
   [[ -z "$(ls -A /var/lib/samsung-galaxybook 2>/dev/null)" ]]; then
    rmdir /var/lib/samsung-galaxybook && info "Removed empty /var/lib/samsung-galaxybook"
fi

step "Fingerprint Step 4: Reinstalling system libfprint"
if [[ "$DISTRO" == "fedora" ]]; then
    dnf reinstall -y libfprint && info "System libfprint reinstalled" \
        || warn "dnf reinstall failed — run 'sudo dnf reinstall libfprint' manually"
elif [[ "$DISTRO" == "arch" ]]; then
    pacman -S --noconfirm libfprint && info "System libfprint reinstalled" \
        || warn "pacman install failed — run 'sudo pacman -S libfprint' manually"
else
    apt-get install -y --reinstall libfprint-2-2 && info "System libfprint reinstalled" \
        || warn "apt reinstall failed — run 'sudo apt install --reinstall libfprint-2-2' manually"
fi
ldconfig && info "ldconfig updated"

step "Fingerprint Step 5: Clearing enrolled fingerprints"
if [[ -d /var/lib/fprint ]] && [[ -n "$(ls -A /var/lib/fprint 2>/dev/null)" ]]; then
    rm -rf /var/lib/fprint/* && info "Cleared /var/lib/fprint — fingerprints removed"
else
    info "No enrolled fingerprints to remove"
fi

info "✓ Fingerprint fix uninstalled"
