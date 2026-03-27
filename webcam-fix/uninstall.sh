#!/bin/bash
# Uninstall the Galaxy Book4 webcam fix
# Removes all config files, packages, and PPA added by install.sh
# Supports Ubuntu, Fedora, Arch, and other distros.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo "  Samsung Galaxy Book4 Webcam Fix Uninstaller"
echo "=============================================="
echo ""

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Don't run this as root. The script will use sudo where needed."
    exit 1
fi

# Detect distro
if command -v pacman >/dev/null 2>&1; then
    DISTRO="arch"
elif command -v dnf >/dev/null 2>&1; then
    DISTRO="fedora"
elif command -v apt >/dev/null 2>&1; then
    DISTRO="debian"  # covers Ubuntu too
else
    DISTRO="unknown"
fi

# Stop the relay service
echo "[1/9] Stopping v4l2-relayd service..."
sudo systemctl stop v4l2-relayd@default 2>/dev/null || true
sudo systemctl stop v4l2-relayd 2>/dev/null || true
sudo systemctl disable v4l2-relayd 2>/dev/null || true

# Remove config files
echo "[2/9] Removing configuration files..."
sudo rm -f /etc/modules-load.d/ivsc.conf
sudo rm -f /etc/modprobe.d/ivsc-camera.conf
sudo rm -f /etc/modprobe.d/v4l2loopback.conf
sudo rm -f /etc/v4l2-relayd.d/default.conf
sudo rm -f /etc/udev/rules.d/90-hide-ipu6-v4l2.rules
# Clean up WirePlumber rule (older versions of install.sh created this; no longer needed)
sudo rm -f /etc/wireplumber/wireplumber.conf.d/50-v4l2-ipu6-camera.conf
# Clean up legacy config path (older versions of install.sh wrote here)
sudo rm -f /etc/v4l2-relayd
echo "  Done"

# Remove v4l2-relayd systemd override
echo "[3/9] Removing systemd overrides..."
sudo rm -rf /etc/systemd/system/v4l2-relayd@default.service.d
sudo systemctl daemon-reload
echo "  Done"

# Remove watchdog (legacy) and resolution detection
echo "[4/9] Removing watchdog and resolution detection..."
sudo systemctl stop v4l2-relayd-watchdog.timer 2>/dev/null || true
sudo systemctl disable v4l2-relayd-watchdog.timer 2>/dev/null || true
sudo systemctl stop v4l2-relayd-watchdog.service 2>/dev/null || true
sudo rm -f /usr/local/sbin/v4l2-relayd-watchdog.sh
sudo rm -f /usr/local/sbin/v4l2-relayd-detect-resolution.sh
sudo rm -f /run/v4l2-relayd-resolution.env
sudo rm -f /etc/systemd/system/v4l2-relayd-watchdog.service
sudo rm -f /etc/systemd/system/v4l2-relayd-watchdog.timer
sudo rm -rf /run/v4l2-relayd-watchdog
sudo systemctl daemon-reload
echo "  Done"

# Remove upstream detection service
echo "[5/9] Removing upstream detection service..."
sudo systemctl stop v4l2-relayd-check-upstream.service 2>/dev/null || true
sudo systemctl disable v4l2-relayd-check-upstream.service 2>/dev/null || true
sudo rm -f /usr/local/sbin/v4l2-relayd-check-upstream.sh
sudo rm -f /etc/systemd/system/v4l2-relayd-check-upstream.service
sudo systemctl daemon-reload
echo "  Done"

# Remove IVSC modules from initramfs and rebuild
echo "[6/9] Removing IVSC modules from initramfs..."
# Remove initramfs config for all tools (clean up whichever was used)
INITRAMFS_REBUILT=false

# Check for initramfs-tools config (Debian/Ubuntu)
if [[ -f /etc/initramfs-tools/modules ]]; then
    INITRAMFS_CHANGED=false
    for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
        if grep -qxF "$mod" /etc/initramfs-tools/modules 2>/dev/null; then
            sudo sed -i "/^${mod}$/d" /etc/initramfs-tools/modules
            INITRAMFS_CHANGED=true
        fi
    done
    if $INITRAMFS_CHANGED && command -v update-initramfs &>/dev/null; then
        echo "  Rebuilding initramfs..."
        sudo update-initramfs -u
        INITRAMFS_REBUILT=true
    fi
fi

# Check for dracut config
if [[ -f /etc/dracut.conf.d/ivsc-camera.conf ]]; then
    sudo rm -f /etc/dracut.conf.d/ivsc-camera.conf
    if command -v dracut &>/dev/null; then
        echo "  Rebuilding initramfs with dracut..."
        sudo dracut --force
        INITRAMFS_REBUILT=true
    fi
fi

# Check for mkinitcpio config
if [[ -f /etc/mkinitcpio.conf.d/ivsc-camera.conf ]]; then
    sudo rm -f /etc/mkinitcpio.conf.d/ivsc-camera.conf
    if command -v mkinitcpio &>/dev/null; then
        echo "  Rebuilding initramfs with mkinitcpio..."
        sudo mkinitcpio -P
        INITRAMFS_REBUILT=true
    fi
fi

if $INITRAMFS_REBUILT; then
    echo "  Done"
else
    echo "  No initramfs config to remove (or no supported tool found)"
fi

# Reload udev rules
sudo udevadm control --reload-rules 2>/dev/null || true

# Remove packages / source builds
echo "[7/9] Removing packages..."
case "$DISTRO" in
    debian)
        sudo apt remove -y libcamhal-ipu6epmtl v4l2-relayd 2>/dev/null || true
        sudo apt autoremove -y 2>/dev/null || true
        ;;
    fedora)
        sudo dnf remove -y ipu6-camera-hal ipu6-camera-bins gstreamer1-plugins-icamerasrc v4l2-relayd 2>/dev/null || true
        ;;
    arch)
        # Arch packages are typically from AUR or source; try pacman first
        sudo pacman -R --noconfirm ipu6-camera-hal ipu6-camera-bins icamerasrc v4l2-relayd 2>/dev/null || true
        ;;
esac

# Remove source-built HAL if present
if [[ -f /var/lib/ipu6-hal-backup/.source-build-stamp ]]; then
    echo "  Removing source-built camera HAL..."
    sudo "$SCRIPT_DIR/build-ipu6-from-source.sh" --uninstall 2>/dev/null || true
fi
echo "  Done"

# Remove PPA (Ubuntu/Debian only)
echo "[8/9] Removing Intel IPU6 PPA..."
case "$DISTRO" in
    debian)
        sudo add-apt-repository -y --remove ppa:oem-solutions-group/intel-ipu6 2>/dev/null || true
        echo "  Done"
        ;;
    *)
        echo "  Skipped (no PPA on this distro)"
        ;;
esac

# Restart WirePlumber to pick up removed config
echo "[9/9] Restarting WirePlumber..."
systemctl --user restart wireplumber 2>/dev/null || true

echo ""
echo "=============================================="
echo "  Uninstall complete."
echo "  Reboot to fully restore the original state."
echo "=============================================="
