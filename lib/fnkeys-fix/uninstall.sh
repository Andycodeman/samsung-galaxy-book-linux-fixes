#!/bin/bash
# =============================================================================
# Samsung Galaxy Book — Function Key Fix — Uninstall
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

FKEYS_PKG="samsung-galaxybook-book5pro"
FKEYS_PKG_VER="1.0"
FKEYS_SRCDIR="/usr/src/samsung-galaxybook-book5pro-1.0"
FKEYS_MODULES_CONF="/etc/modules-load.d/samsung-galaxybook.conf"
FKEYS_BLACKLIST="/etc/modprobe.d/samsung-galaxybook-blacklist.conf"
FKEYS_MONITOR_SVC="samsung-galaxybook-fkeys-monitor.service"
FKEYS_CHECK_SCRIPT="/usr/local/bin/samsung-galaxybook-fkeys-monitor.sh"
FKEYS_CLEANUP="/usr/local/bin/samsung-galaxybook-fkeys-cleanup.sh"

echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Uninstalling: Function Key Fix                   ║"
echo "╚════════════════════════════════════════════════════════════╝"

step \"F-Keys Step 1: Skipping live module unload — reboot required after uninstall\"\ninfo \"The patched module will be replaced by the in-tree module on next reboot\"\n

step "F-Keys Step 2: Removing DKMS entry"
dkms remove ${FKEYS_PKG}/${FKEYS_PKG_VER} --all 2>/dev/null \
    && info "DKMS entry removed" \
    || warn "dkms remove returned an error — may already be partially removed"

step "F-Keys Step 3: Removing source directory"
if [[ -d "$FKEYS_SRCDIR" ]]; then
    rm -rf "$FKEYS_SRCDIR" && info "Removed $FKEYS_SRCDIR"
else
    info "Source directory not found — already removed"
fi

step "F-Keys Step 4: Removing boot configuration"
[[ -f "$FKEYS_MODULES_CONF" ]] && rm "$FKEYS_MODULES_CONF" && info "Removed $FKEYS_MODULES_CONF"
[[ -f "$FKEYS_BLACKLIST"    ]] && rm "$FKEYS_BLACKLIST"    && info "Removed $FKEYS_BLACKLIST"

step "F-Keys Step 5: Removing kernel version marker"
rm -f /var/lib/samsung-galaxybook/fkeys-kernel.ver && info "Kernel version marker removed"

step "F-Keys Step 6: Disabling function key monitor service"
systemctl disable "$FKEYS_MONITOR_SVC" 2>/dev/null || true
rm -f "/etc/systemd/system/${FKEYS_MONITOR_SVC}" && info "Removed monitor service" || true
rm -f "$FKEYS_CHECK_SCRIPT" && info "Removed $FKEYS_CHECK_SCRIPT" || true
rm -f "$FKEYS_CLEANUP"      && info "Removed $FKEYS_CLEANUP"      || true
systemctl daemon-reload 2>/dev/null || true

step "F-Keys Step 7: Skipping in-tree module reload — reboot required"
info "The in-tree samsung_galaxybook module will load automatically on next reboot"

step "F-Keys Step 8: Removing Copilot key XKB workaround"
COPILOT_USER=$(loginctl list-sessions --no-legend | awk '$4 == "seat0" {print $3}' | head -1)
COPILOT_HOME=$(getent passwd "$COPILOT_USER" | cut -d: -f6)
COPILOT_DBUS="unix:path=/run/user/$(id -u "$COPILOT_USER")/bus"

COPILOT_XKB_FILE="$COPILOT_HOME/.config/xkb/symbols/inet"
if [[ -f "$COPILOT_XKB_FILE" ]]; then
    rm -f "$COPILOT_XKB_FILE" && info "Removed $COPILOT_XKB_FILE" || warn "Could not remove $COPILOT_XKB_FILE"
    rmdir "$COPILOT_HOME/.config/xkb/symbols" 2>/dev/null || true
    rmdir "$COPILOT_HOME/.config/xkb" 2>/dev/null || true
else
    info "Copilot key XKB inet file not present — skipping"
fi

COPILOT_AUTOSTART="$COPILOT_HOME/.config/autostart/samsung-galaxybook-fkeys.desktop"
[[ -f "$COPILOT_AUTOSTART" ]] && rm -f "$COPILOT_AUTOSTART" && info "Removed $COPILOT_AUTOSTART" || true

if ps -u "$COPILOT_USER" -o comm= 2>/dev/null | grep -qi "plasmashell"; then
    COPILOT_DE="kde"
elif ps -u "$COPILOT_USER" -o comm= 2>/dev/null | grep -qi "gnome-shell"; then
    COPILOT_DE="gnome"
elif ps -u "$COPILOT_USER" -o comm= 2>/dev/null | grep -qi "cinnamon"; then
    COPILOT_DE="cinnamon"
else
    COPILOT_DE="unknown"
fi

if echo "$COPILOT_DE" | grep -qi "kde\|plasma"; then
    EXISTING_OPTS=$(sudo -u "$COPILOT_USER" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$COPILOT_USER")" \
        DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
        kreadconfig6 --file kxkbrc --group Layout --key Options 2>/dev/null || true)
    NEW_OPTS=$(echo "$EXISTING_OPTS" | tr ',' '\n' | grep -v "fkeys:basic_13-24" | tr '\n' ',' | sed 's/,$//')
    sudo -u "$COPILOT_USER" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$COPILOT_USER")" \
        DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
        kwriteconfig6 --file kxkbrc --group Layout --key Options "$NEW_OPTS"
    sudo -u "$COPILOT_USER" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$COPILOT_USER")" \
        DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
        kwriteconfig6 --file kxkbrc --group Layout --key ResetOldOptions "false"
    info "KDE fkeys:basic_13-24 option removed (takes effect on next login)"
elif echo "$COPILOT_DE" | grep -qi "gnome\|unity"; then
    EXISTING_OPTS=$(sudo -u "$COPILOT_USER" DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
        gsettings get org.gnome.desktop.input-sources xkb-options 2>/dev/null || echo "[]")
    NEW_OPTS=$(echo "$EXISTING_OPTS" | python3 -c "
import sys,json; raw=sys.stdin.read().strip()
opts=json.loads(raw.replace(\"'\", '\"'))
opts=[o for o in opts if o != 'fkeys:basic_13-24']
print(json.dumps(opts).replace('\"', \"'\"))
" 2>/dev/null || echo "[]")
    sudo -u "$COPILOT_USER" DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
        gsettings set org.gnome.desktop.input-sources xkb-options "$NEW_OPTS"
    info "GNOME fkeys:basic_13-24 option removed"
elif echo "$COPILOT_DE" | grep -qi "cinnamon"; then
    EXISTING_OPTS=$(sudo -u "$COPILOT_USER" DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
        gsettings get org.cinnamon.desktop.input-sources xkb-options 2>/dev/null || echo "[]")
    NEW_OPTS=$(echo "$EXISTING_OPTS" | python3 -c "
import sys,json; raw=sys.stdin.read().strip()
opts=json.loads(raw.replace(\"'\", '\"'))
opts=[o for o in opts if o != 'fkeys:basic_13-24']
print(json.dumps(opts).replace('\"', \"'\"))
" 2>/dev/null || echo "[]")
    sudo -u "$COPILOT_USER" DBUS_SESSION_BUS_ADDRESS="$COPILOT_DBUS" \
        gsettings set org.cinnamon.desktop.input-sources xkb-options "$NEW_OPTS"
    info "Cinnamon fkeys:basic_13-24 option removed"
else
    info "Unknown DE — xkb option not reverted (autostart entry already removed)"
fi

info "✓ Function key fix uninstalled"
