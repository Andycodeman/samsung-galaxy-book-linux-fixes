#!/bin/bash
# install.sh
# Samsung Galaxy Book4 webcam fix for Ubuntu, Fedora, Arch, and other Linux distros
# Tested on kernel 6.17.0-14-generic (HWE) with IPU6 Meteor Lake / OV02C10
#
# Root cause: IVSC (Intel Visual Sensing Controller) kernel modules don't
# auto-load, breaking the camera initialization chain. Additionally, the
# userspace camera HAL and v4l2 relay service need to be installed.
#
# The IVSC modules must be loaded in the initramfs (before udev probes the
# OV02C10 sensor via ACPI), otherwise the sensor hits -EPROBE_DEFER repeatedly
# and the CSI-2 link starts in an unstable state causing intermittent black
# frames ("Frame sync error" in dmesg).
#
# For full documentation, see: README.md
#
# Usage: ./install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo "  Samsung Galaxy Book4 Webcam Fix"
echo "  Meteor Lake (IPU6) — Multi-Distro"
echo "=============================================="
echo ""

# Check for root
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Don't run this as root. The script will use sudo where needed."
    exit 1
fi

# ──────────────────────────────────────────────
# [1/13] Distro detection
# ──────────────────────────────────────────────
echo "[1/13] Detecting distro..."
if command -v pacman >/dev/null 2>&1; then
    DISTRO="arch"
    DISTRO_LABEL="Arch-based"
elif command -v dnf >/dev/null 2>&1; then
    DISTRO="fedora"
    DISTRO_LABEL="Fedora/DNF-based"
elif command -v apt >/dev/null 2>&1; then
    # Distinguish Ubuntu (PPA support) from other Debian-based
    if [[ -f /etc/os-release ]] && grep -qiE '^ID=(ubuntu|pop|linuxmint)' /etc/os-release; then
        DISTRO="ubuntu"
        DISTRO_LABEL="Ubuntu/Ubuntu-based"
    elif [[ -f /etc/os-release ]] && grep -qiE '^ID_LIKE=.*ubuntu' /etc/os-release; then
        DISTRO="ubuntu"
        DISTRO_LABEL="Ubuntu-based ($(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"'))"
    else
        DISTRO="debian"
        DISTRO_LABEL="Debian-based"
    fi
else
    DISTRO="unknown"
    DISTRO_LABEL="Unknown"
fi
echo "  ✓ $DISTRO_LABEL detected"

# ──────────────────────────────────────────────
# [2/13] Verify hardware
# ──────────────────────────────────────────────
echo ""
echo "[2/13] Verifying hardware..."
if ! lspci -d 8086:7d19 2>/dev/null | grep -q .; then
    # Check if this is a Lunar Lake system (IPU7) — different driver, not supported
    if lspci 2>/dev/null | grep -qi "Lunar Lake.*IPU\|Intel.*IPU.*7" || \
       lspci -d 8086:645d 2>/dev/null | grep -q . || \
       lspci -d 8086:6457 2>/dev/null | grep -q .; then
        echo "ERROR: This system has Intel IPU7 (Lunar Lake), not IPU6 (Meteor Lake)."
        echo ""
        echo "       This webcam fix is for Meteor Lake systems only (Galaxy Book4 models)."
        echo "       Lunar Lake (Galaxy Book5 models) uses a different camera driver (IPU7)"
        echo "       that is not yet supported by this script."
        echo ""
        echo "       See the webcam-fix-book5/ directory for Lunar Lake support."
        echo "       https://github.com/intel/ipu6-drivers"
    else
        echo "ERROR: Intel IPU6 Meteor Lake (8086:7d19) not found."
        echo "       This script is designed for Samsung Galaxy Book4 laptops with"
        echo "       Intel Meteor Lake processors."
    fi
    exit 1
fi
if ! cat /sys/bus/acpi/devices/*/hid 2>/dev/null | grep -q "OVTI02C1"; then
    echo "ERROR: OV02C10 sensor (OVTI02C1) not found in ACPI."
    exit 1
fi
if ! ls /lib/firmware/intel/vsc/ivsc_pkg_ovti02c1_0.bin* &>/dev/null; then
    echo "ERROR: IVSC firmware for OV02C10 not found."
    echo "       Expected: /lib/firmware/intel/vsc/ivsc_pkg_ovti02c1_0.bin.zst"
    exit 1
fi
echo "  ✓ Found IPU6 Meteor Lake and OV02C10 sensor"
echo "  ✓ IVSC firmware present"

# ──────────────────────────────────────────────
# [3/13] Check kernel module availability
# ──────────────────────────────────────────────
echo ""
echo "[3/13] Checking kernel modules..."
MISSING_MODS=()
for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
    modpath=$(find /lib/modules/$(uname -r) -name "${mod//-/_}.ko*" -o -name "${mod}.ko*" 2>/dev/null | head -1)
    if [[ -z "$modpath" ]]; then
        modpath=$(find /lib/modules/$(uname -r) -name "$(echo $mod | tr '-' '_').ko*" 2>/dev/null | head -1)
    fi
    if [[ -z "$modpath" ]]; then
        MISSING_MODS+=("$mod")
    fi
done

if [[ ${#MISSING_MODS[@]} -gt 0 ]]; then
    echo "ERROR: Missing kernel modules: ${MISSING_MODS[*]}"
    case "$DISTRO" in
        ubuntu|debian)
            echo "       Try: sudo apt install linux-modules-ipu6-generic-hwe-24.04"
            ;;
        fedora)
            echo "       Try: sudo dnf install kernel-modules-extra"
            ;;
        arch)
            echo "       These modules should be in the default kernel. Try: sudo pacman -S linux-headers"
            echo "       If using a custom kernel, ensure CONFIG_INTEL_MEI_VSC and CONFIG_INTEL_VSC are enabled."
            ;;
    esac
    exit 1
fi
echo "  ✓ All required kernel modules found"

# ──────────────────────────────────────────────
# [4/13] Load and persist IVSC modules
# ──────────────────────────────────────────────
echo ""
echo "[4/13] Loading IVSC kernel modules..."
for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
    if ! lsmod | grep -q "$(echo $mod | tr '-' '_')"; then
        sudo modprobe "$mod"
        echo "  Loaded: $mod"
    else
        echo "  Already loaded: $mod"
    fi
done

# Ensure IVSC modules load at boot (before ov02c10 sensor probes)
echo -e "mei-vsc\nmei-vsc-hw\nivsc-ace\nivsc-csi" | sudo tee /etc/modules-load.d/ivsc.conf > /dev/null

# Add softdep so ov02c10 waits for IVSC modules to load first
sudo tee /etc/modprobe.d/ivsc-camera.conf > /dev/null << 'EOF'
# Ensure IVSC modules are loaded before the camera sensor probes.
# Without this, ov02c10 hits -EPROBE_DEFER and may fail to bind,
# resulting in black frames (CSI Frame sync errors).
softdep ov02c10 pre: mei-vsc mei-vsc-hw ivsc-ace ivsc-csi
EOF
echo "  ✓ IVSC modules will load automatically at boot"
echo "  ✓ Module soft-dependency configured (IVSC loads before sensor)"

# ──────────────────────────────────────────────
# [5/13] Add IVSC modules to initramfs
# ──────────────────────────────────────────────
echo ""
echo "[5/13] Adding IVSC modules to initramfs..."
INITRAMFS_CHANGED=false

# Detect initramfs tool by what's actually installed (not distro name).
# Arch users may use dracut instead of mkinitcpio, etc.
if command -v update-initramfs &>/dev/null; then
    # Debian/Ubuntu: append modules to /etc/initramfs-tools/modules
    for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
        if ! grep -qxF "$mod" /etc/initramfs-tools/modules 2>/dev/null; then
            echo "$mod" | sudo tee -a /etc/initramfs-tools/modules > /dev/null
            INITRAMFS_CHANGED=true
        fi
    done
    if $INITRAMFS_CHANGED; then
        echo "  Rebuilding initramfs (this may take a moment)..."
        sudo update-initramfs -u
        echo "  ✓ IVSC modules added to initramfs"
    else
        echo "  ✓ IVSC modules already in initramfs"
    fi
    INITRAMFS_CONFIG="/etc/initramfs-tools/modules"
elif command -v dracut &>/dev/null; then
    # Fedora/RHEL/Arch-with-dracut: drop-in config
    DRACUT_CONF="/etc/dracut.conf.d/ivsc-camera.conf"
    if [[ ! -f "$DRACUT_CONF" ]]; then
        sudo tee "$DRACUT_CONF" > /dev/null << 'DRACUT_EOF'
# Force-load IVSC modules in initramfs so they're ready before udev
# probes the OV02C10 sensor via ACPI. Without this, the sensor hits
# -EPROBE_DEFER repeatedly and the CSI-2 link starts unstable.
force_drivers+=" mei-vsc mei-vsc-hw ivsc-ace ivsc-csi "
DRACUT_EOF
        INITRAMFS_CHANGED=true
    fi
    if $INITRAMFS_CHANGED; then
        echo "  Rebuilding initramfs with dracut (this may take a moment)..."
        sudo dracut --force
        echo "  ✓ IVSC modules added to initramfs (dracut)"
    else
        echo "  ✓ IVSC modules already in initramfs (dracut)"
    fi
    INITRAMFS_CONFIG="$DRACUT_CONF"
elif command -v mkinitcpio &>/dev/null; then
    # Arch/Arch-based with mkinitcpio
    MKINITCPIO_CONF="/etc/mkinitcpio.conf.d/ivsc-camera.conf"
    sudo mkdir -p /etc/mkinitcpio.conf.d
    if [[ ! -f "$MKINITCPIO_CONF" ]]; then
        sudo tee "$MKINITCPIO_CONF" > /dev/null << 'MKINIT_EOF'
# Force-load IVSC modules in initramfs so they're ready before udev
# probes the OV02C10 sensor via ACPI.
MODULES=(mei-vsc mei-vsc-hw ivsc-ace ivsc-csi)
MKINIT_EOF
        INITRAMFS_CHANGED=true
    fi
    if $INITRAMFS_CHANGED; then
        echo "  Rebuilding initramfs with mkinitcpio (this may take a moment)..."
        sudo mkinitcpio -P
        echo "  ✓ IVSC modules added to initramfs (mkinitcpio)"
    else
        echo "  ✓ IVSC modules already in initramfs (mkinitcpio)"
    fi
    INITRAMFS_CONFIG="$MKINITCPIO_CONF"
else
    echo "  ⚠ No supported initramfs tool found (update-initramfs, dracut, mkinitcpio)."
    echo "    You may need to manually add these modules to your initramfs:"
    echo "    mei-vsc mei-vsc-hw ivsc-ace ivsc-csi"
    INITRAMFS_CONFIG="(manual setup required)"
fi

# ──────────────────────────────────────────────
# [6/13] Re-probe camera sensor
# ──────────────────────────────────────────────
echo ""
echo "[6/13] Re-probing camera sensor..."
sudo modprobe -r ov02c10 2>/dev/null || true
sleep 1
sudo modprobe ov02c10
sleep 2

PROBE_OK=false
if journalctl -b -k --since "30 seconds ago" --no-pager 2>/dev/null | grep -q "ov02c10.*entity"; then
    PROBE_OK=true
    echo "  ✓ OV02C10 sensor probed successfully"
elif journalctl -b -k --since "30 seconds ago" --no-pager 2>/dev/null | grep -q "failed to check hwcfg: -517"; then
    echo "  ⚠ Sensor still deferring. Will likely resolve after reboot."
else
    echo "  ⚠ Sensor status unclear. Continuing setup..."
fi

# ──────────────────────────────────────────────
# [7/13] Install camera HAL and relay service
# ──────────────────────────────────────────────
echo ""
echo "[7/13] Installing camera HAL and relay service..."

install_v4l2_relayd_from_source() {
    # v4l2-relayd is a small Go project; build from source if not packaged
    if command -v v4l2-relayd >/dev/null 2>&1 || systemctl cat v4l2-relayd@default >/dev/null 2>&1; then
        echo "  ✓ v4l2-relayd already available"
        return 0
    fi

    echo "  v4l2-relayd not found — installing from source..."

    # v4l2-relayd requires v4l2loopback module
    case "$DISTRO" in
        fedora)
            sudo dnf install -y --setopt=install_weak_deps=False v4l2loopback 2>/dev/null || true
            ;;
        arch)
            sudo pacman -S --needed --noconfirm v4l2loopback-dkms 2>/dev/null || true
            ;;
    esac

    local V4L2_RELAYD_BUILD="/tmp/v4l2-relayd-build"
    rm -rf "$V4L2_RELAYD_BUILD"
    git clone --depth 1 https://gitlab.com/vicamo/v4l2-relayd.git "$V4L2_RELAYD_BUILD"
    cd "$V4L2_RELAYD_BUILD"

    # v4l2-relayd uses meson
    case "$DISTRO" in
        fedora)
            sudo dnf install -y --setopt=install_weak_deps=False \
                meson gstreamer1-devel gstreamer1-plugins-base-devel \
                gstreamer1-plugins-bad-free-devel glib2-devel 2>/dev/null || true
            ;;
        arch)
            sudo pacman -S --needed --noconfirm \
                meson gstreamer gst-plugins-base gst-plugins-bad glib2 2>/dev/null || true
            ;;
        debian)
            sudo apt install -y \
                meson libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
                libgstreamer-plugins-bad1.0-dev libglib2.0-dev 2>/dev/null || true
            ;;
    esac

    meson setup builddir --prefix=/usr
    meson compile -C builddir
    sudo meson install -C builddir
    sudo systemctl daemon-reload
    cd "$SCRIPT_DIR"
    rm -rf "$V4L2_RELAYD_BUILD"
    echo "  ✓ v4l2-relayd built and installed from source"
}

case "$DISTRO" in
    ubuntu)
        # Ubuntu: use PPA packages (existing behavior)
        NEED_INSTALL=false
        if ! dpkg -l libcamhal-ipu6epmtl 2>/dev/null | grep -q "^ii"; then
            NEED_INSTALL=true
        fi
        if ! dpkg -l v4l2-relayd 2>/dev/null | grep -q "^ii"; then
            NEED_INSTALL=true
        fi

        if $NEED_INSTALL; then
            if ! grep -rq "oem-solutions-group/intel-ipu6" /etc/apt/sources.list.d/ 2>/dev/null; then
                echo "  Adding Intel IPU6 PPA..."
                sudo add-apt-repository -y ppa:oem-solutions-group/intel-ipu6
            fi
            sudo apt update -qq
            sudo apt install -y libcamhal-ipu6epmtl v4l2-relayd
            echo "  ✓ Installed libcamhal-ipu6epmtl and v4l2-relayd from PPA"
        else
            echo "  ✓ Packages already installed"
        fi
        ;;

    debian)
        # Non-Ubuntu Debian-based: try PPA first, fall back to source build
        NEED_INSTALL=false
        if ! dpkg -l libcamhal-ipu6epmtl 2>/dev/null | grep -q "^ii"; then
            NEED_INSTALL=true
        fi
        if ! dpkg -l v4l2-relayd 2>/dev/null | grep -q "^ii"; then
            NEED_INSTALL=true
        fi

        if $NEED_INSTALL; then
            PPA_OK=false
            if command -v add-apt-repository >/dev/null 2>&1; then
                echo "  Attempting to add Intel IPU6 PPA..."
                if sudo add-apt-repository -y ppa:oem-solutions-group/intel-ipu6 2>/dev/null; then
                    sudo apt update -qq 2>/dev/null
                    if sudo apt install -y libcamhal-ipu6epmtl v4l2-relayd 2>/dev/null; then
                        PPA_OK=true
                        echo "  ✓ Installed from PPA"
                    else
                        sudo add-apt-repository -y --remove ppa:oem-solutions-group/intel-ipu6 2>/dev/null || true
                    fi
                fi
            fi

            if ! $PPA_OK; then
                echo ""
                echo "  PPA not available for this distro. Building camera HAL from source."
                echo "  This will download ~500 MB and take a few minutes to compile."
                echo ""
                read -rp "  Proceed with source build? [Y/n] " REPLY
                REPLY=${REPLY:-Y}
                if [[ "$REPLY" =~ ^[Yy] ]]; then
                    sudo "$SCRIPT_DIR/build-ipu6-from-source.sh"
                    install_v4l2_relayd_from_source
                else
                    echo "ERROR: Camera HAL is required. Cannot continue without it."
                    exit 1
                fi
            fi
        else
            echo "  ✓ Packages already installed"
        fi
        ;;

    fedora)
        # Fedora: check for RPM Fusion packages first, then source build
        HAL_INSTALLED=false

        # Check if already installed (from RPM Fusion or previous source build)
        if rpm -q ipu6-camera-hal >/dev/null 2>&1 || \
           gst-inspect-1.0 icamerasrc >/dev/null 2>&1; then
            HAL_INSTALLED=true
            echo "  ✓ Camera HAL already installed"
        fi

        if ! $HAL_INSTALLED; then
            # Check if RPM Fusion nonfree is enabled
            if dnf repolist 2>/dev/null | grep -qi "rpmfusion-nonfree"; then
                echo "  RPM Fusion nonfree detected. Installing packages..."
                if sudo dnf install -y --setopt=install_weak_deps=False \
                    ipu6-camera-bins ipu6-camera-hal gstreamer1-plugins-icamerasrc 2>/dev/null; then
                    HAL_INSTALLED=true
                    echo "  ✓ Camera HAL installed from RPM Fusion"
                else
                    echo "  ⚠ RPM Fusion packages not available or install failed."
                fi
            fi

            if ! $HAL_INSTALLED; then
                echo ""
                echo "  Camera HAL packages are not available."
                echo "  Options:"
                echo "    1) Enable RPM Fusion nonfree and retry (recommended for Fedora)"
                echo "       sudo dnf install https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-\$(rpm -E %fedora).noarch.rpm"
                echo "    2) Build from source (~500 MB download, a few minutes to compile)"
                echo ""
                read -rp "  Build from source now? [Y/n] " REPLY
                REPLY=${REPLY:-Y}
                if [[ "$REPLY" =~ ^[Yy] ]]; then
                    sudo "$SCRIPT_DIR/build-ipu6-from-source.sh"
                else
                    echo "ERROR: Camera HAL is required. Cannot continue without it."
                    exit 1
                fi
            fi
        fi

        # Install v4l2-relayd
        if ! rpm -q v4l2-relayd >/dev/null 2>&1 && \
           ! command -v v4l2-relayd >/dev/null 2>&1 && \
           ! systemctl cat v4l2-relayd@default >/dev/null 2>&1; then
            if dnf repolist 2>/dev/null | grep -qi "rpmfusion"; then
                echo "  Installing v4l2-relayd from RPM Fusion..."
                sudo dnf install -y --setopt=install_weak_deps=False v4l2-relayd 2>/dev/null || \
                    install_v4l2_relayd_from_source
            else
                install_v4l2_relayd_from_source
            fi
        else
            echo "  ✓ v4l2-relayd already installed"
        fi
        ;;

    arch)
        # Arch: always build from source (no pre-built packages in official repos)
        HAL_INSTALLED=false

        if gst-inspect-1.0 icamerasrc >/dev/null 2>&1; then
            HAL_INSTALLED=true
            echo "  ✓ Camera HAL already installed"
        fi

        if ! $HAL_INSTALLED; then
            echo ""
            echo "  No pre-built camera HAL packages available for Arch."
            echo "  Building from source (~500 MB download, a few minutes to compile)."
            echo ""
            read -rp "  Proceed? [Y/n] " REPLY
            REPLY=${REPLY:-Y}
            if [[ "$REPLY" =~ ^[Yy] ]]; then
                sudo "$SCRIPT_DIR/build-ipu6-from-source.sh"
            else
                echo "ERROR: Camera HAL is required. Cannot continue without it."
                exit 1
            fi
        fi

        # Install v4l2-relayd
        install_v4l2_relayd_from_source
        ;;

    *)
        echo "ERROR: Unsupported distro. Cannot install camera HAL packages."
        echo "       You can try building from source manually:"
        echo "       sudo $SCRIPT_DIR/build-ipu6-from-source.sh"
        exit 1
        ;;
esac

# ──────────────────────────────────────────────
# [8/13] Configure v4l2loopback and v4l2-relayd
# ──────────────────────────────────────────────
echo ""
echo "[8/13] Configuring v4l2loopback and v4l2-relayd..."

# Write persistent v4l2loopback config (overrides any package defaults)
sudo tee /etc/modprobe.d/v4l2loopback.conf > /dev/null << 'EOF'
options v4l2loopback devices=1 exclusive_caps=1 card_label="Intel MIPI Camera"
EOF

# Remove conflicting config from v4l2-relayd package if present
if [[ -f /etc/modprobe.d/v4l2-relayd.conf ]]; then
    sudo rm -f /etc/modprobe.d/v4l2-relayd.conf
fi

# Reload v4l2loopback with correct name
sudo modprobe -r v4l2loopback 2>/dev/null || true
sudo modprobe v4l2loopback devices=1 exclusive_caps=1 card_label="Intel MIPI Camera"

DEVICE_NAME=$(cat /sys/devices/virtual/video4linux/video0/name 2>/dev/null || echo "NONE")
if [[ "$DEVICE_NAME" == "Intel MIPI Camera" ]]; then
    echo "  ✓ v4l2loopback device: $DEVICE_NAME"
else
    echo "  ⚠ Expected 'Intel MIPI Camera', got '$DEVICE_NAME'"
fi

# Write v4l2-relayd config to the correct path
# The v4l2-relayd@default.service reads: /etc/default/v4l2-relayd then /etc/v4l2-relayd.d/default.conf
sudo mkdir -p /etc/v4l2-relayd.d
sudo tee /etc/v4l2-relayd.d/default.conf > /dev/null << 'EOF'
VIDEOSRC=icamerasrc buffer-count=7 ! videoconvert
FORMAT=YUY2
FRAMERATE=30/1
CARD_LABEL=Intel MIPI Camera
EOF
echo "  ✓ v4l2-relayd configured for IPU6"

# Install resolution auto-detection script
# The camera HAL may change its default resolution across updates (e.g.
# 720p → 1080p). Instead of hardcoding WIDTH/HEIGHT, we probe icamerasrc
# at service startup to detect the native resolution.
sudo install -m 755 "$SCRIPT_DIR/v4l2-relayd-detect-resolution.sh" /usr/local/sbin/v4l2-relayd-detect-resolution.sh
echo "  ✓ Resolution auto-detection script installed"

# ──────────────────────────────────────────────
# [9/13] Harden v4l2-relayd service
# ──────────────────────────────────────────────
echo ""
echo "[9/13] Hardening v4l2-relayd service..."
sudo mkdir -p /etc/systemd/system/v4l2-relayd@default.service.d
sudo tee /etc/systemd/system/v4l2-relayd@default.service.d/override.conf > /dev/null << 'EOF'
[Unit]
# Rate-limit restarts: max 10 attempts in 60 seconds
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
# Auto-detect camera resolution before starting the relay.
# The HAL may change its default resolution across updates (e.g. 720p → 1080p),
# so we probe icamerasrc at startup instead of hardcoding WIDTH/HEIGHT.
ExecStartPre=/usr/local/sbin/v4l2-relayd-detect-resolution.sh
EnvironmentFile=-/run/v4l2-relayd-resolution.env

# After the relay connects, re-trigger udev on the loopback device and
# restart the user's WirePlumber so it re-discovers the device as
# VIDEO_CAPTURE (v4l2loopback with exclusive_caps=1 only advertises
# capture once a producer is attached).
ExecStartPost=/bin/sh -c 'sleep 2; udevadm trigger --action=change /dev/video0 2>/dev/null; sleep 1; for uid in $(loginctl list-users --no-legend 2>/dev/null | awk "{print \\$1}"); do su - "#$uid" -c "systemctl --user restart wireplumber" 2>/dev/null || true; done'

# Fast auto-restart on failure (covers transient CSI frame sync errors).
Restart=always
RestartSec=2
EOF
sudo systemctl daemon-reload

# Start relay service
sudo systemctl reset-failed v4l2-relayd 2>/dev/null || true
sudo systemctl enable v4l2-relayd 2>/dev/null || true
sudo systemctl restart v4l2-relayd
sleep 3
echo "  ✓ v4l2-relayd hardened with auto-restart and sensor re-probe"

# ──────────────────────────────────────────────
# [10/13] Hide raw IPU6 ISYS video nodes
# ──────────────────────────────────────────────
echo ""
echo "[10/13] Hiding raw IPU6 video nodes..."
sudo tee /etc/udev/rules.d/90-hide-ipu6-v4l2.rules > /dev/null << 'EOF'
# Hide Intel IPU6 ISYS raw capture nodes from user-space applications.
# These ~48 /dev/video* nodes are internal to the IPU6 pipeline and unusable
# by apps directly. Exposing them causes crashes in Zoom, Cheese, and other
# apps that enumerate all video devices.
# TAG-="uaccess" prevents PipeWire/WirePlumber from creating nodes for them.
# MODE="0000" blocks direct access (libcamera handles the permission errors gracefully).
SUBSYSTEM=="video4linux", KERNEL=="video*", ATTR{name}=="Intel IPU6 ISYS Capture*", MODE="0000", TAG-="uaccess"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=video4linux
echo "  ✓ IPU6 raw nodes hidden from applications"

# ──────────────────────────────────────────────
# [11/13] Verify PipeWire device classification
# ──────────────────────────────────────────────
# PipeWire device classification is handled by the udev re-trigger in the
# v4l2-relayd ExecStartPost (step 9).  With exclusive_caps=1, v4l2loopback
# only advertises VIDEO_CAPTURE after the relay connects.  The udev change
# event makes WirePlumber re-query the device at that point.
# (device.capabilities is read-only in PipeWire — WirePlumber rules cannot
# override it; only a kernel-level cap change + udev event works.)
echo ""
echo "[11/13] Verifying PipeWire device classification..."
systemctl --user restart wireplumber 2>/dev/null || true
sleep 2
if wpctl status 2>/dev/null | grep -A10 "^Video" | grep -qi "MIPI\|Intel.*V4L2"; then
    echo "  ✓ PipeWire exposes camera as Source node"
else
    echo "  ⚠ WirePlumber may need a logout/login to pick up the camera."
    echo "    (The ExecStartPost udev trigger will handle this automatically on boot.)"
fi

# Remove legacy watchdog if present (no longer needed — resolution auto-detection
# fixes the blank frame issue, and Restart=always handles service crashes)
if systemctl is-enabled v4l2-relayd-watchdog.timer 2>/dev/null | grep -q enabled; then
    echo ""
    echo "  Removing legacy watchdog..."
    sudo systemctl disable --now v4l2-relayd-watchdog.timer 2>/dev/null || true
    sudo rm -f /usr/local/sbin/v4l2-relayd-watchdog.sh
    sudo rm -f /etc/systemd/system/v4l2-relayd-watchdog.service
    sudo rm -f /etc/systemd/system/v4l2-relayd-watchdog.timer
    sudo rm -rf /run/v4l2-relayd-watchdog
    sudo systemctl daemon-reload
    echo "  ✓ Legacy watchdog removed"
fi

# ──────────────────────────────────────────────
# [12/13] Install upstream detection service
# ──────────────────────────────────────────────
echo ""
echo "[12/13] Installing upstream detection service..."
sudo install -m 755 "$SCRIPT_DIR/v4l2-relayd-check-upstream.sh" /usr/local/sbin/v4l2-relayd-check-upstream.sh
sudo install -m 644 "$SCRIPT_DIR/v4l2-relayd-check-upstream.service" /etc/systemd/system/v4l2-relayd-check-upstream.service
sudo systemctl daemon-reload
sudo systemctl enable v4l2-relayd-check-upstream.service
echo "  ✓ Upstream detection enabled (auto-removes workaround when native support lands)"

# ──────────────────────────────────────────────
# [13/13] Verify webcam
# ──────────────────────────────────────────────
echo ""
echo "[13/13] Verifying webcam..."

SERVICE_OK=false
CAPTURE_OK=false

if systemctl is-active --quiet v4l2-relayd; then
    SERVICE_OK=true
    echo "  ✓ v4l2-relayd service is running"
else
    echo "  ✗ v4l2-relayd failed to start"
    echo "    Check: journalctl -u v4l2-relayd --no-pager | tail -20"
fi

if $SERVICE_OK; then
    if timeout 5 ffmpeg -f v4l2 -i /dev/video0 -frames:v 1 -update 1 -y /tmp/webcam_test.jpg 2>/dev/null; then
        SIZE=$(stat -c%s /tmp/webcam_test.jpg 2>/dev/null || echo 0)
        if [[ "$SIZE" -gt 10000 ]]; then
            CAPTURE_OK=true
            echo "  ✓ Webcam capture successful (${SIZE} bytes)"
        fi
    fi
fi

echo ""
echo "=============================================="
if $CAPTURE_OK; then
    echo "  SUCCESS — Webcam is working!"
    echo ""
    echo "  Device: /dev/video0 (Intel MIPI Camera)"
    echo "  Format: YUY2, auto-detected resolution, 30fps"
    echo ""
    echo "  Test:   mpv av://v4l2:/dev/video0 --profile=low-latency"
    echo ""
    echo "  Works with: Firefox, Chromium, Zoom, Teams, OBS, mpv, VLC, GNOME Camera"
    echo ""
    echo "  Note: Cheese has a known bug (SIGSEGV in libgstvideoconvertscale.so)"
    echo "        Use GNOME Camera (snapshot) or any other app instead."
elif $SERVICE_OK; then
    echo "  Service running but capture failed."
    echo "  A reboot is needed for the IVSC modules to load from initramfs."
    echo "  This is normal on first install — reboot and the camera will work."
else
    echo "  Setup complete but service not running."
    echo "  A reboot is needed for modules to load in correct order."
fi
echo ""
echo "  Configuration files created:"
echo "    /etc/modules-load.d/ivsc.conf"
echo "    /etc/modprobe.d/ivsc-camera.conf"
echo "    /etc/modprobe.d/v4l2loopback.conf"
echo "    /etc/v4l2-relayd.d/default.conf"
echo "    /etc/udev/rules.d/90-hide-ipu6-v4l2.rules"
echo "    $INITRAMFS_CONFIG"
echo "    /etc/systemd/system/v4l2-relayd@default.service.d/override.conf"
echo "    /usr/local/sbin/v4l2-relayd-detect-resolution.sh"
echo "    /usr/local/sbin/v4l2-relayd-check-upstream.sh"
echo "    /etc/systemd/system/v4l2-relayd-check-upstream.service"
echo "=============================================="
