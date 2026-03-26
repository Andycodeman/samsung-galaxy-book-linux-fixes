#!/bin/bash
# Uninstall the libcamera-based webcam fix
# Removes config files, tuning files, and camera relay added by install.sh
# Does NOT uninstall distro packages or source-built libcamera

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo: sudo bash uninstall.sh" >&2
    exit 1
fi

# Flag to track whether initramfs needs rebuilding at the end
NEED_INITRAMFS_REBUILD=false

echo "=============================================="
echo "  Samsung Galaxy Book 4 Webcam Fix Uninstaller"
echo "=============================================="
echo ""


# [1/8] Stop and remove camera relay
echo "[1/8] Removing camera relay..."
# Identify the real desktop user for session-bus operations
_relay_user=$(loginctl list-sessions --no-legend 2>/dev/null \
    | awk '$4 == "seat0" {print $3}' | head -1)
_relay_uid=$(id -u "$_relay_user" 2>/dev/null)
# Disable persistent mode and stop relay as the real user
if [[ -n "$_relay_user" ]] && command -v camera-relay >/dev/null 2>&1; then
    sudo -u "$_relay_user" \
        XDG_RUNTIME_DIR="/run/user/${_relay_uid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_relay_uid}/bus" \
        /usr/local/bin/camera-relay disable-persistent 2>/dev/null || true
    sudo -u "$_relay_user" \
        XDG_RUNTIME_DIR="/run/user/${_relay_uid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_relay_uid}/bus" \
        /usr/local/bin/camera-relay stop 2>/dev/null || true
fi
# Stop any running relay processes
pkill -f "camera-relay-monitor" 2>/dev/null || true
pkill -f "camera-relay start" 2>/dev/null || true
# Remove binaries and config
sudo rm -f /usr/local/bin/camera-relay
sudo rm -f /usr/local/bin/camera-relay-monitor
sudo rm -f /etc/modprobe.d/99-camera-relay-loopback.conf
sudo rm -f /etc/modules-load.d/v4l2loopback.conf
sudo rm -rf /usr/local/share/camera-relay
sudo rm -f /usr/share/applications/camera-relay-systray.desktop
# Remove user service file for all users who have it
for user_home in /home/*; do
    service_file="$user_home/.config/systemd/user/camera-relay.service"
    if [[ -f "$service_file" ]]; then
        user=$(basename "$user_home")
        uid=$(id -u "$user" 2>/dev/null)
        sudo -u "$user" \
            XDG_RUNTIME_DIR="/run/user/${uid}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
            systemctl --user daemon-reload 2>/dev/null || true
        rm -f "$service_file"
    fi
done
# Unload v4l2loopback if it was only used by the relay
if lsmod 2>/dev/null | grep -q v4l2loopback; then
    if ! grep -rqs "v4l2loopback" /etc/modprobe.d/ 2>/dev/null; then
        sudo modprobe -r v4l2loopback 2>/dev/null || true
    fi
fi
# Fedora needs initramfs rebuild to pick up v4l2loopback config removal
if command -v dracut >/dev/null 2>&1; then
    NEED_INITRAMFS_REBUILD=true
fi
echo "  ✓ Camera relay removed"

# [2/8] Remove module configuration
echo "[2/8] Removing module configuration..."
sudo rm -f /etc/modules-load.d/ivsc.conf
sudo rm -f /etc/modprobe.d/ivsc-camera.conf
echo "  ✓ Module configuration removed"

# [3/8] Remove initramfs configuration
echo "[3/8] Removing initramfs configuration..."
INITRAMFS_CHANGED=false
if [[ -f /etc/initramfs-tools/modules ]]; then
    for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
        if grep -qxF "$mod" /etc/initramfs-tools/modules 2>/dev/null; then
            sudo sed -i "/^${mod}$/d" /etc/initramfs-tools/modules
            INITRAMFS_CHANGED=true
        fi
    done
    if $INITRAMFS_CHANGED; then
        NEED_INITRAMFS_REBUILD=true
    fi
fi
sudo rm -f /etc/dracut.conf.d/ivsc-camera.conf
sudo rm -f /etc/mkinitcpio.conf.d/ivsc-camera.conf
echo "  ✓ Initramfs configuration removed"

# [4/8] Remove udev rules
echo "[4/8] Removing udev rules..."
sudo rm -f /etc/udev/rules.d/90-hide-ipu6-v4l2.rules
sudo udevadm control --reload-rules 2>/dev/null || true
echo "  ✓ Udev rules removed"

# [5/8] Remove WirePlumber rules
echo "[5/8] Removing WirePlumber rules..."
sudo rm -f /etc/wireplumber/main.lua.d/51-disable-ipu6-v4l2.lua
sudo rm -f /etc/wireplumber/wireplumber.conf.d/50-disable-ipu6-v4l2.conf
# Restore backed-up SPA plugin if present
SPA_BAK=$(find /usr/lib -name "libspa-libcamera.so.bak" -path "*/spa-0.2/libcamera/*" 2>/dev/null | head -1)
if [[ -n "$SPA_BAK" ]]; then
    sudo mv "$SPA_BAK" "${SPA_BAK%.bak}"
    echo "  ✓ Original SPA plugin restored"
fi
echo "  ✓ WirePlumber rules removed"

# [6/8] Remove sensor tuning files
echo "[6/8] Removing sensor tuning files..."
for dir in /usr/local/share/libcamera/ipa/simple /usr/share/libcamera/ipa/simple; do
    if [[ -f "$dir/ov02c10.yaml" ]]; then
        sudo rm -f "$dir/ov02c10.yaml"
        echo "  ✓ Removed $dir/ov02c10.yaml"
    fi
done
echo "  ✓ Sensor tuning files removed"

# [7/8] Remove environment configs
echo "[7/8] Removing environment configuration..."
sudo rm -f /etc/profile.d/libcamera-ipa.sh
sudo rm -f /etc/environment.d/libcamera-ipa.conf
echo "  ✓ Environment configuration removed"

# [7b/8] Single initramfs rebuild
echo "[7b/8] Rebuilding initramfs..."
if [[ "${SKIP_INITRAMFS:-0}" == "1" ]]; then
    echo "  ✓ Skipping initramfs rebuild (will be done at end of Uninstall All)."
elif $NEED_INITRAMFS_REBUILD; then
    if command -v dracut >/dev/null 2>&1; then
        sudo dracut --force 2>/dev/null && echo "  ✓ initramfs rebuilt" ||             echo "  ⚠ initramfs rebuild failed — reboot may not apply all changes"
    elif command -v update-initramfs >/dev/null 2>&1; then
        sudo update-initramfs -u -k "$(uname -r)" 2>/dev/null &&             echo "  ✓ initramfs rebuilt" ||             echo "  ⚠ initramfs rebuild failed — reboot may not apply all changes"
    elif command -v mkinitcpio >/dev/null 2>&1; then
        sudo mkinitcpio -P 2>/dev/null && echo "  ✓ initramfs rebuilt" ||             echo "  ⚠ initramfs rebuild failed — reboot may not apply all changes"
    fi
else
    echo "  ✓ No initramfs rebuild needed"
fi

echo ""
echo "=============================================="
echo "  Uninstall complete."
echo ""
echo "  Note: Source-built libcamera (if any) in /usr/local was NOT removed."
echo "  To remove it manually:  sudo rm -rf /usr/local/lib/*/libcamera*"
echo "                          sudo rm -rf /usr/local/share/libcamera"
echo "                          sudo rm -f /usr/local/bin/cam"
echo "                          sudo ldconfig"
echo ""
echo "  Distro packages (libcamera, pipewire-libcamera, v4l2loopback, etc.)"
echo "  were NOT removed — you may need them for other purposes."
echo ""
echo "  Reboot to fully restore the original state."
echo "=============================================="
