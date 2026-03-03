#!/bin/bash
# install.sh
# Samsung Galaxy Book webcam fix using libcamera (open-source stack)
# Supports: Galaxy Book3 (Raptor Lake / IPU6), Galaxy Book4 (Meteor Lake / IPU6)
# Distros:  Ubuntu, Fedora, Arch (and derivatives)
#
# This is the recommended webcam fix for Book3/Book4. It uses the open-source
# libcamera Simple pipeline handler with Software ISP to access the camera
# directly through PipeWire. A legacy proprietary stack (icamerasrc + v4l2-relayd)
# exists in webcam-fix/ but is not recommended.
#
# Advantages over the proprietary stack:
#   - No proprietary firmware HAL binaries
#   - Works through PipeWire natively (apps access camera on-demand)
#   - On-demand camera relay for non-PipeWire apps (Zoom, OBS, VLC)
#     with near-zero idle CPU/battery usage
#   - Supports both Meteor Lake and Raptor Lake IPU6 variants
#
# Pipeline: IVSC -> OV02C10 -> IPU6 ISYS -> libcamera SimplePipeline -> PipeWire
#
# Requirements:
#   - Kernel 6.10+ (IPU6 ISYS driver in mainline)
#   - libcamera 0.4.0+ (SimplePipelineHandler with IPU6 support on x86)
#   - PipeWire with libcamera SPA plugin
#
# Usage: ./install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBCAMERA_MIN_VER="0.4.0"
LIBCAMERA_BUILD_VER="v0.4.0"
LIBCAMERA_BUILD_DIR="/tmp/libcamera-ipu6-build"

echo "=============================================="
echo "  Samsung Galaxy Book Webcam Fix (libcamera)"
echo "  Book3 / Book4 — IPU6 Open-Source Stack"
echo "=============================================="
echo ""

# ──────────────────────────────────────────────
# [1/15] Root check
# ──────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Don't run this as root. The script will use sudo where needed."
    exit 1
fi

# ──────────────────────────────────────────────
# [2/15] Distro detection
# ──────────────────────────────────────────────
echo "[2/15] Detecting distro..."
if command -v pacman >/dev/null 2>&1; then
    DISTRO="arch"
    DISTRO_LABEL="Arch-based"
elif command -v dnf >/dev/null 2>&1; then
    DISTRO="fedora"
    DISTRO_LABEL="Fedora/DNF-based"
elif command -v apt >/dev/null 2>&1; then
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
    echo "ERROR: Unsupported distro. This script requires pacman (Arch), dnf (Fedora), or apt (Ubuntu)."
    exit 1
fi
echo "  ✓ $DISTRO_LABEL detected"

# ──────────────────────────────────────────────
# [3/15] Verify hardware
# ──────────────────────────────────────────────
echo ""
echo "[3/15] Verifying hardware..."

IPU_GENERATION=""
if lspci -d 8086:7d19 2>/dev/null | grep -q .; then
    IPU_GENERATION="meteor_lake"
    echo "  ✓ Found IPU6 Meteor Lake (Galaxy Book4)"
elif lspci -d 8086:a75d 2>/dev/null | grep -q .; then
    IPU_GENERATION="raptor_lake"
    echo "  ✓ Found IPU6 Raptor Lake (Galaxy Book3)"
else
    # Check for IPU7 (Lunar Lake) — redirect to Book5 fix
    if lspci -d 8086:645d 2>/dev/null | grep -q . || \
       lspci -d 8086:6457 2>/dev/null | grep -q .; then
        echo "ERROR: This system has Intel IPU7 (Lunar Lake), not IPU6."
        echo "       Use the webcam-fix-book5/ directory instead."
    else
        echo "ERROR: No supported Intel IPU6 device found."
        echo "       Supported: Meteor Lake (8086:7d19), Raptor Lake (8086:a75d)"
        echo ""
        echo "       If you have a different IPU6 variant, please open an issue"
        echo "       with your 'lspci -nn' output."
    fi
    exit 1
fi

# Check for OV02C10 sensor
if ! cat /sys/bus/acpi/devices/*/hid 2>/dev/null | grep -q "OVTI02C1"; then
    echo "ERROR: OV02C10 sensor (OVTI02C1) not found in ACPI."
    echo "       This script is designed for laptops with the OV02C10 webcam sensor."
    exit 1
fi
echo "  ✓ OV02C10 sensor found"

# Check for IVSC firmware
if ! ls /lib/firmware/intel/vsc/ivsc_pkg_ovti02c1_0.bin* &>/dev/null; then
    echo "ERROR: IVSC firmware for OV02C10 not found."
    echo "       Expected: /lib/firmware/intel/vsc/ivsc_pkg_ovti02c1_0.bin.zst"
    echo ""
    case "$DISTRO" in
        ubuntu|debian)
            echo "       Try: sudo apt install linux-firmware"
            ;;
        fedora)
            echo "       Try: sudo dnf install linux-firmware"
            ;;
        arch)
            echo "       Try: sudo pacman -S linux-firmware"
            ;;
    esac
    exit 1
fi
echo "  ✓ IVSC firmware present"

# ──────────────────────────────────────────────
# [4/15] Check kernel version
# ──────────────────────────────────────────────
echo ""
echo "[4/15] Checking kernel version..."
KERNEL_VER=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL_VER" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_VER" | cut -d. -f2)

if [[ "$KERNEL_MAJOR" -lt 6 ]] || { [[ "$KERNEL_MAJOR" -eq 6 ]] && [[ "$KERNEL_MINOR" -lt 10 ]]; }; then
    echo "ERROR: Kernel $KERNEL_VER is too old."
    echo "       IPU6 ISYS driver requires kernel 6.10 or newer."
    echo ""
    case "$DISTRO" in
        ubuntu|debian)
            echo "       Try: sudo apt install linux-generic-hwe-24.04"
            ;;
        fedora)
            echo "       Try: sudo dnf upgrade kernel"
            ;;
        arch)
            echo "       Try: sudo pacman -Syu"
            ;;
    esac
    exit 1
fi
echo "  ✓ Kernel $KERNEL_VER (>= 6.10 required)"

# ──────────────────────────────────────────────
# [5/15] Check kernel modules
# ──────────────────────────────────────────────
echo ""
echo "[5/15] Checking kernel modules..."
MISSING_MODS=()
for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi intel-ipu6 intel-ipu6-isys ov02c10; do
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
            echo "       These modules should be in the default kernel."
            echo "       Try: sudo pacman -S linux-headers"
            ;;
    esac
    exit 1
fi
echo "  ✓ All required kernel modules found"

# ──────────────────────────────────────────────
# [6/15] Check OV02C10 sensor probe (26 MHz clock fix)
# ──────────────────────────────────────────────
echo ""
echo "[6/15] Checking OV02C10 sensor probe status..."

# Some Galaxy Book models (notably Book3/Book4 Ultra with Raptor Lake) have a
# 26 MHz external clock instead of the expected 19.2 MHz. The upstream ov02c10
# driver rejects this, causing the sensor to fail to probe. A DKMS-patched
# driver adds 26 MHz support.

DKMS_26MHZ_NEEDED=false
DKMS_26MHZ_INSTALLED=false

# Check if DKMS fix is already installed
if command -v dkms >/dev/null 2>&1 && dkms status ov02c10/1.0 2>/dev/null | grep -q "installed"; then
    DKMS_26MHZ_INSTALLED=true
    echo "  ✓ OV02C10 26 MHz DKMS fix already installed"
fi

if ! $DKMS_26MHZ_INSTALLED; then
    # Check dmesg for the 26 MHz clock rejection
    if dmesg 2>/dev/null | grep -qi "external clock 26000000 is not supported"; then
        DKMS_26MHZ_NEEDED=true
        echo "  ⚠ Detected 26 MHz external clock error in dmesg."
        echo "    Your hardware has a 26 MHz clock but the kernel driver only supports 19.2 MHz."
        echo "    A DKMS-patched ov02c10 driver is available to fix this."
        echo ""
        read -rp "  Install the patched driver now? [Y/n] " REPLY_26MHZ
        REPLY_26MHZ=${REPLY_26MHZ:-Y}
        if [[ "$REPLY_26MHZ" =~ ^[Yy] ]]; then
            DKMS_FIX_DIR="${SCRIPT_DIR}/../ov02c10-26mhz-fix"
            DKMS_FIX_SCRIPT=""

            if [[ -f "$DKMS_FIX_DIR/install.sh" ]]; then
                DKMS_FIX_SCRIPT="$DKMS_FIX_DIR/install.sh"
            else
                # Files not present locally — download from GitHub
                echo "  Downloading 26 MHz fix from GitHub..."
                DKMS_TMP_DIR="/tmp/ov02c10-26mhz-fix"
                rm -rf "$DKMS_TMP_DIR"
                mkdir -p "$DKMS_TMP_DIR"
                GITHUB_RAW="https://raw.githubusercontent.com/Andycodeman/samsung-galaxy-book4-linux-fixes/main/ov02c10-26mhz-fix"
                for fname in install.sh ov02c10.c Makefile dkms.conf; do
                    if ! curl -fsSL "$GITHUB_RAW/$fname" -o "$DKMS_TMP_DIR/$fname"; then
                        echo "  ERROR: Failed to download $fname"
                        echo "         Please clone the full repo and try again:"
                        echo "         git clone https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes.git"
                        rm -rf "$DKMS_TMP_DIR"
                        break
                    fi
                done
                if [[ -f "$DKMS_TMP_DIR/install.sh" ]]; then
                    DKMS_FIX_SCRIPT="$DKMS_TMP_DIR/install.sh"
                fi
            fi

            if [[ -n "$DKMS_FIX_SCRIPT" ]]; then
                echo "  Running 26 MHz DKMS fix installer..."
                sudo bash "$DKMS_FIX_SCRIPT"

                # Verify the fix worked
                sleep 2
                if dmesg 2>/dev/null | grep -qi "external clock 26000000 is not supported" && \
                   ! dkms status ov02c10/1.0 2>/dev/null | grep -q "installed"; then
                    echo "  ⚠ DKMS fix may not have applied correctly."
                    echo "    A reboot may be needed for the patched driver to load."
                else
                    echo "  ✓ 26 MHz DKMS fix installed successfully"
                fi

                # Clean up temp download
                rm -rf /tmp/ov02c10-26mhz-fix
            else
                echo "  ⚠ Could not locate fix installer. Continuing without the fix."
                echo "    The camera will likely NOT work until this is resolved."
                echo "    See: https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes/tree/main/ov02c10-26mhz-fix"
            fi
        else
            echo "  ⚠ Skipping 26 MHz fix. The camera will likely NOT work without it."
            echo "    You can install it later from: ov02c10-26mhz-fix/install.sh"
        fi
    else
        echo "  ✓ Sensor clock OK (no 26 MHz clock mismatch detected)"
    fi
fi

# ──────────────────────────────────────────────
# [7/15] Load and persist IVSC modules
# ──────────────────────────────────────────────
echo ""
echo "[7/15] Loading IVSC kernel modules..."
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
# Without this, ov02c10 hits -EPROBE_DEFER and may fail to bind.
softdep ov02c10 pre: mei-vsc mei-vsc-hw ivsc-ace ivsc-csi
EOF
echo "  ✓ IVSC modules will load automatically at boot"

# Add IVSC modules to initramfs
echo "  Adding IVSC modules to initramfs..."
INITRAMFS_CHANGED=false

case "$DISTRO" in
    ubuntu|debian)
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
        ;;
    fedora)
        DRACUT_CONF="/etc/dracut.conf.d/ivsc-camera.conf"
        if [[ ! -f "$DRACUT_CONF" ]]; then
            sudo tee "$DRACUT_CONF" > /dev/null << 'DRACUT_EOF'
# Force-load IVSC modules in initramfs so they're ready before udev
# probes the OV02C10 sensor via ACPI.
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
        ;;
    arch)
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
        ;;
    *)
        echo "  ⚠ Unknown initramfs system. Manually add these modules"
        echo "    to your initramfs: mei-vsc mei-vsc-hw ivsc-ace ivsc-csi"
        ;;
esac

# ──────────────────────────────────────────────
# [8/15] Install/build libcamera
# ──────────────────────────────────────────────
echo ""
echo "[8/15] Installing libcamera..."

# Check if a sufficient version is already installed
check_libcamera_version() {
    local ver=""

    # Check /usr/local first (source builds), then system paths
    ver=$(ls -l /usr/local/lib/*/libcamera.so.* /usr/local/lib/libcamera.so.* \
          /usr/lib64/libcamera.so.* /usr/lib/*/libcamera.so.* /usr/lib/libcamera.so.* 2>/dev/null \
        | grep -oP 'libcamera\.so\.\K[0-9]+\.[0-9]+' | sort -V | tail -1 || true)

    if [[ -z "$ver" ]]; then
        echo ""
        return 1
    fi

    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)

    # Need >= 0.4
    if [[ "$major" -gt 0 ]] || { [[ "$major" -eq 0 ]] && [[ "$minor" -ge 4 ]]; }; then
        echo "$ver"
        return 0
    fi

    echo "$ver"
    return 1
}

build_libcamera_from_source() {
    echo "  Building libcamera $LIBCAMERA_BUILD_VER from source..."
    echo "  (This will take a few minutes)"
    echo ""

    # Install build dependencies
    case "$DISTRO" in
        ubuntu|debian)
            sudo apt-get update -qq
            sudo apt-get install -y --no-install-recommends \
                git meson ninja-build pkg-config cmake \
                python3-yaml python3-ply python3-jinja2 \
                libgnutls28-dev libudev-dev libyaml-dev libevent-dev \
                libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
                libdrm-dev libjpeg-dev libtiff-dev \
                openssl libssl-dev libdw-dev libunwind-dev
            ;;
        fedora)
            sudo dnf install -y \
                git meson ninja-build gcc gcc-c++ pkgconfig cmake \
                python3-pyyaml python3-ply python3-jinja2 \
                gnutls-devel libudev-devel libyaml-devel libevent-devel \
                gstreamer1-devel gstreamer1-plugins-base-devel \
                libdrm-devel libjpeg-turbo-devel libtiff-devel \
                openssl openssl-devel elfutils-libelf-devel libunwind-devel
            ;;
        arch)
            sudo pacman -S --needed --noconfirm \
                git meson ninja gcc pkgconf cmake \
                python-yaml python-ply python-jinja \
                gnutls libyaml libevent \
                gstreamer gst-plugins-base \
                libdrm libjpeg-turbo libtiff \
                openssl libelf libunwind
            ;;
    esac

    # Clone and build
    rm -rf "$LIBCAMERA_BUILD_DIR"
    git clone --depth 1 --branch "$LIBCAMERA_BUILD_VER" \
        https://git.libcamera.org/libcamera/libcamera.git "$LIBCAMERA_BUILD_DIR"

    cd "$LIBCAMERA_BUILD_DIR"
    meson setup build \
        -Dprefix=/usr/local \
        -Dpipelines=simple \
        -Dipas=simple \
        -Dgstreamer=enabled \
        -Dv4l2=true \
        -Dcam=enabled \
        -Dqcam=disabled \
        -Dlc-compliance=disabled \
        -Dtracing=disabled \
        -Ddocumentation=disabled \
        -Dpycamera=disabled

    ninja -C build -j$(nproc)
    sudo ninja -C build install
    sudo ldconfig

    cd "$SCRIPT_DIR"
    rm -rf "$LIBCAMERA_BUILD_DIR"
    echo "  ✓ libcamera $LIBCAMERA_BUILD_VER built and installed to /usr/local"
}

LIBCAMERA_VER=$(check_libcamera_version || true)
LIBCAMERA_OK=false
if check_libcamera_version >/dev/null 2>&1; then
    LIBCAMERA_OK=true
fi

case "$DISTRO" in
    fedora)
        if $LIBCAMERA_OK; then
            echo "  ✓ libcamera $LIBCAMERA_VER already installed (>= $LIBCAMERA_MIN_VER)"
        else
            # Fedora 41+ ships libcamera 0.4+ in repos
            echo "  Installing libcamera from Fedora repos..."
            sudo dnf install -y libcamera libcamera-gstreamer libcamera-ipa \
                pipewire-plugin-libcamera 2>/dev/null || true
            LIBCAMERA_VER=$(check_libcamera_version || true)
            if check_libcamera_version >/dev/null 2>&1; then
                echo "  ✓ libcamera $LIBCAMERA_VER installed from repos"
            else
                echo "  Fedora repo version ($LIBCAMERA_VER) is too old. Building from source..."
                build_libcamera_from_source
            fi
        fi
        ;;
    arch)
        if $LIBCAMERA_OK; then
            echo "  ✓ libcamera $LIBCAMERA_VER already installed (>= $LIBCAMERA_MIN_VER)"
        else
            echo "  Installing libcamera from Arch repos..."
            sudo pacman -S --needed --noconfirm libcamera 2>/dev/null || true
            LIBCAMERA_VER=$(check_libcamera_version || true)
            if check_libcamera_version >/dev/null 2>&1; then
                echo "  ✓ libcamera $LIBCAMERA_VER installed from repos"
            else
                echo "  Arch repo version ($LIBCAMERA_VER) is too old. Building from source..."
                build_libcamera_from_source
            fi
        fi
        ;;
    ubuntu|debian)
        if $LIBCAMERA_OK; then
            echo "  ✓ libcamera $LIBCAMERA_VER already installed (>= $LIBCAMERA_MIN_VER)"
        else
            if [[ -n "$LIBCAMERA_VER" ]]; then
                echo "  System libcamera ($LIBCAMERA_VER) is too old (need >= $LIBCAMERA_MIN_VER)."
            else
                echo "  libcamera not found."
            fi
            echo ""
            echo "  Ubuntu/Debian repos ship an older version that doesn't support IPU6."
            echo "  libcamera $LIBCAMERA_BUILD_VER will be built from source and installed to /usr/local."
            echo "  This requires ~200MB of disk space and takes a few minutes."
            echo ""
            read -rp "  Proceed with source build? [Y/n] " REPLY
            REPLY=${REPLY:-Y}
            if [[ "$REPLY" =~ ^[Yy] ]]; then
                build_libcamera_from_source
            else
                echo "ERROR: libcamera >= $LIBCAMERA_MIN_VER is required. Cannot continue."
                exit 1
            fi
        fi
        ;;
esac

# ──────────────────────────────────────────────
# [9/15] Install PipeWire libcamera plugin
# ──────────────────────────────────────────────
echo ""
echo "[9/15] Installing PipeWire libcamera plugin..."

# On Ubuntu/Debian with source-built libcamera, the system PipeWire SPA plugin
# links against the old system libcamera (0.2.x). We need to rebuild the SPA
# plugin against our source-built libcamera (0.4.x).
rebuild_spa_plugin() {
    local PW_VER
    PW_VER=$(pipewire --version 2>/dev/null | grep -oP 'libpipewire \K[0-9]+\.[0-9]+\.[0-9]+' || echo "1.0.5")
    echo "  Rebuilding PipeWire SPA libcamera plugin (PipeWire $PW_VER)..."

    local SPA_BUILD_DIR="/tmp/pipewire-spa-build"
    rm -rf "$SPA_BUILD_DIR"
    git clone --depth 1 --branch "$PW_VER" \
        https://gitlab.freedesktop.org/pipewire/pipewire.git "$SPA_BUILD_DIR" 2>/dev/null || \
    git clone --depth 1 \
        https://gitlab.freedesktop.org/pipewire/pipewire.git "$SPA_BUILD_DIR"

    cd "$SPA_BUILD_DIR"
    PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH \
        meson setup build \
        -Dsession-managers=[] \
        -Dpipewire-jack=disabled \
        -Dpipewire-v4l2=disabled \
        -Djack=disabled \
        -Dbluez5=disabled \
        -Dlibcamera=enabled \
        -Dvulkan=disabled \
        -Dlibpulse=disabled \
        -Droc=disabled \
        -Davahi=disabled \
        -Decho-cancel-webrtc=disabled \
        -Dlibusb=disabled \
        -Draop=disabled \
        -Dffmpeg=disabled \
        -Dman=disabled \
        -Ddocs=disabled \
        -Dtests=disabled \
        -Dexamples=disabled

    ninja -C build spa/plugins/libcamera/libspa-libcamera.so

    # Find the system SPA plugin path and replace it
    local SPA_DIR
    SPA_DIR=$(find /usr/lib -name "libspa-libcamera.so" -path "*/spa-0.2/libcamera/*" 2>/dev/null | head -1)
    if [[ -n "$SPA_DIR" ]]; then
        sudo cp "$SPA_DIR" "${SPA_DIR}.bak"
        sudo cp build/spa/plugins/libcamera/libspa-libcamera.so "$SPA_DIR"
        echo "  ✓ SPA plugin rebuilt and installed (original backed up)"
    else
        # Install to /usr/local instead
        sudo mkdir -p /usr/local/lib/spa-0.2/libcamera
        sudo cp build/spa/plugins/libcamera/libspa-libcamera.so /usr/local/lib/spa-0.2/libcamera/
        echo "  ✓ SPA plugin installed to /usr/local/lib/spa-0.2/libcamera/"
        echo "  ⚠ You may need to set SPA_PLUGIN_DIR to include /usr/local/lib/spa-0.2"
    fi

    cd "$SCRIPT_DIR"
    rm -rf "$SPA_BUILD_DIR"
}

case "$DISTRO" in
    ubuntu|debian)
        # Install the system package first (provides the SPA plugin framework)
        if ! dpkg -l libspa-0.2-libcamera 2>/dev/null | grep -q "^ii"; then
            sudo apt-get install -y libspa-0.2-libcamera
        fi
        # Install IPA modules from repos (may be old but provides file paths)
        if ! dpkg -l libcamera-ipa 2>/dev/null | grep -q "^ii"; then
            sudo apt-get install -y libcamera-ipa 2>/dev/null || true
        fi

        # Check if the installed SPA plugin links against our source-built libcamera
        SPA_SO=$(find /usr/lib -name "libspa-libcamera.so" -path "*/spa-0.2/libcamera/*" 2>/dev/null | head -1)
        if [[ -n "$SPA_SO" ]]; then
            SPA_LIBCAMERA_VER=$(ldd "$SPA_SO" 2>/dev/null | grep -oP 'libcamera\.so\.\K[0-9]+\.[0-9]+' | head -1 || true)
            SPA_LIBCAMERA_MINOR=$(echo "$SPA_LIBCAMERA_VER" | cut -d. -f2)
            if [[ -n "$SPA_LIBCAMERA_MINOR" ]] && [[ "$SPA_LIBCAMERA_MINOR" -lt 4 ]] && \
               [[ -f /usr/local/lib/x86_64-linux-gnu/libcamera.so.0.4 ]]; then
                echo "  SPA plugin links against libcamera $SPA_LIBCAMERA_VER (need >= 0.4)"
                rebuild_spa_plugin
            else
                echo "  ✓ PipeWire libcamera SPA plugin ready"
            fi
        else
            echo "  ⚠ SPA plugin not found — may need manual configuration"
        fi
        ;;
    fedora)
        if ! rpm -q pipewire-plugin-libcamera >/dev/null 2>&1; then
            sudo dnf install -y pipewire-plugin-libcamera 2>/dev/null || true
        fi
        echo "  ✓ PipeWire libcamera plugin installed"
        ;;
    arch)
        # On Arch, the libcamera SPA plugin is typically part of the pipewire package
        if ! pacman -Qi pipewire >/dev/null 2>&1; then
            sudo pacman -S --needed --noconfirm pipewire
        fi
        echo "  ✓ PipeWire (includes libcamera SPA plugin) installed"
        ;;
esac

# ──────────────────────────────────────────────
# [10/15] Install sensor tuning and configure environment
# ──────────────────────────────────────────────
echo ""
echo "[10/15] Installing sensor tuning and environment config..."

# Install OV02C10 tuning file for libcamera Simple ISP
for dir in /usr/local/share/libcamera/ipa/simple /usr/share/libcamera/ipa/simple; do
    if [[ -d "$(dirname "$dir")" ]]; then
        sudo mkdir -p "$dir"
        sudo cp "$SCRIPT_DIR/ov02c10.yaml" "$dir/ov02c10.yaml"
        echo "  ✓ Installed tuning file: $dir/ov02c10.yaml"
    fi
done

# Set IPA module search path for source-built libcamera
if [[ -d /usr/local/lib/x86_64-linux-gnu/libcamera ]]; then
    sudo tee /etc/profile.d/libcamera-ipa.sh > /dev/null << 'EOF'
# libcamera IPA module path for source-built libcamera
export LIBCAMERA_IPA_MODULE_PATH=/usr/local/lib/x86_64-linux-gnu/libcamera
EOF
    sudo mkdir -p /etc/environment.d
    echo "LIBCAMERA_IPA_MODULE_PATH=/usr/local/lib/x86_64-linux-gnu/libcamera" | \
        sudo tee /etc/environment.d/libcamera-ipa.conf > /dev/null
    echo "  ✓ IPA module path configured"
    export LIBCAMERA_IPA_MODULE_PATH=/usr/local/lib/x86_64-linux-gnu/libcamera
fi

# Ensure user is in video group (needed for non-root camera access)
CURRENT_USER="${SUDO_USER:-$USER}"
if ! groups "$CURRENT_USER" 2>/dev/null | grep -q '\bvideo\b'; then
    sudo usermod -aG video "$CURRENT_USER"
    echo "  ✓ Added $CURRENT_USER to video group (takes effect on next login)"
else
    echo "  ✓ User already in video group"
fi

# ──────────────────────────────────────────────
# [11/15] Hide raw IPU6 nodes from PipeWire
# ──────────────────────────────────────────────
echo ""
echo "[11/15] Hiding raw IPU6 nodes from applications..."

# Remove session-level ACL from raw V4L2 nodes (keeps file permissions intact
# so libcamera can still access them via the video group)
sudo tee /etc/udev/rules.d/90-hide-ipu6-v4l2.rules > /dev/null << 'EOF'
# Remove uaccess tag from raw Intel IPU6 ISYS V4L2 nodes.
# libcamera accesses these via /dev/media0 and the video device nodes.
# TAG-="uaccess" removes session-level permissions added by systemd.
SUBSYSTEM=="video4linux", KERNEL=="video*", ATTR{name}=="Intel IPU6 ISYS Capture*", TAG-="uaccess"
SUBSYSTEM=="video4linux", KERNEL=="video*", ATTR{name}=="Intel IPU6 CSI2*", TAG-="uaccess"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --action=change --subsystem-match=video4linux

# WirePlumber rule to hide raw IPU6 V4L2 nodes from PipeWire
# This prevents ~48 unusable "ipu6 (V4L2)" entries in app camera lists.
# Detect WirePlumber version for correct config format
WP_VER=$(wireplumber --version 2>/dev/null | grep -oP 'libwireplumber \K[0-9]+\.[0-9]+' | head -1 || echo "0.4")
WP_MAJOR=$(echo "$WP_VER" | cut -d. -f1)
WP_MINOR=$(echo "$WP_VER" | cut -d. -f2)

if [[ "$WP_MAJOR" -eq 0 ]] && [[ "$WP_MINOR" -lt 5 ]]; then
    # WirePlumber 0.4.x — uses Lua config
    sudo mkdir -p /etc/wireplumber/main.lua.d
    sudo tee /etc/wireplumber/main.lua.d/51-disable-ipu6-v4l2.lua > /dev/null << 'WPEOF'
-- Disable raw Intel IPU6 ISYS V4L2 nodes in PipeWire.
-- The camera is accessed through the libcamera SPA plugin instead.
rule = {
  matches = {
    {
      { "node.name", "matches", "v4l2_input.pci-0000_00_05*" },
    },
  },
  apply_properties = {
    ["node.disabled"] = true,
  },
}
table.insert(v4l2_monitor.rules, rule)
WPEOF
    echo "  ✓ WirePlumber Lua rule installed (v4l2 nodes hidden)"
else
    # WirePlumber 0.5+ — uses JSON conf.d
    sudo mkdir -p /etc/wireplumber/wireplumber.conf.d
    sudo tee /etc/wireplumber/wireplumber.conf.d/50-disable-ipu6-v4l2.conf > /dev/null << 'WPEOF'
# Disable raw Intel IPU6 ISYS V4L2 nodes in PipeWire.
# The camera is accessed through the libcamera SPA plugin instead.
monitor.v4l2.rules = [
  {
    matches = [
      { node.name = "~v4l2_input.pci-0000_00_05*" }
    ]
    actions = {
      update-props = {
        node.disabled = true
      }
    }
  }
]
WPEOF
    echo "  ✓ WirePlumber conf.d rule installed (v4l2 nodes hidden)"
fi

echo "  ✓ Raw IPU6 nodes hidden from applications"

# ──────────────────────────────────────────────
# [12/15] Camera relay tool (for non-PipeWire apps)
# ──────────────────────────────────────────────
echo ""
echo "[12/15] Installing camera relay tool..."

# Some apps (Zoom, OBS, VLC) don't support PipeWire/libcamera directly and
# need a standard V4L2 device. The camera-relay tool creates an on-demand
# v4l2loopback bridge: libcamerasrc → GStreamer → /dev/videoX.
# Near-zero CPU when idle — camera only activates when an app opens the device.

RELAY_DIR="$SCRIPT_DIR/../camera-relay"

if [[ -d "$RELAY_DIR" ]]; then
    # Install GStreamer libcamerasrc element if not present
    if ! gst-inspect-1.0 libcamerasrc &>/dev/null 2>&1; then
        echo "  Installing GStreamer libcamera plugin..."
        case "$DISTRO" in
            fedora)
                sudo dnf install -y gstreamer1-plugins-bad-free-extras 2>/dev/null || \
                sudo dnf install -y gstreamer1-plugins-bad-free 2>/dev/null || true
                ;;
            arch)
                sudo pacman -S --needed --noconfirm gst-plugins-bad 2>/dev/null || true
                ;;
            ubuntu|debian)
                sudo apt-get install -y gstreamer1.0-plugins-bad 2>/dev/null || true
                ;;
        esac
    fi

    # Install v4l2loopback if not present
    if ! modinfo v4l2loopback &>/dev/null 2>&1; then
        echo "  Installing v4l2loopback..."
        case "$DISTRO" in
            fedora)
                sudo dnf install -y v4l2loopback 2>/dev/null || true
                ;;
            arch)
                sudo pacman -S --needed --noconfirm v4l2loopback-dkms 2>/dev/null || true
                ;;
            ubuntu|debian)
                sudo apt-get install -y v4l2loopback-dkms 2>/dev/null || true
                ;;
        esac
    fi

    # Deploy v4l2loopback config (always overwrite — Fedora's v4l2loopback-akmods
    # can drop its own config that overrides ours, causing wrong card_label)
    sudo cp "$RELAY_DIR/99-camera-relay-loopback.conf" /etc/modprobe.d/
    echo "  ✓ Installed v4l2loopback config (/etc/modprobe.d/99-camera-relay-loopback.conf)"

    # Ensure v4l2loopback loads at boot (modprobe.d only sets options, doesn't trigger load)
    echo "v4l2loopback" | sudo tee /etc/modules-load.d/v4l2loopback.conf > /dev/null
    echo "  ✓ Installed v4l2loopback autoload (/etc/modules-load.d/v4l2loopback.conf)"

    # Fedora: rebuild initramfs so dracut picks up the new v4l2loopback config.
    # Without this, v4l2loopback-akmods loads the module from initramfs with stale
    # defaults (e.g. "OBS Virtual Camera") before /etc/modprobe.d/ is read.
    if [[ "$DISTRO" == "fedora" ]]; then
        echo "  Rebuilding initramfs for v4l2loopback config (this may take a moment)..."
        sudo dracut --regenerate-all -f 2>/dev/null || true
        echo "  ✓ Initramfs rebuilt with Camera Relay config"
    fi

    # Check for stale v4l2loopback with wrong label (e.g. OBS Virtual Camera)
    if lsmod 2>/dev/null | grep -q v4l2loopback; then
        current_label=$(cat /sys/devices/virtual/video4linux/video*/name 2>/dev/null | grep -v "Intel IPU" | head -1)
        if [[ -n "$current_label" ]] && [[ "$current_label" != "Camera Relay" ]]; then
            echo "  ⚠ v4l2loopback is currently loaded with label '$current_label'"
            echo "    Reloading module with correct label..."
            sudo modprobe -r v4l2loopback 2>/dev/null || true
            sudo modprobe v4l2loopback 2>/dev/null || true
            new_label=$(cat /sys/devices/virtual/video4linux/video*/name 2>/dev/null | grep -v "Intel IPU" | head -1)
            if [[ "$new_label" == "Camera Relay" ]]; then
                echo "  ✓ v4l2loopback reloaded with correct label"
            else
                echo "  ⚠ Could not reload v4l2loopback — a reboot should fix this"
            fi
        fi
    fi

    # Build and install on-demand monitor (C binary)
    if [[ -f "$RELAY_DIR/camera-relay-monitor.c" ]]; then
        echo "  Building on-demand monitor..."
        if gcc -O2 -Wall -o /tmp/camera-relay-monitor "$RELAY_DIR/camera-relay-monitor.c"; then
            # Stop running monitor before replacing binary (avoids "Text file busy")
            if pgrep -x camera-relay-monitor >/dev/null 2>&1; then
                systemctl --user stop camera-relay.service 2>/dev/null || true
                pkill -x camera-relay-monitor 2>/dev/null || true
                sleep 1
            fi
            sudo install -m 755 /tmp/camera-relay-monitor /usr/local/bin/camera-relay-monitor
            sudo chmod 755 /usr/local/bin/camera-relay-monitor
            rm -f /tmp/camera-relay-monitor
            echo "  ✓ Installed /usr/local/bin/camera-relay-monitor"
        else
            echo "  ⚠ Failed to build monitor (gcc required) — on-demand mode unavailable"
        fi
    fi

    # Install CLI tool
    sudo cp "$RELAY_DIR/camera-relay" /usr/local/bin/camera-relay
    sudo chmod 755 /usr/local/bin/camera-relay
    echo "  ✓ Installed /usr/local/bin/camera-relay"

    # Install systray GUI
    sudo mkdir -p /usr/local/share/camera-relay
    sudo cp "$RELAY_DIR/camera-relay-systray.py" /usr/local/share/camera-relay/
    sudo chmod 755 /usr/local/share/camera-relay/camera-relay-systray.py
    echo "  ✓ Installed systray GUI"

    # Install desktop file
    sudo cp "$RELAY_DIR/camera-relay-systray.desktop" /usr/share/applications/
    echo "  ✓ Installed desktop entry"

    # Auto-enable persistent on-demand relay
    echo "  Enabling on-demand relay (auto-starts on login)..."
    /usr/local/bin/camera-relay enable-persistent --yes 2>/dev/null && \
        echo "  ✓ On-demand relay enabled (near-zero idle CPU)" || \
        echo "  ⚠ Could not enable persistent relay — run 'camera-relay enable-persistent' after reboot"
else
    echo "  ⚠ camera-relay directory not found — skipping"
fi

# ──────────────────────────────────────────────
# [13/15] Enable PipeWire camera in Chromium browsers
# ──────────────────────────────────────────────
echo ""
echo "[13/15] Configuring Chromium-based browsers for PipeWire camera..."

# Chromium/Brave/Chrome use direct V4L2 by default and may not show the
# v4l2loopback device. Enabling the PipeWire camera flag makes them use
# the camera portal, which correctly sees all PipeWire camera sources.
# The flag is: enable-webrtc-pipewire-camera (stored in "Local State" JSON).

enable_pipewire_camera_flag() {
    local browser_name="$1"
    local state_file="$2"

    if [[ ! -f "$state_file" ]]; then
        return 1  # browser never launched
    fi

    # Check if browser is running (by checking lock files next to Local State)
    local profile_dir
    profile_dir=$(dirname "$state_file")
    if [[ -f "$profile_dir/SingletonLock" ]]; then
        echo "  ⚠ $browser_name is running — close it first to enable the flag"
        echo "    Then run: camera-relay enable-browser-flags"
        return 1
    fi

    python3 -c "
import json, sys
state_file = sys.argv[1]
flag = 'enable-webrtc-pipewire-camera'
with open(state_file, 'r') as f:
    data = json.load(f)
browser = data.setdefault('browser', {})
labs = browser.setdefault('enabled_labs_experiments', [])
# Check if already enabled
if flag + '@1' in labs:
    sys.exit(2)  # already set
# Remove any existing value for this flag
labs = [e for e in labs if not e.startswith(flag + '@')]
labs.append(flag + '@1')
browser['enabled_labs_experiments'] = labs
with open(state_file, 'w') as f:
    json.dump(data, f)
" "$state_file" 2>/dev/null
    return $?
}

BROWSER_FLAGS_SET=false
declare -A BROWSERS=(
    ["Brave"]="$HOME/.config/BraveSoftware/Brave-Browser/Local State"
    ["Chrome"]="$HOME/.config/google-chrome/Local State"
    ["Chromium"]="$HOME/.config/chromium/Local State"
)

for browser_name in "${!BROWSERS[@]}"; do
    state_file="${BROWSERS[$browser_name]}"
    if [[ -f "$state_file" ]]; then
        ret=0
        enable_pipewire_camera_flag "$browser_name" "$state_file" || ret=$?
        if [[ $ret -eq 0 ]]; then
            echo "  ✓ Enabled PipeWire camera flag for $browser_name"
            BROWSER_FLAGS_SET=true
        elif [[ $ret -eq 2 ]]; then
            echo "  ✓ $browser_name already has PipeWire camera flag enabled"
        fi
    fi
done

if ! $BROWSER_FLAGS_SET; then
    echo "  No Chromium-based browsers found (or already configured)"
    echo "  Firefox works without any flags"
fi

# ──────────────────────────────────────────────
# [14/15] Cheese CameraBin crash fix
# ──────────────────────────────────────────────
echo ""
echo "[14/15] Checking for Cheese (GNOME webcam app)..."

if command -v cheese >/dev/null 2>&1; then
    CHEESE_FIX_SRC="$SCRIPT_DIR/../camera-relay/cheese-camerabin-fix.c"
    if [[ -f "$CHEESE_FIX_SRC" ]]; then
        echo "  Cheese is installed — installing CameraBin crash fix..."

        # Build the LD_PRELOAD shared library
        if gcc -shared -fPIC -o /tmp/cheese-camerabin-fix.so "$CHEESE_FIX_SRC" -ldl; then
            sudo cp /tmp/cheese-camerabin-fix.so /usr/local/lib/cheese-camerabin-fix.so
            sudo chmod 644 /usr/local/lib/cheese-camerabin-fix.so
            rm -f /tmp/cheese-camerabin-fix.so
            echo "  ✓ Installed /usr/local/lib/cheese-camerabin-fix.so"
        else
            echo "  ⚠ Failed to compile cheese-camerabin-fix.so (gcc required)"
        fi

        # Install wrapper script
        if [[ -f /usr/local/lib/cheese-camerabin-fix.so ]]; then
            sudo tee /usr/local/bin/cheese > /dev/null << 'CHEESE_WRAPPER'
#!/bin/sh
# Pre-start camera relay so v4l2loopback has frames, then launch Cheese
# with LD_PRELOAD fix (swaps pipewiresrc→v4l2src + videoconvert buffer fix)
camera-relay start 2>/dev/null &
sleep 3
LD_PRELOAD=/usr/local/lib/cheese-camerabin-fix.so /usr/bin/cheese "$@"
CHEESE_WRAPPER
            sudo chmod 755 /usr/local/bin/cheese
            echo "  ✓ Installed /usr/local/bin/cheese (wrapper)"

            # Install .desktop override so GNOME launcher uses the wrapper
            CHEESE_DESKTOP=$(find /usr/share/applications -name "*heese*.desktop" -o -name "*cheese*.desktop" 2>/dev/null | head -1)
            if [[ -n "$CHEESE_DESKTOP" ]]; then
                sudo mkdir -p /usr/local/share/applications
                sed -e 's|^Exec=.*|Exec=/usr/local/bin/cheese|' \
                    -e 's|^DBusActivatable=true|DBusActivatable=false|' "$CHEESE_DESKTOP" | \
                    sudo tee /usr/local/share/applications/$(basename "$CHEESE_DESKTOP") > /dev/null
                echo "  ✓ Installed .desktop override (/usr/local/share/applications/$(basename "$CHEESE_DESKTOP"))"
            else
                sudo mkdir -p /usr/local/share/applications
                sudo tee /usr/local/share/applications/org.gnome.Cheese.desktop > /dev/null << 'CHEESE_DESKTOP_EOF'
[Desktop Entry]
Name=Cheese
Comment=Take photos and videos with your webcam, with fun graphical effects
Exec=/usr/local/bin/cheese
Icon=org.gnome.Cheese
Terminal=false
Type=Application
Categories=GNOME;AudioVideo;Video;
StartupNotify=true
CHEESE_DESKTOP_EOF
                echo "  ✓ Installed .desktop file (/usr/local/share/applications/org.gnome.Cheese.desktop)"
            fi
        fi
    else
        echo "  ⚠ cheese-camerabin-fix.c not found — skipping Cheese fix"
    fi
else
    echo "  Cheese not installed — skipping (fix will be available if Cheese is installed later)"
fi

# ──────────────────────────────────────────────
# [15/15] Restart PipeWire and verify
# ──────────────────────────────────────────────
echo ""
echo "[15/15] Restarting PipeWire and verifying camera..."

# Restart PipeWire so it picks up the libcamera SPA plugin
systemctl --user restart pipewire wireplumber 2>/dev/null || true
sleep 3

# Check if PipeWire sees the camera via libcamera
CAMERA_FOUND=false
if pw-cli ls Node 2>/dev/null | grep -q "libcamera"; then
    CAMERA_FOUND=true
    CAMERA_NAME=$(pw-cli ls Node 2>/dev/null | grep -A5 "libcamera" | grep "node.description" | head -1 | sed 's/.*= "\(.*\)"/\1/')
    echo "  ✓ PipeWire sees camera via libcamera: $CAMERA_NAME"
fi

# Also try a direct libcamera test
CAM_CMD=""
if [[ -x /usr/local/bin/cam ]]; then
    CAM_CMD="/usr/local/bin/cam"
elif command -v cam >/dev/null 2>&1; then
    CAM_CMD="cam"
fi

CAPTURE_OK=false
if [[ -n "$CAM_CMD" ]]; then
    CAM_OUTPUT=$(sudo LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu "$CAM_CMD" --list 2>&1 || true)
    if echo "$CAM_OUTPUT" | grep -qi "ov02c10"; then
        echo "  ✓ libcamera detects OV02C10 sensor"
        CAPTURE_OK=true
    fi
fi

echo ""
echo "=============================================="
if $CAMERA_FOUND; then
    echo "  SUCCESS — Camera is available through PipeWire!"
    echo ""
    echo "  PipeWire-native apps (Firefox, Chromium, OBS) see the camera directly."
    echo "  Non-PipeWire apps (Zoom, VLC) use the Camera Relay (on-demand)."
    echo "  The on-demand relay is enabled and will auto-start on login."
    echo ""
    echo "  Test:  Open Firefox and go to a video chat site, or run:"
    echo "         gst-launch-1.0 libcamerasrc ! videoconvert ! autovideosink"
    echo ""
    echo "  Note:  If apps show raw IPU6 entries instead of the camera,"
    echo "         log out and back in for udev rules to take effect."
elif $CAPTURE_OK; then
    echo "  libcamera detects the camera but PipeWire hasn't picked it up yet."
    echo ""
    echo "  This is normal on first install. Please:"
    echo "    1. Log out and back in (or reboot)"
    echo "    2. The camera should appear in PipeWire automatically"
    echo ""
    echo "  To test directly:  sudo cam --list"
else
    echo "  Setup complete but camera not detected yet."
    echo ""
    echo "  A reboot is likely needed for:"
    echo "    - IVSC modules to load from initramfs"
    echo "    - PipeWire to discover the libcamera source"
    echo ""
    echo "  After reboot, test with:  sudo cam --list"
fi
echo ""
echo "  Configuration files created:"
echo "    /etc/modules-load.d/ivsc.conf"
echo "    /etc/modprobe.d/ivsc-camera.conf"
echo "    /etc/udev/rules.d/90-hide-ipu6-v4l2.rules"
case "$DISTRO" in
    ubuntu|debian)
        echo "    /etc/initramfs-tools/modules (updated)"
        ;;
    fedora)
        echo "    /etc/dracut.conf.d/ivsc-camera.conf"
        ;;
    arch)
        echo "    /etc/mkinitcpio.conf.d/ivsc-camera.conf"
        ;;
esac
if [[ -f /etc/wireplumber/main.lua.d/51-disable-ipu6-v4l2.lua ]]; then
    echo "    /etc/wireplumber/main.lua.d/51-disable-ipu6-v4l2.lua"
elif [[ -f /etc/wireplumber/wireplumber.conf.d/50-disable-ipu6-v4l2.conf ]]; then
    echo "    /etc/wireplumber/wireplumber.conf.d/50-disable-ipu6-v4l2.conf"
fi
if [[ -f /etc/profile.d/libcamera-ipa.sh ]]; then
    echo "    /etc/profile.d/libcamera-ipa.sh"
    echo "    /etc/environment.d/libcamera-ipa.conf"
fi
echo "    /usr/local/share/libcamera/ipa/simple/ov02c10.yaml"
if [[ -f /usr/local/bin/camera-relay ]]; then
    echo "    /usr/local/bin/camera-relay"
    echo "    /usr/local/bin/camera-relay-monitor"
    echo "    /etc/modprobe.d/99-camera-relay-loopback.conf"
fi
if [[ -f /usr/local/lib/cheese-camerabin-fix.so ]]; then
    echo "    /usr/local/lib/cheese-camerabin-fix.so"
    echo "    /usr/local/bin/cheese (wrapper)"
    CHEESE_DESKTOP_INSTALLED=$(find /usr/local/share/applications -name "*cheese*" -o -name "*Cheese*" 2>/dev/null | head -1)
    if [[ -n "$CHEESE_DESKTOP_INSTALLED" ]]; then
        echo "    $CHEESE_DESKTOP_INSTALLED"
    fi
fi
echo "=============================================="
