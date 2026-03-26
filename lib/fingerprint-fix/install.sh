#!/bin/bash
# =============================================================================
# Samsung Galaxy Book — Fingerprint Fix (libfprint sdcp-v2) — Install
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
    local id="${ID,,}" like="${ID_LIKE:-}"; like="${like,,}"
    if [[ "$id" == "fedora" ]]; then DISTRO="fedora"
    elif [[ "$id" == "ubuntu" || "$like" == *"ubuntu"* || "$id" == "debian" || "$like" == *"debian"* ]]; then DISTRO="ubuntu"
    elif [[ "$id" == "arch" || "$like" == *"arch"* ]]; then DISTRO="arch"
    else error "Unsupported distro: $PRETTY_NAME"
    fi
}

# ── Install ───────────────────────────────────────────────────────────────────
detect_distro
KVER=$(uname -r)
HARDWARE_USB_ID=""
# Detect USB ID for fingerprint sensor
SENSOR_RAW=$(lsusb 2>/dev/null | grep -iE "1c7a:05a5|1c7a:05a1" || true)
[[ "$SENSOR_RAW" == *"1c7a:05a5"* ]] && HARDWARE_USB_ID="1c7a:05a5"
[[ "$SENSOR_RAW" == *"1c7a:05a1"* ]] && HARDWARE_USB_ID="${HARDWARE_USB_ID:+$HARDWARE_USB_ID|}1c7a:05a1"
[[ -z "$HARDWARE_USB_ID" ]] && HARDWARE_USB_ID="1c7a:05a5|1c7a:05a1"

FPRINT_MARKER="/etc/samsung-galaxybook-libfprint-sdcp-v2.installed"
FPRINT_HASH_FILE="/var/lib/samsung-galaxybook/libfprint.sha256"
FPRINT_MONITOR_SVC="samsung-galaxybook-fprint-monitor.service"
FPRINT_CHECK_SCRIPT="/usr/local/bin/samsung-galaxybook-fprint-monitor.sh"
FPRINT_LIBFPRINT_CLEANUP="/usr/local/bin/samsung-galaxybook-libfprint-cleanup.sh"
FPRINT_CLONE_DIR="/tmp/libfprint-sdcp-v2"

echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Installing: Fingerprint Fix (sdcp-v2)            ║"
echo "╚════════════════════════════════════════════════════════════╝"

step "Fingerprint Step 0: Checking sensor is present"
SENSOR_ON_BUS=$(lsusb 2>/dev/null | grep -iE "1c7a:05a5|1c7a:05a1" || true)
[[ -z "$SENSOR_ON_BUS" ]] && \
    error "EgisTec SDCP fingerprint sensor not found on USB bus.\nExpected: 1c7a:05a5 (Galaxy Book 5) or 1c7a:05a1 (Galaxy Book 4)\nRun 'lsusb' to check what USB devices are present."
info "✓ Sensor found: $SENSOR_ON_BUS"

step "Fingerprint Step 1: Installing dependencies"
if [[ "$DISTRO" == "fedora" ]]; then
    dnf install -y \
        meson cmake libgusb-devel cairo-devel gobject-introspection-devel \
        nss-devel libgudev-devel openssl-devel systemd-devel \
        fprintd libfprint fprintd-pam git libnotify \
        || error "dnf install failed"
elif [[ "$DISTRO" == "arch" ]]; then
    pacman -S --noconfirm --needed \
        meson cmake libgusb cairo gobject-introspection nss libgudev \
        openssl systemd fprintd libfprint git libnotify glib2 \
        || error "pacman install failed"
else
    apt-get update -q
    apt-get install -y \
        meson cmake libgusb-dev libcairo2-dev libgirepository1.0-dev \
        libnss3-dev libgudev-1.0-dev libssl-dev libsystemd-dev \
        fprintd libfprint-2-2 libpam-fprintd git libnotify-bin \
        || error "apt-get install failed"
fi
info "Dependencies installed"

step "Fingerprint Step 2: Cloning libfprint (feature/sdcp-v2)"
rm -rf "$FPRINT_CLONE_DIR"
git clone --depth=1 --branch feature/sdcp-v2 \
    https://gitlab.freedesktop.org/libfprint/libfprint.git "$FPRINT_CLONE_DIR" \
    || error "git clone failed.\n  Check your network connection and that the branch still exists:\n  https://gitlab.freedesktop.org/libfprint/libfprint/-/branches\n  If 'feature/sdcp-v2' has been merged or renamed, this fix may no longer be needed\n  — try installing the system libfprint package instead."
FPRINT_COMMIT=$(git -C "$FPRINT_CLONE_DIR" rev-parse --short HEAD)
info "Cloned at commit $FPRINT_COMMIT"

step "Fingerprint Step 3: Building libfprint"
cd "$FPRINT_CLONE_DIR"
meson setup builddir --prefix=/usr --buildtype=release -Ddoc=false \
    || error "meson setup failed"
ninja -C builddir || error "ninja build failed"
info "Build complete"

step "Fingerprint Step 4: Installing libfprint"
ninja -C builddir install || error "ninja install failed"
ldconfig
info "libfprint installed and ldconfig updated"
rm -rf "$FPRINT_CLONE_DIR"
info "Build directory cleaned up"

step "Fingerprint Step 5: Storing library hash for change detection"
FPRINT_LIB=$(ldconfig -p | grep 'libfprint-2\.so\b' | awk '{print $NF}' | head -1)
[[ -z "$FPRINT_LIB" ]] && error "Cannot locate installed libfprint-2.so via ldconfig"
mkdir -p /var/lib/samsung-galaxybook
sha256sum "$FPRINT_LIB" | awk '{print $1}' > "$FPRINT_HASH_FILE"
chmod 644 "$FPRINT_HASH_FILE"
info "Hash stored: $(cat "$FPRINT_HASH_FILE")"

step "Fingerprint Step 6: Enabling fingerprint authentication"
if [[ "$DISTRO" == "fedora" ]]; then
    authselect enable-feature with-fingerprint \
        && info "✓ Fingerprint auth enabled via authselect" \
        || warn "authselect failed — run 'sudo authselect enable-feature with-fingerprint' manually"
elif [[ "$DISTRO" == "arch" ]]; then
    info "Arch: PAM configuration will be shown in the post-install instructions"
else
    cat > /usr/share/pam-configs/samsung-galaxybook-fingerprint << 'PAMEOF'
Name: Samsung Galaxy Book fingerprint authentication
Default: yes
Priority: 900
Auth-Type: Primary
Auth:
    [success=end default=ignore]    pam_fprintd.so max-tries=3 timeout=10
PAMEOF
    if DEBIAN_FRONTEND=noninteractive pam-auth-update --force --package 2>/dev/null; then
        info "✓ PAM fingerprint profile installed and activated"
    else
        warn "pam-auth-update failed — fingerprint PAM profile written but not activated"
        warn "Run manually after reboot: sudo pam-auth-update"
    fi
fi

step "Fingerprint Step 7: Clearing stale fingerprint data"
if [[ -d /var/lib/fprint ]] && [[ -n "$(ls -A /var/lib/fprint 2>/dev/null)" ]]; then
    warn "Removing stale enrollment data from /var/lib/fprint"
    rm -rf /var/lib/fprint/*
    info "Cleared — all users will need to re-enroll fingerprints after reboot"
fi

step "Fingerprint Step 8: Writing fingerprint marker"
echo "${FPRINT_COMMIT} (installed $(date '+%Y-%m-%d'))" > "$FPRINT_MARKER"

step "Fingerprint Step 9: Installing fingerprint monitor service"
cat > "$FPRINT_LIBFPRINT_CLEANUP" << CLEANEOF
#!/bin/bash
# Samsung Galaxy Book — remove libfprint fix (runs as root)
rm -f "${FPRINT_HASH_FILE}"
rm -f "${FPRINT_MARKER}"
systemctl disable ${FPRINT_MONITOR_SVC} 2>/dev/null || true
rm -f /etc/systemd/system/${FPRINT_MONITOR_SVC}
systemctl daemon-reload 2>/dev/null || true
rm -f ${FPRINT_CHECK_SCRIPT}
rm -f ${FPRINT_LIBFPRINT_CLEANUP}
CLEANEOF
chmod 750 "$FPRINT_LIBFPRINT_CLEANUP"

cat > "$FPRINT_CHECK_SCRIPT" << 'FPRNTCHECKEOF'
#!/bin/bash
# Samsung Galaxy Book — libfprint fix monitor (system service, runs as root)
FPRINT_HASH_FILE="/var/lib/samsung-galaxybook/libfprint.sha256"
FPRINT_MARKER="/etc/samsung-galaxybook-libfprint-sdcp-v2.installed"
FPRINT_LIBFPRINT_CLEANUP="/usr/local/bin/samsung-galaxybook-libfprint-cleanup.sh"
HARDWARE_USB_ID="__HARDWARE_USB_ID__"

notify_user() {
    local title="$1" msg="$2" type="$3"
    local urgency="normal"
    [[ "$type" != "info" ]] && urgency="critical"
    local USER_NAME USER_ID
    USER_NAME=$(loginctl list-sessions --no-legend 2>/dev/null \
        | awk '$4 == "seat0" {print $3}' | head -1)
    USER_ID=$(id -u "$USER_NAME" 2>/dev/null)
    if [[ -n "$USER_ID" ]]; then
        local QDBUS=""
        if pgrep -u "$USER_NAME" plasmashell >/dev/null 2>&1; then
            command -v qdbus-qt6 &>/dev/null && QDBUS="qdbus-qt6"
            [[ -z "$QDBUS" ]] && command -v qdbus6 &>/dev/null && QDBUS="qdbus6"
        fi
        if [[ -n "$QDBUS" ]]; then
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_ID}/bus" \
                "$QDBUS" org.kde.plasmashell /org/kde/osdService \
                org.kde.osdService.showText "dialog-information" "$title: $msg" 2>/dev/null || true
        else
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_ID}/bus" \
                notify-send --urgency="$urgency" "$title" "$msg" 2>/dev/null || true
        fi
    else
        logger -t samsung-galaxybook-monitor "$title: $msg"
    fi
}

if [[ -f "$FPRINT_HASH_FILE" ]] && [[ -f "$FPRINT_MARKER" ]]; then
    FPRINT_LIB=$(ldconfig -p | grep 'libfprint-2\.so\b' | awk '{print $NF}' | head -1)
    if [[ -n "$FPRINT_LIB" ]]; then
        CURRENT_HASH=$(sha256sum "$FPRINT_LIB" | awk '{print $1}')
        STORED_HASH=$(cat "$FPRINT_HASH_FILE")
        if [[ "$CURRENT_HASH" != "$STORED_HASH" ]]; then
            sleep 5
            systemctl start fprintd 2>/dev/null || true
            sleep 2
            SENSOR_ON_BUS=$(lsusb 2>/dev/null | grep -Ei "$HARDWARE_USB_ID" || true)
            if [[ -n "$SENSOR_ON_BUS" ]]; then
                FPRINTD_DEVICES=$(gdbus call --system \
                    --dest net.reactivated.Fprint \
                    --object-path /net/reactivated/Fprint/Manager \
                    --method net.reactivated.Fprint.Manager.GetDevices 2>/dev/null || echo "")
                if echo "$FPRINTD_DEVICES" | grep -q "Fprint/Device"; then
                    notify_user "Samsung Galaxy Book — Fingerprint" \
                        "The system libfprint now supports your fingerprint sensor natively. The fix has been removed. You may need to re-enroll your fingerprints." "info"
                    "$FPRINT_LIBFPRINT_CLEANUP"
                else
                    notify_user "Samsung Galaxy Book — Fingerprint Fix Overwritten" \
                        "A system update has overwritten the libfprint fix. Sensor $HARDWARE_USB_ID is no longer working. Re-run the fingerprint fix installer." "warn"
                    echo "$CURRENT_HASH" > "$FPRINT_HASH_FILE"
                fi
            fi
        fi
    fi
fi
FPRNTCHECKEOF
chmod +x "$FPRINT_CHECK_SCRIPT"
sed -i "s|__HARDWARE_USB_ID__|${HARDWARE_USB_ID}|g" "$FPRINT_CHECK_SCRIPT"

cat > "/etc/systemd/system/${FPRINT_MONITOR_SVC}" << SVCEOF
[Unit]
Description=Samsung Galaxy Book — libfprint fix monitor
After=multi-user.target

[Service]
Type=oneshot
ExecStart=${FPRINT_CHECK_SCRIPT}
RemainAfterExit=no
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable "${FPRINT_MONITOR_SVC}" \
    && info "✓ Fingerprint monitor service enabled" \
    || warn "systemctl enable failed for ${FPRINT_MONITOR_SVC}"

info "✓ Fingerprint fix installed"
