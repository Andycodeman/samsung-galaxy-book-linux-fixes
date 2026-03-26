#!/bin/bash
# install.sh — Samsung Galaxy Book 4 Webcam Fix
# For Samsung Galaxy Book 4 series (Meteor Lake / IPU6)
# Using libcamera open-source stack on Arch, Fedora, and Ubuntu
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

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo: sudo bash install.sh" >&2
    exit 1
fi

# Flag to track whether initramfs needs rebuilding at the end
NEED_INITRAMFS_REBUILD=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────────
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }

# ── find_libcamera ────────────────────────────────────────────────────────────
# Locates libcamera on the system and sets the following globals:
#   LIBCAMERA_SO       — full path to the highest-versioned .so file found
#   LIBCAMERA_MAJOR    — major version number
#   LIBCAMERA_MINOR    — minor version number
#   LIBCAMERA_PATCH    — patch version number
#   LIBCAMERA_IPA_PATH — path to the libcamera IPA modules directory
#   LIBCAMERA_TUNE_DIR — path to the libcamera simple ISP tuning directory
#
# IPA_PATH and TUNE_DIR are found independently via find — NOT derived from
# the .so location — so this works correctly on all distros regardless of
# whether libcamera was installed to /usr, /usr/local, /usr/lib64, etc.
#
# Returns 0 if libcamera .so is found, 1 if not.
# Missing IPA/tune dirs are reported as warnings but do NOT cause failure.
# Supports LIBCAMERA_OVERRIDE_PATH env var for non-standard install locations.
find_libcamera() {
    # ── Allow manual override ─────────────────────────────────────────────────
    if [[ -n "${LIBCAMERA_OVERRIDE_PATH:-}" ]]; then
        if [[ ! -f "$LIBCAMERA_OVERRIDE_PATH" ]]; then
            echo "Error: LIBCAMERA_OVERRIDE_PATH set but file not found: $LIBCAMERA_OVERRIDE_PATH" >&2
            return 1
        fi
        LIBCAMERA_SO="$LIBCAMERA_OVERRIDE_PATH"
    else
        # ── Find highest versioned .so across all standard locations ──────────
        # Matches files like libcamera.so.0.7.0 — three numeric components.
        # Excludes soname symlinks (libcamera.so.0) and non-library files.
        LIBCAMERA_SO=$(
            find /usr /opt \
                -name "libcamera.so.*" 2>/dev/null \
            | grep -P 'libcamera\.so\.\d+\.\d+\.\d+' \
            | sed 's|.*libcamera\.so\.\(.*\)|\1 &|' \
            | sort -V \
            | tail -1 \
            | cut -d' ' -f2-
        )
    fi

    if [[ -z "$LIBCAMERA_SO" ]]; then
        return 1
    fi

    # ── Extract version numbers from filename ─────────────────────────────────
    local _version
    _version=$(basename "$LIBCAMERA_SO" | grep -oP '\d+\.\d+\.\d+')
    LIBCAMERA_MAJOR="${_version%%.*}"
    LIBCAMERA_MINOR=$(echo "$_version" | cut -d. -f2)
    LIBCAMERA_PATCH="${_version##*.}"

    # ── Find IPA path independently via find ─────────────────────────────────
    # Search broadly — do NOT derive from .so location as layout varies by distro.
    # Exclude /usr/include — that contains header files, not loadable IPA modules.
    LIBCAMERA_IPA_PATH=$(
        find /usr /opt \
            -not -path "*/include/*" \
            -type d -name "ipa" \
            -path "*/libcamera/ipa" 2>/dev/null \
        | head -1
    )
    if [[ -z "$LIBCAMERA_IPA_PATH" ]]; then
        warn "libcamera IPA directory not found — LIBCAMERA_IPA_MODULE_PATH will not be set"
    fi

    # ── Find tuning directory independently via find ──────────────────────────
    LIBCAMERA_TUNE_DIR=$(
        find /usr /opt \
            -not -path "*/include/*" \
            -type d -name "simple" \
            -path "*/libcamera/ipa/simple" 2>/dev/null \
        | head -1
    )
    if [[ -z "$LIBCAMERA_TUNE_DIR" ]]; then
        warn "libcamera tuning directory not found — sensor tuning file will not be installed"
    fi

    return 0
}

LIBCAMERA_MIN_VER="0.7.0"
LIBCAMERA_BUILD_VER="v0.7.0"
LIBCAMERA_BUILD_DIR="/tmp/libcamera-ipu6-build"

echo "=============================================="
echo "  Samsung Galaxy Book Webcam Fix (libcamera)"
echo "  Book3 / Book4 — IPU6 Open-Source Stack"
echo "=============================================="
echo ""

# ──────────────────────────────────────────────
# [1/14] Root check
# ──────────────────────────────────────────────

# ──────────────────────────────────────────────
# [2/14] Distro detection
# ──────────────────────────────────────────────
echo "[2/14] Detecting distro..."
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
# [3/14] Verify hardware
# ──────────────────────────────────────────────
echo ""
echo "[3/14] Verifying hardware..."

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
# [4/14] Check kernel version
# ──────────────────────────────────────────────
echo ""
echo "[4/14] Checking kernel version..."
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
# [5/14] Check kernel modules
# ──────────────────────────────────────────────
echo ""
echo "[5/14] Checking kernel modules..."
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
# [6/14] Check OV02C10 sensor probe (26 MHz clock fix)
# ──────────────────────────────────────────────
echo ""
echo "[6/14] Checking OV02C10 sensor probe status..."

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
    # Check dmesg for the 26 MHz clock rejection.
    # On Fedora/newer kernels, unprivileged dmesg may be blocked (dmesg_restrict=1),
    # so try multiple sources: dmesg, sudo dmesg, journalctl.
    CLOCK_ERROR_FOUND=false
    if dmesg 2>/dev/null | grep -qi "external clock 26000000 is not supported"; then
        CLOCK_ERROR_FOUND=true
    elif sudo dmesg 2>/dev/null | grep -qi "external clock 26000000 is not supported"; then
        CLOCK_ERROR_FOUND=true
    elif journalctl -k --no-pager 2>/dev/null | grep -qi "external clock 26000000 is not supported"; then
        CLOCK_ERROR_FOUND=true
    fi
    if $CLOCK_ERROR_FOUND; then
        DKMS_26MHZ_NEEDED=true
        echo "  ⚠ Detected 26 MHz external clock error in dmesg."
        echo "    Your hardware has a 26 MHz clock but the kernel driver only supports 19.2 MHz."
        echo "    A DKMS-patched ov02c10 driver is available to fix this."
        echo ""
        read -rp "  Install the patched driver now? [Y/n] " REPLY_26MHZ </dev/tty 2>/dev/null || REPLY_26MHZ="Y"
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
# [7/14] Load and persist IVSC modules
# ──────────────────────────────────────────────
echo ""
echo "[7/14] Loading IVSC kernel modules..."
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
            NEED_INITRAMFS_REBUILD=true
            echo "  ✓ IVSC modules added to initramfs (will rebuild at end)"
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
            NEED_INITRAMFS_REBUILD=true
            echo "  ✓ IVSC modules added to initramfs (will rebuild at end)"
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
            NEED_INITRAMFS_REBUILD=true
            echo "  ✓ IVSC modules added to initramfs (will rebuild at end)"
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
# [8/14] Samsung camera rotation fix (ipu-bridge DKMS)
# ──────────────────────────────────────────────
echo ""
echo "[8/14] Checking camera rotation fix..."

# Samsung Galaxy Book3/Book4 models have their OV02C10 sensor mounted
# upside-down, but Samsung's BIOS reports rotation=0. The kernel's
# ipu-bridge driver has a DMI quirk table for this, but the Samsung entries
# aren't upstream yet. Ship a patched ipu-bridge.ko via DKMS until they are.

NEEDS_ROTATION_FIX=false
DMI_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
DMI_PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
if [[ "$DMI_VENDOR" == "SAMSUNG ELECTRONICS CO., LTD." ]]; then
    case "$DMI_PRODUCT" in
        940XFG|960XFG|960XGL|960QFG|960QGK) NEEDS_ROTATION_FIX=true ;;
    esac
fi

IPU_BRIDGE_FIX_VER="1.0"
IPU_BRIDGE_FIX_SRC="/usr/src/ipu-bridge-fix-${IPU_BRIDGE_FIX_VER}"

if $NEEDS_ROTATION_FIX; then
    IPU_BRIDGE_DIR="$SCRIPT_DIR/../webcam-fix-book5/ipu-bridge-fix"

    if [[ ! -d "$IPU_BRIDGE_DIR" ]]; then
        # Try downloading from GitHub if not present locally
        echo "  ipu-bridge-fix not found locally, downloading..."
        IPU_BRIDGE_DIR="/tmp/ipu-bridge-fix"
        rm -rf "$IPU_BRIDGE_DIR"
        mkdir -p "$IPU_BRIDGE_DIR"
        GITHUB_RAW="https://raw.githubusercontent.com/Andycodeman/samsung-galaxy-book4-linux-fixes/main/webcam-fix-book5/ipu-bridge-fix"
        for fname in ipu-bridge.c Makefile dkms.conf; do
            if ! curl -fsSL "$GITHUB_RAW/$fname" -o "$IPU_BRIDGE_DIR/$fname"; then
                echo "  ERROR: Failed to download $fname"
                echo "         Please clone the full repo and try again."
                rm -rf "$IPU_BRIDGE_DIR"
                IPU_BRIDGE_DIR=""
                break
            fi
        done
    fi

    if [[ -n "$IPU_BRIDGE_DIR" ]]; then
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
                if $DECOMPRESS "$NATIVE_IPU_BRIDGE" 2>/dev/null | strings | grep -q "$DMI_PRODUCT"; then
                    UPSTREAM_HAS_FIX=true
                fi
            fi

            if $UPSTREAM_HAS_FIX; then
                echo "  ✓ Native kernel ipu-bridge already has Samsung rotation fix — skipping DKMS"
            else
                # Remove old DKMS version if present
                if dkms status "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}" 2>/dev/null | grep -q "ipu-bridge-fix"; then
                    sudo dkms remove "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}" --all 2>/dev/null || true
                fi

                # Copy source to DKMS tree
                sudo rm -rf "$IPU_BRIDGE_FIX_SRC"
                sudo mkdir -p "$IPU_BRIDGE_FIX_SRC"
                sudo cp -a "$IPU_BRIDGE_DIR/"* "$IPU_BRIDGE_FIX_SRC/"

                # Secure Boot handling for Fedora
                if [[ "$DISTRO" == "fedora" ]] && mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
                    MOK_KEY="/etc/pki/akmods/private/private_key.priv"
                    MOK_CERT="/etc/pki/akmods/certs/public_key.der"
                    if [[ -f "$MOK_KEY" ]] && [[ -f "$MOK_CERT" ]]; then
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
                NEED_INITRAMFS_REBUILD=true
                echo "  ✓ ipu-bridge DKMS installed (initramfs will rebuild at end)"
            fi
        fi

        # Install upstream check script and service
        BOOK5_DIR="$SCRIPT_DIR/../webcam-fix-book5"
        if [[ -f "$BOOK5_DIR/ipu-bridge-check-upstream.sh" ]]; then
            sudo cp "$BOOK5_DIR/ipu-bridge-check-upstream.sh" /usr/local/sbin/ipu-bridge-check-upstream.sh
            sudo chmod 755 /usr/local/sbin/ipu-bridge-check-upstream.sh
            sudo cp "$BOOK5_DIR/ipu-bridge-check-upstream.service" /etc/systemd/system/ipu-bridge-check-upstream.service
            sudo systemctl daemon-reload
            sudo systemctl enable ipu-bridge-check-upstream.service
            echo "  ✓ Upstream check service enabled (auto-removes fix when kernel catches up)"
        fi

        # Clean up temp download
        rm -rf /tmp/ipu-bridge-fix
    else
        echo "  ⚠ Could not locate ipu-bridge fix files. Camera image may be upside-down."
        echo "    Clone the full repo and re-run the installer to fix this."
    fi
else
    echo "  ✓ No rotation fix needed for this model"
fi

# ──────────────────────────────────────────────
# [9/14] Install/build libcamera
# ──────────────────────────────────────────────
echo ""
echo "[9/14] Installing libcamera..."

# Check if a sufficient version is already installed
check_libcamera_version() {
    # Use find_libcamera — searches /usr and /opt broadly,
    # works on all distros regardless of lib path layout.
    if ! find_libcamera 2>/dev/null; then
        echo ""
        return 1
    fi

    # Need >= 0.7 (0.5.x detects OV02C10 but fails to stream; 0.7.0 has
    # proper IPASoft sensor support, Ccm/Awb/Adjust algorithms, and handles
    # missing selection API gracefully)
    if [[ "$LIBCAMERA_MAJOR" -gt 0 ]] || \
       { [[ "$LIBCAMERA_MAJOR" -eq 0 ]] && [[ "$LIBCAMERA_MINOR" -ge 7 ]]; }; then
        echo "${LIBCAMERA_MAJOR}.${LIBCAMERA_MINOR}.${LIBCAMERA_PATCH}"
        return 0
    fi

    echo "${LIBCAMERA_MAJOR}.${LIBCAMERA_MINOR}.${LIBCAMERA_PATCH}"
    return 1
}

build_libcamera_from_source() {
    echo "  Building libcamera $LIBCAMERA_BUILD_VER from source..."
    echo "  (This will take a few minutes)"
    echo ""

    # Ensure the build uses the system Python, not pyenv/conda/virtualenv shims.
    # System packages (python3-pyyaml, python3-ply, python3-jinja2) are installed
    # into the system Python's site-packages, but pyenv/conda shims redirect
    # 'python3' to a user-managed interpreter that won't have them.
    if [[ -x /usr/bin/python3 ]]; then
        if [[ -n "$PYENV_ROOT" ]] || [[ -n "$CONDA_PREFIX" ]] || [[ -n "$VIRTUAL_ENV" ]]; then
            echo "  Note: pyenv/conda/virtualenv detected — using system Python for build"
        fi
        export PATH="/usr/bin:$PATH"
    fi

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
                openssl libssl-dev libdw-dev libunwind-dev \
                libdbus-1-dev
            ;;
        fedora)
            sudo dnf install -y \
                git meson ninja-build gcc gcc-c++ pkgconfig cmake \
                python3-pyyaml python3-ply python3-jinja2 \
                gnutls-devel libudev-devel libyaml-devel libevent-devel \
                gstreamer1-devel gstreamer1-plugins-base-devel \
                libdrm-devel libjpeg-turbo-devel libtiff-devel \
                openssl openssl-devel elfutils-libelf-devel libunwind-devel \
                dbus-devel
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

    # Patch: Add OV02C10 CameraSensorHelper so IPASoft can properly control
    # exposure and gain. Without this, auto-exposure uses a generic fallback
    # that produces a very dark image.
    # The helper file moved between libcamera versions:
    #   <= 0.5.x: src/libcamera/sensor/camera_sensor_helper.cpp
    #   >= 0.7.0: src/ipa/libipa/camera_sensor_helper.cpp
    HELPER_FILE=""
    for candidate in src/ipa/libipa/camera_sensor_helper.cpp \
                     src/libcamera/sensor/camera_sensor_helper.cpp; do
        if [[ -f "$candidate" ]]; then
            HELPER_FILE="$candidate"
            break
        fi
    done
    if [[ -n "$HELPER_FILE" ]] && ! grep -q "CameraSensorHelperOv02c10" "$HELPER_FILE"; then
        echo "  Patching libcamera with OV02C10 sensor helper..."
        # In libcamera 0.7.0 the helpers are inside namespace ipa { namespace libcamera { }}.
        # We must insert before the closing braces, not append after them.
        # Also, 0.7.0 uses gain_ = AnalogueGainLinear{} instead of gainType_/gainConstants_.
        if grep -q "namespace ipa" "$HELPER_FILE"; then
            # v0.7.0+ format: insert before "#endif /* __DOXYGEN__ */" or before
            # the final namespace closing
            sed -i '/#endif.*__DOXYGEN__/i\
class CameraSensorHelperOv02c10 : public CameraSensorHelper\
{\
public:\
\tCameraSensorHelperOv02c10()\
\t{\
\t\tgain_ = AnalogueGainLinear{ 1, 0, 0, 16 };\
\t}\
};\
REGISTER_CAMERA_SENSOR_HELPER("ov02c10", CameraSensorHelperOv02c10)\
' "$HELPER_FILE"
        else
            # Pre-0.7.0 format: append to end of file
            cat >> "$HELPER_FILE" << 'PATCH_EOF'

class CameraSensorHelperOv02c10 : public CameraSensorHelper
{
public:
	CameraSensorHelperOv02c10()
	{
		gainType_ = AnalogueGainLinear;
		gainConstants_.linear = { 1, 0, 0, 16 };
	}
};
REGISTER_CAMERA_SENSOR_HELPER("ov02c10", CameraSensorHelperOv02c10)
PATCH_EOF
        fi
        echo "  ✓ OV02C10 sensor helper patched"
    fi

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

    # Ensure /usr/local/lib64 (Fedora) and /usr/local/lib (Ubuntu) are in the
    # dynamic linker search path. Without this, 'cam' and gstreamer plugins
    # fail with "cannot open shared object file" on Fedora where /usr/local/lib64
    # is not in the default search path.
    if [[ ! -f /etc/ld.so.conf.d/libcamera-local.conf ]]; then
        echo "/usr/local/lib64" | sudo tee /etc/ld.so.conf.d/libcamera-local.conf > /dev/null
        echo "/usr/local/lib/x86_64-linux-gnu" | sudo tee -a /etc/ld.so.conf.d/libcamera-local.conf > /dev/null
    fi
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

# Check if a source-built libcamera at /usr/local has the OV02C10 sensor helper.
# A previous install (before v0.3.6) may have built v0.7.0 without the helper patch.
# If so, force a rebuild so the sensor helper gets patched in.
check_sensor_helper() {
    # LIBCAMERA_SO is set by find_libcamera / check_libcamera_version
    # Only check source builds under /usr/local — system packages manage themselves
    if [[ -n "${LIBCAMERA_SO:-}" ]] && echo "$LIBCAMERA_SO" | grep -q "^/usr/local/"; then
        strings "$LIBCAMERA_SO" | grep -q "CameraSensorHelperOv02c10"
    else
        return 0  # system package — assume sensor helper present
    fi
}

if $LIBCAMERA_OK; then
    if echo "${LIBCAMERA_SO:-}" | grep -q "^/usr/local/" && ! check_sensor_helper 2>/dev/null; then
        echo "  ⚠ libcamera $LIBCAMERA_VER found but missing OV02C10 sensor helper — rebuild needed"
        LIBCAMERA_OK=false
    fi
fi

# Clean up stale /usr/local libcamera builds that are older than the minimum.
# This can happen if a user previously built libcamera from source (e.g. an
# older version or an AI-assisted attempt) and later upgraded the system packages
# to a sufficient version. The stale /usr/local files would shadow the system
# libraries and GStreamer plugins, causing "Algorithm 'Ccm' not found" failures.
cleanup_stale_local_libcamera() {
    local stale_so stale_minor min_minor
    min_minor=$(echo "$LIBCAMERA_MIN_VER" | cut -d. -f2)

    # Only care about stale builds in /usr/local
    stale_so=$(find /usr/local -name "libcamera.so.*" 2>/dev/null \
        | grep -P 'libcamera\.so\.\d+\.\d+\.\d+' \
        | sed 's|.*libcamera\.so\.\(.*\)|\1 &|' \
        | sort -V | tail -1 | cut -d' ' -f2-)
    stale_minor=$(basename "${stale_so:-}" | grep -oP '\d+\.\d+\.\d+' | cut -d. -f2)

    # Also check for orphaned binaries from a previous partial cleanup
    # (e.g. .so files already removed but /usr/local/bin/cam still exists)
    if [[ -z "$stale_so" ]]; then
        for bin in cam qcam lc-compliance; do
            if [[ -x "/usr/local/bin/$bin" ]] && \
               ! "/usr/local/bin/$bin" --version &>/dev/null 2>&1; then
                sudo rm -f "/usr/local/bin/$bin"
                echo "  Removed orphaned /usr/local/bin/$bin (missing libraries)"
            fi
        done
        return
    fi

    if [[ -n "$stale_minor" ]] && [[ "$stale_minor" -lt "$min_minor" ]]; then
        echo "  ⚠ Removing stale libcamera build (0.$stale_minor) from /usr/local..."
        # Remove stale binaries from the old source build. They link against
        # the libcamera.so.0.X we're about to remove and would fail with
        # "cannot open shared object file" if left behind.
        for bin in cam qcam lc-compliance; do
            if [[ -x "/usr/local/bin/$bin" ]]; then
                sudo rm -f "/usr/local/bin/$bin"
                echo "    Removed stale /usr/local/bin/$bin"
            fi
        done
        for dir in /usr/local/lib/x86_64-linux-gnu /usr/local/lib/aarch64-linux-gnu \
                   /usr/local/lib64 /usr/local/lib; do
            sudo rm -f "$dir"/libcamera*.so* 2>/dev/null || true
            sudo rm -f "$dir"/gstreamer-1.0/libgstlibcamera.so 2>/dev/null || true
            sudo rm -rf "$dir"/libcamera/ 2>/dev/null || true
            sudo rm -f "$dir"/pkgconfig/libcamera*.pc 2>/dev/null || true
        done
        sudo rm -rf /usr/local/share/libcamera/ipa/simple 2>/dev/null || true
        sudo rm -rf /usr/local/include/libcamera 2>/dev/null || true
        # Remove environment configs that pointed to the now-gone /usr/local paths
        sudo rm -f /etc/profile.d/libcamera-ipa.sh 2>/dev/null || true
        sudo rm -f /etc/environment.d/libcamera-ipa.conf 2>/dev/null || true
        sudo ldconfig
        echo "  ✓ Stale /usr/local libcamera removed"

        # Ensure system packages provide cam and the GStreamer plugin now that
        # the /usr/local copies are gone.
        case "$DISTRO" in
            ubuntu|debian)
                for pkg in libcamera-tools gstreamer1.0-libcamera; do
                    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                        echo "  Installing $pkg (replacing removed /usr/local build)..."
                        sudo apt-get install -y "$pkg" 2>/dev/null || true
                    fi
                done
                ;;
        esac
    fi
}

case "$DISTRO" in
    fedora)
        if $LIBCAMERA_OK; then
            echo "  ✓ libcamera $LIBCAMERA_VER already installed (>= $LIBCAMERA_MIN_VER)"
            cleanup_stale_local_libcamera
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
            cleanup_stale_local_libcamera
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
            cleanup_stale_local_libcamera
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
            read -rp "  Proceed with source build? [Y/n] " REPLY </dev/tty 2>/dev/null || REPLY="Y"
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
# [10/14] Install PipeWire libcamera plugin
# ──────────────────────────────────────────────
echo ""
echo "[10/14] Installing PipeWire libcamera plugin..."

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

    # Find the system SPA plugin path and replace it — search broadly
    local SPA_DIR
    SPA_DIR=$(find /usr /opt -name "libspa-libcamera.so" -path "*/spa-0.2/libcamera/*" 2>/dev/null | head -1)
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
        SPA_SO=$(find /usr /opt -name "libspa-libcamera.so" -path "*/spa-0.2/libcamera/*" 2>/dev/null | head -1)
        # LOCAL_LIBCAMERA only relevant if libcamera was installed to /usr/local
        LOCAL_LIBCAMERA=""
        if echo "${LIBCAMERA_SO:-}" | grep -q "^/usr/local/"; then
            LOCAL_LIBCAMERA="$LIBCAMERA_SO"
        fi
        if [[ -n "$SPA_SO" ]]; then
            SPA_LIBCAMERA_VER=$(ldd "$SPA_SO" 2>/dev/null | grep -oP 'libcamera\.so\.\K[0-9]+\.[0-9]+' | head -1 || true)
            SPA_LIBCAMERA_MINOR=$(echo "$SPA_LIBCAMERA_VER" | cut -d. -f2)
            if [[ -n "$SPA_LIBCAMERA_MINOR" ]] && [[ "$SPA_LIBCAMERA_MINOR" -lt 7 ]] && \
               [[ -n "$LOCAL_LIBCAMERA" ]]; then
                echo "  SPA plugin links against libcamera $SPA_LIBCAMERA_VER (need >= 0.7)"
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
# [11/14] Install sensor tuning and configure environment
# ──────────────────────────────────────────────
echo ""
echo "[11/14] Installing sensor tuning and environment config..."

# Use find_libcamera results for tuning dir and IPA path.
# find_libcamera may have already been called — re-run if paths not yet set.
if [[ -z "${LIBCAMERA_IPA_PATH:-}" ]]; then
    find_libcamera 2>/dev/null || true
fi

# Install OV02C10 tuning file for libcamera Simple ISP
if [[ -n "${LIBCAMERA_TUNE_DIR:-}" ]]; then
    sudo mkdir -p "$LIBCAMERA_TUNE_DIR"
    sudo cp "$SCRIPT_DIR/ov02c10.yaml" "$LIBCAMERA_TUNE_DIR/ov02c10.yaml"
    echo "  ✓ Installed tuning file: $LIBCAMERA_TUNE_DIR/ov02c10.yaml"
else
    echo "  ⚠ Could not determine tuning directory — tuning file not installed"
fi

# Set IPA module search path using find_libcamera result
if [[ -n "${LIBCAMERA_IPA_PATH:-}" ]]; then
    sudo tee /etc/profile.d/libcamera-ipa.sh > /dev/null << EOF
# libcamera IPA module path
export LIBCAMERA_IPA_MODULE_PATH=${LIBCAMERA_IPA_PATH}
EOF
    sudo mkdir -p /etc/environment.d
    echo "LIBCAMERA_IPA_MODULE_PATH=${LIBCAMERA_IPA_PATH}" | \
        sudo tee /etc/environment.d/libcamera-ipa.conf > /dev/null
    # Set GST_PLUGIN_PATH so gst-launch/gst-inspect find libcamerasrc from any terminal
    if [[ -d /usr/local/lib/x86_64-linux-gnu/gstreamer-1.0 ]]; then
        echo "GST_PLUGIN_PATH=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0" | \
            sudo tee -a /etc/environment.d/libcamera-ipa.conf > /dev/null
        cat << 'GSTEOF' | sudo tee /etc/profile.d/libcamera-gst.sh > /dev/null
# GStreamer plugin path for source-built libcamera
export GST_PLUGIN_PATH=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0
GSTEOF
        echo "  ✓ IPA module path configured: ${LIBCAMERA_IPA_PATH}  and GStreamer plugin path configured"
    else
        echo "  ✓ IPA module path configured: ${LIBCAMERA_IPA_PATH}"
    fi
    export LIBCAMERA_IPA_MODULE_PATH="${LIBCAMERA_IPA_PATH}"
else
    echo "  ⚠ Could not determine IPA module path — LIBCAMERA_IPA_MODULE_PATH will not be set"
fi

# Ensure user is in video group (needed for non-root camera access)
# Use loginctl to reliably find the real desktop user when running as root via pkexec
CURRENT_USER=$(loginctl list-sessions --no-legend 2>/dev/null \
    | awk '$4 == "seat0" {print $3}' | head -1)
[[ -z "$CURRENT_USER" ]] && CURRENT_USER="${SUDO_USER:-$USER}"
if ! groups "$CURRENT_USER" 2>/dev/null | grep -q '\bvideo\b'; then
    sudo usermod -aG video "$CURRENT_USER"
    echo "  ✓ Added $CURRENT_USER to video group (takes effect on next login)"
else
    echo "  ✓ User already in video group"
fi

# ──────────────────────────────────────────────
# [12/14] Hide raw IPU6 nodes from PipeWire
# ──────────────────────────────────────────────
echo ""
echo "[12/14] Hiding raw IPU6 nodes from applications..."

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
# [13/14] Camera relay tool (for non-PipeWire apps)
# ──────────────────────────────────────────────
echo ""
echo "[13/14] Installing camera relay tool..."

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
        NEED_INITRAMFS_REBUILD=true
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
                _ru=$(loginctl list-sessions --no-legend 2>/dev/null \
                    | awk '$4 == "seat0" {print $3}' | head -1)
                _ruid=$(id -u "$_ru" 2>/dev/null)
                if [[ -n "$_ru" ]]; then
                    sudo -u "$_ru" \
                        XDG_RUNTIME_DIR="/run/user/${_ruid}" \
                        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_ruid}/bus" \
                        systemctl --user stop camera-relay.service 2>/dev/null || true
                fi
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
    _relay_user=$(loginctl list-sessions --no-legend 2>/dev/null \
        | awk '$4 == "seat0" {print $3}' | head -1)
    _relay_uid=$(id -u "$_relay_user" 2>/dev/null)
    if [[ -n "$_relay_user" && -n "$_relay_uid" ]]; then
        sudo -u "$_relay_user" \
            XDG_RUNTIME_DIR="/run/user/${_relay_uid}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_relay_uid}/bus" \
            /usr/local/bin/camera-relay enable-persistent --yes 2>/dev/null && \
            echo "  ✓ On-demand relay enabled for ${_relay_user} (near-zero idle CPU)" || \
            echo "  ⚠ Could not enable persistent relay — run 'camera-relay enable-persistent' after reboot"
    else
        echo "  ⚠ Could not detect logged-in user — run 'camera-relay enable-persistent' after reboot"
    fi
else
    echo "  ⚠ camera-relay directory not found — skipping"
fi

# ──────────────────────────────────────────────
# [13b/14] Single initramfs rebuild (covers all changes above)
# ──────────────────────────────────────────────
echo ""
echo "[13b/14] Rebuilding initramfs..."
if [[ "${SKIP_INITRAMFS:-0}" == "1" ]]; then
    echo "  ✓ Skipping initramfs rebuild (will be done at end of Install All)."
elif $NEED_INITRAMFS_REBUILD; then
    case "$DISTRO" in
        fedora)
            if command -v dracut >/dev/null 2>&1; then
                sudo dracut --force 2>/dev/null && echo "  ✓ initramfs rebuilt" ||                     echo "  ⚠ initramfs rebuild failed — reboot may not apply all changes"
            fi
            ;;
        ubuntu|debian)
            if command -v update-initramfs >/dev/null 2>&1; then
                sudo update-initramfs -u -k "$(uname -r)" 2>/dev/null &&                     echo "  ✓ initramfs rebuilt" ||                     echo "  ⚠ initramfs rebuild failed — reboot may not apply all changes"
            fi
            ;;
        arch)
            if command -v mkinitcpio >/dev/null 2>&1; then
                sudo mkinitcpio -P 2>/dev/null && echo "  ✓ initramfs rebuilt" ||                     echo "  ⚠ initramfs rebuild failed — reboot may not apply all changes"
            fi
            ;;
    esac
else
    echo "  ✓ No initramfs rebuild needed"
fi

# ──────────────────────────────────────────────
# [14/14] Restart PipeWire and verify
# ──────────────────────────────────────────────
echo ""
echo "[14/14] Restarting PipeWire and verifying camera..."

# Restart PipeWire so it picks up the libcamera SPA plugin
_pw_user=$(loginctl list-sessions --no-legend 2>/dev/null \
    | awk '$4 == "seat0" {print $3}' | head -1)
_pw_uid=$(id -u "$_pw_user" 2>/dev/null)
if [[ -n "$_pw_user" ]]; then
    sudo -u "$_pw_user" \
        XDG_RUNTIME_DIR="/run/user/${_pw_uid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_pw_uid}/bus" \
        systemctl --user restart pipewire wireplumber 2>/dev/null || true
fi
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
# Prefer /usr/local/bin/cam only if it actually runs (not broken by stale libs)
if [[ -x /usr/local/bin/cam ]] && /usr/local/bin/cam --list &>/dev/null; then
    CAM_CMD="/usr/local/bin/cam"
elif command -v cam >/dev/null 2>&1; then
    CAM_CMD="cam"
fi

CAPTURE_OK=false
if [[ -n "$CAM_CMD" ]]; then
    CAM_OUTPUT=$(sudo "$CAM_CMD" --list 2>&1 || true)
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
echo ""
echo "  Browser setup:"
echo "    Firefox:  Works out of the box (no flags needed)"
echo "    Chrome:   Works out of the box with the V4L2 camera relay"
echo "    Troubleshooting: If your browser doesn't see the camera, try enabling"
echo "      chrome://flags/#enable-webrtc-pipewire-camera — but note this flag"
echo "      can break camera access in some Chromium-based browsers."
echo ""
echo "  Cheese fix (if needed):"
echo "    Cheese crashes with this camera. A standalone fix is available:"
echo "    cd ../camera-relay && ./cheese-fix.sh"
echo ""
echo "  *** IMPORTANT: A full system reboot is required! ***"
echo ""
echo "  The installer added your user to the 'kvm' group for /dev/udmabuf"
echo "  access. This only takes effect after a FULL REBOOT — logging out"
echo "  and back in is NOT sufficient because PipeWire, WirePlumber, and"
echo "  the camera relay all need to start fresh with the new group."
echo ""
echo "  Please reboot now:  sudo reboot"
echo "=============================================="
