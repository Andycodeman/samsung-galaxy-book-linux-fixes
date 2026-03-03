#!/bin/bash
# Install patched ov02c10 driver with 26 MHz clock support via DKMS
# For Samsung Galaxy Book 3/4 with Raptor Lake IPU6 (26 MHz external clock)

set -e

DKMS_NAME="ov02c10"
DKMS_VERSION="1.0"
SRC_DIR="/usr/src/${DKMS_NAME}-${DKMS_VERSION}"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo bash install.sh"
    exit 1
fi

# Check for dkms
if ! command -v dkms &>/dev/null; then
    echo "dkms is not installed. Installing..."
    if command -v apt &>/dev/null; then
        apt install -y dkms
    elif command -v dnf &>/dev/null; then
        dnf install -y dkms
    else
        echo "Error: Could not install dkms. Please install it manually."
        exit 1
    fi
fi

# Check for kernel headers
KVER=$(uname -r)
if [ ! -d "/lib/modules/${KVER}/build" ]; then
    echo "Kernel headers for ${KVER} not found. Installing..."
    if command -v apt &>/dev/null; then
        apt install -y "linux-headers-${KVER}"
    elif command -v dnf &>/dev/null; then
        dnf install -y "kernel-devel-${KVER}"
    else
        echo "Error: Could not install kernel headers. Please install them manually."
        exit 1
    fi
fi

# Remove old DKMS module if present
if dkms status "${DKMS_NAME}/${DKMS_VERSION}" 2>/dev/null | grep -q .; then
    echo "Removing existing DKMS module..."
    dkms remove "${DKMS_NAME}/${DKMS_VERSION}" --all 2>/dev/null || true
fi

# Remove old source directory if present
rm -rf "${SRC_DIR}"

# Copy source files
echo "Copying source files to ${SRC_DIR}..."
mkdir -p "${SRC_DIR}"
cp "$(dirname "$0")/ov02c10.c" "${SRC_DIR}/"
cp "$(dirname "$0")/Makefile" "${SRC_DIR}/"
cp "$(dirname "$0")/dkms.conf" "${SRC_DIR}/"

# Add, build, and install
echo "Building and installing DKMS module..."
dkms add "${DKMS_NAME}/${DKMS_VERSION}"
dkms build "${DKMS_NAME}/${DKMS_VERSION}"
dkms install "${DKMS_NAME}/${DKMS_VERSION}"

# Rebuild initramfs so the DKMS module replaces the stock one in early boot
echo "Rebuilding initramfs..."
if command -v update-initramfs &>/dev/null; then
    update-initramfs -u
elif command -v dracut &>/dev/null; then
    dracut --force
elif command -v mkinitcpio &>/dev/null; then
    mkinitcpio -P
else
    echo "Warning: could not rebuild initramfs. Reboot may still load the stock driver."
fi

# Reload the module
echo "Reloading ov02c10 module..."
if lsmod | grep -q "^ov02c10"; then
    rmmod ov02c10 2>/dev/null || echo "Warning: could not unload ov02c10 (may be in use). Reboot to apply."
fi
modprobe ov02c10

# Verify the right module loaded
LOADED_PATH=$(modinfo ov02c10 2>/dev/null | grep "^filename:" | awk '{print $2}')
if echo "$LOADED_PATH" | grep -q "/updates/"; then
    echo "  ✓ DKMS module loaded: ${LOADED_PATH}"
else
    echo "  ⚠ Stock module loaded: ${LOADED_PATH}"
    echo "    The DKMS module may not be taking priority."
    echo "    Check: mokutil --sb-state"
    echo "    If Secure Boot is enabled, you may need to enroll the MOK key or disable Secure Boot."
fi

echo ""
echo "Done! The patched ov02c10 driver is now installed."
echo "If the camera still doesn't work, try rebooting."
echo ""
echo "To verify the fix, run: dmesg | grep -i ov02c10"
echo "You should no longer see 'external clock 26000000 is not supported'"
