#!/bin/bash
# =============================================================================
# Samsung Galaxy Book — Webcam Toggle — Install
# =============================================================================
# Self-contained. Run as root: sudo bash install.sh
# =============================================================================

set -e

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Please run as root: sudo bash install.sh"
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
    local id="${ID,,}" like="${ID_LIKE:-}"
    like="${like,,}"
    if [[ "$id" == "fedora" ]]; then DISTRO="fedora"
    elif [[ "$id" == "ubuntu" || "$like" == *"ubuntu"* || "$id" == "debian" || "$like" == *"debian"* ]]; then DISTRO="ubuntu"
    elif [[ "$id" == "arch" || "$like" == *"arch"* ]]; then DISTRO="arch"
    else error "Unsupported distro: $PRETTY_NAME"
    fi
}

# ── Install ───────────────────────────────────────────────────────────────────
detect_distro

WEBCAM_TOGGLE="/usr/local/bin/webcam-toggle.sh"
WEBCAM_UDEV="/etc/udev/rules.d/70-galaxybook-camera.rules"
WEBCAM_SUDOERS="/etc/sudoers.d/webcam-toggle"
WEBCAM_STATE="/tmp/webcam-blocked"

# ── Sensor detection — base Book 5 uses OV02C10, Pro uses OV02E10 ─────────────
# Detected from ACPI — works regardless of which driver is loaded at install time.
# The GUI + galaxybook.json ensure this only runs on Book 5 models.
if cat /sys/bus/acpi/devices/*/hid 2>/dev/null | grep -q "OVTI02E1"; then
    WEBCAM_DRIVER="/sys/bus/i2c/drivers/ov02e10"
    WEBCAM_DEVICE="i2c-OVTI02E1:00"
    WEBCAM_LED="/sys/class/leds/OVTI02E1_00::privacy_led/brightness"
else
    # Base Book 5 models with OV02C10 sensor
    WEBCAM_DRIVER="/sys/bus/i2c/drivers/ov02c10"
    WEBCAM_DEVICE="i2c-OVTI02C1:00"
    WEBCAM_LED="/sys/class/leds/OVTI02C1_00::privacy_led/brightness"
fi

echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              Installing: Webcam Toggle                     ║"
echo "╚════════════════════════════════════════════════════════════╝"

step "Webcam Step 1: Disabling camera-relay persistent mode"
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
else
    info "No active seat0 session found or camera-relay not installed — skipping"
fi

if [[ "$HARDWARE_SERIES" == "book5" ]]; then
    step "Webcam Step 2: Checking minimum kernel for IPU7 camera (Galaxy Book 5)"
    KW_MAJ=$(uname -r | cut -d. -f1)
    KW_MIN=$(uname -r | cut -d. -f2)
    if [[ "$KW_MAJ" -lt 6 ]] || { [[ "$KW_MAJ" -eq 6 ]] && [[ "$KW_MIN" -lt 17 ]]; }; then
        error "Webcam toggle on the Galaxy Book 5 requires kernel 6.17 or newer.\nYour running kernel is $(uname -r). Please update and try again."
    fi
    info "✓ Kernel $(uname -r) meets the IPU7 minimum requirement (6.17)"

    if [[ "$DISTRO" == "ubuntu" ]]; then
        step "Webcam Step 2b: Installing IPU7 kernel modules (Ubuntu/Debian)"
        IPU7_PKG="linux-modules-ipu7-$(uname -r)"
        IPU7_USBIO_PKG="linux-modules-ipu7-usbio-$(uname -r)"
        PKGS_TO_INSTALL=""
        dpkg -l "$IPU7_PKG"       &>/dev/null || PKGS_TO_INSTALL="$PKGS_TO_INSTALL $IPU7_PKG"
        dpkg -l "$IPU7_USBIO_PKG" &>/dev/null || PKGS_TO_INSTALL="$PKGS_TO_INSTALL $IPU7_USBIO_PKG"
        if [[ -n "$PKGS_TO_INSTALL" ]]; then
            info "Installing IPU7 packages:$PKGS_TO_INSTALL"
            apt-get install -y $PKGS_TO_INSTALL \
                || warn "Failed to install IPU7 packages — webcam driver may not load."
        else
            info "✓ IPU7 kernel modules already installed"
        fi
    fi
fi

step "Webcam Step 3: Checking hardware"
[[ -d "$WEBCAM_DRIVER" ]] \
    || error "Camera sensor driver not found at $WEBCAM_DRIVER — is the camera driver loaded?"
[[ -e "$WEBCAM_DRIVER/$WEBCAM_DEVICE" ]] \
    || error "Camera device $WEBCAM_DEVICE not found under $WEBCAM_DRIVER"
[[ -e "$WEBCAM_LED" ]] \
    && info "✓ Privacy LED found" \
    || error "Privacy LED not found at $WEBCAM_LED — required for in-use detection"
info "✓ Camera sensor driver (${WEBCAM_DRIVER##*/}) and device found"

step "Webcam Step 4: Checking notification dependencies"
if command -v qdbus-qt6 &>/dev/null; then
    info "✓ qdbus-qt6 found — KDE OSD notifications will be used"
elif command -v qdbus6 &>/dev/null; then
    info "✓ qdbus6 found — KDE OSD notifications will be used"
elif command -v notify-send &>/dev/null; then
    warn "qdbus not found — falling back to notify-send"
else
    warn "No notification tool found — notifications will be silent"
fi

step "Webcam Step 5: Ensuring webcam starts unblocked"
if [[ ! -e "$WEBCAM_DRIVER/$WEBCAM_DEVICE" ]]; then
    warn "Camera currently unbound — rebinding..."
    echo "$WEBCAM_DEVICE" > "$WEBCAM_DRIVER/bind" && info "Camera rebound" || warn "Rebind failed"
fi
rm -f "$WEBCAM_STATE"
info "State file cleared"

step "Webcam Step 6: Creating toggle script"
cat > "$WEBCAM_TOGGLE" << 'TOGGLEEOF'
#!/bin/bash
# Samsung Galaxy Book — Hardware Webcam Toggle
DRIVER="__WEBCAM_DRIVER__"
DEVICE="__WEBCAM_DEVICE__"
STATE_FILE="/tmp/webcam-blocked"
LOCK_FILE="/tmp/webcam-toggle.lock"
PRIVACY_LED="__WEBCAM_LED__"

# Prevent concurrent runs — exit silently if already running
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    exit 0
fi
trap 'rm -rf "$LOCK_FILE"' EXIT

USER_NAME=$(loginctl list-sessions --no-legend | awk '$4 == "seat0" {print $3}' | head -1)
USER_ID=$(id -u "$USER_NAME" 2>/dev/null)
DBUS_ADDR="unix:path=/run/user/${USER_ID}/bus"

notify() {
    local icon="$1" text="$2" QDBUS=""
    if pgrep -u "$USER_NAME" plasmashell >/dev/null 2>&1; then
        command -v qdbus-qt6 &>/dev/null && QDBUS="qdbus-qt6"
        [[ -z "$QDBUS" ]] && command -v qdbus6 &>/dev/null && QDBUS="qdbus6"
    fi
    if [[ -n "$QDBUS" ]]; then
        sudo -u "$USER_NAME" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
            "$QDBUS" org.kde.plasmashell /org/kde/osdService \
            org.kde.osdService.showText "$icon" "$text" 2>/dev/null || true
    else
        sudo -u "$USER_NAME" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
            notify-send --icon="$icon" --urgency=low "Webcam" "$text" 2>/dev/null || true
    fi
}

stop_services() {
    if [[ -x "/usr/local/bin/camera-relay" ]]; then
        sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/${USER_ID}" \
            DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
            /usr/local/bin/camera-relay disable-persistent 2>/dev/null || true
    fi
}

start_services() {
    if [[ -x "/usr/local/bin/camera-relay" ]]; then
        sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/${USER_ID}" \
            DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
            /usr/local/bin/camera-relay enable-persistent --yes 2>/dev/null || true
    fi
}

if [[ -f "$STATE_FILE" ]]; then
    stop_services
    start_services
    if echo "$DEVICE" > "$DRIVER/bind" 2>/dev/null; then
        rm -f "$STATE_FILE"; notify "camera-web" "Camera enabled"
    else
        notify "dialog-error" "Failed to enable camera"; exit 1
    fi
else
    LED_STATE=$(cat "$PRIVACY_LED" 2>/dev/null || echo "0")
    if [[ "$LED_STATE" == "1" ]]; then
        notify "camera-web" "Cannot disable. Camera is in use."
    else
        notify "camera-web" "Camera disabled"
        stop_services
        if echo "$DEVICE" > "$DRIVER/unbind" 2>/dev/null; then
            touch "$STATE_FILE"
        else
            notify "dialog-error" "Failed to disable camera"; start_services; exit 1
        fi
    fi
fi
TOGGLEEOF

# Bake in the correct paths
sed -i \
    -e "s|__WEBCAM_DRIVER__|${WEBCAM_DRIVER}|g" \
    -e "s|__WEBCAM_DEVICE__|${WEBCAM_DEVICE}|g" \
    -e "s|__WEBCAM_LED__|${WEBCAM_LED}|g" \
    "$WEBCAM_TOGGLE"
chmod +x "$WEBCAM_TOGGLE"
info "Toggle script created (sensor: ${WEBCAM_DRIVER##*/})"

step "Webcam Step 7: Creating udev rule"
cat > "$WEBCAM_UDEV" << UDEVEOF
# Samsung Galaxy Book — allow userspace to bind/unbind camera sensor driver
SUBSYSTEM=="i2c", KERNEL=="${WEBCAM_DEVICE}", \
    RUN+="/bin/chmod 0222 ${WEBCAM_DRIVER}/bind ${WEBCAM_DRIVER}/unbind"
UDEVEOF
udevadm control --reload-rules
udevadm trigger --subsystem-match=i2c
info "udev rule created and loaded"
sleep 1
if [[ -w "$WEBCAM_DRIVER/unbind" ]]; then
    info "✓ bind/unbind are writable without sudo"
else
    warn "bind/unbind not yet writable — adding sudoers fallback"
    WEBCAM_SUDOERS_GROUP="%wheel"
    [[ "$DISTRO" == "ubuntu" ]] && WEBCAM_SUDOERS_GROUP="%sudo"
    echo "${WEBCAM_SUDOERS_GROUP} ALL=(root) NOPASSWD: $WEBCAM_TOGGLE" > "$WEBCAM_SUDOERS"
    chmod 0440 "$WEBCAM_SUDOERS"
fi

step "Webcam Step 8: Creating boot service"
cat > /etc/systemd/system/webcam-reset.service << SVCEOF
[Unit]
Description=Reset webcam to unblocked state on boot
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'rm -f ${WEBCAM_STATE}; \
    if [ ! -e ${WEBCAM_DRIVER}/${WEBCAM_DEVICE} ]; then \
        echo ${WEBCAM_DEVICE} > ${WEBCAM_DRIVER}/bind; \
    fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable webcam-reset.service
info "webcam-reset.service enabled"

step "Webcam Step 9: Enabling camera-relay (if installed)"
_cr_user=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 == "seat0" {print $3}' | head -1)
_cr_uid=$(id -u "$_cr_user" 2>/dev/null)
_cr_dbus="unix:path=/run/user/${_cr_uid}/bus"
if [[ -n "$_cr_user" ]] && [[ -x "/usr/local/bin/camera-relay" ]]; then
    sudo -u "$_cr_user" XDG_RUNTIME_DIR="/run/user/${_cr_uid}" \
        DBUS_SESSION_BUS_ADDRESS="$_cr_dbus" \
        /usr/local/bin/camera-relay enable-persistent --yes \
        && info "✓ camera-relay enabled" \
        || warn "Could not enable camera-relay"
else
    info "camera-relay not installed — skipping"
fi

info "✓ Webcam toggle installed"
