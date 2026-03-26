#!/bin/bash
# install.sh — Samsung Galaxy Book 5 Webcam Fix
# For Samsung Galaxy Book 5 series (Lunar Lake / IPU7)
# With OV02C10 or OV02E10 sensor on Arch, Fedora, and Ubuntu
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
# For full documentation, see: README_Galaxybook5_Fixes.md
#
# Usage: ./install.sh [--force]

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo: sudo bash install.sh" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────────
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
step()  { echo -e "\n\033[0;34m══ $* \033[0m"; }

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

VISION_DRIVER_VER="1.0.0"
VISION_DRIVER_REPO="https://github.com/intel/vision-drivers"
VISION_DRIVER_BRANCH="main"
SRC_DIR="/usr/src/vision-driver-${VISION_DRIVER_VER}"

FORCE=false
[ "$1" = "--force" ] && FORCE=true

# Flag to track whether initramfs needs rebuilding at the end
NEED_INITRAMFS_REBUILD=false

echo "=============================================="
echo "  Samsung Galaxy Book 5 Webcam Fix"
echo "  Arch / Fedora / Ubuntu — Lunar Lake (IPU7)"
echo "  For Samsung Galaxy Book 5 series only"
echo "=============================================="
echo ""

# ──────────────────────────────────────────────
# [1/15] Root check
# ──────────────────────────────────────────────

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
    if find_libcamera 2>/dev/null; then
        LIBCAMERA_VER="${LIBCAMERA_MAJOR}.${LIBCAMERA_MINOR}.${LIBCAMERA_PATCH}"
        echo "  ✓ Fedora detected with libcamera ${LIBCAMERA_VER}"
    else
        echo "  ✓ Fedora detected (libcamera version will be checked after package install)"
    fi
elif command -v apt >/dev/null 2>&1; then
    DISTRO="ubuntu"
    # Detect Ubuntu version to know if repo libcamera is new enough.
    # Ubuntu 26.04 (Resolute) ships libcamera 0.7.0 from repos — no source build needed.
    # Ubuntu 24.04/25.04 ship libcamera 0.2.0/0.4.0 which are too old for IPU7.
    UBUNTU_VER=$(. /etc/os-release && echo "${VERSION_ID:-0}")
    UBUNTU_MAJOR=$(echo "$UBUNTU_VER" | cut -d. -f1)

    if find_libcamera 2>/dev/null; then
        # libcamera already installed (either from repos on 26.04+ or source build)
        LIBCAMERA_VER="${LIBCAMERA_MAJOR}.${LIBCAMERA_MINOR}.${LIBCAMERA_PATCH}"
        echo "  ✓ Ubuntu detected with libcamera ${LIBCAMERA_VER}"
        # Check version is sufficient
        if [[ "$LIBCAMERA_MINOR" -lt 5 ]]; then
            echo "ERROR: libcamera ${LIBCAMERA_VER} is too old for IPU7. Need 0.5.2+."
            echo ""
            if [[ "$UBUNTU_MAJOR" -ge 26 ]]; then
                echo "       Run: sudo apt install libcamera libcamera-ipa gstreamer1.0-libcamera"
            else
                echo "       Ubuntu ${UBUNTU_VER} repos ship libcamera ${LIBCAMERA_VER}."
                echo "       You need libcamera 0.5.2+ built from source."
                echo ""
                echo "       Build instructions: https://libcamera.org/getting-started.html"
                echo "       Reference: https://wiki.archlinux.org/title/Dell_XPS_13_(9350)_2024#Camera"
            fi
            echo ""
            echo "       If you have a Galaxy Book3/4 (Meteor Lake / IPU6), use the webcam-fix-libcamera/"
            echo "       directory instead: cd ../webcam-fix-libcamera && ./install.sh"
            exit 1
        fi
        if [[ "$UBUNTU_MAJOR" -lt 26 ]]; then
            echo "  ⚠ Ubuntu support is experimental — libcamera was not installed from repos"
        fi
    elif [[ "$UBUNTU_MAJOR" -ge 26 ]]; then
        # Ubuntu 26.04+ — libcamera 0.7.0 available from repos, install it now
        echo "  Ubuntu ${UBUNTU_VER} detected — installing libcamera from repos..."
        if ! sudo apt install -y libcamera libcamera-ipa gstreamer1.0-libcamera \
                pipewire-libcamera libcamera-tools 2>/dev/null; then
            echo "ERROR: Failed to install libcamera from Ubuntu repos."
            echo "       Run: sudo apt install libcamera libcamera-ipa gstreamer1.0-libcamera"
            exit 1
        fi
        find_libcamera 2>/dev/null || true
        LIBCAMERA_VER="${LIBCAMERA_MAJOR}.${LIBCAMERA_MINOR}.${LIBCAMERA_PATCH}"
        echo "  ✓ Ubuntu ${UBUNTU_VER} detected with libcamera ${LIBCAMERA_VER} (from repos)"
    else
        # Ubuntu 24.04/25.04 — repos too old, need source build
        echo "ERROR: Ubuntu ${UBUNTU_VER} detected but libcamera is not installed."
        echo ""
        echo "       Ubuntu ${UBUNTU_VER} repos ship libcamera 0.2.x-0.4.x which does NOT support IPU7."
        echo "       You need libcamera 0.5.2+ built from source."
        echo ""
        echo "       Build instructions: https://libcamera.org/getting-started.html"
        echo "       Reference: https://wiki.archlinux.org/title/Dell_XPS_13_(9350)_2024#Camera"
        echo ""
        echo "       If you have a Galaxy Book3/4 (Meteor Lake / IPU6), use the webcam-fix-libcamera/"
        echo "       directory instead: cd ../webcam-fix-libcamera && ./install.sh"
        exit 1
    fi
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
        if ! sudo pacman -S --needed --noconfirm "${PKGS_NEEDED[@]}"; then
            echo "ERROR: Failed to install required packages: ${PKGS_NEEDED[*]}"
            echo "       Check your internet connection and package repositories."
            exit 1
        fi
        echo "  ✓ Packages installed"
    else
        echo "  ✓ All packages already installed"
    fi

    # Ensure DKMS prerequisites are available
    if ! command -v dkms >/dev/null 2>&1; then
        echo "  Installing DKMS prerequisites..."
        if ! sudo pacman -S --needed --noconfirm dkms linux-headers; then
            echo "ERROR: Failed to install DKMS prerequisites."
            exit 1
        fi
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
        if ! sudo dnf install -y "${PKGS_NEEDED[@]}"; then
            echo "ERROR: Failed to install required packages: ${PKGS_NEEDED[*]}"
            echo "       Check your internet connection and package repositories."
            exit 1
        fi
        echo "  ✓ Packages installed"
    else
        echo "  ✓ All packages already installed"
    fi

    # Ensure DKMS prerequisites are available
    if ! command -v dkms >/dev/null 2>&1; then
        echo "  Installing DKMS prerequisites..."
        if ! sudo dnf install -y dkms kernel-devel; then
            echo "ERROR: Failed to install DKMS prerequisites."
            exit 1
        fi
    fi

elif [[ "$DISTRO" == "ubuntu" ]]; then
    # On Ubuntu 26.04+, libcamera was installed from repos in step 2.
    # On Ubuntu 24.04/25.04, libcamera was built from source — do NOT install
    # from apt as it would conflict with the source build.
    if [[ "${UBUNTU_MAJOR:-0}" -ge 26 ]]; then
        echo "  ✓ libcamera already installed from repos (step 2)"
    else
        echo "  ✓ libcamera already installed (from source)"
    fi

    if ! command -v dkms >/dev/null 2>&1; then
        echo "  Installing DKMS prerequisites..."
        if ! sudo apt install -y dkms linux-headers-$(uname -r); then
            echo "ERROR: Failed to install DKMS prerequisites."
            exit 1
        fi
    fi

    # Install VA-API for hardware-accelerated format conversion in camera relay
    if ! gst-inspect-1.0 vapostproc &>/dev/null 2>&1; then
        echo "  Installing GStreamer VA-API plugin (hardware video conversion)..."
        sudo apt install -y gstreamer1.0-vaapi 2>/dev/null || \
            echo "  ⚠ gstreamer1.0-vaapi not available — relay will use software conversion"
    else
        echo "  ✓ GStreamer VA-API plugin already installed"
    fi

    # Check for pipewire-libcamera SPA plugin
    if ! find /usr/lib /usr/local/lib -path "*/spa-*/libcamera*" -name "*.so" 2>/dev/null | grep -q .; then
        echo "  ⚠ pipewire-libcamera SPA plugin not found."
        echo "    PipeWire apps (Firefox, Zoom, etc.) may not see the camera."
        if [[ "${UBUNTU_MAJOR:-0}" -ge 26 ]]; then
            echo "    Run: sudo apt install pipewire-libcamera"
        else
            echo "    You may need to build the PipeWire libcamera plugin from source,"
            echo "    or use cam/qcam for direct libcamera access."
        fi
    else
        echo "  ✓ PipeWire libcamera plugin found"
    fi
fi

# Ensure iasl (acpica-tools) is available — required for ACPI SSDT rotation fix
if ! command -v iasl >/dev/null 2>&1; then
    echo "  Installing acpica-tools (required for ACPI SSDT rotation fix)..."
    if [[ "$DISTRO" == "fedora" ]]; then
        if ! sudo dnf install -y acpica-tools; then
            echo "ERROR: Failed to install acpica-tools."
            echo "       Run: sudo dnf install acpica-tools"
            exit 1
        fi
    elif [[ "$DISTRO" == "arch" ]]; then
        if ! sudo pacman -S --needed --noconfirm acpica; then
            echo "ERROR: Failed to install acpica."
            echo "       Run: sudo pacman -S acpica"
            exit 1
        fi
    elif [[ "$DISTRO" == "ubuntu" ]]; then
        if ! sudo apt install -y acpica-tools; then
            echo "ERROR: Failed to install acpica-tools."
            echo "       Run: sudo apt install acpica-tools"
            exit 1
        fi
    fi
    echo "  ✓ iasl installed"
else
    echo "  ✓ iasl already available"
fi

# ──────────────────────────────────────────────
# [6/15] Build intel-vision-drivers via DKMS
# ──────────────────────────────────────────────
echo ""
echo "[6/15] Installing intel_cvs module via DKMS..."

# Check if already installed and working — via DKMS or system package (e.g. RPM Fusion)
if dkms status "vision-driver/${VISION_DRIVER_VER}" 2>/dev/null | grep -q "installed"; then
    echo "  ✓ vision-driver/${VISION_DRIVER_VER} already installed via DKMS"
elif modinfo intel_cvs &>/dev/null; then
    echo "  ✓ intel_cvs module available via system package — skipping DKMS build"
else
    # Download tarball (no git dependency)
    VISION_TMPDIR=$(mktemp -d)
    TARBALL="${VISION_TMPDIR}/vision-drivers.tar.gz"
    echo "  Downloading intel/vision-drivers from GitHub..."
    if ! curl -sL "${VISION_DRIVER_REPO}/archive/refs/heads/${VISION_DRIVER_BRANCH}.tar.gz" -o "$TARBALL"; then
        echo "ERROR: Failed to download vision-drivers from GitHub."
        echo "       Check your internet connection and try again."
        rm -rf "$VISION_TMPDIR"
        exit 1
    fi

    # Extract
    tar xzf "$TARBALL" -C "$VISION_TMPDIR"
    EXTRACTED_DIR=$(ls -d "${VISION_TMPDIR}"/vision-drivers-* 2>/dev/null | head -1)
    if [[ -z "$EXTRACTED_DIR" ]] || [[ ! -d "$EXTRACTED_DIR" ]]; then
        echo "ERROR: Failed to extract vision-drivers tarball."
        rm -rf "$VISION_TMPDIR"
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
    if ! sudo dkms build "vision-driver/${VISION_DRIVER_VER}"; then
        echo "ERROR: Failed to build vision-driver DKMS module."
        echo "       Check that kernel headers are installed:"
        if [[ "$DISTRO" == "fedora" ]]; then
            echo "       sudo dnf install kernel-devel-$(uname -r)"
        elif [[ "$DISTRO" == "arch" ]]; then
            echo "       sudo pacman -S linux-headers"
        else
            echo "       sudo apt install linux-headers-$(uname -r)"
        fi
        rm -rf "$VISION_TMPDIR"
        exit 1
    fi
    if ! sudo dkms install "vision-driver/${VISION_DRIVER_VER}"; then
        echo "ERROR: Failed to install vision-driver DKMS module."
        rm -rf "$VISION_TMPDIR"
        exit 1
    fi

    rm -rf "$VISION_TMPDIR"
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
# [7/15] Samsung camera rotation fix (ACPI SSDT override)
# ──────────────────────────────────────────────
echo ""
echo "[7/15] Installing camera rotation fix..."

# Samsung Galaxy Book5 models have their OV02E10 sensor mounted upside-down,
# but Samsung's BIOS reports rotation=0 in the ACPI SSDB.
# We fix this by patching the ACPI SSDT3 table to set degree=1
# (IPU_SENSOR_ROTATION_INVERTED) directly in the firmware, so ipu-bridge reads
# the correct rotation natively without needing a kernel module patch.
#
# Confirmed upside-down:  940XHA, 960XHA (community + hardware verified)
# Likely upside-down:     960QHA (image flip reported by Book5 360 users)
# Untested:               750XHD, 754XHD, 750QHA, 754QHA (assumed upside-down
#                         based on Samsung using same physical design across
#                         the Book5 range — please report results)

NEEDS_ROTATION_FIX=false
ROTATION_FIX_CONFIRMED=false   # confirmed upside-down
ROTATION_FIX_LIKELY=false      # reported upside-down, not hardware-verified
ROTATION_FIX_UNTESTED=false    # assumed upside-down, no reports yet
DMI_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
DMI_PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
# Strip NP prefix if present (some BIOS versions report "NP940XHA", others "940XHA")
DMI_PRODUCT="${DMI_PRODUCT#NP}"
if [[ "$DMI_VENDOR" == "SAMSUNG ELECTRONICS CO., LTD." ]]; then
    case "$DMI_PRODUCT" in
        940XHA|960XHA)
            NEEDS_ROTATION_FIX=true
            ROTATION_FIX_CONFIRMED=true
            ;;
        960QHA)
            NEEDS_ROTATION_FIX=true
            ROTATION_FIX_LIKELY=true
            echo "  ⚠ ${DMI_PRODUCT}: image flip reported by Book5 360 users — applying rotation fix."
            echo "    Please report whether the fix works for you."
            ;;
        750XHD|754XHD|750QHA|754QHA)
            NEEDS_ROTATION_FIX=true
            ROTATION_FIX_UNTESTED=true
            echo "  ⚠ ${DMI_PRODUCT}: rotation fix is UNTESTED on this model."
            echo "    Applying it anyway — please report whether your camera is upside-down"
            echo "    before and after installing, and share results at:"
            echo "    https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes/issues"
            ;;
    esac
fi

# Check if native kernel ipu-bridge already has the Samsung rotation fix upstream
SSDT_ROTATION_AML="/etc/acpi_override/cam-rot.aml"
IPU_BRIDGE_FIX_VER="1.0"
IPU_BRIDGE_FIX_SRC="/usr/src/ipu-bridge-fix-${IPU_BRIDGE_FIX_VER}"

if $NEEDS_ROTATION_FIX; then
    # Check if upstream kernel already has the fix — if so, nothing needed
    NATIVE_IPU_BRIDGE=$(find "/lib/modules/$(uname -r)/kernel" -name "ipu-bridge*" 2>/dev/null | head -1)
    UPSTREAM_HAS_FIX=false
    if [[ -n "$NATIVE_IPU_BRIDGE" ]]; then
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
        echo "  ✓ Native kernel ipu-bridge already has Samsung rotation fix — skipping"
        NEEDS_ROTATION_FIX=false

    # Check if ACPI SSDT fix is already installed
    elif [[ -f "$SSDT_ROTATION_AML" ]]; then
        echo "  ✓ ACPI SSDT camera rotation fix already installed — skipping"
        NEEDS_ROTATION_FIX=false

    # Check if ipu-bridge DKMS fix is already installed
    elif dkms status "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}" 2>/dev/null | grep -q "installed"; then
        echo "  ✓ ipu-bridge-fix/${IPU_BRIDGE_FIX_VER} already installed via DKMS — skipping"
        NEEDS_ROTATION_FIX=false
    fi
fi

if $NEEDS_ROTATION_FIX; then
    # ── Attempt ACPI SSDT patch first (preferred — no kernel module needed) ──
    # Falls back to ipu-bridge DKMS if:
    #   • Secure Boot / kernel lockdown is active (ACPI overrides blocked)
    #   • iasl is unavailable
    #   • SSDT read, decompile, patch, or compile fails at any step
    SSDT_PATCH_OK=false

    # ── Secure Boot / lockdown check ─────────────────────────────────────────
    # Kernel lockdown (integrity/confidentiality) blocks ACPI table overrides
    # from the initramfs.  When active we skip straight to the ipu-bridge DKMS
    # fallback — no need to try (and fail) the ACPI path.
    SB_LOCKED=false
    if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
        SB_LOCKED=true
    fi
    if [[ -f /sys/kernel/security/lockdown ]]; then
        grep -q "\[integrity\]\|\[confidentiality\]" /sys/kernel/security/lockdown && SB_LOCKED=true
    fi

    if $SB_LOCKED; then
        echo "  ⚠ Secure Boot / kernel lockdown is active — ACPI SSDT override is blocked."
        echo "    Falling back to ipu-bridge DKMS rotation fix."
    elif command -v iasl >/dev/null 2>&1; then
        echo "  Attempting ACPI SSDT rotation fix (preferred method)..."
        SSDT_WORK_DIR=$(mktemp -d)

        # Extract live SSDT3
        if ! sudo cat /sys/firmware/acpi/tables/SSDT3 > "$SSDT_WORK_DIR/ssdt3.aml" 2>/dev/null; then
            echo "  ⚠ Could not read /sys/firmware/acpi/tables/SSDT3 — falling back to ipu-bridge fix."
            rm -rf "$SSDT_WORK_DIR"
        elif ! iasl -d "$SSDT_WORK_DIR/ssdt3.aml" 2>/dev/null || \
             [[ ! -f "$SSDT_WORK_DIR/ssdt3.dsl" ]]; then
            echo "  ⚠ SSDT3 decompile failed — falling back to ipu-bridge fix."
            rm -rf "$SSDT_WORK_DIR"
        else
            # Find the correct line — search for PAR [0x54] = CDEG (L0DG)
            # in the LNK device whose _HID returns OVTI02E1 or OVTI02C1
            # We verify by checking the sensor maps to a known LNK in the ACPI device tree
            if [[ "$SENSOR" == "ov02c10" ]]; then
                SENSOR_PATH=$(cat /sys/bus/acpi/devices/OVTI02C1:00/path 2>/dev/null || true)
            else
                SENSOR_PATH=$(cat /sys/bus/acpi/devices/OVTI02E1:00/path 2>/dev/null || true)
            fi
            LNK_NUM=""
            if [[ "$SENSOR_PATH" == *"LNK0"* ]]; then
                LNK_NUM="0"
            elif [[ "$SENSOR_PATH" == *"LNK1"* ]]; then
                LNK_NUM="1"
            elif [[ "$SENSOR_PATH" == *"LNK2"* ]]; then
                LNK_NUM="2"
            fi

            if [[ -z "$LNK_NUM" ]]; then
                echo "  ⚠ Could not determine LNK device for ${SENSOR^^} sensor."
                echo "    Check that intel_cvs and sensor modules are loaded:"
                echo "    sudo modprobe usb_ljca gpio_ljca intel_cvs"
                echo "    Falling back to ipu-bridge fix."
                rm -rf "$SSDT_WORK_DIR"
            else
                # Find the PAR [0x54] = CDEG (L${LNK_NUM}DG) line
                PATCH_LINE=$(grep -n "PAR \[0x54\] = CDEG (L${LNK_NUM}DG)" \
                    "$SSDT_WORK_DIR/ssdt3.dsl" | head -1 | cut -d: -f1)

                if [[ -z "$PATCH_LINE" ]]; then
                    echo "  ⚠ Could not find rotation field in SSDT3."
                    echo "    PAR [0x54] = CDEG (L${LNK_NUM}DG) not found — BIOS may have changed structure."
                    echo "    Falling back to ipu-bridge fix."
                    rm -rf "$SSDT_WORK_DIR"
                else
                    echo "  Found rotation field at line ${PATCH_LINE} (LNK${LNK_NUM}, sensor path: ${SENSOR_PATH})"

                    # Apply patch to new file
                    sed "${PATCH_LINE}s/PAR \[0x54\] = CDEG (L${LNK_NUM}DG)/PAR [0x54] = 0x01/" \
                        "$SSDT_WORK_DIR/ssdt3.dsl" > "$SSDT_WORK_DIR/ssdt3_patched.dsl"

                    # Bump OEM revision
                    CURRENT_REV=$(grep "DefinitionBlock" "$SSDT_WORK_DIR/ssdt3_patched.dsl" \
                        | grep -oP '0x[0-9A-Fa-f]+\)' | tr -d ')')
                    if [[ -n "$CURRENT_REV" ]]; then
                        NEW_REV=$(printf "0x%08X" $(( CURRENT_REV + 1 )))
                        sed -i "s/${CURRENT_REV})/${NEW_REV})/" \
                            "$SSDT_WORK_DIR/ssdt3_patched.dsl"
                    fi

                    # Compile
                    if ! iasl -tc "$SSDT_WORK_DIR/ssdt3_patched.dsl" 2>/dev/null || \
                       [[ ! -f "$SSDT_WORK_DIR/ssdt3_patched.aml" ]]; then
                        echo "  ⚠ SSDT recompilation failed — falling back to ipu-bridge fix."
                        rm -rf "$SSDT_WORK_DIR"
                    else
                        # Verify patch is correct before deploying
                        iasl -d "$SSDT_WORK_DIR/ssdt3_patched.aml" 2>/dev/null
                        if ! grep -q "PAR \[0x54\] = One" \
                                "$SSDT_WORK_DIR/ssdt3_patched.dsl" 2>/dev/null && \
                           ! grep -q "PAR \[0x54\] = 0x01" \
                                "$SSDT_WORK_DIR/ssdt3_patched.dsl" 2>/dev/null; then
                            echo "  ⚠ SSDT patch verification failed — compiled AML did not contain"
                            echo "    the expected rotation value. Falling back to ipu-bridge fix."
                            rm -rf "$SSDT_WORK_DIR"
                        else
                            # Deploy — use short filename (max 18 chars for CPIO)
                            sudo mkdir -p /etc/acpi_override
                            sudo cp "$SSDT_WORK_DIR/ssdt3_patched.aml" "$SSDT_ROTATION_AML"
                            echo "  ✓ ACPI SSDT rotation fix installed → ${SSDT_ROTATION_AML}"

                            # Configure initramfs to include the ACPI override
                            if [[ "$DISTRO" == "arch" ]]; then
                                # Arch uses mkinitcpio — install a custom hook if not already present
                                # (fan fix uses the same hook; skip if already installed)
                                if [[ ! -f /etc/initcpio/hooks/acpi_override ]]; then
                                    sudo tee /etc/initcpio/hooks/acpi_override > /dev/null << 'HOOKEOF'
run_hook() {
    # ACPI overrides are embedded at build time — nothing to do at runtime
    :
}
HOOKEOF
                                    echo "  ✓ Created /etc/initcpio/hooks/acpi_override"
                                fi
                                if [[ ! -f /etc/initcpio/install/acpi_override ]]; then
                                    sudo tee /etc/initcpio/install/acpi_override > /dev/null << 'INSTALLEOF'
#!/bin/bash
# Embeds ACPI override AML files from /etc/acpi_override/ into the initramfs.
# DSDT.aml is placed at the initramfs root (/DSDT.aml).
# All other *.aml files (SSDTs) are placed at /kernel/firmware/acpi/<name>.
build() {
    for _aml in /etc/acpi_override/*.aml; do
        [[ -f "$_aml" ]] || continue
        _name=$(basename "$_aml")
        if [[ "$_name" == "DSDT.aml" || "$_name" == "dsdt_fixed.aml" ]]; then
            add_file "$_aml" "/DSDT.aml"
        else
            add_file "$_aml" "/kernel/firmware/acpi/${_name}"
        fi
    done
}
help() {
    cat << HELPEOF
Embeds ACPI override AML files from /etc/acpi_override/ into the initramfs.
HELPEOF
}
INSTALLEOF
                                    echo "  ✓ Created /etc/initcpio/install/acpi_override"
                                else
                                    # install script already exists (written by fan fix) — update it
                                    # to the generic multi-file version so cam-rot.aml is also embedded
                                    sudo tee /etc/initcpio/install/acpi_override > /dev/null << 'INSTALLEOF'
#!/bin/bash
# Embeds ACPI override AML files from /etc/acpi_override/ into the initramfs.
# DSDT.aml is placed at the initramfs root (/DSDT.aml).
# All other *.aml files (SSDTs) are placed at /kernel/firmware/acpi/<name>.
build() {
    for _aml in /etc/acpi_override/*.aml; do
        [[ -f "$_aml" ]] || continue
        _name=$(basename "$_aml")
        if [[ "$_name" == "DSDT.aml" || "$_name" == "dsdt_fixed.aml" ]]; then
            add_file "$_aml" "/DSDT.aml"
        else
            add_file "$_aml" "/kernel/firmware/acpi/${_name}"
        fi
    done
}
help() {
    cat << HELPEOF
Embeds ACPI override AML files from /etc/acpi_override/ into the initramfs.
HELPEOF
}
INSTALLEOF
                                    echo "  ✓ Updated /etc/initcpio/install/acpi_override (fan fix present — install script upgraded to multi-file)"
                                fi
                                if [[ ! -f /etc/mkinitcpio.conf.d/acpi_override.conf ]]; then
                                    sudo mkdir -p /etc/mkinitcpio.conf.d
                                    sudo tee /etc/mkinitcpio.conf.d/acpi_override.conf > /dev/null << 'MKINITEOF'
# Samsung Galaxy Book ACPI overrides (fan fix / webcam rotation fix)
HOOKS+=(acpi_override)
MKINITEOF
                                    echo "  ✓ Created /etc/mkinitcpio.conf.d/acpi_override.conf"
                                else
                                    echo "  ✓ mkinitcpio ACPI hook already present (fan fix)"
                                fi
                            else
                                # Fedora / Ubuntu — dracut
                                if [[ ! -f /etc/dracut.conf.d/acpi.conf ]]; then
                                    sudo mkdir -p /etc/dracut.conf.d
                                    sudo tee /etc/dracut.conf.d/acpi.conf > /dev/null << 'DRACUTEOF'
# Samsung Galaxy Book ACPI overrides
acpi_override=yes
acpi_table_dir="/etc/acpi_override"
DRACUTEOF
                                    echo "  ✓ Created /etc/dracut.conf.d/acpi.conf"
                                else
                                    echo "  ✓ Dracut ACPI config already present (fan fix)"
                                fi
                            fi

                            NEED_INITRAMFS_REBUILD=true
                            SSDT_PATCH_OK=true
                            rm -rf "$SSDT_WORK_DIR"

                            # Install upstream monitor — auto-removes cam-rot.aml once
                            # the native kernel gains the Samsung rotation DMI entries
                            if [[ -f "$SCRIPT_DIR/cam-rot-check-upstream.sh" ]]; then
                                sudo cp "$SCRIPT_DIR/cam-rot-check-upstream.sh" \
                                    /usr/local/sbin/cam-rot-check-upstream.sh
                                sudo chmod 755 /usr/local/sbin/cam-rot-check-upstream.sh
                            fi
                            if [[ -f "$SCRIPT_DIR/cam-rot-check-upstream.service" ]]; then
                                sudo cp "$SCRIPT_DIR/cam-rot-check-upstream.service" \
                                    /etc/systemd/system/cam-rot-check-upstream.service
                                sudo systemctl daemon-reload
                                sudo systemctl enable cam-rot-check-upstream.service
                                echo "  ✓ cam-rot upstream-check service installed and enabled"
                            fi
                        fi  # end: patch verification
                    fi  # end: iasl compile
                fi  # end: PATCH_LINE found
            fi  # end: LNK_NUM found
        fi  # end: SSDT3 read / decompile
    else
        echo "  ⚠ iasl (acpica-tools) not available — falling back to ipu-bridge fix."
    fi  # end: Secure Boot check / iasl block

    # ── Fallback: ipu-bridge DKMS rotation fix ────────────────────────────────
    # Used when: Secure Boot/lockdown is on, iasl unavailable, or any ACPI step fails.
    if ! $SSDT_PATCH_OK; then
        echo "  Installing ipu-bridge DKMS rotation fix (fallback method)..."
        IPU_BRIDGE_SRC_DIR="$SCRIPT_DIR/ipu-bridge-fix"
        if [[ ! -d "$IPU_BRIDGE_SRC_DIR" ]]; then
            echo "ERROR: ipu-bridge-fix/ directory not found at ${IPU_BRIDGE_SRC_DIR}."
            echo "       Cannot apply any rotation fix. Please report this issue."
            exit 1
        fi

        # Remove previous version if present
        if dkms status "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}" 2>/dev/null | grep -q "ipu-bridge-fix"; then
            echo "  Removing existing ipu-bridge-fix DKMS module..."
            sudo dkms remove "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}" --all 2>/dev/null || true
        fi

        sudo rm -rf "$IPU_BRIDGE_FIX_SRC"
        sudo mkdir -p "$IPU_BRIDGE_FIX_SRC"
        sudo cp -a "$IPU_BRIDGE_SRC_DIR"/* "$IPU_BRIDGE_FIX_SRC/"

        sudo dkms add "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}" 2>/dev/null || true
        if ! sudo dkms build "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}"; then
            echo "ERROR: Failed to build ipu-bridge-fix DKMS module."
            echo "       Ensure kernel headers are installed and try again."
            exit 1
        fi
        if ! sudo dkms install "ipu-bridge-fix/${IPU_BRIDGE_FIX_VER}"; then
            echo "ERROR: Failed to install ipu-bridge-fix DKMS module."
            exit 1
        fi
        echo "  ✓ ipu-bridge-fix/${IPU_BRIDGE_FIX_VER} installed via DKMS"

        # Install the upstream-check service so the DKMS module auto-removes
        # itself once the Samsung rotation fix lands in the mainline kernel.
        if [[ -f "$SCRIPT_DIR/ipu-bridge-check-upstream.sh" ]]; then
            sudo cp "$SCRIPT_DIR/ipu-bridge-check-upstream.sh" \
                /usr/local/sbin/ipu-bridge-check-upstream.sh
            sudo chmod 755 /usr/local/sbin/ipu-bridge-check-upstream.sh
        fi
        if [[ -f "$SCRIPT_DIR/ipu-bridge-check-upstream.service" ]]; then
            sudo cp "$SCRIPT_DIR/ipu-bridge-check-upstream.service" \
                /etc/systemd/system/ipu-bridge-check-upstream.service
            sudo systemctl daemon-reload
            sudo systemctl enable ipu-bridge-check-upstream.service
            echo "  ✓ Upstream-check service installed and enabled"
        fi

        if $SB_LOCKED; then
            echo "  ℹ To switch to the preferred ACPI fix later: disable Secure Boot,"
            echo "    uninstall and reinstall the webcam fix."
        fi
    fi
fi  # end: if $NEEDS_ROTATION_FIX

if ! $NEEDS_ROTATION_FIX; then
    if [[ "$DMI_VENDOR" == "SAMSUNG ELECTRONICS CO., LTD." ]]; then
        echo "  ✓ ${DMI_PRODUCT} — rotation fix not needed or already installed"
    else
        echo "  ✓ Not a Samsung Galaxy Book5 — rotation fix not needed"
    fi
fi

# ──────────────────────────────────────────────
# [8/15] OV02E10 bayer order fix (patched libcamera)
# ──────────────────────────────────────────────
echo ""
echo "[8/15] Checking for OV02E10 bayer order fix..."

# Samsung Book5 models with the OV02E10 sensor mounted upside-down (rotation=180)
# get purple/magenta tint after any rotation fix is applied (ipu-bridge DKMS or
# ACPI SSDT override). This is because the bayer pattern shifts when the sensor
# is flipped, but the kernel driver doesn't update the media bus format code.
# A patched libcamera build corrects the bayer order in the Simple pipeline handler.
# The bayer fix is needed whenever a rotation fix is active — either via ipu-bridge
# DKMS (NEEDS_ROTATION_FIX=true) or via the ACPI SSDT override (cam-rot.aml).
SSDT_ROTATION_ACTIVE=false
[[ -f "${SSDT_ROTATION_AML:-/etc/acpi_override/cam-rot.aml}" ]] && SSDT_ROTATION_ACTIVE=true

if [[ "$SENSOR" == "ov02e10" ]] && { $NEEDS_ROTATION_FIX || $SSDT_ROTATION_ACTIVE; }; then
    BAYER_FIX_BACKUP="/var/lib/libcamera-bayer-fix-backup"
    if [[ -d "$BAYER_FIX_BACKUP" ]]; then
        echo "  ✓ Bayer fix already installed (backup exists at $BAYER_FIX_BACKUP)"
    else
        echo "  OV02E10 + rotation fix detected — building patched libcamera..."
        echo "  (This fixes purple/magenta tint caused by bayer pattern mismatch)"
        echo ""
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
        echo "  ✓ OV02E10 detected but no rotation fix active — bayer fix not required"
    else
        echo "  ✓ Not OV02E10 — bayer fix not needed"
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

# Use find_libcamera to locate IPA path — works across all distros and
# install locations without hardcoded paths.
# find_libcamera may have already been called in step 2; call again if
# LIBCAMERA_IPA_PATH is not yet set (e.g. after a package install in step 5).
if [[ -z "${LIBCAMERA_IPA_PATH:-}" ]]; then
    find_libcamera 2>/dev/null || true
fi
IPA_PATH="${LIBCAMERA_IPA_PATH:-}"
if [[ -z "$IPA_PATH" ]]; then
    echo "  ⚠ Could not locate libcamera IPA directory — LIBCAMERA_IPA_MODULE_PATH will not be set"
else
    echo "  ✓ IPA path: ${IPA_PATH}"
fi

# Detect SPA plugin path — search broadly across /usr and /opt.
# PipeWire's libcamera SPA plugin must be discoverable for PipeWire to
# expose the camera to apps (Firefox, Zoom, etc.).
SPA_PATH=""
SPA_PLUGIN=$(find /usr /opt -path "*/spa-*/libcamera/libspa-libcamera.so" 2>/dev/null | head -1)
if [[ -n "$SPA_PLUGIN" ]]; then
    # Extract the spa-0.2 directory (parent of libcamera/)
    SPA_PATH=$(dirname "$(dirname "$SPA_PLUGIN")")
    echo "  Found PipeWire libcamera SPA plugin at: ${SPA_PLUGIN}"
    echo "  Setting SPA_PLUGIN_DIR=${SPA_PATH}"
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
# Set INSTALL_CAMERA_RELAY=false to skip installation of the camera relay tool.
INSTALL_CAMERA_RELAY="${INSTALL_CAMERA_RELAY:-true}"

RELAY_DIR="$SCRIPT_DIR/../camera-relay"

if [[ "$INSTALL_CAMERA_RELAY" != "true" ]]; then
    echo "  ✓ Camera relay skipped (set INSTALL_CAMERA_RELAY=false to skip)"
elif [[ -d "$RELAY_DIR" ]]; then
    # Detect if camera relay is already installed
    CAMERA_RELAY_INSTALLED=false
    [[ -x /usr/local/bin/camera-relay ]] && CAMERA_RELAY_INSTALLED=true

    # Identify the active desktop user for systemctl --user operations
    _relay_user=$(loginctl list-sessions --no-legend 2>/dev/null         | awk '$4 == "seat0" {print $3}' | head -1)
    _relay_uid=$(id -u "$_relay_user" 2>/dev/null)

    # If already installed, stop the service before updating files
    if $CAMERA_RELAY_INSTALLED && [[ -n "$_relay_user" ]] && [[ -n "$_relay_uid" ]]; then
        if sudo -u "$_relay_user"             XDG_RUNTIME_DIR="/run/user/${_relay_uid}"             DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_relay_uid}/bus"             systemctl --user is-active camera-relay.service &>/dev/null; then
            echo "  Stopping camera-relay service for update..."
            sudo -u "$_relay_user"                 XDG_RUNTIME_DIR="/run/user/${_relay_uid}"                 DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_relay_uid}/bus"                 systemctl --user stop camera-relay.service 2>/dev/null || true
            RELAY_WAS_RUNNING=true
        else
            RELAY_WAS_RUNNING=false
        fi
    else
        RELAY_WAS_RUNNING=false
    fi

    # Install GStreamer libcamerasrc element if not present
    if ! gst-inspect-1.0 libcamerasrc &>/dev/null 2>&1; then
        echo "  Installing GStreamer libcamera plugin..."
        if [[ "$DISTRO" == "fedora" ]]; then
            sudo dnf install -y gstreamer1-plugins-bad-free-extras 2>/dev/null || \
            sudo dnf install -y gstreamer1-plugins-bad-free 2>/dev/null || true
        elif [[ "$DISTRO" == "arch" ]]; then
            sudo pacman -S --needed --noconfirm gst-plugins-bad 2>/dev/null || true
        elif [[ "$DISTRO" == "ubuntu" ]]; then
            sudo apt install -y gstreamer1.0-plugins-bad 2>/dev/null || true
        fi
    fi

    # Install GStreamer VA-API plugin for hardware-accelerated ABGR→YUY2 conversion.
    # vapostproc offloads format conversion to Intel VA-API, reducing relay CPU usage.
    # Falls back gracefully to software videoconvert if unavailable.
    if ! gst-inspect-1.0 vapostproc &>/dev/null 2>&1; then
        echo "  Installing GStreamer VA-API plugin (hardware video conversion)..."
        if [[ "$DISTRO" == "fedora" ]]; then
            sudo dnf install -y gstreamer1-vaapi 2>/dev/null || \
                echo "  ⚠ gstreamer1-vaapi not available — relay will use software conversion"
        elif [[ "$DISTRO" == "arch" ]]; then
            sudo pacman -S --needed --noconfirm gst-vaapi 2>/dev/null || \
                echo "  ⚠ gst-vaapi not available — relay will use software conversion"
        elif [[ "$DISTRO" == "ubuntu" ]]; then
            sudo apt install -y gstreamer1.0-vaapi 2>/dev/null || \
                echo "  ⚠ gstreamer1.0-vaapi not available — relay will use software conversion"
        fi
    else
        echo "  ✓ GStreamer VA-API plugin already installed"
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

    # Fedora: rebuild initramfs so dracut picks up the new v4l2loopback config.
    # Without this, v4l2loopback-akmods loads the module from initramfs with stale
    # defaults (e.g. "OBS Virtual Camera") before /etc/modprobe.d/ is read.
    # Only needed on a fresh install — update doesn't change the modprobe config.
    if ! $CAMERA_RELAY_INSTALLED; then
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

    # Enable persistent on-demand relay and restart if it was running before
    if [[ -n "$_relay_user" && -n "$_relay_uid" ]]; then
        if ! $CAMERA_RELAY_INSTALLED; then
            # Fresh install — enable persistent mode
            echo "  Enabling on-demand relay (auto-starts on login)..."
            sudo -u "$_relay_user"                 XDG_RUNTIME_DIR="/run/user/${_relay_uid}"                 DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_relay_uid}/bus"                 /usr/local/bin/camera-relay enable-persistent --yes 2>/dev/null &&                 echo "  ✓ On-demand relay enabled for ${_relay_user} (near-zero idle CPU)" ||                 echo "  ⚠ Could not enable persistent relay — run 'camera-relay enable-persistent' after reboot"
        else
            echo "  ✓ Camera relay updated"
            # Restart if it was running before the update
            if $RELAY_WAS_RUNNING; then
                echo "  Restarting camera-relay service..."
                sudo -u "$_relay_user"                     XDG_RUNTIME_DIR="/run/user/${_relay_uid}"                     DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_relay_uid}/bus"                     systemctl --user start camera-relay.service 2>/dev/null &&                     echo "  ✓ Camera relay restarted" ||                     echo "  ⚠ Could not restart camera relay — run 'camera-relay start' manually"
            fi
        fi
    else
        echo "  ⚠ Could not detect logged-in user — run 'camera-relay enable-persistent' after reboot"
    fi
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
# [14b/15] Rebuild initramfs (single pass — covers all changes)
# ──────────────────────────────────────────────
echo ""
echo "[14b/15] Rebuilding initramfs..."
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
echo "    - Vertically flipped image: Fixed on 940XHA/960XHA (confirmed). Applied to"
echo "      960QHA (reported) and 750XHD/754XHD/750QHA/754QHA (untested — please report)."
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
echo ""
echo "  To uninstall: ./uninstall.sh"
echo "=============================================="
