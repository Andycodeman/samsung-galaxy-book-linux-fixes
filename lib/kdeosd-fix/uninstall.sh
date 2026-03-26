#!/bin/bash
# =============================================================================
# Samsung Galaxy Book — KDE Power Profile OSD — Uninstall
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

OSD_SCRIPT="/usr/local/sbin/kde-power-osd.sh"
OSD_SERVICE="/etc/systemd/system/kde-power-osd.service"
MARKER_FILE="/var/lib/samsung-galaxybook/kde-power-osd.installed"

echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Uninstalling: KDE Power Profile OSD              ║"
echo "╚════════════════════════════════════════════════════════════╝"

step "Stopping and disabling service"
systemctl stop    kde-power-osd.service 2>/dev/null || true
systemctl disable kde-power-osd.service 2>/dev/null || true
info "Service stopped and disabled"

step "Removing installed files"
[[ -f "$OSD_SERVICE" ]] && rm -f "$OSD_SERVICE" && info "Removed $OSD_SERVICE"
[[ -f "$OSD_SCRIPT"  ]] && rm -f "$OSD_SCRIPT"  && info "Removed $OSD_SCRIPT"
[[ -f "$MARKER_FILE" ]] && rm -f "$MARKER_FILE" && info "Removed $MARKER_FILE"

step "Reloading systemd"
systemctl daemon-reload
info "systemd daemon reloaded"

if [[ -d /var/lib/samsung-galaxybook ]] && \
   [[ -z "$(ls -A /var/lib/samsung-galaxybook 2>/dev/null)" ]]; then
    rmdir /var/lib/samsung-galaxybook && info "Removed empty /var/lib/samsung-galaxybook"
fi

info "✓ KDE Power Profile OSD uninstalled"
