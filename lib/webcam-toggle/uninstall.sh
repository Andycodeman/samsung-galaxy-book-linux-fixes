#!/bin/bash
# =============================================================================
# Samsung Galaxy Book — Webcam Toggle — Uninstall
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

WEBCAM_TOGGLE="/usr/local/bin/webcam-toggle.sh"
WEBCAM_UDEV="/etc/udev/rules.d/70-galaxybook-camera.rules"
WEBCAM_SUDOERS="/etc/sudoers.d/webcam-toggle"
WEBCAM_SERVICE="/etc/systemd/system/webcam-reset.service"
WEBCAM_STATE="/tmp/webcam-blocked"

# ── Sensor detection — base Book 5 uses OV02C10, Pro uses OV02E10 ─────────────
if cat /sys/bus/acpi/devices/*/hid 2>/dev/null | grep -q "OVTI02E1"; then
    WEBCAM_DRIVER="/sys/bus/i2c/drivers/ov02e10"
    WEBCAM_DEVICE="i2c-OVTI02E1:00"
else
    WEBCAM_DRIVER="/sys/bus/i2c/drivers/ov02c10"
    WEBCAM_DEVICE="i2c-OVTI02C1:00"
fi

echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Uninstalling: Webcam Toggle                      ║"
echo "╚════════════════════════════════════════════════════════════╝"

step "Webcam Step 1: Ensuring camera is unblocked"
if [[ -f "$WEBCAM_STATE" ]]; then
    warn "Camera is currently blocked — rebinding driver..."
    if [[ -d "$WEBCAM_DRIVER" ]] && [[ ! -e "$WEBCAM_DRIVER/$WEBCAM_DEVICE" ]]; then
        echo "$WEBCAM_DEVICE" > "$WEBCAM_DRIVER/bind" \
            && info "✓ Camera driver rebound" \
            || warn "Could not rebind — reboot may be required"
    fi
    rm -f "$WEBCAM_STATE"
else
    info "Camera is already unblocked"
fi

step "Webcam Step 2: Disabling camera-relay persistent mode"
CAMERA_RELAY_USER=$(loginctl list-sessions --no-legend 2>/dev/null \
    | awk '$4 == "seat0" {print $3}' | head -1)
CAMERA_RELAY_UID=$(id -u "$CAMERA_RELAY_USER" 2>/dev/null)
CAMERA_RELAY_DBUS="unix:path=/run/user/${CAMERA_RELAY_UID}/bus"
if [[ -n "$CAMERA_RELAY_USER" ]] && [[ -x "/usr/local/bin/camera-relay" ]]; then
    sudo -u "$CAMERA_RELAY_USER" \
        XDG_RUNTIME_DIR="/run/user/${CAMERA_RELAY_UID}" \
        DBUS_SESSION_BUS_ADDRESS="$CAMERA_RELAY_DBUS" \
        /usr/local/bin/camera-relay disable-persistent 2>/dev/null || true
    info "camera-relay persistent mode disabled"
fi

step "Webcam Step 3: Disabling boot service"
systemctl is-enabled webcam-reset.service &>/dev/null && \
    systemctl disable webcam-reset.service && info "webcam-reset.service disabled" || true
[[ -f "$WEBCAM_SERVICE" ]] && rm "$WEBCAM_SERVICE" && info "Service file removed"
systemctl daemon-reload && info "systemd daemon reloaded"

step "Webcam Step 4: Removing udev rule"
[[ -f "$WEBCAM_UDEV" ]] && rm "$WEBCAM_UDEV" && info "Removed $WEBCAM_UDEV" || true
udevadm control --reload-rules
udevadm trigger --subsystem-match=i2c
info "udev rules reloaded"

step "Webcam Step 5: Removing sudoers file"
[[ -f "$WEBCAM_SUDOERS" ]] && rm "$WEBCAM_SUDOERS" && info "Removed $WEBCAM_SUDOERS" || true

step "Webcam Step 6: Removing toggle script"
[[ -f "$WEBCAM_TOGGLE" ]] && rm "$WEBCAM_TOGGLE" && info "Removed $WEBCAM_TOGGLE" || true

step "Webcam Step 7: Re-enabling camera-relay persistent mode"
_cr_user=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 == "seat0" {print $3}' | head -1)
_cr_uid=$(id -u "$_cr_user" 2>/dev/null)
_cr_dbus="unix:path=/run/user/${_cr_uid}/bus"
if [[ -n "$_cr_user" ]] && [[ -x "/usr/local/bin/camera-relay" ]]; then
    sudo -u "$_cr_user" XDG_RUNTIME_DIR="/run/user/${_cr_uid}" \
        DBUS_SESSION_BUS_ADDRESS="$_cr_dbus" \
        /usr/local/bin/camera-relay enable-persistent --yes \
        && info "✓ camera-relay persistent mode re-enabled" \
        || warn "Could not re-enable camera-relay — run manually if needed"
else
    info "camera-relay not installed — skipping"
fi

info "✓ Webcam toggle uninstalled"
