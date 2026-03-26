#!/bin/bash
set -e

# =============================================================================
# SOF Firmware Uninstaller — Revert Internal Mic Fix
# =============================================================================
# Restores the original SOF firmware from backups and removes the dsp_driver=3
# modprobe configuration. After reboot, the system will use the distro's
# original firmware and default DSP driver selection.
#
# Usage: sudo bash uninstall.sh
# =============================================================================

FW_BASE="/lib/firmware/intel"
MODPROBE_CONF="/etc/modprobe.d/sof-dsp-driver.conf"

echo "=== SOF Firmware Uninstaller (Mic Fix Revert) ==="
echo ""

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo" >&2
    exit 1
fi

# ─── Restore Firmware Backups ────────────────────────────────────────────────

echo "Restoring firmware backups..."

restore_dir() {
    local dst="$1"
    local bak="${dst}.bak-mic-fix"
    if [ -d "$bak" ]; then
        echo "  Restoring: ${bak} → ${dst}"
        rm -rf "$dst"
        mv "$bak" "$dst"
    else
        echo "  No backup found: ${bak} (skipping)"
    fi
}

restore_dir "${FW_BASE}/sof-ipc4"
restore_dir "${FW_BASE}/sof-ipc4-lib"
restore_dir "${FW_BASE}/sof-ace-tplg"
restore_dir "${FW_BASE}/sof"
restore_dir "${FW_BASE}/sof-tplg"

# ─── Remove dsp_driver Config ───────────────────────────────────────────────

echo ""
if [ -f "$MODPROBE_CONF" ]; then
    echo "Removing: ${MODPROBE_CONF}"
    rm -f "$MODPROBE_CONF"
else
    echo "No modprobe config to remove (${MODPROBE_CONF})"
fi

# ─── Rebuild initramfs ──────────────────────────────────────────────────────

echo ""
if [ "${SKIP_INITRAMFS:-0}" = "1" ]; then
    echo "Skipping initramfs rebuild (will be done at end of Uninstall All)."
else
    echo "Rebuilding initramfs with restored firmware..."
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k all 2>&1 | tail -2
    elif command -v dracut >/dev/null 2>&1; then
        dracut --force --regenerate-all 2>&1 | tail -2
    elif command -v mkinitcpio >/dev/null 2>&1; then
        mkinitcpio -P 2>&1 | tail -2
    else
        echo "WARNING: Could not detect initramfs tool."
        echo "         You may need to rebuild your initramfs manually."
    fi
fi

# ─── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "=== Uninstall complete ==="
echo "Original firmware restored. Reboot to apply changes."
echo ""
echo "After reboot, verify with:"
echo "  sudo dmesg | grep -i sof | head -20"
echo "  arecord -l"
echo ""
