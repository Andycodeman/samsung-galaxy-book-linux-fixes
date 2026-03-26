#!/bin/bash
# Uninstall the patched ov02c10 DKMS module and restore the stock kernel driver

set -e

DKMS_NAME="ov02c10"
DKMS_VERSION="1.0"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo bash uninstall.sh"
    exit 1
fi

if dkms status "${DKMS_NAME}/${DKMS_VERSION}" 2>/dev/null | grep -q .; then
    echo "Removing DKMS module..."
    dkms remove "${DKMS_NAME}/${DKMS_VERSION}" --all
else
    echo "DKMS module not found, nothing to remove."
fi

rm -rf "/usr/src/${DKMS_NAME}-${DKMS_VERSION}"

# Reload stock module
if lsmod | grep -q "^ov02c10"; then
    rmmod ov02c10 2>/dev/null || true
fi
modprobe ov02c10 2>/dev/null || true

echo "Done! Stock ov02c10 driver restored. Reboot if needed."

# Remove installation marker
rm -f /var/lib/samsung-galaxybook/ov02c10-fix.installed
if [ -d /var/lib/samsung-galaxybook ] && [ -z "$(ls -A /var/lib/samsung-galaxybook 2>/dev/null)" ]; then
    rmdir /var/lib/samsung-galaxybook
fi
