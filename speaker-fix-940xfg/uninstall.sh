#!/bin/bash
set -e

echo "=== Samsung Galaxy Book3 Pro 14\" (940XFG) Speaker Fix Uninstaller ==="
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo" >&2
    exit 1
fi

echo "Stopping and disabling boot service..."
systemctl stop    alc298-amp-init.service 2>/dev/null || true
systemctl disable alc298-amp-init.service 2>/dev/null || true

echo "Removing installed files..."
rm -f /usr/local/sbin/alc298-amp-init.sh
rm -f /etc/systemd/system/alc298-amp-init.service
rm -f /lib/systemd/system-sleep/alc298-amp-init
rm -f /etc/udev/rules.d/99-alc298-amp-init.rules

systemctl daemon-reload
udevadm control --reload-rules

echo ""
echo "=== Uninstall complete ==="
echo ""
echo "Internal speakers will return to their default (silent) state on the"
echo "next reboot. To restore audio in this session without rebooting, you can"
echo "log out and back in, or just reboot."
