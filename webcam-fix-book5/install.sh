#!/bin/bash
# install.sh
# Samsung Galaxy Book5 webcam fix for Arch, Fedora, and Ubuntu (with custom libcamera)
# For Lunar Lake (IPU7) with OV02C10 or OV02E10 sensor
#
# Root cause: IPU7 on Lunar Lake requires the intel_cvs (Computer Vision
# Subsystem) kernel module to power the camera sensor, but this module is
# not yet in-tree. Intel provides it via DKMS from their vision-drivers
# repo. Additionally, LJCA (Lunar Lake Joint Controller for Accessories)
# GPIO/USB modules must be loaded before the vision driver and sensor.
# The userspace pipeline uses libcamera (not the IPU6 camera HAL).
#
# Pipeline: LJCA -> intel_cvs -> OV02C10/OV02E10 -> libcamera -> PipeWire
# No v4l2loopback or relay needed — libcamera talks to PipeWire directly.
#
# Confirmed working on Galaxy Book5 Pro 940XHA (Fedora 43), 960XHA (Ubuntu
# 24.04), Galaxy Book5 360 (Fedora 42), Dell XPS 13 9350 (Arch), and
# Lenovo X1 Carbon Gen13 (Fedora 42).
#
# For full documentation, see: README.md
#
# Usage: ./install.sh [--force]

set -e

NEEDS_INITRAMFS=0  # set to 1 by any section that modifies initramfs-relevant state

VISION_DRIVER_VER="1.0.0"
VISION_DRIVER_REPO="https://github.com/intel/vision-drivers"
VISION_DRIVER_BRANCH="main"
SRC_DIR="/usr/src/vision-driver-${VISION_DRIVER_VER}"

FORCE=false
[ "$1" = "--force" ] && FORCE=true

echo "=============================================="
echo "  Samsung Galaxy Book5 Webcam Fix"
echo "  Arch / Fedora / Ubuntu — Lunar Lake (IPU7)"
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
    echo "  ✓ Arch-based distro detected"
elif command -v dnf >/dev/null 2>&1; then
    DISTRO="fedora"
    # Check libcamera version — IPU7 needs libcamera 0.5.2+ with Simple pipeline
    # handler and Software ISP. Fedora 43 ships 0.5.2, Fedora 44 ships 0.7.0.
    LIBCAMERA_VER=$(ls -l /usr/lib64/libcamera.so.* /usr/lib/libcamera.so.* 2>/dev/null \
        | grep -oP 'libcamera\.so\.\K[0-9]+\.[0-9]+' | sort -V | tail -1 || true)
    if [[ -n "$LIBCAMERA_VER" ]]; then
        LIBCAMERA_MAJOR=$(echo "$LIBCAMERA_VER" | cut -d. -f1)
        LIBCAMERA_MINOR=$(echo "$LIBCAMERA_VER" | cut -d. -f2)
        echo "  ✓ Fedora detected with libcamera ${LIBCAMERA_VER}"
    else
        echo "  ✓ Fedora detected (libcamera version will be checked after package install)"
    fi
elif command -v apt >/dev/null 2>&1; then
    DISTRO="ubuntu"
    # Ubuntu doesn't ship libcamera 0.5.2+ (needed for IPU7) in its repos.
    # But users who build libcamera from source can still use this script.
    # Note: cam --version doesn't exist in all libcamera versions (e.g. 0.7.0).
    # Use the libcamera.so symlink version instead.
    LIBCAMERA_VER=$(ls -l /usr/local/lib/*/libcamera.so.* /usr/local/lib/libcamera.so.* /usr/lib/*/libcamera.so.* /usr/lib/libcamera.so.* 2>/dev/null \
        | grep -oP 'libcamera\.so\.\K[0-9]+\.[0-9]+' | sort -V | tail -1 || true)
    if [[ -z "$LIBCAMERA_VER" ]]; then
        echo "ERROR: Ubuntu detected but libcamera is not installed."
        echo ""
        echo "       Ubuntu's repos ship libcamera 0.2.x which does NOT support IPU7."
        echo "       You need libcamera 0.5.2+ built from source."
        echo ""
        echo "       Build instructions: https://libcamera.org/getting-started.html"
        echo "       Reference: https://wiki.archlinux.org/title/Dell_XPS_13_(9350)_2024#Camera"
        echo ""
        echo "       If you have a Galaxy Book3/4 (Meteor Lake / IPU6), use the webcam-fix-libcamera/"
        echo "       directory instead: cd ../webcam-fix-libcamera && ./install.sh"
        exit 1
    fi
    LIBCAMERA_MAJOR=$(echo "$LIBCAMERA_VER" | cut -d. -f1)
    LIBCAMERA_MINOR=$(echo "$LIBCAMERA_VER" | cut -d. -f2)
    echo "  ✓ Ubuntu detected with libcamera ${LIBCAMERA_VER}"
    echo "  ⚠ Ubuntu support is experimental — libcamera was not installed from repos"
else
    echo "ERROR: Unsupported distro. This script requires pacman (Arch), dnf (Fedora), or apt (Ubuntu)."
    exit 1
fi

# ──────────────────────────────────────────────
# [3/15] Hardware detection
# ──────────────────────────────────────────────
echo ""
echo "[3/15] Verifying hardware..."

# Check for Lunar Lake IPU7
IPU7_FOUND=false
if lspci -d 8086:645d 2>/dev/null | grep -q . || \
   lspci -d 8086:6457 2>/dev/null | grep -q .; then
    IPU7_FOUND=true
fi

if ! $IPU7_FOUND; then
    # Check if this is a Meteor Lake system (IPU6) — point them to webcam-fix-libcamera/
    if lspci -d 8086:7d19 2>/dev/null | grep -q .; then
        echo "ERROR: This system has Intel IPU6 (Meteor Lake), not IPU7 (Lunar Lake)."
        echo ""
        echo "       This webcam fix is for Lunar Lake systems (Galaxy Book5 models)."
        echo "       For Meteor Lake (Galaxy Book3/4), use the webcam-fix-libcamera/ directory:"
        echo "       cd ../webcam-fix-libcamera && ./install.sh"
        exit 1
    fi

    if $FORCE; then
        echo "  ⚠ No IPU7 detected — installing anyway (--force)"
    else
        echo "ERROR: Intel IPU7 Lunar Lake (8086:645d or 8086:6457) not found."
        echo "       This script is designed for Samsung Galaxy Book5 laptops with"
        echo "       Intel Lunar Lake processors."
        echo ""
        echo "       Use --force to install anyway on unsupported hardware."
        exit 1
    fi
else
    echo "  ✓ Found IPU7 Lunar Lake"
fi

# Check for OV02C10 or OV02E10 sensor
SENSOR=""
if cat /sys/bus/acpi/devices/*/hid 2>/dev/null | grep -q "OVTI02C1"; then
    SENSOR="ov02c10"
    echo "  ✓ Found OV02C10 sensor (OVTI02C1)"
elif cat /sys/bus/acpi/devices/*/hid 2>/dev/null | grep -q "OVTI02E1"; then
    SENSOR="ov02e10"
    echo "  ✓ Found OV02E10 sensor (OVTI02E1)"
elif $FORCE; then
    echo "  ⚠ No OV02C10/OV02E10 sensor found in ACPI — continuing anyway (--force)"
else
    echo "  ⚠ No OV02C10 (OVTI02C1) or OV02E10 (OVTI02E1) sensor found in ACPI."
    echo "    This may be normal if the CVS module isn't loaded yet."
    echo "    Continuing with installation..."
fi

# ──────────────────────────────────────────────
# [4/15] Kernel version check
# ──────────────────────────────────────────────
echo ""
echo "[4/15] Checking kernel version..."
KVER=$(uname -r)
KMAJOR=$(echo "$KVER" | cut -d. -f1)
KMINOR=$(echo "$KVER" | cut -d. -f2)

if [[ "$KMAJOR" -lt 6 ]] || { [[ "$KMAJOR" -eq 6 ]] && [[ "$KMINOR" -lt 18 ]]; }; then
    echo "ERROR: Kernel ${KVER} is too old. IPU7 webcam support requires kernel 6.18+."
    echo ""
    echo "       Kernel 6.18 includes in-tree IPU7, USBIO, and OV02C10 drivers."
    if [[ "$DISTRO" == "arch" ]]; then
        echo "       Update your kernel: sudo pacman -Syu"
    elif [[ "$DISTRO" == "fedora" ]]; then
        echo "       Update your kernel: sudo dnf upgrade --refresh"
    else
        echo "       Ubuntu 24.04 ships kernel 6.17. You need to compile 6.18+ from source"
        echo "       or install a mainline kernel build."
    fi
    exit 1
fi
echo "  ✓ Kernel ${KVER} (>= 6.18 required)"

# ──────────────────────────────────────────────
# [5/15] Install distro packages
# ──────────────────────────────────────────────
echo ""
echo "[5/15] Installing required packages..."

if [[ "$DISTRO" == "arch" ]]; then
    # Check what's missing
    PKGS_NEEDED=()
    for pkg in libcamera libcamera-ipa pipewire-libcamera linux-firmware; do
        if ! pacman -Qi "$pkg" &>/dev/null; then
            PKGS_NEEDED+=("$pkg")
        fi
    done

    if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
        echo "  Installing: ${PKGS_NEEDED[*]}"
        sudo pacman -S --needed --noconfirm "${PKGS_NEEDED[@]}"
        echo "  ✓ Packages installed"
    else
        echo "  ✓ All packages already installed"
    fi

    # Ensure DKMS prerequisites are available
    if ! command -v dkms >/dev/null 2>&1; then
        echo "  Installing DKMS prerequisites..."
        sudo pacman -S --needed --noconfirm dkms linux-headers
    fi

elif [[ "$DISTRO" == "fedora" ]]; then
    PKGS_NEEDED=()
    for pkg in libcamera pipewire-plugin-libcamera linux-firmware; do
        if ! rpm -q "$pkg" &>/dev/null; then
            PKGS_NEEDED+=("$pkg")
        fi
    done

    if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
        echo "  Installing: ${PKGS_NEEDED[*]}"
        sudo dnf install -y "${PKGS_NEEDED[@]}"
        echo "  ✓ Packages installed"
    else
        echo "  ✓ All packages already installed"
    fi

    # Ensure DKMS prerequisites are available
    if ! command -v dkms >/dev/null 2>&1; then
        echo "  Installing DKMS prerequisites..."
        sudo dnf install -y dkms kernel-devel
    fi

elif [[ "$DISTRO" == "ubuntu" ]]; then
    # On Ubuntu, libcamera was already verified in step 2 (built from source).
    # We only install DKMS prerequisites — do NOT install libcamera from apt
    # (it's too old and would conflict with the source build).
    echo "  ✓ libcamera already installed (from source)"

    if ! command -v dkms >/dev/null 2>&1; then
        echo "  Installing DKMS prerequisites..."
        sudo apt install -y dkms linux-headers-$(uname -r)
    fi

    # Check for pipewire-libcamera SPA plugin
    if ! find /usr/lib /usr/local/lib -path "*/spa-*/libcamera*" -name "*.so" 2>/dev/null | grep -q .; then
        echo "  ⚠ pipewire-libcamera SPA plugin not found."
        echo "    PipeWire apps (Firefox, Zoom, etc.) may not see the camera."
        echo "    You may need to build the PipeWire libcamera plugin from source,"
        echo "    or use cam/qcam for direct libcamera access."
    else
        echo "  ✓ PipeWire libcamera plugin found"
    fi
fi

# ──────────────────────────────────────────────
# [6/15] Build intel-vision-drivers via DKMS
# ──────────────────────────────────────────────
echo ""
echo "[6/15] Installing intel_cvs module via DKMS..."

# Check if already installed and working
if modinfo usb_ljca &>/dev/null 2>&1 && \
   modinfo gpio_ljca &>/dev/null 2>&1 && \
   modinfo intel_cvs &>/dev/null 2>&1; then
    echo "  ✓ usb_ljca, gpio_ljca and intel_cvs modules already available — skipping DKMS build"
elif dkms status "vision-driver/${VISION_DRIVER_VER}" 2>/dev/null | grep -q "installed"; then
    echo "  ✓ vision-driver/${VISION_DRIVER_VER} already installed via DKMS"
else
    # Download tarball (no git dependency)
    TMPDIR=$(mktemp -d)
    TARBALL="${TMPDIR}/vision-drivers.tar.gz"
    echo "  Downloading intel/vision-drivers from GitHub..."
    if ! curl -sL "${VISION_DRIVER_REPO}/archive/refs/heads/${VISION_DRIVER_BRANCH}.tar.gz" -o "$TARBALL"; then
        echo "ERROR: Failed to download vision-drivers from GitHub."
        echo "       Check your internet connection and try again."
        rm -rf "$TMPDIR"
        exit 1
    fi

    # Extract
    tar xzf "$TARBALL" -C "$TMPDIR"
    EXTRACTED_DIR=$(ls -d "${TMPDIR}"/vision-drivers-* 2>/dev/null | head -1)
    if [[ -z "$EXTRACTED_DIR" ]] || [[ ! -d "$EXTRACTED_DIR" ]]; then
        echo "ERROR: Failed to extract vision-drivers tarball."
        rm -rf "$TMPDIR"
        exit 1
    fi

    # Remove old DKMS version if present
    if dkms status "vision-driver/${VISION_DRIVER_VER}" 2>/dev/null | grep -q "vision-driver"; then
        echo "  Removing existing DKMS module..."
        sudo dkms remove "vision-driver/${VISION_DRIVER_VER}" --all 2>/dev/null || true
    fi

    # Copy source to DKMS tree
    sudo rm -rf "$SRC_DIR"
    sudo mkdir -p "$SRC_DIR"
    sudo cp -a "$EXTRACTED_DIR"/* "$SRC_DIR/"

    # Ensure dkms.conf exists
    if [[ ! -f "$SRC_DIR/dkms.conf" ]]; then
        # Create a minimal dkms.conf if the repo doesn't include one
        sudo tee "$SRC_DIR/dkms.conf" > /dev/null << EOF
PACKAGE_NAME="vision-driver"
PACKAGE_VERSION="${VISION_DRIVER_VER}"
BUILT_MODULE_NAME[0]="intel_cvs"
BUILT_MODULE_LOCATION[0]="backport-include/cvs/"
DEST_MODULE_LOCATION[0]="/updates"
AUTOINSTALL="yes"
EOF
    fi

    # Secure Boot handling for Fedora
    if [[ "$DISTRO" == "fedora" ]] && mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
        MOK_KEY="/etc/pki/akmods/private/private_key.priv"
        MOK_CERT="/etc/pki/akmods/certs/public_key.der"

        if [[ ! -f "$MOK_KEY" ]] || [[ ! -f "$MOK_CERT" ]]; then
            echo "  Generating MOK key for Secure Boot module signing..."
            sudo dnf install -y kmodtool akmods mokutil openssl >/dev/null 2>&1 || true
            sudo kmodgenca -a 2>/dev/null || true
        fi

        if [[ -f "$MOK_KEY" ]] && [[ -f "$MOK_CERT" ]]; then
            echo "  Configuring DKMS to sign modules with Fedora akmods MOK key..."
            sudo mkdir -p /etc/dkms/framework.conf.d
            sudo tee /etc/dkms/framework.conf.d/akmods-keys.conf > /dev/null << SIGNEOF
# Fedora akmods MOK key for Secure Boot module signing
mok_signing_key=${MOK_KEY}
mok_certificate=${MOK_CERT}
SIGNEOF

            if ! mokutil --test-key "$MOK_CERT" 2>/dev/null | grep -q "is already enrolled"; then
                echo ""
                echo "  >>> Secure Boot: You need to enroll the MOK key. <<<"
                echo "  >>> Run: sudo mokutil --import ${MOK_CERT}        <<<"
                echo "  >>> Then reboot and follow the MOK enrollment prompt. <<<"
                echo ""
                sudo mokutil --import "$MOK_CERT" 2>/dev/null || true
            fi
        fi
    fi

    # Register, build, install
    echo "  Building DKMS module (this may take a moment)..."
    sudo dkms add "vision-driver/${VISION_DRIVER_VER}" 2>/dev/null || true
    sudo dkms build "vision-driver/${VISION_DRIVER_VER}"
    sudo dkms install "vision-driver/${VISION_DRIVER_VER}"

    rm -rf "$TMPDIR"
    echo "  ✓ vision-driver/${VISION_DRIVER_VER} installed via DKMS"

    # Verify module signing when Secure Boot is enabled
    if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
        MOD_PATH=$(find /lib/modules/$(uname -r) -name "intel_cvs.ko*" 2>/dev/null | head -1)
        if [[ -n "$MOD_PATH" ]]; then
            if ! modinfo "$MOD_PATH" 2>/dev/null | grep -qi "^sig"; then
                echo ""
                echo "  ⚠ Secure Boot is enabled but the module is NOT signed."
                echo "    This can happen when the MOK signing key was just configured."
                echo "    Rebuilding module with signing..."
                sudo dkms remove "vision-driver/${VISION_DRIVER_VER}" --all 2>/dev/null || true
                sudo dkms add "vision-driver/${VISION_DRIVER_VER}" 2>/dev/null || true
                sudo dkms build "vision-driver/${VISION_DRIVER_VER}"
                sudo dkms install "vision-driver/${VISION_DRIVER_VER}"

                MOD_PATH=$(find /lib/modules/$(uname -r) -name "intel_cvs.ko*" 2>/dev/null | head -1)
                if [[ -n "$MOD_PATH" ]] && modinfo "$MOD_PATH" 2>/dev/null | grep -qi "^sig"; then
                    echo "  ✓ Module is now signed"
                else
                    echo ""
                    echo "  ⚠ Module is still unsigned. It will NOT load with Secure Boot."
                    echo "    After rebooting and completing MOK enrollment, run the installer again."
                fi
            else
                echo "  ✓ Module is signed for Secure Boot"
            fi
        fi
    fi
fi

# ──────────────────────────────────────────────
# [7/15] Samsung camera rotation fix (ipu-bridge DKMS)
# ──────────────────────────────────────────────
echo ""
echo "[7/15] Installing ipu-bridge camera rotation fix..."

# Samsung Galaxy Book5 Pro models (940XHA, 960XHA) have their OV02E10 sensor
# mounted upside-down, but Samsung's BIOS reports rotation=0. The kernel's
# ipu-bridge driver has a DMI quirk table for this, but the Samsung entries
# aren't upstream yet. Ship a patched ipu-bridge.ko via DKMS until they are.

# Only install on Samsung systems with known affected models
NEEDS_ROTATION_FIX=false
DMI_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
DMI_PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
if [[ "$DMI_VENDOR" == "SAMSUNG ELECTRONICS CO., LTD." ]]; then
    case "$DMI_PRODUCT" in
        940XHA|960XHA|960QHA) NEEDS_ROTATION_FIX=true ;;
    esac
fi

IPU_BRIDGE_FIX_VER="1.1"
IPU_BRIDGE_FIX_SRC="/usr/src/ipu-bridge-fix-${IPU_BRIDGE_FIX_VER}"

if $NEEDS_ROTATION_FIX; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Check if already installed and working
    if dkms status "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}" 2>/dev/null | grep -q "installed"; then
        echo "  ✓ ipu-bridge-fix/${IPU_BRIDGE_FIX_VER} already installed via DKMS"
    else
        # Check if the native kernel module already has the fix
        NATIVE_IPU_BRIDGE=$(find "/lib/modules/$(uname -r)/kernel" -name "ipu-bridge*" 2>/dev/null | head -1)
        UPSTREAM_HAS_FIX=false
        if [ -n "$NATIVE_IPU_BRIDGE" ]; then
            case "$NATIVE_IPU_BRIDGE" in
                *.zst)  DECOMPRESS="zstdcat" ;;
                *.xz)   DECOMPRESS="xzcat" ;;
                *.gz)   DECOMPRESS="zcat" ;;
                *)      DECOMPRESS="cat" ;;
            esac
            if $DECOMPRESS "$NATIVE_IPU_BRIDGE" 2>/dev/null | strings | grep -q "940XHA"; then
                UPSTREAM_HAS_FIX=true
            fi
        fi

        if $UPSTREAM_HAS_FIX; then
            echo "  ✓ Native kernel ipu-bridge already has Samsung rotation fix — skipping DKMS"
        else
            # Remove any old DKMS version before installing
            for old_ver in "1.0" "${IPU_BRIDGE_FIX_VER}"; do
                if dkms status "ipu-bridge-fix/${old_ver}" 2>/dev/null | grep -q "ipu-bridge-fix"; then
                    sudo dkms remove "ipu-bridge-fix/${old_ver}" --all 2>/dev/null || true
                fi
                sudo rm -rf "/usr/src/ipu-bridge-fix-${old_ver}" 2>/dev/null || true
            done

            # Copy source to DKMS tree
            sudo rm -rf "$IPU_BRIDGE_FIX_SRC"
            sudo mkdir -p "$IPU_BRIDGE_FIX_SRC"
            sudo cp -a "$SCRIPT_DIR/ipu-bridge-fix/"* "$IPU_BRIDGE_FIX_SRC/"

            # Secure Boot handling for Fedora (reuse key from step 6 if already set up)
            if [[ "$DISTRO" == "fedora" ]] && mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
                MOK_KEY="/etc/pki/akmods/private/private_key.priv"
                MOK_CERT="/etc/pki/akmods/certs/public_key.der"

                if [[ -f "$MOK_KEY" ]] && [[ -f "$MOK_CERT" ]]; then
                    # Ensure DKMS drop-in is present (may already exist from step 6)
                    sudo mkdir -p /etc/dkms/framework.conf.d
                    sudo tee /etc/dkms/framework.conf.d/akmods-keys.conf > /dev/null << SIGNEOF
# Fedora akmods MOK key for Secure Boot module signing
mok_signing_key=${MOK_KEY}
mok_certificate=${MOK_CERT}
SIGNEOF
                fi
            fi

            # Register, build, install
            echo "  Building ipu-bridge DKMS module..."
            sudo dkms add "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}" 2>/dev/null || true
            sudo dkms build "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}"
            sudo dkms install "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}"
            echo "  ✓ ipu-bridge-fix/${IPU_BRIDGE_FIX_VER} installed via DKMS"

            # Update initramfs so the DKMS module is loaded at next boot
            # instead of the stock kernel module (which has rotation=0).
            # initramfs will be rebuilt once at the end of the script
            NEEDS_INITRAMFS=1
            echo "  ✓ initramfs update defered until the end of the script"

        fi
    fi

    # Install upstream check script and service
    sudo cp "$SCRIPT_DIR/ipu-bridge-check-upstream.sh" /usr/local/sbin/ipu-bridge-check-upstream.sh
    sudo chmod 755 /usr/local/sbin/ipu-bridge-check-upstream.sh
    sudo cp "$SCRIPT_DIR/ipu-bridge-check-upstream.service" /etc/systemd/system/ipu-bridge-check-upstream.service
    sudo systemctl daemon-reload
    sudo systemctl enable ipu-bridge-check-upstream.service
    echo "  ✓ Upstream check service enabled (auto-removes fix when kernel catches up)"

else
    echo "  ✓ Not a Samsung 940XHA/960XHA/960QHA — rotation fix not needed"
fi

# ──────────────────────────────────────────────
# [8/15] OV02E10 bayer order fix (patched libcamera)
# ──────────────────────────────────────────────
echo ""
echo "[8/15] Checking for OV02E10 bayer order fix..."

# Samsung Book5 models with the OV02E10 sensor mounted upside-down (rotation=180)
# get purple/magenta tint after the ipu-bridge rotation fix is applied. This is
# because the bayer pattern shifts when the sensor is flipped, but the kernel
# driver doesn't update the media bus format code. A patched libcamera build
# corrects the bayer order in the Simple pipeline handler's SoftISP debayer.

if [[ "$SENSOR" == "ov02e10" ]] && $NEEDS_ROTATION_FIX; then
    BAYER_FIX_BACKUP="/var/lib/libcamera-bayer-fix-backup"
    if [[ -d "$BAYER_FIX_BACKUP" ]]; then
        echo "  ✓ Bayer fix already installed (backup exists at $BAYER_FIX_BACKUP)"
    else
        echo "  OV02E10 + rotation fix detected — building patched libcamera..."
        echo "  (This fixes purple/magenta tint caused by bayer pattern mismatch)"
        echo ""
        SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
        if sudo "$SCRIPT_DIR/libcamera-bayer-fix/build-patched-libcamera.sh"; then
            echo "  ✓ Patched libcamera installed (bayer order fix)"
        else
            echo ""
            echo "  ⚠ Bayer fix build failed — camera will work but may have purple tint."
            echo "    You can retry later: sudo ./libcamera-bayer-fix/build-patched-libcamera.sh"
        fi
    fi
else
    if [[ "$SENSOR" == "ov02e10" ]]; then
        echo "  ✓ OV02E10 detected but no rotation fix needed — bayer fix not required"
    else
        echo "  ✓ Not OV02E10 with rotation fix — bayer fix not needed"
    fi
fi

# ──────────────────────────────────────────────
# [9/15] Module load configuration
# ──────────────────────────────────────────────
echo ""
echo "[9/15] Configuring module loading..."

# The full module chain for IPU7 camera on Lunar Lake:
# usb_ljca -> gpio_ljca -> intel_cvs -> ov02c10/ov02e10
# LJCA (Lunar Lake Joint Controller for Accessories) provides GPIO/USB
# control needed by the vision subsystem to power the sensor.
sudo tee /etc/modules-load.d/intel-ipu7-camera.conf > /dev/null << 'EOF'
# IPU7 camera module chain for Lunar Lake
# LJCA provides GPIO/USB control for the vision subsystem
usb_ljca
gpio_ljca
# Intel Computer Vision Subsystem — powers the camera sensor
intel_cvs
EOF
echo "  ✓ Created /etc/modules-load.d/intel-ipu7-camera.conf"

# Determine which sensor module name to use for softdep
SENSOR_MOD="${SENSOR:-ov02e10}"

# Ensure correct load order: LJCA -> intel_cvs -> sensor
sudo tee /etc/modprobe.d/intel-ipu7-camera.conf > /dev/null << EOF
# Ensure LJCA and intel_cvs are loaded before the camera sensor probes.
# Without this, the sensor may fail to bind on boot.
# LJCA (GPIO/USB) -> intel_cvs (CVS) -> sensor
softdep intel_cvs pre: usb_ljca gpio_ljca
softdep ${SENSOR_MOD} pre: intel_cvs usb_ljca gpio_ljca
EOF
echo "  ✓ Created /etc/modprobe.d/intel-ipu7-camera.conf"

# ──────────────────────────────────────────────
# [10/15] libcamera IPA module path
# ──────────────────────────────────────────────
echo ""
echo "[10/15] Configuring libcamera environment..."

# Determine IPA path based on distro
if [[ "$DISTRO" == "fedora" ]]; then
    # Fedora uses lib64
    if [[ -d "/usr/lib64/libcamera/ipa" ]]; then
        IPA_PATH="/usr/lib64/libcamera/ipa"
    else
        IPA_PATH="/usr/lib/libcamera/ipa"
    fi
elif [[ "$DISTRO" == "ubuntu" ]]; then
    # Source builds typically install to /usr/local/lib
    if [[ -d "/usr/local/lib/libcamera/ipa" ]]; then
        IPA_PATH="/usr/local/lib/libcamera/ipa"
    elif [[ -d "/usr/local/lib/x86_64-linux-gnu/libcamera/ipa" ]]; then
        IPA_PATH="/usr/local/lib/x86_64-linux-gnu/libcamera/ipa"
    else
        IPA_PATH="/usr/lib/libcamera/ipa"
    fi
else
    # Arch and other
    IPA_PATH="/usr/lib/libcamera/ipa"
fi

# Detect SPA plugin path for source-built PipeWire (Ubuntu)
# PipeWire's libcamera SPA plugin must be discoverable for PipeWire to
# expose the camera to apps (Firefox, Zoom, etc.). Source builds install
# to /usr/local which PipeWire's systemd service doesn't search by default.
SPA_PATH=""
if [[ "$DISTRO" == "ubuntu" ]]; then
    SPA_PLUGIN=$(find /usr/local/lib -path "*/spa-*/libcamera/libspa-libcamera.so" 2>/dev/null | head -1)
    if [[ -n "$SPA_PLUGIN" ]]; then
        # Extract the spa-0.2 directory (parent of libcamera/)
        SPA_PATH=$(dirname "$(dirname "$SPA_PLUGIN")")
        echo "  Found PipeWire libcamera SPA plugin at: ${SPA_PLUGIN}"
        echo "  Setting SPA_PLUGIN_DIR=${SPA_PATH}"
    fi
fi

# systemd user environment
sudo mkdir -p /etc/environment.d
if [[ -n "$SPA_PATH" ]]; then
    sudo tee /etc/environment.d/libcamera-ipa.conf > /dev/null << EOF
LIBCAMERA_IPA_MODULE_PATH=${IPA_PATH}
SPA_PLUGIN_DIR=${SPA_PATH}
EOF
else
    sudo tee /etc/environment.d/libcamera-ipa.conf > /dev/null << EOF
LIBCAMERA_IPA_MODULE_PATH=${IPA_PATH}
EOF
fi
echo "  ✓ Created /etc/environment.d/libcamera-ipa.conf"

# Non-systemd shell sessions
if [[ -n "$SPA_PATH" ]]; then
    sudo tee /etc/profile.d/libcamera-ipa.sh > /dev/null << EOF
export LIBCAMERA_IPA_MODULE_PATH=${IPA_PATH}
export SPA_PLUGIN_DIR=${SPA_PATH}
EOF
else
    sudo tee /etc/profile.d/libcamera-ipa.sh > /dev/null << EOF
export LIBCAMERA_IPA_MODULE_PATH=${IPA_PATH}
EOF
fi
echo "  ✓ Created /etc/profile.d/libcamera-ipa.sh"

# ──────────────────────────────────────────────
# [11/15] Hide raw IPU7 V4L2 nodes from PipeWire
# ──────────────────────────────────────────────
echo ""
echo "[11/15] Configuring WirePlumber to hide raw IPU7 V4L2 nodes..."

# IPU7 exposes 32 raw V4L2 capture nodes that output bayer data unusable by
# apps. Without this rule, PipeWire creates 32 "ipu7" camera sources that
# flood app camera lists and produce garbled images. libcamera handles the
# actual camera pipeline separately — this only suppresses the V4L2 monitor.
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

WP_RULE_INSTALLED=false

# WirePlumber 0.5+ uses JSON conf files in wireplumber.conf.d/
if [[ -d /etc/wireplumber/wireplumber.conf.d ]] || \
   wireplumber --version 2>/dev/null | grep -qP '0\.[5-9]|[1-9]\.' 2>/dev/null; then
    sudo mkdir -p /etc/wireplumber/wireplumber.conf.d
    sudo cp "$SCRIPT_DIR/50-disable-ipu7-v4l2.conf" \
        /etc/wireplumber/wireplumber.conf.d/50-disable-ipu7-v4l2.conf
    echo "  ✓ Installed WirePlumber 0.5+ rule (wireplumber.conf.d/)"
    WP_RULE_INSTALLED=true
    # Clean up Lua file from older installer runs (unsupported on 0.5+, causes warnings)
    if [[ -f /etc/wireplumber/main.lua.d/51-disable-ipu7-v4l2.lua ]]; then
        sudo rm -f /etc/wireplumber/main.lua.d/51-disable-ipu7-v4l2.lua
        echo "  ✓ Removed stale WirePlumber 0.4 Lua rule (unsupported on 0.5+)"
    fi
fi

# WirePlumber 0.4 uses Lua scripts in main.lua.d/ (skip if 0.5+ already installed)
if ! $WP_RULE_INSTALLED; then
    if [[ -d /etc/wireplumber/main.lua.d ]] || \
       [[ -d /usr/share/wireplumber/main.lua.d ]]; then
        sudo mkdir -p /etc/wireplumber/main.lua.d
        sudo cp "$SCRIPT_DIR/50-disable-ipu7-v4l2.lua" \
            /etc/wireplumber/main.lua.d/51-disable-ipu7-v4l2.lua
        echo "  ✓ Installed WirePlumber 0.4 rule (main.lua.d/)"
        WP_RULE_INSTALLED=true
    fi
fi

if ! $WP_RULE_INSTALLED; then
    echo "  ⚠ Could not detect WirePlumber config directory"
    echo "    Apps may show 32 raw IPU7 camera entries instead of the libcamera source"
fi

# ──────────────────────────────────────────────
# [12/15] Install sensor color tuning file
# ──────────────────────────────────────────────
echo ""
echo "[12/15] Installing libcamera color tuning file..."

# libcamera's Software ISP uses uncalibrated.yaml by default, which has no
# color correction matrix (CCM) — producing near-grayscale or green-tinted
# images. We install a sensor-specific tuning file with a light CCM that
# restores reasonable color. libcamera looks for <sensor>.yaml first, so
# this doesn't modify the system's uncalibrated.yaml.

TUNING_SENSOR="${SENSOR:-ov02e10}"
TUNING_FILE="${TUNING_SENSOR}.yaml"

# Find where libcamera's IPA tuning files are installed
TUNING_DIR=""
for dir in /usr/local/share/libcamera/ipa/simple \
           /usr/share/libcamera/ipa/simple; do
    if [[ -d "$dir" ]]; then
        TUNING_DIR="$dir"
        break
    fi
done

if [[ -n "$TUNING_DIR" ]]; then
    SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    if [[ -f "$SCRIPT_DIR/$TUNING_FILE" ]]; then
        sudo cp "$SCRIPT_DIR/$TUNING_FILE" "$TUNING_DIR/$TUNING_FILE"

        # libcamera 0.5.x uses Lut; 0.6+ uses Adjust (replaces Lut)
        if [[ -n "${LIBCAMERA_MINOR:-}" ]] && [[ "${LIBCAMERA_MINOR}" -lt 6 ]] 2>/dev/null; then
            sudo sed -i '/^  - Adjust:/d' "$TUNING_DIR/$TUNING_FILE"
            echo "  ✓ Installed $TUNING_FILE → $TUNING_DIR/ (v0.5: using Lut)"
        else
            sudo sed -i '/^  - Lut:/d' "$TUNING_DIR/$TUNING_FILE"
            echo "  ✓ Installed $TUNING_FILE → $TUNING_DIR/ (v0.6+: using Adjust)"
        fi
        echo "    (CCM tuned by david-bartlett on Galaxy Book5 Pro)"
        echo "    Use ./tune-ccm.sh to interactively find the best color preset"
    else
        echo "  ⚠ Tuning file $TUNING_FILE not found in installer directory"
    fi
else
    echo "  ⚠ Could not find libcamera IPA data directory"
    echo "    Images may appear grayscale or green-tinted until a tuning file is installed"
fi

# ──────────────────────────────────────────────
# [13/15] Camera relay tool (for non-PipeWire apps)
# ──────────────────────────────────────────────
echo ""
echo "[13/15] Installing camera relay tool..."

# Some apps (Zoom, OBS, VLC) don't support PipeWire/libcamera directly and
# need a standard V4L2 device. The camera-relay tool creates an on-demand
# v4l2loopback bridge: libcamerasrc → GStreamer → /dev/videoX.
# Not enabled by default — users start it when needed.

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
RELAY_DIR="$SCRIPT_DIR/../camera-relay"

if [[ -d "$RELAY_DIR" ]]; then
    # Install GStreamer libcamerasrc element if not present
    if ! gst-inspect-1.0 libcamerasrc &>/dev/null 2>&1; then
        echo "  Installing GStreamer libcamera plugin..."
        if [[ "$DISTRO" == "fedora" ]]; then
            sudo dnf install -y gstreamer1-plugins-bad-free-extras 2>/dev/null || \
            sudo dnf install -y gstreamer1-plugins-bad-free 2>/dev/null || true
        elif [[ "$DISTRO" == "arch" ]]; then
            sudo pacman -S --needed --noconfirm gst-plugin-libcamera 2>/dev/null || true
        elif [[ "$DISTRO" == "ubuntu" ]]; then
            sudo apt install -y gstreamer1.0-plugins-bad 2>/dev/null || true
        fi
    fi

    # Install v4l2loopback if not present
    if ! modinfo v4l2loopback &>/dev/null 2>&1; then
        echo "  Installing v4l2loopback..."
        if [[ "$DISTRO" == "fedora" ]]; then
            sudo dnf install -y v4l2loopback 2>/dev/null || true
        elif [[ "$DISTRO" == "arch" ]]; then
            sudo pacman -S --needed --noconfirm v4l2loopback-dkms 2>/dev/null || true
        elif [[ "$DISTRO" == "ubuntu" ]]; then
            sudo apt install -y v4l2loopback-dkms 2>/dev/null || true
        fi
    fi

    # Deploy v4l2loopback config (always overwrite — Fedora's v4l2loopback-akmods
    # can drop its own config that overrides ours, causing wrong card_label)
    sudo cp "$RELAY_DIR/99-camera-relay-loopback.conf" /etc/modprobe.d/
    echo "  ✓ Installed v4l2loopback config (/etc/modprobe.d/99-camera-relay-loopback.conf)"

    # Ensure v4l2loopback loads at boot (modprobe.d only sets options, doesn't trigger load)
    echo "v4l2loopback" | sudo tee /etc/modules-load.d/v4l2loopback.conf > /dev/null
    echo "  ✓ Installed v4l2loopback autoload (/etc/modules-load.d/v4l2loopback.conf)"

    # Rebuild initramfs so it picks up the new v4l2loopback config.
    # Without this, v4l2loopback may load from initramfs with stale
    # defaults (e.g. "OBS Virtual Camera") before /etc/modprobe.d/ is read.
    if command -v dracut &>/dev/null; then
    	# (initramfs rebuilt once at end of script)
    	NEEDS_INITRAMFS=1
        echo "  ✓ Initramfs rebuild with Camera Relay config defered until the end of the script"
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
            sudo cp /tmp/camera-relay-monitor /usr/local/bin/camera-relay-monitor
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
    echo "  ✓ Installed systray GUI (/usr/local/share/camera-relay/)"

    # Install desktop file
    sudo cp "$RELAY_DIR/camera-relay-systray.desktop" /usr/share/applications/
    echo "  ✓ Installed desktop entry"

    # Auto-enable persistent on-demand relay
    echo "  Enabling on-demand relay (auto-starts on login)..."
    /usr/local/bin/camera-relay enable-persistent --yes 2>/dev/null && \
        echo "  ✓ On-demand relay enabled (near-zero idle CPU)" || \
        echo "  ⚠ Could not enable persistent relay — run 'camera-relay enable-persistent' after reboot"
else
    echo "  ⚠ camera-relay directory not found — skipping relay tool installation"
fi

# ──────────────────────────────────────────────
# [14/15] Load modules and test
# ──────────────────────────────────────────────
echo ""
echo "[14/15] Loading modules and testing..."

# Try to load LJCA and intel_cvs now
for mod in usb_ljca gpio_ljca; do
    if ! lsmod | grep -q "$(echo $mod | tr '-' '_')"; then
        sudo modprobe "$mod" 2>/dev/null || true
    fi
done
if ! lsmod | grep -q "intel_cvs"; then
    if sudo modprobe intel_cvs 2>/dev/null; then
        echo "  ✓ intel_cvs module loaded"
    else
        echo "  ⚠ Could not load intel_cvs now — will load after reboot"
    fi
else
    echo "  ✓ intel_cvs module already loaded"
fi

# Export IPA path for current session test
export LIBCAMERA_IPA_MODULE_PATH="${IPA_PATH}"

# Test with cam -l if available
if command -v cam >/dev/null 2>&1; then
    echo "  Testing with cam -l..."
    CAM_OUTPUT=$(cam -l 2>&1 || true)
    if echo "$CAM_OUTPUT" | grep -qi "ov02c10\|ov02e10\|Camera\|sensor"; then
        echo "  ✓ libcamera detects camera!"
        echo "$CAM_OUTPUT" | head -5 | sed 's/^/    /'
    else
        echo "  ⚠ libcamera does not see the camera yet (may need reboot)"
    fi
else
    echo "  ⚠ cam (libcamera-tools) not installed — skipping live test"
    if [[ "$DISTRO" == "arch" ]]; then
        echo "    Optional: sudo pacman -S libcamera-tools"
    fi
fi

# ──────────────────────────────────────────────
# [14b/15] Rebuild initramfs (once, if needed)
# ──────────────────────────────────────────────
if [[ "$NEEDS_INITRAMFS" == "1" ]]; then
    echo ""
    echo "  Rebuilding initramfs (this may take a moment)..."
    if command -v dracut >/dev/null 2>&1; then
        sudo dracut --force 2>/dev/null && echo "  ✓ initramfs rebuilt" || true
    elif command -v update-initramfs >/dev/null 2>&1; then
        sudo update-initramfs -u -k "$(uname -r)" 2>/dev/null && echo "  ✓ initramfs rebuilt" || true
    elif command -v mkinitcpio >/dev/null 2>&1; then
        sudo mkinitcpio -P 2>/dev/null && echo "  ✓ initramfs rebuilt" || true
    else
        echo "  ⚠ Could not detect initramfs tool — rebuild manually before rebooting"
    fi
fi

# ──────────────────────────────────────────────
# [15/15] Summary
# ──────────────────────────────────────────────
echo ""
echo "=============================================="
echo "  Installation complete — reboot required"
echo "=============================================="
echo ""
echo "  After rebooting, test with:"
echo "    cam -l                      # List cameras (libcamera)"
echo "    cam -c1 --capture=10        # Capture 10 frames"
echo "    mpv av://v4l2:/dev/video0   # Live preview (if V4L2 device appears)"
echo ""
echo "  The camera should appear automatically in apps that use PipeWire."
echo "  No v4l2loopback needed."
echo ""
echo "  Browser setup (if camera doesn't appear in browser):"
echo "    Firefox:  about:config → media.webrtc.camera.allow-pipewire = true"
echo "              For full resolution: media.navigator.video.default_width = 1920"
echo "                                   media.navigator.video.default_height = 1080"
echo "    Chrome:   Works out of the box with the V4L2 camera relay"
echo "    Troubleshooting: If your browser doesn't see the camera, try enabling"
echo "      chrome://flags/#enable-webrtc-pipewire-camera — but note this flag"
echo "      can break camera access in some Chromium-based browsers."
echo ""
echo "  Non-PipeWire apps (Zoom, OBS, VLC) use the on-demand camera relay."
echo "  The relay is enabled and will auto-start on login (near-zero idle CPU)."
echo "    camera-relay status             # Check relay state"
echo "    camera-relay disable-persistent # Disable auto-start"
echo "    Or launch 'Camera Relay' from your app menu for a systray toggle"
echo ""
echo "  Known issues:"
echo "    - Color quality: A light color correction profile is installed, but image"
echo "      quality may not match Windows. Full sensor calibration is pending upstream."
echo "    - Vertically flipped image: Fixed on Samsung 940XHA/960XHA/960QHA via ipu-bridge"
echo "      DKMS patch. Other models may still be affected."
echo "    - Only one app can use the camera at a time (libcamera limitation)."
echo "      Close the first app before opening another. Use 'camera-relay' if you"
echo "      need the camera in apps that don't support PipeWire."
echo "    - If PipeWire doesn't see the camera, try: systemctl --user restart pipewire"
echo ""
echo "  Configuration files created:"
echo "    /etc/modules-load.d/intel-ipu7-camera.conf"
echo "    /etc/modprobe.d/intel-ipu7-camera.conf"
echo "    /etc/environment.d/libcamera-ipa.conf"
echo "    /etc/profile.d/libcamera-ipa.sh"
echo "    ${SRC_DIR}/ (DKMS source)"
if [[ -d "$IPU_BRIDGE_FIX_SRC" ]]; then
echo "    ${IPU_BRIDGE_FIX_SRC}/ (ipu-bridge rotation fix DKMS source)"
echo "    /usr/local/sbin/ipu-bridge-check-upstream.sh"
echo "    /etc/systemd/system/ipu-bridge-check-upstream.service"
fi
if [[ -d "/var/lib/libcamera-bayer-fix-backup" ]]; then
echo "    /var/lib/libcamera-bayer-fix-backup/ (original libcamera backup)"
fi
echo ""
echo "  To uninstall: ./uninstall.sh"
echo "=============================================="
