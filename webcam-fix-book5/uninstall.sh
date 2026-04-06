#!/bin/bash
# Uninstall the Galaxy Book5 webcam fix
# Removes DKMS module, config files, and environment settings added by install.sh
# Does NOT uninstall distro packages (libcamera, pipewire-libcamera, etc.)

set -e

VISION_DRIVER_VER="1.0.0"
SRC_DIR="/usr/src/vision-driver-${VISION_DRIVER_VER}"
IPU_BRIDGE_FIX_VER="1.1"
IPU_BRIDGE_FIX_SRC="/usr/src/ipu-bridge-fix-${IPU_BRIDGE_FIX_VER}"

echo "=============================================="
echo "  Samsung Galaxy Book5 Webcam Fix Uninstaller"
echo "=============================================="
echo ""

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Don't run this as root. The script will use sudo where needed."
    exit 1
fi

# [1/11] Remove vision-driver DKMS module
echo "[1/11] Removing vision-driver DKMS module..."
if dkms status "vision-driver/${VISION_DRIVER_VER}" 2>/dev/null | grep -q "vision-driver"; then
    sudo dkms remove "vision-driver/${VISION_DRIVER_VER}" --all 2>/dev/null || true
    echo "  ✓ DKMS module removed"
else
    echo "  ✓ DKMS module not installed (nothing to remove)"
fi

# [2/11] Remove vision-driver DKMS source
echo "[2/11] Removing vision-driver DKMS source..."
if [[ -d "$SRC_DIR" ]]; then
    sudo rm -rf "$SRC_DIR"
    echo "  ✓ Removed ${SRC_DIR}"
else
    echo "  ✓ Source directory not present"
fi

# [3/11] Remove ipu-bridge-fix DKMS module (camera rotation fix)
echo "[3/11] Removing ipu-bridge-fix DKMS module..."
IPU_BRIDGE_REMOVED=false
for ver in "$IPU_BRIDGE_FIX_VER" "1.0"; do
    if dkms status "ipu-bridge-fix/${ver}" 2>/dev/null | grep -q "ipu-bridge-fix"; then
        sudo dkms remove "ipu-bridge-fix/${ver}" --all 2>/dev/null || true
        IPU_BRIDGE_REMOVED=true
    fi
    [[ -d "/usr/src/ipu-bridge-fix-${ver}" ]] && sudo rm -rf "/usr/src/ipu-bridge-fix-${ver}"
done
if $IPU_BRIDGE_REMOVED; then
    echo "  ✓ DKMS module removed"
else
    echo "  ✓ DKMS module not installed (nothing to remove)"
fi
# Remove upstream check script and service
sudo systemctl disable ipu-bridge-check-upstream.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/ipu-bridge-check-upstream.service
sudo rm -f /usr/local/sbin/ipu-bridge-check-upstream.sh
# Restore kernel's original ipu-bridge
sudo depmod -a 2>/dev/null || true

# [3b/11] Remove ov02e10-fix DKMS module (legacy — no longer installed)
echo "[3b/11] Removing ov02e10-fix DKMS module (if present from older install)..."
if dkms status "ov02e10-fix/1.0" 2>/dev/null | grep -q "ov02e10-fix"; then
    sudo dkms remove "ov02e10-fix/1.0" --all 2>/dev/null || true
    echo "  ✓ DKMS module removed"
else
    echo "  ✓ DKMS module not installed (nothing to remove)"
fi
if [[ -d "/usr/src/ov02e10-fix-1.0" ]]; then
    sudo rm -rf "/usr/src/ov02e10-fix-1.0"
    echo "  ✓ Removed /usr/src/ov02e10-fix-1.0"
fi

# [4/11] Remove modprobe config
echo "[4/11] Removing module configuration..."
sudo rm -f /etc/modprobe.d/intel-ipu7-camera.conf
# Also remove old name from earlier versions of the installer
sudo rm -f /etc/modprobe.d/intel-cvs-camera.conf
echo "  ✓ Module configuration removed"

# [5/11] Remove modules-load config
echo "[5/11] Removing module autoload configuration..."
sudo rm -f /etc/modules-load.d/intel-ipu7-camera.conf
# Also remove old name from earlier versions of the installer
sudo rm -f /etc/modules-load.d/intel-cvs.conf
echo "  ✓ Module autoload configuration removed"

# [6/11] Remove udev rules (including legacy hide rule from earlier versions)
echo "[6/11] Removing udev rules..."
sudo rm -f /etc/udev/rules.d/90-hide-ipu7-v4l2.rules
sudo udevadm control --reload-rules 2>/dev/null || true
echo "  ✓ Udev rules removed"

# [7/11] Remove WirePlumber rules
echo "[7/11] Removing WirePlumber rules..."
sudo rm -f /etc/wireplumber/wireplumber.conf.d/50-disable-ipu7-v4l2.conf
sudo rm -f /etc/wireplumber/main.lua.d/51-disable-ipu7-v4l2.lua
echo "  ✓ WirePlumber rules removed"

# [8/11] Remove sensor color tuning files
echo "[8/11] Removing libcamera sensor tuning files..."
for dir in /usr/local/share/libcamera/ipa/simple /usr/share/libcamera/ipa/simple; do
    for sensor in ov02e10 ov02c10; do
        if [[ -f "$dir/${sensor}.yaml" ]]; then
            sudo rm -f "$dir/${sensor}.yaml"
            echo "  ✓ Removed $dir/${sensor}.yaml"
        fi
    done
done
echo "  ✓ Sensor tuning files removed"

# [9/11] Remove patched libcamera (bayer order fix)
echo "[9/11] Removing patched libcamera (bayer order fix)..."
BAYER_FIX_BACKUP="/var/lib/libcamera-bayer-fix-backup"
if [[ -d "$BAYER_FIX_BACKUP" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$SCRIPT_DIR/libcamera-bayer-fix/build-patched-libcamera.sh" ]]; then
        sudo "$SCRIPT_DIR/libcamera-bayer-fix/build-patched-libcamera.sh" --uninstall
        echo "  ✓ Original libcamera restored"
    else
        echo "  ⚠ build-patched-libcamera.sh not found — manually restore from $BAYER_FIX_BACKUP"
    fi
else
    echo "  ✓ Bayer fix not installed (nothing to remove)"
fi

# [10/11] Remove camera relay tool
echo "[10/11] Removing camera relay tool..."
_relay_user=$(loginctl list-sessions --no-legend 2>/dev/null \
    | awk '$4 == "seat0" {print $3}' | head -1)

# Remove bundled icons
if [[ -n "$_relay_user" ]]; then
    ICON_DIR="/home/${_relay_user}/.local/share/icons/hicolor/symbolic/apps"
    for icon in camera-disabled-symbolic camera-switch-symbolic camera-video-symbolic; do
        sudo -u "$_relay_user" rm -f "${ICON_DIR}/${icon}.svg" \
            && echo "✓ Removed ${icon}.svg" || true
    done
    sudo -u "$_relay_user" \
        gtk-update-icon-cache -f -t \
        "/home/${_relay_user}/.local/share/icons/hicolor" 2>/dev/null \
        && echo "✓ GTK icon cache updated" \
        || echo "gtk-update-icon-cache failed — stale icons may linger until next login"
else
    echo "Could not detect logged-in user — icons not removed"
fi
# Stop any running relay
if [[ -x /usr/local/bin/camera-relay ]]; then
    /usr/local/bin/camera-relay stop 2>/dev/null || true
fi
# Disable persistent mode for all users
for user_home in /home/*; do
    service_file="$user_home/.config/systemd/user/camera-relay.service"
    if [[ -f "$service_file" ]]; then
        user=$(basename "$user_home")
        sudo -u "$user" systemctl --user disable camera-relay.service 2>/dev/null || true
        rm -f "$service_file"
    fi
done
sudo rm -f /usr/local/bin/camera-relay
sudo rm -f /usr/local/bin/camera-relay-monitor
sudo rm -rf /usr/local/share/camera-relay
sudo rm -f /usr/share/applications/camera-relay-systray.desktop
# Only remove our v4l2loopback config if it's ours
if [[ -f /etc/modprobe.d/99-camera-relay-loopback.conf ]] && \
   grep -q "Camera Relay" /etc/modprobe.d/99-camera-relay-loopback.conf 2>/dev/null; then
    sudo rm -f /etc/modprobe.d/99-camera-relay-loopback.conf
    sudo rm -f /etc/modules-load.d/v4l2loopback.conf
    # Fedora: rebuild initramfs so dracut doesn't load v4l2loopback with stale config
    if command -v dracut &>/dev/null; then
        echo "  Rebuilding initramfs to remove v4l2loopback config..."
        sudo dracut --regenerate-all -f 2>/dev/null || true
    fi
fi
echo "  ✓ Camera relay tool removed"

# [11/11] Remove environment configs
echo "[11/11] Removing environment configuration..."
sudo rm -f /etc/environment.d/libcamera-ipa.conf
sudo rm -f /etc/profile.d/libcamera-ipa.sh
echo "  ✓ Removed libcamera environment files"

echo ""
echo "=============================================="
echo "  Uninstall complete."
echo ""
echo "  Note: Distro packages (libcamera, pipewire-libcamera, etc.) were NOT"
echo "  removed — you may need them for other purposes. Remove manually if desired."
echo ""
echo "  Reboot to fully restore the original state."
echo "=============================================="
