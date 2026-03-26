#!/bin/bash
set -e

DKMS_NAME="max98390-hda"
DKMS_VER="1.0"
SRC_DIR="/usr/src/${DKMS_NAME}-${DKMS_VER}"

echo "=== MAX98390 HDA Speaker Driver Uninstaller ==="
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo" >&2
    exit 1
fi

# Check if installed — marker file or DKMS entry
MARKER_FILE="/var/lib/samsung-galaxybook/speaker-fix.installed"
DKMS_PRESENT=false
dkms status "${DKMS_NAME}/${DKMS_VER}" 2>/dev/null | grep -q "${DKMS_NAME}" && DKMS_PRESENT=true

if [ ! -f "$MARKER_FILE" ] && ! $DKMS_PRESENT; then
    echo "WARNING: Speaker fix does not appear to be installed (no marker file or DKMS entry found)."
    echo "         Proceeding to clean up any partial installation..."
fi

# Stop and disable systemd services
echo "Stopping services..."
systemctl stop max98390-hda-i2c-setup.service 2>/dev/null || true
systemctl disable max98390-hda-i2c-setup.service 2>/dev/null || true
systemctl stop max98390-hda-check-upstream.service 2>/dev/null || true
systemctl disable max98390-hda-check-upstream.service 2>/dev/null || true

# Unload modules
echo "Unloading modules..."
rmmod snd_hda_scodec_max98390_i2c 2>/dev/null || true
rmmod snd_hda_scodec_max98390 2>/dev/null || true

# Remove DKMS module
echo "Removing DKMS module..."
if dkms status "${DKMS_NAME}/${DKMS_VER}" 2>/dev/null | grep -q "${DKMS_NAME}"; then
    dkms remove "${DKMS_NAME}/${DKMS_VER}" --all
fi

# Remove installed files
echo "Removing installed files..."
rm -f /etc/systemd/system/max98390-hda-i2c-setup.service
rm -f /etc/systemd/system/max98390-hda-check-upstream.service
rm -f /etc/modules-load.d/max98390-hda.conf
rm -f /usr/local/sbin/max98390-hda-i2c-setup.sh
rm -f /usr/local/sbin/max98390-hda-check-upstream.sh
rm -rf "${SRC_DIR}"

systemctl daemon-reload

# Remove installed marker
rm -f "$MARKER_FILE"

echo ""
echo "=== Uninstall complete ==="
echo "Reboot to fully restore the original audio state."
