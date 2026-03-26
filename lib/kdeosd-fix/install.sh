#!/bin/bash
# =============================================================================
# Samsung Galaxy Book — KDE Power Profile OSD — Install
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

# ── Install ───────────────────────────────────────────────────────────────────
OSD_SCRIPT="/usr/local/sbin/kde-power-osd.sh"
OSD_SERVICE="/etc/systemd/system/kde-power-osd.service"
MARKER_FILE="/var/lib/samsung-galaxybook/kde-power-osd.installed"

echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Installing: KDE Power Profile OSD                ║"
echo "╚════════════════════════════════════════════════════════════╝"

step "Checking dependencies"
if ! command -v dbus-monitor &>/dev/null; then
    step "Installing dbus-tools (required for D-Bus monitoring)..."
    if command -v dnf &>/dev/null; then
        dnf install -y dbus-tools || error "Failed to install dbus-tools"
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm --needed dbus || error "Failed to install dbus"
    elif command -v apt-get &>/dev/null; then
        apt-get install -y dbus-x11 || error "Failed to install dbus-x11"
    else
        error "dbus-monitor not found and package manager unknown.\n  Install dbus-tools (Fedora), dbus (Arch), or dbus-x11 (Debian/Ubuntu)."
    fi
fi

command -v busctl &>/dev/null || error "busctl not found — this is part of systemd and should always be present."

if ! busctl status net.hadess.PowerProfiles &>/dev/null; then
    warn "net.hadess.PowerProfiles D-Bus interface not found."
    warn "power-profiles-daemon or tuned-ppd may not be running."
    info "Installing anyway — the service will start cleanly once the daemon is running."
fi

if command -v qdbus-qt6 &>/dev/null; then
    info "Notification method: qdbus-qt6 (KDE Plasma 6 OSD)"
elif command -v qdbus6 &>/dev/null; then
    info "Notification method: qdbus6 (KDE Plasma 6 OSD)"
elif command -v qdbus &>/dev/null; then
    info "Notification method: qdbus (KDE Plasma 5 OSD)"
elif command -v notify-send &>/dev/null; then
    warn "Notification method: notify-send (fallback — install qt6-tools for native KDE OSD)"
else
    warn "Neither qdbus nor notify-send found — notifications will be silent until one is installed."
fi

step "Writing OSD script"
cat > "$OSD_SCRIPT" << 'EOF_OSD_SCRIPT'
#!/bin/bash
# =============================================================================
# KDE Power Profile OSD
# Shows an on-screen notification when the power profile changes.
# Installed to: /usr/local/sbin/kde-power-osd.sh
# Managed by:   kde-power-osd.service (system service, runs as root)
# =============================================================================

_desktop=$(loginctl list-sessions --no-legend \
    | awk '$4 == "seat0" {print $3}' | head -1 \
    | xargs -I{} bash -c 'XDG_RUNTIME_DIR=/run/user/$(id -u {}) \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u {})/bus \
        sudo -u {} env XDG_CURRENT_DESKTOP 2>/dev/null' 2>/dev/null || true)

if [[ "${_desktop,,}" != *"kde"* ]] && [[ "${_desktop,,}" != *"plasma"* ]]; then
    _user=$(loginctl list-sessions --no-legend | awk '$4 == "seat0" {print $3}' | head -1)
    if [[ -n "$_user" ]]; then
        _uid=$(id -u "$_user" 2>/dev/null)
        _session_desktop=$(cat /proc/$(pgrep -u "$_uid" plasmashell 2>/dev/null | head -1)/environ \
            2>/dev/null | tr '\0' '\n' | grep '^XDG_CURRENT_DESKTOP=' | cut -d= -f2 || true)
        if [[ "${_session_desktop,,}" != *"kde"* ]] && [[ "${_session_desktop,,}" != *"plasma"* ]]; then
            if ! pgrep -u "$_uid" plasmashell &>/dev/null; then
                echo "kde-power-osd: KDE Plasma not detected — exiting"
                exit 0
            fi
        fi
    fi
fi

show_osd() {
    local ICON="$1" TEXT="$2"
    local USER_NAME USER_ID DBUS_ADDR _qdbus_cmd
    USER_NAME=$(loginctl list-sessions --no-legend | awk '$4 == "seat0" {print $3}' | head -1)
    [ -z "$USER_NAME" ] && return
    USER_ID=$(id -u "$USER_NAME" 2>/dev/null)
    DBUS_ADDR="unix:path=/run/user/${USER_ID}/bus"
    for _candidate in /usr/bin/qdbus-qt6 /usr/lib/qt6/bin/qdbus /usr/bin/qdbus6 /usr/bin/qdbus; do
        if [[ -x "$_candidate" ]]; then _qdbus_cmd="$_candidate"; break; fi
    done
    if [[ -n "$_qdbus_cmd" ]]; then
        sudo -u "$USER_NAME" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
            "$_qdbus_cmd" org.kde.plasmashell /org/kde/osdService \
            org.kde.osdService.showText "$ICON" "$TEXT" 2>/dev/null || \
        sudo -u "$USER_NAME" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
            notify-send --icon="$ICON" "Power Profile" "$TEXT" 2>/dev/null || true
    else
        sudo -u "$USER_NAME" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
            notify-send --icon="$ICON" "Power Profile" "$TEXT" 2>/dev/null || true
    fi
}

dbus-monitor --system \
    "type='signal',interface='org.freedesktop.DBus.Properties',path='/net/hadess/PowerProfiles'" | \
grep --line-buffered "ActiveProfile" | \
while read -r line; do
    sleep 0.1
    PROFILE=$(busctl get-property net.hadess.PowerProfiles \
        /net/hadess/PowerProfiles net.hadess.PowerProfiles ActiveProfile \
        2>/dev/null | awk -F'"' '{print $2}')
    case "$PROFILE" in
        performance) show_osd "battery-profile-performance" "Performance Mode" ;;
        power-saver)  show_osd "battery-profile-powersave"  "Power Saver Mode" ;;
        *)            show_osd "battery-profile-balanced"   "Balanced Mode"    ;;
    esac
done
EOF_OSD_SCRIPT
chmod 755 "$OSD_SCRIPT"
info "Written $OSD_SCRIPT"

step "Writing systemd service"
cat > "$OSD_SERVICE" << 'EOF_OSD_SERVICE'
[Unit]
Description=KDE Power Profile OSD — show notification when power profile changes
Documentation=https://github.com/galaxy-book-linux/samsung-galaxybook5-fixes
After=graphical-session.target dbus.service
ConditionPathExists=/usr/local/sbin/kde-power-osd.sh

[Service]
Type=simple
ExecStart=/usr/local/sbin/kde-power-osd.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_OSD_SERVICE
chmod 644 "$OSD_SERVICE"
info "Written $OSD_SERVICE"

step "Enabling and starting kde-power-osd.service"
systemctl daemon-reload
systemctl enable kde-power-osd.service
systemctl start  kde-power-osd.service
info "Service enabled and started"

step "Writing installation marker"
mkdir -p /var/lib/samsung-galaxybook
touch "$MARKER_FILE"
info "Marker written"

info "✓ KDE Power Profile OSD installed"
