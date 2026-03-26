#!/bin/bash
# Uninstall the Galaxy Book5 webcam fix
# Removes DKMS module, config files, and environment settings added by install.sh
# Does NOT uninstall distro packages (libcamera, pipewire-libcamera, etc.)

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo: sudo bash uninstall.sh" >&2
    exit 1
fi

VISION_DRIVER_VER="1.0.0"
SRC_DIR="/usr/src/vision-driver-${VISION_DRIVER_VER}"
IPU_BRIDGE_FIX_VER="1.0"
IPU_BRIDGE_FIX_SRC="/usr/src/ipu-bridge-fix-${IPU_BRIDGE_FIX_VER}"

echo "=============================================="
echo "  Samsung Galaxy Book 5 Webcam Fix Uninstaller"
echo "=============================================="
echo ""

# ── Stop camera-relay before touching anything ───────────────────────────────
# camera-relay disable-persistent does a clean shutdown — no need to stop
# WirePlumber or PipeWire as they remain stable during the uninstall.
_UNINSTALL_USER=$(loginctl list-sessions --no-legend 2>/dev/null \
    | awk '$4 == "seat0" {print $3}' | head -1)
_UNINSTALL_UID=$(id -u "$_UNINSTALL_USER" 2>/dev/null)

if [[ -n "$_UNINSTALL_USER" ]] && [[ -n "$_UNINSTALL_UID" ]]; then
    echo "[0/11] Stopping camera-relay..."
    if [[ -x "/usr/local/bin/camera-relay" ]]; then
        sudo -u "$_UNINSTALL_USER" \
            XDG_RUNTIME_DIR="/run/user/${_UNINSTALL_UID}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_UNINSTALL_UID}/bus" \
            /usr/local/bin/camera-relay disable-persistent 2>/dev/null || true
        echo "  ✓ camera-relay stopped via disable-persistent"
    else
        echo "  ✓ camera-relay not installed — skipping"
    fi
else
    echo "[0/11] No active desktop session found — skipping camera-relay stop"
fi
echo ""
echo "[1/11] Checking vision-driver installation..."
# Check if intel_cvs is available via a system package (RPM Fusion, distro repo, etc.)
# If so, we never installed the DKMS module and there is nothing to remove.
VISION_VIA_PACKAGE=false
if command -v rpm >/dev/null 2>&1 && rpm -q intel-vision-drivers &>/dev/null 2>&1; then
    VISION_VIA_PACKAGE=true
elif command -v pacman >/dev/null 2>&1 && pacman -Qi intel-vision-drivers &>/dev/null 2>&1; then
    VISION_VIA_PACKAGE=true
elif command -v dpkg >/dev/null 2>&1 && dpkg -l intel-vision-drivers &>/dev/null 2>&1; then
    VISION_VIA_PACKAGE=true
fi

if $VISION_VIA_PACKAGE; then
    echo "  ✓ intel_cvs installed via system package — skipping DKMS removal"
elif dkms status "vision-driver/${VISION_DRIVER_VER}" 2>/dev/null | grep -q "vision-driver"; then
    sudo dkms remove "vision-driver/${VISION_DRIVER_VER}" --all 2>/dev/null || true
    echo "  ✓ vision-driver DKMS module removed"
else
    echo "  ✓ vision-driver DKMS module not installed (nothing to remove)"
fi

# [2/11] Remove vision-driver DKMS source (only if it exists and was installed via DKMS)
echo "[2/11] Removing vision-driver DKMS source..."
if ! $VISION_VIA_PACKAGE && [[ -d "$SRC_DIR" ]]; then
    sudo rm -rf "$SRC_DIR"
    echo "  ✓ Removed ${SRC_DIR}"
else
    echo "  ✓ DKMS source not present or installed via system package (nothing to remove)"
fi

# [3/11] Remove camera rotation fix — either ACPI SSDT override or ipu-bridge DKMS
echo "[3/11] Removing camera rotation fix..."

SSDT_ROTATION_AML="/etc/acpi_override/cam-rot.aml"
NEEDS_INITRAMFS_REBUILD=false

# Check for our ACPI SSDT override fix
if [[ -f "$SSDT_ROTATION_AML" ]]; then
    sudo rm -f "$SSDT_ROTATION_AML"
    echo "  ✓ ACPI SSDT camera rotation override removed (${SSDT_ROTATION_AML})"
    NEEDS_INITRAMFS_REBUILD=true

    # Clean up initramfs ACPI config if acpi_override dir is now empty
    # (guard: don't remove if fan fix's dsdt_fixed.aml is still present)
    if [[ -z "$(ls /etc/acpi_override/ 2>/dev/null)" ]]; then
        sudo rmdir /etc/acpi_override 2>/dev/null || true
        echo "  ✓ Removed empty /etc/acpi_override/"

        # Dracut (Fedora / Ubuntu) — remove acpi.conf if it exists and fan fix isn't using it
        if [[ -f /etc/dracut.conf.d/acpi.conf ]]; then
            sudo rm -f /etc/dracut.conf.d/acpi.conf
            echo "  ✓ Removed /etc/dracut.conf.d/acpi.conf"
        fi

        # Arch / mkinitcpio — remove ACPI override hook and conf if fan fix isn't using them
        if [[ -f /etc/mkinitcpio.conf.d/acpi_override.conf ]]; then
            sudo rm -f /etc/mkinitcpio.conf.d/acpi_override.conf
            echo "  ✓ Removed /etc/mkinitcpio.conf.d/acpi_override.conf"
        fi
        if [[ -f /etc/initcpio/hooks/acpi_override ]]; then
            sudo rm -f /etc/initcpio/hooks/acpi_override
            echo "  ✓ Removed /etc/initcpio/hooks/acpi_override"
        fi
        if [[ -f /etc/initcpio/install/acpi_override ]]; then
            sudo rm -f /etc/initcpio/install/acpi_override
            echo "  ✓ Removed /etc/initcpio/install/acpi_override"
        fi
    else
        echo "  ✓ /etc/acpi_override/ still has files (fan fix present) — initramfs config kept"
    fi
fi

# Check for Andy's ipu-bridge DKMS fix (may coexist on some systems)
if dkms status "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}" 2>/dev/null | grep -q "ipu-bridge-fix"; then
    sudo dkms remove "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}" --all 2>/dev/null || true
    echo "  ✓ ipu-bridge-fix DKMS module removed"
    sudo depmod -a 2>/dev/null || true
else
    echo "  ✓ ipu-bridge-fix DKMS module not installed (nothing to remove)"
fi
if [[ -d "$IPU_BRIDGE_FIX_SRC" ]]; then
    sudo rm -rf "$IPU_BRIDGE_FIX_SRC"
    echo "  ✓ Removed ${IPU_BRIDGE_FIX_SRC}"
fi

# Remove ipu-bridge upstream check script and service (Andy's fix)
if [[ -f /etc/systemd/system/ipu-bridge-check-upstream.service ]]; then
    sudo systemctl disable ipu-bridge-check-upstream.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/ipu-bridge-check-upstream.service
    sudo rm -f /usr/local/sbin/ipu-bridge-check-upstream.sh
    echo "  ✓ ipu-bridge upstream check service removed"
fi

# Remove cam-rot upstream monitor (installed with ACPI SSDT override method)
if [[ -f /etc/systemd/system/cam-rot-check-upstream.service ]]; then
    sudo systemctl disable cam-rot-check-upstream.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/cam-rot-check-upstream.service
    sudo rm -f /usr/local/sbin/cam-rot-check-upstream.sh
    echo "  ✓ cam-rot upstream check service removed"
fi

# initramfs will be rebuilt at end of script

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
# Stop any running relay — use the real desktop user's session bus
_relay_user=$(loginctl list-sessions --no-legend 2>/dev/null \
    | awk '$4 == "seat0" {print $3}' | head -1)
_relay_uid=$(id -u "$_relay_user" 2>/dev/null)
if [[ -n "$_relay_user" ]] && [[ -x /usr/local/bin/camera-relay ]]; then
    sudo -u "$_relay_user" \
        XDG_RUNTIME_DIR="/run/user/${_relay_uid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_relay_uid}/bus" \
        /usr/local/bin/camera-relay stop 2>/dev/null || true
fi
# Disable persistent mode for all users who have the service file
for user_home in /home/*; do
    service_file="$user_home/.config/systemd/user/camera-relay.service"
    if [[ -f "$service_file" ]]; then
        user=$(basename "$user_home")
        uid=$(id -u "$user" 2>/dev/null)
        sudo -u "$user" \
            XDG_RUNTIME_DIR="/run/user/${uid}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
            systemctl --user disable camera-relay.service 2>/dev/null || true
        rm -f "$service_file"
    fi
done
sudo rm -f /usr/local/bin/camera-relay
sudo rm -f /usr/local/bin/camera-relay-monitor
sudo rm -rf /usr/local/share/camera-relay
sudo rm -f /usr/share/applications/camera-relay-systray.desktop
# Kill the systray process if running — files are gone so it can't function anyway
if [[ -n "$_relay_user" ]]; then
    if pkill -u "$_relay_user" -f "camera-relay-systray" 2>/dev/null; then
        echo "  ✓ camera-relay systray process terminated"
    else
        echo "  ✓ camera-relay systray not running — skipping"
    fi
fi
# Only remove our v4l2loopback config if it's ours
if [[ -f /etc/modprobe.d/99-camera-relay-loopback.conf ]] && \
   grep -q "Camera Relay" /etc/modprobe.d/99-camera-relay-loopback.conf 2>/dev/null; then
    sudo rm -f /etc/modprobe.d/99-camera-relay-loopback.conf
    sudo rm -f /etc/modules-load.d/v4l2loopback.conf
    NEEDS_INITRAMFS_REBUILD=true
fi
echo "  ✓ Camera relay tool removed"

# [11/11] Remove environment configs
echo "[11/11] Removing environment configuration..."
sudo rm -f /etc/environment.d/libcamera-ipa.conf
sudo rm -f /etc/profile.d/libcamera-ipa.sh
echo "  ✓ Removed libcamera environment files"

# ──────────────────────────────────────────────
# Rebuild initramfs (single pass — covers all changes)
# ──────────────────────────────────────────────
echo ""
echo "Rebuilding initramfs..."
if [[ "${SKIP_INITRAMFS:-0}" == "1" ]]; then
    echo "  ✓ Skipping initramfs rebuild (will be done at end of Uninstall All)."
elif $NEEDS_INITRAMFS_REBUILD; then
    if command -v dracut >/dev/null 2>&1; then
        sudo dracut --force 2>/dev/null && echo "  ✓ initramfs rebuilt" ||             echo "  ⚠ initramfs rebuild failed — reboot may not fully restore original state"
    elif command -v update-initramfs >/dev/null 2>&1; then
        sudo update-initramfs -u -k "$(uname -r)" 2>/dev/null &&             echo "  ✓ initramfs rebuilt" ||             echo "  ⚠ initramfs rebuild failed — reboot may not fully restore original state"
    elif command -v mkinitcpio >/dev/null 2>&1; then
        sudo mkinitcpio -P 2>/dev/null && echo "  ✓ initramfs rebuilt" ||             echo "  ⚠ initramfs rebuild failed — reboot may not fully restore original state"
    fi
else
    echo "  ✓ No initramfs rebuild needed"
fi

echo ""
echo "=============================================="
echo "  Uninstall complete."
echo ""
echo "  Note: Distro packages (libcamera, pipewire-libcamera, etc.) were NOT"
echo "  removed — you may need them for other purposes. Remove manually if desired."
echo ""
echo "  Reboot to fully restore the original state."
echo ""

# WirePlumber config changes take effect on next login/reboot.
# Do not restart PipeWire/WirePlumber here — restarting WirePlumber while
# the IPU7 camera stack (libcamera) is active causes a deadlock crash.

echo "=============================================="
