#!/bin/bash
# build-patched-libcamera.sh — Build and install patched libcamera with
# unconditional bayer order fix for OV02E10 purple tint.
#
# This script:
#   1. Detects the installed libcamera version
#   2. Installs build dependencies for your distro
#   3. Clones matching libcamera source from git
#   4. Applies the bayer order fix patch
#   5. Builds libcamera
#   6. Installs the patched library (with backup of originals)
#
# The fix makes the Simple pipeline handler ALWAYS recalculate the bayer
# pattern order when sensor transforms (hflip/vflip) are applied, instead
# of only doing so when the sensor reports a changed media bus format code.
# This fixes OV02E10 (and any sensor with the same MODIFY_LAYOUT bug).
#
# Usage: sudo ./build-patched-libcamera.sh
#
# To uninstall: sudo ./build-patched-libcamera.sh --uninstall

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/tmp/libcamera-bayer-fix-build"
BACKUP_DIR="/var/lib/libcamera-bayer-fix-backup"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
die()   { error "$*"; exit 1; }

# ─── Root check ───────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (sudo)."
fi

REAL_USER="${SUDO_USER:-$USER}"

# ─── Uninstall mode ──────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    echo ""
    echo "=============================================="
    echo "  Uninstall Patched libcamera"
    echo "=============================================="
    echo ""

    if [[ ! -d "$BACKUP_DIR" ]]; then
        die "No backup found at $BACKUP_DIR — nothing to restore."
    fi

    # Check if the system libcamera version has changed since backup
    # (e.g., distro upgrade). Restoring stale backup files over a newer
    # version would break ABI compatibility and potentially brick camera.
    BACKUP_VERSION=$(cat "$BACKUP_DIR/version" 2>/dev/null || echo "")
    CURRENT_VERSION=""
    if command -v pkg-config &>/dev/null; then
        CURRENT_VERSION=$(pkg-config --modversion libcamera 2>/dev/null || true)
    fi
    if [[ -z "$CURRENT_VERSION" ]] && command -v rpm &>/dev/null; then
        CURRENT_VERSION=$(rpm -q --qf '%{VERSION}' libcamera 2>/dev/null || true)
        [[ "$CURRENT_VERSION" == *"not installed"* ]] && CURRENT_VERSION=""
    fi
    if [[ -z "$CURRENT_VERSION" ]] && command -v pacman &>/dev/null; then
        CURRENT_VERSION=$(pacman -Q libcamera 2>/dev/null | awk '{print $2}' | grep -oP '^\d+\.\d+\.\d+' || true)
    fi
    if [[ -z "$CURRENT_VERSION" ]] && command -v dpkg &>/dev/null; then
        CURRENT_VERSION=$(dpkg -l 'libcamera*' 2>/dev/null | awk '/^ii.*libcamera0/ {print $3}' | head -1 | grep -oP '^\d+\.\d+\.\d+' || true)
    fi

    STALE_BACKUP=false
    if [[ -n "$BACKUP_VERSION" && -n "$CURRENT_VERSION" ]]; then
        # Extract just major.minor.patch for comparison
        BACKUP_VER_CLEAN=$(echo "$BACKUP_VERSION" | grep -oP '^\d+\.\d+\.\d+' || echo "$BACKUP_VERSION")
        CURRENT_VER_CLEAN=$(echo "$CURRENT_VERSION" | grep -oP '^\d+\.\d+\.\d+' || echo "$CURRENT_VERSION")
        if [[ "$BACKUP_VER_CLEAN" != "$CURRENT_VER_CLEAN" ]]; then
            STALE_BACKUP=true
        fi
    elif [[ -z "$BACKUP_VERSION" ]]; then
        # No version file — backup predates this check. Warn but proceed.
        warn "Backup has no version marker (created before v0.3.25)."
        warn "Cannot verify version match — proceeding with restore."
        warn "If this breaks, reinstall libcamera from your package manager."
    fi

    if $STALE_BACKUP; then
        warn "libcamera version changed since backup ($BACKUP_VER_CLEAN → $CURRENT_VER_CLEAN)"
        warn "Restoring stale backup would break the system — skipping restore."
        info "Removing stale backup and reinstalling from package manager..."
        rm -rf "$BACKUP_DIR"

        # Reinstall from distro package manager
        if command -v dnf &>/dev/null; then
            dnf reinstall -y 'libcamera*' 2>/dev/null || true
        elif command -v pacman &>/dev/null; then
            pacman -S --noconfirm libcamera libcamera-ipa 2>/dev/null || true
        elif command -v apt-get &>/dev/null; then
            apt-get install --reinstall -y 'libcamera*' 2>/dev/null || true
        fi

        ldconfig 2>/dev/null || true
        rm -f /etc/profile.d/libcamera-ipa-path.sh
        ok "Stale backup removed. libcamera reinstalled from package manager."
        echo ""
        exit 0
    fi

    info "Restoring original libcamera files (version: ${BACKUP_VERSION:-unknown})..."
    while IFS= read -r backup_file; do
        rel_path="${backup_file#$BACKUP_DIR}"
        # Skip the version marker file
        [[ "$backup_file" == "$BACKUP_DIR/version" ]] && continue
        if [[ -f "$backup_file" ]]; then
            cp -v "$backup_file" "$rel_path"
        fi
    done < <(find "$BACKUP_DIR" -type f)

    ldconfig 2>/dev/null || true
    rm -rf "$BACKUP_DIR"
    # Clean up IPA path env file
    rm -f /etc/profile.d/libcamera-ipa-path.sh
    ok "Original libcamera restored."
    echo ""
    exit 0
fi

# ─── Detect distro ───────────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint|pop)
                DISTRO="debian"
                DISTRO_NAME="$PRETTY_NAME"
                ;;
            fedora)
                DISTRO="fedora"
                DISTRO_NAME="$PRETTY_NAME"
                ;;
            arch|manjaro|endeavouros)
                DISTRO="arch"
                DISTRO_NAME="$PRETTY_NAME"
                ;;
            opensuse*|suse*)
                DISTRO="suse"
                DISTRO_NAME="$PRETTY_NAME"
                ;;
            *)
                DISTRO="unknown"
                DISTRO_NAME="$PRETTY_NAME"
                ;;
        esac
    else
        DISTRO="unknown"
        DISTRO_NAME="Unknown"
    fi
}

# ─── Detect installed libcamera version ──────────────────────────────
detect_libcamera_version() {
    LIBCAMERA_VERSION=""
    LIBCAMERA_GIT_TAG=""

    # Try pkg-config first
    if command -v pkg-config &>/dev/null; then
        LIBCAMERA_VERSION=$(pkg-config --modversion libcamera 2>/dev/null || true)
    fi

    # Try dpkg on Debian/Ubuntu
    if [[ -z "$LIBCAMERA_VERSION" ]] && command -v dpkg &>/dev/null; then
        LIBCAMERA_VERSION=$(dpkg -l 'libcamera*' 2>/dev/null | awk '/^ii.*libcamera0/ {print $3}' | head -1 || true)
    fi

    # Try rpm on Fedora
    if [[ -z "$LIBCAMERA_VERSION" ]] && command -v rpm &>/dev/null; then
        LIBCAMERA_VERSION=$(rpm -q --qf '%{VERSION}' libcamera 2>/dev/null || true)
        [[ "$LIBCAMERA_VERSION" == *"not installed"* ]] && LIBCAMERA_VERSION=""
    fi

    # Try pacman on Arch
    if [[ -z "$LIBCAMERA_VERSION" ]] && command -v pacman &>/dev/null; then
        LIBCAMERA_VERSION=$(pacman -Q libcamera 2>/dev/null | awk '{print $2}' || true)
    fi

    if [[ -z "$LIBCAMERA_VERSION" ]]; then
        die "Cannot detect installed libcamera version. Is libcamera installed?"
    fi

    # Extract version number (e.g., "0.6.0" from "0.6.0+53-f4f8b487-dirty" or "0.6.0-1.fc43")
    local ver_clean
    ver_clean=$(echo "$LIBCAMERA_VERSION" | grep -oP '^\d+\.\d+\.\d+' || true)

    if [[ -z "$ver_clean" ]]; then
        # Try alternate format (e.g., "0.6.0")
        ver_clean=$(echo "$LIBCAMERA_VERSION" | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
    fi

    if [[ -z "$ver_clean" ]]; then
        warn "Could not parse version from: $LIBCAMERA_VERSION"
        warn "Will try to build from latest source."
        LIBCAMERA_GIT_TAG="master"
        return
    fi

    LIBCAMERA_VERSION_CLEAN="$ver_clean"

    # Map to git tag
    LIBCAMERA_GIT_TAG="v${ver_clean}"
}

# ─── Install build dependencies ──────────────────────────────────────
install_deps_debian() {
    info "Installing build dependencies (Debian/Ubuntu)..."
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        git \
        meson \
        ninja-build \
        pkg-config \
        python3-yaml \
        python3-ply \
        python3-jinja2 \
        libgnutls28-dev \
        libudev-dev \
        libyaml-dev \
        libevent-dev \
        libgstreamer1.0-dev \
        libgstreamer-plugins-base1.0-dev \
        libdrm-dev \
        libjpeg-dev \
        libsdl2-dev \
        libtiff-dev \
        openssl \
        libssl-dev \
        libdw-dev \
        libunwind-dev \
        cmake
}

install_deps_fedora() {
    info "Installing build dependencies (Fedora)..."
    dnf install -y \
        git \
        meson \
        ninja-build \
        gcc \
        gcc-c++ \
        pkgconfig \
        python3-pyyaml \
        python3-ply \
        python3-jinja2 \
        gnutls-devel \
        systemd-devel \
        libyaml-devel \
        libevent-devel \
        gstreamer1-devel \
        gstreamer1-plugins-base-devel \
        libdrm-devel \
        libjpeg-turbo-devel \
        SDL2-devel \
        libtiff-devel \
        openssl-devel \
        elfutils-devel \
        libunwind-devel \
        cmake \
        rpm-build \
        dnf-plugins-core

    # Install build dependencies from the libcamera spec file
    info "Installing libcamera build dependencies from spec..."
    dnf builddep -y libcamera 2>&1 || warn "dnf builddep failed — may need manual deps"
}

install_deps_arch() {
    info "Installing build dependencies (Arch)..."
    pacman -S --noconfirm --needed \
        git \
        meson \
        ninja \
        pkgconf \
        python-yaml \
        python-ply \
        python-jinja \
        gnutls \
        systemd-libs \
        libyaml \
        libevent \
        gstreamer \
        gst-plugins-base \
        libdrm \
        libjpeg-turbo \
        sdl2 \
        libtiff \
        openssl \
        elfutils \
        libunwind \
        cmake
}

install_deps() {
    case "$DISTRO" in
        debian) install_deps_debian ;;
        fedora) install_deps_fedora ;;
        arch)   install_deps_arch ;;
        *)
            warn "Unknown distro '$DISTRO_NAME'. Skipping dependency installation."
            warn "You may need to install build dependencies manually."
            warn "Required: git meson ninja pkg-config python3-yaml python3-ply python3-jinja2"
            warn "          gnutls-dev libudev-dev libyaml-dev libevent-dev gstreamer-dev"
            ;;
    esac
}

# ─── Find libcamera .so files ────────────────────────────────────────
find_libcamera_libs() {
    LIBCAMERA_LIB_DIR=""

    # First, try to detect which libcamera is ACTUALLY loaded at runtime
    # (handles cases where /usr/local overrides /usr/lib)
    if command -v qcam &>/dev/null; then
        LIBCAMERA_LIB_DIR=$(ldd "$(which qcam)" 2>/dev/null | grep 'libcamera.so' | head -1 | sed 's|.*=> \(.*\)/libcamera.so.*|\1|' || true)
        if [[ -n "$LIBCAMERA_LIB_DIR" ]]; then
            info "Detected runtime library: $LIBCAMERA_LIB_DIR (from qcam)"
        fi
    fi

    # If runtime detection failed, check common locations
    # IMPORTANT: /usr/local FIRST — it takes priority in linker search order
    if [[ -z "$LIBCAMERA_LIB_DIR" ]]; then
        for dir in /usr/local/lib64 /usr/local/lib/x86_64-linux-gnu /usr/local/lib \
                   /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib; do
            if [[ -f "$dir/libcamera.so" ]] || ls "$dir"/libcamera.so.* &>/dev/null 2>&1; then
                LIBCAMERA_LIB_DIR="$dir"
                break
            fi
        done
    fi

    if [[ -z "$LIBCAMERA_LIB_DIR" ]]; then
        # Try ldconfig
        LIBCAMERA_LIB_DIR=$(ldconfig -p 2>/dev/null | grep 'libcamera.so ' | head -1 | sed 's|.*=> \(.*\)/libcamera.so.*|\1|' || true)
    fi

    if [[ -z "$LIBCAMERA_LIB_DIR" ]]; then
        die "Cannot find libcamera.so — is libcamera installed?"
    fi

    # Find IPA module directory (match the lib directory we found)
    LIBCAMERA_IPA_DIR=""
    # First try under the same prefix as the library
    local lib_prefix="${LIBCAMERA_LIB_DIR%%/lib*}"
    for dir in "${lib_prefix}/lib64/libcamera" \
               "${lib_prefix}/lib/x86_64-linux-gnu/libcamera" \
               "${lib_prefix}/lib/libcamera" \
               /usr/local/lib64/libcamera /usr/local/lib/x86_64-linux-gnu/libcamera \
               /usr/local/lib/libcamera /usr/lib64/libcamera \
               /usr/lib/x86_64-linux-gnu/libcamera /usr/lib/libcamera; do
        if [[ -d "$dir" ]]; then
            LIBCAMERA_IPA_DIR="$dir"
            break
        fi
    done
}

# ─── Apply patch using sed (more robust than patch files) ────────────
apply_patch_sed() {
    local simple_cpp="$BUILD_DIR/libcamera/src/libcamera/pipeline/simple/simple.cpp"

    if [[ ! -f "$simple_cpp" ]]; then
        die "Cannot find simple.cpp at expected path: $simple_cpp"
    fi

    info "Applying bayer order fix..."

    # NEW APPROACH: Don't touch videoFormat (V4L2 rejects format changes).
    # Instead, only override inputCfg.pixelFormat which goes directly to
    # the SoftISP debayer. The debayer gets its bayer pattern ENTIRELY from
    # inputCfg.pixelFormat — it never queries V4L2.
    #
    # The patch replaces the single line:
    #   inputCfg.pixelFormat = pipeConfig->captureFormat;     (v0.5)
    #   inputCfg.pixelFormat = videoFormat.toPixelFormat();   (v0.6+)
    # with code that computes the correct bayer order based on sensor transform.

    python3 - "$simple_cpp" << 'PYEOF'
import sys, re

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# The replacement code: compute corrected bayer order for SoftISP debayer
replacement_block = r'''{
\t\t/*
\t\t * Override the bayer order for the SoftISP debayer based on the
\t\t * actual sensor transform. Some sensors (e.g. OV02E10) set
\t\t * V4L2_CTRL_FLAG_MODIFY_LAYOUT on flip controls but never update
\t\t * the media bus format code. The V4L2 capture format stays as the
\t\t * native bayer order, but the physical pixel data has shifted.
\t\t * We leave the V4L2 format unchanged (driver rejects changes) and
\t\t * only tell the SoftISP debayer the correct pattern.
\t\t */
\t\tBayerFormat inputBayer = BayerFormat::fromPixelFormat(ORIGINAL_EXPR);
\t\tif (inputBayer.isValid()) {
\t\t\tinputBayer.order = data->sensor_->bayerOrder(config->combinedTransform());
\t\t\tinputCfg.pixelFormat = inputBayer.toPixelFormat();
\t\t} else {
\t\t\tinputCfg.pixelFormat = ORIGINAL_EXPR;
\t\t}
\t}'''

patched = False

# Try v0.6+ pattern first: inputCfg.pixelFormat = videoFormat.toPixelFormat();
v06_pattern = r'inputCfg\.pixelFormat\s*=\s*videoFormat\.toPixelFormat\(\)\s*;'
m = re.search(v06_pattern, content)
if m:
    # Get the indentation
    line_start = content.rfind('\n', 0, m.start()) + 1
    indent = re.match(r'^(\s*)', content[line_start:]).group(1)

    block = replacement_block.replace('ORIGINAL_EXPR', 'videoFormat.toPixelFormat()')
    # Fix indentation - use actual indent from source
    block = block.replace('\\t', '\t')
    lines = block.split('\n')
    indented = '\n'.join(indent + line.lstrip('{').rstrip('}') if i > 0 and i < len(lines)-1
                         else line for i, line in enumerate(lines))

    # Actually, let's just do a clean replacement
    new_code = (
        f'/*\n'
        f'{indent} * Override bayer order for SoftISP based on actual sensor transform.\n'
        f'{indent} * OV02E10 sets MODIFY_LAYOUT but never updates format code.\n'
        f'{indent} * bayerOrder() uses standard CFA XOR (HFlip=bit0, VFlip=bit1) but\n'
        f'{indent} * OV02E10 only shifts the bayer pattern for HFlip, not VFlip.\n'
        f'{indent} * We XOR the native order with just the HFlip component (bit 0).\n'
        f'{indent} * Set LIBCAMERA_BAYER_ORDER=0..3 to manually override (BGGR/GBRG/GRBG/RGGB).\n'
        f'{indent} */\n'
        f'{indent}BayerFormat inputBayer = BayerFormat::fromPixelFormat(videoFormat.toPixelFormat());\n'
        f'{indent}if (inputBayer.isValid()) {{\n'
        f'{indent}\tBayerFormat::Order origOrder = inputBayer.order;\n'
        f'{indent}\tconst char *bayerEnv = std::getenv("LIBCAMERA_BAYER_ORDER");\n'
        f'{indent}\tif (bayerEnv) {{\n'
        f'{indent}\t\tint bo = std::atoi(bayerEnv);\n'
        f'{indent}\t\tif (bo >= 0 && bo <= 3)\n'
        f'{indent}\t\t\tinputBayer.order = static_cast<BayerFormat::Order>(bo);\n'
        f'{indent}\t}} else {{\n'
        f'{indent}\t\t/* OV02E10: HFlip shifts bayer by 1 in X, VFlip does not\n'
        f'{indent}\t\t * shift (even readout window height). Only XOR with bit 0\n'
        f'{indent}\t\t * of the transform (HFlip component). */\n'
        f'{indent}\t\tint t = static_cast<int>(config->combinedTransform()) & 1;\n'
        f'{indent}\t\tinputBayer.order = static_cast<BayerFormat::Order>(\n'
        f'{indent}\t\t\tstatic_cast<int>(origOrder) ^ t);\n'
        f'{indent}\t}}\n'
        f'{indent}\tLOG(SimplePipeline, Warning)\n'
        f'{indent}\t\t<< "[BAYER-FIX] transform="\n'
        f'{indent}\t\t<< static_cast<int>(config->combinedTransform())\n'
        f'{indent}\t\t<< " origOrder=" << static_cast<int>(origOrder)\n'
        f'{indent}\t\t<< " newOrder=" << static_cast<int>(inputBayer.order)\n'
        f'{indent}\t\t<< " origFmt=" << videoFormat.toPixelFormat()\n'
        f'{indent}\t\t<< " newFmt=" << inputBayer.toPixelFormat()\n'
        f'{indent}\t\t<< " override=" << (bayerEnv ? bayerEnv : "auto");\n'
        f'{indent}\tinputCfg.pixelFormat = inputBayer.toPixelFormat();\n'
        f'{indent}}} else {{\n'
        f'{indent}\tinputCfg.pixelFormat = videoFormat.toPixelFormat();\n'
        f'{indent}}}'
    )

    result = content[:m.start()] + new_code + content[m.end():]
    patched = True
    print("Patched v0.6+ inputCfg.pixelFormat with bayer order override + diagnostics")

# Try v0.5 pattern: inputCfg.pixelFormat = pipeConfig->captureFormat;
if not patched:
    v05_pattern = r'inputCfg\.pixelFormat\s*=\s*pipeConfig->captureFormat\s*;'
    m = re.search(v05_pattern, content)
    if m:
        line_start = content.rfind('\n', 0, m.start()) + 1
        indent = re.match(r'^(\s*)', content[line_start:]).group(1)

        new_code = (
            f'/*\n'
            f'{indent} * Override bayer order for SoftISP based on actual sensor transform.\n'
            f'{indent} * OV02E10 sets MODIFY_LAYOUT but never updates format code.\n'
            f'{indent} * bayerOrder() uses standard CFA XOR (HFlip=bit0, VFlip=bit1) but\n'
            f'{indent} * OV02E10 only shifts the bayer pattern for HFlip, not VFlip.\n'
            f'{indent} * We XOR the native order with just the HFlip component (bit 0).\n'
            f'{indent} * Set LIBCAMERA_BAYER_ORDER=0..3 to manually override (BGGR/GBRG/GRBG/RGGB).\n'
            f'{indent} */\n'
            f'{indent}BayerFormat inputBayer = BayerFormat::fromPixelFormat(pipeConfig->captureFormat);\n'
            f'{indent}if (inputBayer.isValid()) {{\n'
            f'{indent}\tBayerFormat::Order origOrder = inputBayer.order;\n'
            f'{indent}\tconst char *bayerEnv = std::getenv("LIBCAMERA_BAYER_ORDER");\n'
            f'{indent}\tif (bayerEnv) {{\n'
            f'{indent}\t\tint bo = std::atoi(bayerEnv);\n'
            f'{indent}\t\tif (bo >= 0 && bo <= 3)\n'
            f'{indent}\t\t\tinputBayer.order = static_cast<BayerFormat::Order>(bo);\n'
            f'{indent}\t}} else {{\n'
            f'{indent}\t\t/* OV02E10: HFlip shifts bayer by 1 in X, VFlip does not\n'
            f'{indent}\t\t * shift (even readout window height). Only XOR with bit 0\n'
            f'{indent}\t\t * of the transform (HFlip component). */\n'
            f'{indent}\t\tint t = static_cast<int>(config->combinedTransform()) & 1;\n'
            f'{indent}\t\tinputBayer.order = static_cast<BayerFormat::Order>(\n'
            f'{indent}\t\t\tstatic_cast<int>(origOrder) ^ t);\n'
            f'{indent}\t}}\n'
            f'{indent}\tLOG(SimplePipeline, Warning)\n'
            f'{indent}\t\t<< "[BAYER-FIX] transform="\n'
            f'{indent}\t\t<< static_cast<int>(config->combinedTransform())\n'
            f'{indent}\t\t<< " origOrder=" << static_cast<int>(origOrder)\n'
            f'{indent}\t\t<< " newOrder=" << static_cast<int>(inputBayer.order)\n'
            f'{indent}\t\t<< " origFmt=" << pipeConfig->captureFormat\n'
            f'{indent}\t\t<< " newFmt=" << inputBayer.toPixelFormat()\n'
            f'{indent}\t\t<< " override=" << (bayerEnv ? bayerEnv : "auto");\n'
            f'{indent}\tinputCfg.pixelFormat = inputBayer.toPixelFormat();\n'
            f'{indent}}} else {{\n'
            f'{indent}\tinputCfg.pixelFormat = pipeConfig->captureFormat;\n'
            f'{indent}}}'
        )

        result = content[:m.start()] + new_code + content[m.end():]
        patched = True
        print("Patched v0.5 inputCfg.pixelFormat with bayer order override")

if not patched:
    # Check if already patched
    if 'inputBayer.order' in content and 'bayerOrder' in content:
        print("Source appears already patched (inputBayer.order + bayerOrder found)")
        result = content
    else:
        print("ERROR: Could not find inputCfg.pixelFormat assignment to patch", file=sys.stderr)
        print("Searched for both v0.5 and v0.6+ patterns.", file=sys.stderr)
        sys.exit(1)

# ── Second patch: Add diagnostic LOG at converter_/swIsp_ dispatch ──
# This tells us which code path actually receives the inputCfg.
# Pattern: "if (data->converter_) {"
dispatch_pattern = r'if\s*\(data->converter_\)\s*\{'
dm = re.search(dispatch_pattern, result)
if dm:
    line_start = result.rfind('\n', 0, dm.start()) + 1
    indent = re.match(r'^(\s*)', result[line_start:]).group(1)

    diag_log = (
        f'LOG(SimplePipeline, Warning)\n'
        f'{indent}\t<< "[BAYER-FIX] dispatch: converter_="\n'
        f'{indent}\t<< (data->converter_ ? "YES" : "no")\n'
        f'{indent}\t<< " swIsp_=" << (data->swIsp_ ? "YES" : "no")\n'
        f'{indent}\t<< " inputCfg.pixelFormat=" << inputCfg.pixelFormat;\n'
        f'{indent}'
    )
    result = result[:dm.start()] + diag_log + result[dm.start():]
    print("Added dispatch diagnostic LOG before converter_/swIsp_ branch")
else:
    print("WARNING: Could not find converter_ dispatch to add diagnostic", file=sys.stderr)

# ── Third patch: Add #include <cstdlib> for std::getenv ──
if '#include <cstdlib>' not in result:
    # Insert after the first #include line
    first_include = re.search(r'^#include\s+[<"].*[>"]', result, re.MULTILINE)
    if first_include:
        insert_pos = result.find('\n', first_include.start()) + 1
        result = result[:insert_pos] + '#include <cstdlib>\n' + result[insert_pos:]
        print("Added #include <cstdlib> for std::getenv/std::atoi")

with open(filepath, 'w') as f:
    f.write(result)
PYEOF

    if [[ $? -ne 0 ]]; then
        die "Failed to apply patch. The libcamera source may have an unexpected structure."
    fi

    ok "Patch applied successfully."
}

# ─── Detect meson build options from installed libcamera ─────────────
detect_build_options() {
    MESON_OPTIONS=(
        -Dgstreamer=enabled
        -Dv4l2=true
        -Dqcam=disabled
        -Dcam=disabled
        -Dlc-compliance=disabled
        -Dtest=false
        -Ddocumentation=disabled
    )

    # Match the prefix and libdir of the detected library location
    local prefix="${LIBCAMERA_LIB_DIR%%/lib*}"
    [[ -z "$prefix" ]] && prefix="/usr"

    if [[ "$LIBCAMERA_LIB_DIR" == */lib64* ]]; then
        MESON_OPTIONS+=(-Dprefix="$prefix" -Dlibdir=lib64)
    elif [[ "$LIBCAMERA_LIB_DIR" == */x86_64-linux-gnu* ]]; then
        MESON_OPTIONS+=(-Dprefix="$prefix" -Dlibdir=lib/x86_64-linux-gnu)
    else
        MESON_OPTIONS+=(-Dprefix="$prefix")
    fi

    info "Build prefix: $prefix (library target: $LIBCAMERA_LIB_DIR)"
}

# ─── Main ─────────────────────────────────────────────────────────────

echo ""
echo "=============================================="
echo "  libcamera Bayer Order Fix Builder"
echo "  (OV02E10 purple tint fix)"
echo "=============================================="
echo ""

# Step 1: Detect environment
info "Detecting environment..."
detect_distro
ok "Distro: $DISTRO_NAME ($DISTRO)"

detect_libcamera_version
ok "libcamera version: $LIBCAMERA_VERSION (tag: $LIBCAMERA_GIT_TAG)"

find_libcamera_libs
ok "Library dir: $LIBCAMERA_LIB_DIR"
[[ -n "${LIBCAMERA_IPA_DIR:-}" ]] && ok "IPA dir: $LIBCAMERA_IPA_DIR"

echo ""

# Step 2: Install build dependencies
info "Installing build dependencies..."
install_deps
ok "Build dependencies installed."
echo ""

# Step 3: Get source
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

USE_SRPM=false

# On Fedora, use SRPM to get distro-patched source (vanilla source may
# lack distro-specific patches for camera/pipeline support)
if [[ "$DISTRO" == "fedora" ]]; then
    info "Fedora detected — downloading source RPM for distro-patched source..."

    SRPM_DIR="$BUILD_DIR/srpmbuild"
    mkdir -p "$SRPM_DIR"

    # Download the source RPM
    if dnf download --source libcamera --destdir "$SRPM_DIR" 2>&1; then
        SRPM_FILE=$(ls "$SRPM_DIR"/*.src.rpm 2>/dev/null | head -1)
        if [[ -n "$SRPM_FILE" ]]; then
            ok "Downloaded: $(basename "$SRPM_FILE")"

            # Extract SRPM
            RPM_BUILD="$BUILD_DIR/rpmbuild"
            mkdir -p "$RPM_BUILD"/{SOURCES,SPECS}
            rpm -i --define "_topdir $RPM_BUILD" "$SRPM_FILE" 2>&1

            # Find the spec file
            SPEC_FILE=$(ls "$RPM_BUILD/SPECS/"*.spec 2>/dev/null | head -1)
            if [[ -n "$SPEC_FILE" ]]; then
                # Prep the source (extract + apply distro patches)
                info "Preparing source with Fedora patches..."
                rpmbuild -bp --define "_topdir $RPM_BUILD" "$SPEC_FILE" 2>&1 | tail -10

                # Find the prepared source directory
                # Try multiple strategies — Fedora may name the dir differently
                PREPPED_SRC=""

                # Strategy 1: Look for meson.build with project('libcamera')
                while IFS= read -r meson_file; do
                    if grep -q "project.*libcamera" "$meson_file" 2>/dev/null; then
                        PREPPED_SRC="$(dirname "$meson_file")"
                        break
                    fi
                done < <(find "$RPM_BUILD/BUILD" -maxdepth 3 -name "meson.build" 2>/dev/null)

                # Strategy 2: Just grab the first directory in BUILD
                if [[ -z "$PREPPED_SRC" ]]; then
                    PREPPED_SRC=$(find "$RPM_BUILD/BUILD" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
                fi

                # Debug: show what's in BUILD
                if [[ -z "$PREPPED_SRC" || ! -d "$PREPPED_SRC" ]]; then
                    warn "Could not find prepared source. Contents of BUILD dir:"
                    ls -la "$RPM_BUILD/BUILD/" 2>/dev/null || true
                    find "$RPM_BUILD/BUILD" -maxdepth 2 -name "meson.build" 2>/dev/null || true
                    warn "Falling back to git clone."
                else
                    info "Found source at: $PREPPED_SRC"
                    mv "$PREPPED_SRC" "$BUILD_DIR/libcamera"
                    USE_SRPM=true
                    ok "Source prepared with Fedora patches."
                fi
            else
                warn "Could not find spec file. Falling back to git clone."
            fi
        else
            warn "No SRPM downloaded. Falling back to git clone."
        fi
    else
        warn "dnf download --source failed. Falling back to git clone."
    fi
fi

# Fall back to git clone (for non-Fedora or if SRPM approach failed)
if [[ "$USE_SRPM" != "true" ]]; then
    info "Cloning libcamera source (${LIBCAMERA_GIT_TAG})..."

    if ! git clone --depth 1 --branch "$LIBCAMERA_GIT_TAG" \
        https://git.libcamera.org/libcamera/libcamera.git \
        "$BUILD_DIR/libcamera" 2>&1; then

        warn "Could not clone tag $LIBCAMERA_GIT_TAG — trying master..."
        git clone --depth 1 \
            https://git.libcamera.org/libcamera/libcamera.git \
            "$BUILD_DIR/libcamera" 2>&1
        LIBCAMERA_GIT_TAG="master"

        # Re-detect version from source
        if [[ -f "$BUILD_DIR/libcamera/meson.build" ]]; then
            SRC_VER=$(grep "version :" "$BUILD_DIR/libcamera/meson.build" | head -1 | grep -oP "'[\d.]+'") || true
            [[ -n "$SRC_VER" ]] && info "Source version: $SRC_VER"
        fi
    fi

    ok "Source cloned."
fi
echo ""

# Step 4: Apply patch
apply_patch_sed
echo ""

# Step 4b: Add OV02E10 sensor helper (fixes greyish/washed-out colors)
# Without this, the software ISP uses generic auto-exposure defaults.
# The OV02E10 has the same linear analog gain model as OV02C10: gain = value/16.
info "Adding OV02E10 sensor helper..."
HELPER_FILE=""
for candidate in "$BUILD_DIR/libcamera/src/ipa/libipa/camera_sensor_helper.cpp" \
                 "$BUILD_DIR/libcamera/src/libcamera/sensor/camera_sensor_helper.cpp"; do
    if [[ -f "$candidate" ]]; then
        HELPER_FILE="$candidate"
        break
    fi
done
if [[ -n "$HELPER_FILE" ]] && ! grep -q "CameraSensorHelperOv02e10" "$HELPER_FILE"; then
    if grep -q "namespace ipa" "$HELPER_FILE"; then
        # v0.7.0+ format
        sed -i '/#endif.*__DOXYGEN__/i\
class CameraSensorHelperOv02e10 : public CameraSensorHelper\
{\
public:\
\tCameraSensorHelperOv02e10()\
\t{\
\t\tgain_ = AnalogueGainLinear{ 1, 0, 0, 16 };\
\t}\
};\
REGISTER_CAMERA_SENSOR_HELPER("ov02e10", CameraSensorHelperOv02e10)\
' "$HELPER_FILE"
    else
        # Pre-0.7.0 format
        cat >> "$HELPER_FILE" << 'HELPER_EOF'

class CameraSensorHelperOv02e10 : public CameraSensorHelper
{
public:
	CameraSensorHelperOv02e10()
	{
		gainType_ = AnalogueGainLinear;
		gainConstants_.linear = { 1, 0, 0, 16 };
	}
};
REGISTER_CAMERA_SENSOR_HELPER("ov02e10", CameraSensorHelperOv02e10)
HELPER_EOF
    fi
    ok "OV02E10 sensor helper added (auto-exposure + gain control)"
elif [[ -n "$HELPER_FILE" ]]; then
    ok "OV02E10 sensor helper already present"
else
    warn "Could not find camera_sensor_helper.cpp — sensor helper not added"
    warn "Auto-exposure may produce washed-out colors"
fi
echo ""

# Step 5: Verify patch
info "Verifying patch..."
if grep -q 'inputBayer.order' "$BUILD_DIR/libcamera/src/libcamera/pipeline/simple/simple.cpp"; then
    ok "Patch verified — bayer order override for SoftISP debayer present."
else
    die "Patch verification failed — inputBayer.order not found in patched source."
fi
echo ""

# Step 6: Configure and build
info "Configuring build with meson..."
detect_build_options

cd "$BUILD_DIR/libcamera"
meson setup builddir "${MESON_OPTIONS[@]}" 2>&1 | tail -20

info "Building (this may take 5-10 minutes)..."
ninja -C builddir 2>&1 | tail -5

ok "Build completed."
echo ""

# Step 7: Backup originals
info "Backing up original libcamera files..."
mkdir -p "$BACKUP_DIR/$LIBCAMERA_LIB_DIR"

for f in "$LIBCAMERA_LIB_DIR"/libcamera*.so*; do
    if [[ -f "$f" ]]; then
        cp -a "$f" "$BACKUP_DIR/$LIBCAMERA_LIB_DIR/"
    fi
done

# Backup IPA modules too
if [[ -n "${LIBCAMERA_IPA_DIR:-}" && -d "$LIBCAMERA_IPA_DIR" ]]; then
    mkdir -p "$BACKUP_DIR/$LIBCAMERA_IPA_DIR"
    cp -a "$LIBCAMERA_IPA_DIR"/* "$BACKUP_DIR/$LIBCAMERA_IPA_DIR/" 2>/dev/null || true
fi

# Backup libexec (IPA proxy workers) for full install
LIB_PREFIX="${LIBCAMERA_LIB_DIR%%/lib*}"
LIBCAMERA_LIBEXEC_DIR=""
for dir in "${LIB_PREFIX}/libexec/libcamera" /usr/local/libexec/libcamera /usr/libexec/libcamera; do
    if [[ -d "$dir" ]]; then
        LIBCAMERA_LIBEXEC_DIR="$dir"
        mkdir -p "$BACKUP_DIR/$dir"
        cp -a "$dir"/* "$BACKUP_DIR/$dir/" 2>/dev/null || true
        break
    fi
done

# Record the libcamera version so uninstall can detect stale backups
# (e.g., after a distro upgrade changes the system libcamera version)
echo "${LIBCAMERA_VERSION_CLEAN:-$LIBCAMERA_VERSION}" > "$BACKUP_DIR/version"

ok "Originals backed up to $BACKUP_DIR (version: ${LIBCAMERA_VERSION_CLEAN:-$LIBCAMERA_VERSION})"
echo ""

# Step 8: Install
cd "$BUILD_DIR/libcamera"

# Determine install strategy:
# - SRPM build: full install (distro source, matching signatures)
# - /usr/local prefix: full install (built from source, no distro packages to preserve)
# - Distro package paths (/usr/lib*): .so-only install (preserve distro IPA signatures)
USE_FULL_INSTALL=false
if [[ "$USE_SRPM" == "true" ]]; then
    USE_FULL_INSTALL=true
    info "Full install: built from distro source RPM."
elif [[ "$LIBCAMERA_LIB_DIR" == /usr/local/* ]]; then
    USE_FULL_INSTALL=true
    info "Full install: library is in /usr/local (built from source, not distro package)."
elif [[ "$DISTRO" == "arch" ]]; then
    # Arch: must use full install. The .so-only approach leaves build-tree
    # paths embedded in the library (IPA search path becomes //src/ipa)
    # because meson install is what rewrites the rpath. Arch's IPA signature
    # checking falls back to non-sandboxed mode when signatures don't match,
    # so this is safe.
    USE_FULL_INSTALL=true
    info "Full install: Arch Linux (so-only install breaks IPA path resolution)."
elif [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
    # Ubuntu/Debian: IPA modules must match the patched library's build hash.
    # The .so-only approach preserves distro IPA .sign files which were built
    # against the original library — causing signature mismatch and camera failure.
    USE_FULL_INSTALL=true
    info "Full install: Ubuntu/Debian (IPA modules must match patched library)."
fi

if [[ "$USE_FULL_INSTALL" == "true" ]]; then
    info "Installing patched libcamera (full install)..."
    ninja -C builddir install 2>&1 | tail -10
    ldconfig 2>/dev/null || true
    ok "Patched libcamera installed (full install)."
else
    # Distro package: ONLY replace .so files, NOT IPA modules.
    # IPA modules are signed at build time. Replacing them with our build's
    # modules would break IPA signature validation → "No camera detected".
    info "Installing patched libcamera (libraries only, preserving distro IPA modules)..."

    BUILD_LIB_DIR="builddir/src/libcamera"
    INSTALLED_COUNT=0

    for built_so in "$BUILD_LIB_DIR"/libcamera*.so*; do
        if [[ -f "$built_so" && ! -L "$built_so" ]]; then
            so_name=$(basename "$built_so")
            target="$LIBCAMERA_LIB_DIR/$so_name"
            if [[ -f "$target" ]]; then
                cp -a "$built_so" "$target"
                info "  Replaced: $target"
                INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
            fi
        fi
    done

    # Also copy symlinks
    for built_so in "$BUILD_LIB_DIR"/libcamera*.so*; do
        if [[ -L "$built_so" ]]; then
            so_name=$(basename "$built_so")
            target="$LIBCAMERA_LIB_DIR/$so_name"
            cp -a "$built_so" "$target" 2>/dev/null || true
        fi
    done

    # Also replace libcamera-base .so
    for built_so in "$BUILD_LIB_DIR"/../libcamera-base*.so* \
                    "$BUILD_LIB_DIR"/../../libcamera-base*.so* \
                    "builddir/src/libcamera/base"/libcamera-base*.so*; do
        if [[ -f "$built_so" ]] || [[ -L "$built_so" ]]; then
            so_name=$(basename "$built_so")
            target="$LIBCAMERA_LIB_DIR/$so_name"
            if [[ -f "$target" ]] || [[ -L "$target" ]]; then
                cp -a "$built_so" "$target"
                [[ ! -L "$built_so" ]] && info "  Replaced: $target"
            fi
        fi
    done

    if [[ $INSTALLED_COUNT -eq 0 ]]; then
        warn "No .so files were replaced. Falling back to full install..."
        ninja -C builddir install 2>&1 | tail -10
    fi

    ldconfig 2>/dev/null || true

    # Fix IPA module path: our built .so has compiled-in IPA paths that may
    # not match the distro's layout.
    if [[ -n "${LIBCAMERA_IPA_DIR:-}" && -d "$LIBCAMERA_IPA_DIR" ]]; then
        IPA_ENV_FILE="/etc/profile.d/libcamera-ipa-path.sh"
        echo "export LIBCAMERA_IPA_MODULE_PATH=$LIBCAMERA_IPA_DIR/ipa" > "$IPA_ENV_FILE"
        chmod 644 "$IPA_ENV_FILE"
        export LIBCAMERA_IPA_MODULE_PATH="$LIBCAMERA_IPA_DIR/ipa"
        ok "IPA module path configured: $LIBCAMERA_IPA_DIR/ipa"
        info "  Environment file: $IPA_ENV_FILE"
    fi

    ok "Patched libcamera installed ($INSTALLED_COUNT libraries replaced)."
    info "IPA modules were NOT replaced (preserving original signatures)."
fi
echo ""

# Step 9: Verify installation
info "Verifying installation..."
INSTALLED_LIB=$(find "$LIBCAMERA_LIB_DIR" -name 'libcamera.so.*' -newer "$BACKUP_DIR" -print -quit 2>/dev/null || true)
if [[ -n "$INSTALLED_LIB" ]]; then
    ok "Verified: $INSTALLED_LIB is newer than backup."
else
    warn "Could not verify installation timestamp. Library may need ldconfig."
fi

# Cleanup build directory
rm -rf "$BUILD_DIR"

echo ""
echo "=============================================="
echo "  Installation Complete!"
echo "=============================================="
echo ""
echo "  The patched libcamera has been installed."
echo "  Original files backed up to: $BACKUP_DIR"
echo ""
echo "  IMPORTANT: Restart PipeWire so apps pick up the new library:"
echo "    systemctl --user restart pipewire wireplumber"
echo ""
echo "  If camera apps (Firefox, Chrome) still don't detect the camera,"
echo "  a full reboot may be needed."
echo ""
echo "  To test: Open a camera app (Firefox, Chrome, qcam)"
echo "           Colors should now be correct (no purple tint)."
echo ""
echo "  To uninstall and restore original:"
echo "    sudo $0 --uninstall"
echo ""
echo "  NOTE: System updates may overwrite the patched library."
echo "  If purple tint returns after an update, re-run this script."
echo ""
