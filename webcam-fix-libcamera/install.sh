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

NEEDS_INITRAMFS=0  # set to 1 by any section that modifies initramfs-relevant state

# --force-libcamera-rebuild: build the patched libcamera into /usr/local even if
# the distro package looks "good enough". Needed when the packaged libcamera has
# the OV02C10 sensor-helper symbols compiled in but the factory registration is
# dead-code-eliminated at link time (observed on Arch/CachyOS) — in that case
# check_sensor_helper() greps the symbol, sees it, and wrongly skips the source
# build, leaving the software AGC with no working helper -> black frames.
FORCE_LIBCAMERA_REBUILD=false
# --skip-module-check: don't abort if the IVSC/IPU6 kernel modules can't be
# found by name. Some kernels build the IVSC bridge in (so there is no .ko) or
# ship it under a consolidated module name; the in-tree detection below already
# handles the common cases, but this flag is the escape hatch when it doesn't.
SKIP_MODULE_CHECK=false
NO_RESTART=false
for arg in "$@"; do
    case "$arg" in
        --force-libcamera-rebuild) FORCE_LIBCAMERA_REBUILD=true ;;
        --skip-module-check) SKIP_MODULE_CHECK=true ;;
        --no-restart) NO_RESTART=true ;;
        -h|--help)
            echo "Usage: $0 [--force-libcamera-rebuild] [--skip-module-check] [--no-restart]"
            echo "  --force-libcamera-rebuild  Always build the patched libcamera from source"
            echo "                             (use if your packaged libcamera's OV02C10 helper"
            echo "                             doesn't register at runtime, e.g. Arch/CachyOS)"
            echo "  --skip-module-check        Continue even if the IVSC/IPU6 kernel modules"
            echo "                             can't be found by name (built-in or renamed)"
            echo "  --no-restart               Never restart PipeWire. The camera will not be"
            echo "                             verified at the end; reboot and run"
            echo "                             'camera-relay doctor' instead"
            exit 0
            ;;
        *) echo "WARNING: unknown argument '$arg' (ignored)" ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBCAMERA_MIN_VER="0.7.0"
# Build 0.7.2, not 0.7.0. libcamera 0.7.0's SoftISP AGC has a bug that breaks
# auto-exposure: soft_simple.cpp computes `again10 = camHelper_->gain(1.0)`, but
# gain() takes an integer hardware code, so the float 1.0 truncates to 1 and
# again10 becomes ~0.0625x. The AGC "too bright" branch then always chooses to
# reduce gain (already at min) and never reduces exposure, so a bright scene stays
# blown out to pure white. Fixed upstream in v0.7.1 (commit 02277d4c). 0.7.2 keeps
# the same libcamera.so.0.7 soname, and being a higher patch than the 0.7.0 some
# distros ship, ldconfig prefers our build for direct-libcamera apps too — closing
# the long-standing gap where cam/Snapshot hit the distro lib. (issue #71)
LIBCAMERA_BUILD_VER="v0.7.2"
LIBCAMERA_BUILD_DIR="/tmp/libcamera-ipu6-build"

echo "=============================================="
echo "  Samsung Galaxy Book Webcam Fix (libcamera)"
echo "  Book3 / Book4 — IPU6 Open-Source Stack"
echo "=============================================="
echo ""

# ──────────────────────────────────────────────
# [1/14] Root check
# ──────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Don't run this as root. The script will use sudo where needed."
    exit 1
fi

# ──────────────────────────────────────────────
# [2/14] Distro detection
# ──────────────────────────────────────────────
# Identify the distro from os-release (ID first, then ID_LIKE) and only fall
# back to probing for a package manager when os-release gives no answer. The
# binary probe alone is not trustworthy: Fedora ships a real `pacman` package,
# so a Fedora host with it installed used to be detected as Arch and step
# [9/14] then tried to install Arch package names with pacman.
# Takes an optional os-release path (default /etc/os-release) so tests can
# feed it fixture files. Sets DISTRO and DISTRO_LABEL.
detect_distro() {
    local os_release="${1:-/etc/os-release}"
    local id="" id_like="" pretty_name="" key value

    if [[ -r "$os_release" ]]; then
        while IFS='=' read -r key value; do
            value="${value%\"}"; value="${value#\"}"
            value="${value%\'}"; value="${value#\'}"
            case "$key" in
                ID)          id="${value,,}" ;;
                ID_LIKE)     id_like="${value,,}" ;;
                PRETTY_NAME) pretty_name="$value" ;;
            esac
        done < "$os_release"
    fi

    case "$id" in
        arch)                 DISTRO="arch";   DISTRO_LABEL="Arch-based" ;;
        fedora)               DISTRO="fedora"; DISTRO_LABEL="Fedora/DNF-based" ;;
        ubuntu|pop|linuxmint) DISTRO="ubuntu"; DISTRO_LABEL="Ubuntu/Ubuntu-based" ;;
        debian)               DISTRO="debian"; DISTRO_LABEL="Debian-based" ;;
    esac

    # ID_LIKE is a space-separated ancestry list, e.g. EndeavourOS has
    # ID=endeavouros ID_LIKE=arch and Pop!_OS has ID_LIKE="ubuntu debian".
    # Ubuntu is checked before Debian so Ubuntu descendants keep apt PPAs.
    if [[ -z "$DISTRO" ]]; then
        case " $id_like " in
            *" arch "*)   DISTRO="arch";   DISTRO_LABEL="Arch-based (${pretty_name:-$id})" ;;
            *" fedora "*) DISTRO="fedora"; DISTRO_LABEL="Fedora/DNF-based (${pretty_name:-$id})" ;;
            *" ubuntu "*) DISTRO="ubuntu"; DISTRO_LABEL="Ubuntu-based (${pretty_name:-$id})" ;;
            *" debian "*) DISTRO="debian"; DISTRO_LABEL="Debian-based (${pretty_name:-$id})" ;;
        esac
    fi

    # Last resort for systems without a usable os-release: probe package
    # managers and accept the ambiguity that has on hybrid systems.
    if [[ -z "$DISTRO" ]]; then
        if command -v pacman >/dev/null 2>&1; then
            DISTRO="arch";   DISTRO_LABEL="Arch-based"
        elif command -v dnf >/dev/null 2>&1; then
            DISTRO="fedora"; DISTRO_LABEL="Fedora/DNF-based"
        elif command -v apt >/dev/null 2>&1; then
            DISTRO="debian"; DISTRO_LABEL="Debian-based"
        fi
    fi

    if [[ -z "$DISTRO" ]]; then
        echo "ERROR: Unsupported distro. This script supports Arch, Fedora, and Ubuntu/Debian (and derivatives)."
        exit 1
    fi
}

echo "[2/14] Detecting distro..."
DISTRO=""
DISTRO_LABEL=""
detect_distro
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

# A module counts as "available" if any of these are true:
#   - it's already loaded (or built in)            -> /sys/module/<name> exists
#   - it's compiled into the kernel                -> listed in modules.builtin
#   - it's installed as a loadable module          -> modinfo finds it
# modinfo handles compression (.ko.zst/.xz/.gz), module signing, dash vs.
# underscore spelling and non-standard install paths — all of which the old
# `find ... -name '*.ko*'` heuristic got wrong, producing false negatives on
# kernels that ship the IVSC bridge built-in (e.g. Fedora 44 / kernel 7.x).
# See https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/51
module_available() {
    local m="$1"
    local mu="${m//-/_}"
    [[ -d "/sys/module/$mu" ]] && return 0
    local builtin_list="/lib/modules/$(uname -r)/modules.builtin"
    if [[ -r "$builtin_list" ]] && grep -qE "/(${m}|${mu})\.ko\$" "$builtin_list"; then
        return 0
    fi
    if modinfo "$m" &>/dev/null || modinfo "$mu" &>/dev/null; then
        return 0
    fi
    return 1
}

MISSING_MODS=()
for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi intel-ipu6 intel-ipu6-isys ov02c10; do
    module_available "$mod" || MISSING_MODS+=("$mod")
done

if [[ ${#MISSING_MODS[@]} -gt 0 ]]; then
    echo "WARNING: These kernel modules couldn't be found for kernel $(uname -r):"
    echo "         ${MISSING_MODS[*]}"
    echo ""
    echo "  Most likely either your kernel package doesn't ship them, or this"
    echo "  kernel builds the IVSC bridge in / under a different module name."
    case "$DISTRO" in
        ubuntu|debian)
            echo "  Try: sudo apt install linux-modules-ipu6-generic-hwe-24.04   # (match your HWE variant)"
            ;;
        fedora)
            echo "  Try: sudo dnf install kernel-modules-extra kernel-modules"
            echo "  If dnf says 'nothing to do', the drivers are probably built in or"
            echo "  shipped under a different name. Confirm with:"
            echo "      find /lib/modules/\$(uname -r) -iname '*vsc*'"
            echo "      modinfo mei_vsc ivsc_csi ivsc_ace 2>&1 | head"
            echo "      grep -i vsc /lib/modules/\$(uname -r)/modules.builtin"
            ;;
        arch)
            echo "  These modules ship with the linux package. Try: sudo pacman -S linux linux-headers"
            ;;
    esac
    echo ""
    if [[ "$SKIP_MODULE_CHECK" == true ]]; then
        echo "  --skip-module-check given — continuing anyway."
    elif [[ -t 0 ]]; then
        read -rp "  Continue the install anyway? [y/N] " REPLY_MODS
        REPLY_MODS=${REPLY_MODS:-N}
        if [[ ! "$REPLY_MODS" =~ ^[Yy] ]]; then
            echo "  Aborting. Re-run with --skip-module-check to bypass this check."
            exit 1
        fi
    else
        echo "  Aborting (no interactive terminal). Re-run with --skip-module-check to bypass."
        exit 1
    fi
else
    echo "  ✓ All required kernel modules found"
fi

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
                GITHUB_RAW="https://raw.githubusercontent.com/Andycodeman/samsung-galaxy-book-linux-fixes/main/ov02c10-26mhz-fix"
                for fname in install.sh ov02c10.c Makefile dkms.conf; do
                    if ! curl -fsSL "$GITHUB_RAW/$fname" -o "$DKMS_TMP_DIR/$fname"; then
                        echo "  ERROR: Failed to download $fname"
                        echo "         Please clone the full repo and try again:"
                        echo "         git clone https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes.git"
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

                # Verify the fix worked.
                # The in-tree driver has already probed this boot, so dmesg
                # still shows the old 26 MHz rejection — that alone does NOT
                # mean failure. What actually matters is which ov02c10.ko
                # modprobe now resolves, and (under Secure Boot) whether the
                # patched module can even be loaded. Don't claim success on a
                # bare "dkms installed".
                sleep 2
                OV_PATH=$(modinfo ov02c10 2>/dev/null | awk '/^filename:/{print $2}')
                if echo "$OV_PATH" | grep -q "/updates/"; then
                    echo "  ✓ Patched ov02c10 in place ($OV_PATH)"
                    echo "    Reboot required — the stock driver is still bound this boot."
                else
                    echo "  ⚠ modprobe still resolves the stock ov02c10 ($OV_PATH)."
                    echo "    The 26 MHz fix will NOT take effect until this is resolved:"
                    if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
                        echo "      • Secure Boot is ENABLED — the unsigned/unenrolled module is"
                        echo "        rejected and the kernel falls back to the in-tree driver."
                        echo "        Complete MOK enrollment on the next boot (the DKMS"
                        echo "        installer queues it), then reboot and re-run this script."
                    fi
                    if ! dkms status ov02c10/1.0 2>/dev/null | grep -q "installed"; then
                        echo "      • DKMS build/install did not complete — see the output above"
                        echo "        and /var/lib/dkms/ov02c10/1.0/build/make.log"
                    fi
                    echo "      • Otherwise just reboot so /updates/ takes priority, then:"
                    echo "        dmesg | grep -i ov02c10 ; modinfo ov02c10 | grep filename"
                fi

                # Clean up temp download
                rm -rf /tmp/ov02c10-26mhz-fix
            else
                echo "  ⚠ Could not locate fix installer. Continuing without the fix."
                echo "    The camera will likely NOT work until this is resolved."
                echo "    See: https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/tree/main/ov02c10-26mhz-fix"
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
    mod_u="${mod//-/_}"
    if lsmod | grep -q "^${mod_u} " || [[ -d "/sys/module/$mod_u" ]]; then
        echo "  Already loaded: $mod"
    elif sudo modprobe "$mod" 2>/dev/null; then
        echo "  Loaded: $mod"
    else
        echo "  Note: '$mod' isn't loadable as a module (built into the kernel, or"
        echo "        not provided) — skipping. If the camera works after reboot this"
        echo "        is fine; if not, see issue #51."
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

# Detect initramfs tool. Prefer the distro we already detected over
# `command -v`, because some Arch-based distros (e.g. CachyOS) ship an
# `update-initramfs` compat wrapper that shells out to mkinitcpio — which
# would otherwise hijack the Debian branch and try to write to a
# /etc/initramfs-tools/ directory that doesn't exist on Arch. See
# https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/40
INITRAMFS_TOOL=""
case "$DISTRO" in
    arch)
        if command -v mkinitcpio &>/dev/null; then INITRAMFS_TOOL="mkinitcpio"
        elif command -v dracut &>/dev/null; then INITRAMFS_TOOL="dracut"
        fi
        ;;
    fedora)
        if command -v dracut &>/dev/null; then INITRAMFS_TOOL="dracut"
        elif command -v mkinitcpio &>/dev/null; then INITRAMFS_TOOL="mkinitcpio"
        fi
        ;;
    ubuntu|debian)
        if command -v update-initramfs &>/dev/null && [[ -d /etc/initramfs-tools ]]; then
            INITRAMFS_TOOL="update-initramfs"
        elif command -v dracut &>/dev/null; then INITRAMFS_TOOL="dracut"
        fi
        ;;
esac
# Fallback for unknown/unset distro: pick by what exists, but still guard
# the Debian branch on the config directory actually being present.
if [[ -z "$INITRAMFS_TOOL" ]]; then
    if command -v update-initramfs &>/dev/null && [[ -d /etc/initramfs-tools ]]; then
        INITRAMFS_TOOL="update-initramfs"
    elif command -v dracut &>/dev/null; then INITRAMFS_TOOL="dracut"
    elif command -v mkinitcpio &>/dev/null; then INITRAMFS_TOOL="mkinitcpio"
    fi
fi

if [[ "$INITRAMFS_TOOL" == "update-initramfs" ]]; then
    # Debian/Ubuntu: append modules to /etc/initramfs-tools/modules
    for mod in mei-vsc mei-vsc-hw ivsc-ace ivsc-csi; do
        if ! grep -qxF "$mod" /etc/initramfs-tools/modules 2>/dev/null; then
            echo "$mod" | sudo tee -a /etc/initramfs-tools/modules > /dev/null
            INITRAMFS_CHANGED=true
        fi
    done
    if $INITRAMFS_CHANGED; then
        echo "  ✓ IVSC modules added to initramfs config (will rebuild at end)"
        NEEDS_INITRAMFS=1
    else
        echo "  ✓ IVSC modules already in initramfs"
    fi
elif [[ "$INITRAMFS_TOOL" == "dracut" ]]; then
    # Fedora/RHEL/Arch-with-dracut: drop-in config
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
        echo "  ✓ IVSC modules added to initramfs config (will rebuild at end)"
        NEEDS_INITRAMFS=1
    else
        echo "  ✓ IVSC modules already in initramfs (dracut)"
    fi
elif [[ "$INITRAMFS_TOOL" == "mkinitcpio" ]]; then
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
        echo "  ✓ IVSC modules added to initramfs config (will rebuild at end)"
        NEEDS_INITRAMFS=1
    else
        echo "  ✓ IVSC modules already in initramfs (mkinitcpio)"
    fi
else
    echo "  ⚠ No supported initramfs tool found (update-initramfs, dracut, mkinitcpio)."
    echo "    Manually add these modules to your initramfs:"
    echo "    mei-vsc mei-vsc-hw ivsc-ace ivsc-csi"
fi

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
        940XFG|940XGK|960XFG|960XFH|960XGK|960XGL|960QFG|960QGK) NEEDS_ROTATION_FIX=true ;;
    esac
fi

IPU_BRIDGE_FIX_VER="1.4"
IPU_BRIDGE_FIX_SRC="/usr/src/ipu-bridge-fix-${IPU_BRIDGE_FIX_VER}"

if $NEEDS_ROTATION_FIX; then
    IPU_BRIDGE_DIR="$SCRIPT_DIR/../webcam-fix-book5/ipu-bridge-fix"

    if [[ ! -d "$IPU_BRIDGE_DIR" ]]; then
        # Try downloading from GitHub if not present locally
        echo "  ipu-bridge-fix not found locally, downloading..."
        IPU_BRIDGE_DIR="/tmp/ipu-bridge-fix"
        rm -rf "$IPU_BRIDGE_DIR"
        mkdir -p "$IPU_BRIDGE_DIR"
        GITHUB_RAW="https://raw.githubusercontent.com/Andycodeman/samsung-galaxy-book-linux-fixes/main/webcam-fix-book5/ipu-bridge-fix"
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
                # Remove any previously installed ipu-bridge-fix versions (all are superseded)
                if dkms status 2>/dev/null | grep -q '^ipu-bridge-fix'; then
                    while IFS= read -r _old_ver; do
                        sudo dkms remove "ipu-bridge-fix/${_old_ver}" --all 2>/dev/null || true
                    done < <(dkms status 2>/dev/null | awk -F'[/,: ]+' '/^ipu-bridge-fix/ {print $2}' | sort -u)
                fi
                sudo rm -rf /usr/src/ipu-bridge-fix-* 2>/dev/null || true

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
                # initramfs will be rebuilt once at the end of the script
                NEEDS_INITRAMFS=1
                echo "  ✓ initramfs update deferred until end of script"
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

    # Need >= 0.7 (0.5.x detects OV02C10 but fails to stream; 0.7.0 has
    # proper IPASoft sensor support, Ccm/Awb/Adjust algorithms, and handles
    # missing selection API gracefully)
    if [[ "$major" -gt 0 ]] || { [[ "$major" -eq 0 ]] && [[ "$minor" -ge 7 ]]; }; then
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
    # Install with the same meson that configured the build. /usr/bin/meson is a
    # thin wrapper that imports whichever mesonbuild module Python can see: for
    # the invoking user that may be a pip install under ~/.local, but sudo's
    # secure_path hides it and root falls back to the older distro mesonbuild.
    # The mismatch makes 'meson install' reject the install.dat setup just wrote
    # ("references functions or classes that don't exist"), so the whole build is
    # thrown away at the final step. Hand root the user's module path when the
    # two differ.
    MESON_USER_SITE=$(python3 -c 'import site; print(site.getusersitepackages())' 2>/dev/null || true)
    if [[ -n "$MESON_USER_SITE" && -d "$MESON_USER_SITE/mesonbuild" ]] && \
       [[ "$(meson --version 2>/dev/null)" != "$(sudo meson --version 2>/dev/null)" ]]; then
        echo "  Note: root's meson differs from yours — installing with PYTHONPATH=$MESON_USER_SITE"
        sudo env PYTHONPATH="${MESON_USER_SITE}${PYTHONPATH:+:$PYTHONPATH}" ninja -C build install
    else
        sudo ninja -C build install
    fi

    # Ensure the source-built libcamera is in the dynamic linker search path.
    # meson's libdir under /usr/local differs by distro: Ubuntu/Debian use
    # lib/<triplet>, Fedora uses lib64, Arch uses plain lib. List all of them
    # so 'cam', the gstreamer plugin and PipeWire load the build we just made
    # instead of the (possibly unpatched) distro libcamera. (issue #52)
    sudo tee /etc/ld.so.conf.d/libcamera-local.conf > /dev/null << 'EOF'
/usr/local/lib
/usr/local/lib64
/usr/local/lib/x86_64-linux-gnu
/usr/local/lib/aarch64-linux-gnu
EOF
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

# Check whether ANY installed libcamera (system OR /usr/local) carries the
# OV02C10 sensor helper. Without it, IPASoft can't translate the kernel's
# analogue-gain control to the right multiplier and exposure ends up dim
# (issue #45 — Kubuntu 26.04 ships libcamera 0.7.0-1ubuntu2 which lacks the
# helper, since upstream v0.7.0 only registers ov2685 and ov2740 for the OV
# family). If the helper is missing everywhere, force a source build to add it.
check_sensor_helper() {
    local lib
    for lib in $(find /usr/local/lib /usr/local/lib64 \
                      /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu \
                      /usr/lib64 /usr/lib \
                      -maxdepth 2 -name "libcamera.so.0.7*" -not -type l 2>/dev/null); do
        if strings "$lib" 2>/dev/null | grep -q "CameraSensorHelperOv02c10"; then
            return 0
        fi
    done
    # Also check the libipa shared object, since the helper compiles into
    # libipa rather than libcamera-base on some build configurations.
    for lib in $(find /usr/local/lib /usr/local/lib64 \
                      /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu \
                      /usr/lib64 /usr/lib \
                      -name "ipa_soft_simple*.so" -o -name "libcamera-ipa*.so" 2>/dev/null); do
        if strings "$lib" 2>/dev/null | grep -q "CameraSensorHelperOv02c10"; then
            return 0
        fi
    done
    return 1
}

# Same check, but ONLY against a /usr/local source build (the one *we* produce
# and know registers the helper at runtime). Distro packages are excluded.
check_sensor_helper_local() {
    local lib
    for lib in $(find /usr/local/lib /usr/local/lib64 \
                      /usr/local/lib/x86_64-linux-gnu /usr/local/lib/aarch64-linux-gnu \
                      -maxdepth 3 \( -name "libcamera.so.0.7*" -o -name "ipa_soft_simple*.so" \) \
                      -not -type l 2>/dev/null); do
        if strings "$lib" 2>/dev/null | grep -q "CameraSensorHelperOv02c10"; then
            return 0
        fi
    done
    return 1
}

if $FORCE_LIBCAMERA_REBUILD; then
    echo "  ⚠ --force-libcamera-rebuild: building patched libcamera from source regardless of packaged version"
    LIBCAMERA_OK=false
fi

if $LIBCAMERA_OK; then
    if ! check_sensor_helper 2>/dev/null; then
        echo "  ⚠ libcamera $LIBCAMERA_VER lacks OV02C10 sensor helper — source build needed for proper exposure"
        LIBCAMERA_OK=false
    fi
fi

# Arch/CachyOS caveat: their packaged libcamera (0.7.x) compiles the OV02C10
# CameraSensorHelper symbols into ipa_soft_simple.so, so check_sensor_helper()
# (which greps for the symbol) sees it and thinks all is well — but the
# static-initializer that *registers* the helper factory gets dead-code-
# eliminated at link time, so at runtime libcamera logs "Failed to create
# camera sensor helper for ov02c10" and the software AGC has no working gain
# model. That leaves the OV02C10 stuck at a useless exposure → black frames.
# (See issue #50.) So on Arch, only trust the helper if it lives in a /usr/local
# source build we produced; otherwise force the patched source build.
if [[ "$DISTRO" == "arch" ]] && $LIBCAMERA_OK && ! check_sensor_helper_local 2>/dev/null; then
    echo "  ⚠ Arch's packaged libcamera has the OV02C10 helper symbols but does not register them"
    echo "    at runtime — building the patched libcamera from source instead (issue #50)."
    LIBCAMERA_OK=false
fi

# Clean up stale /usr/local libcamera builds that would shadow the system
# package. This can happen if a user previously built libcamera from source
# (an older version, or an AI-assisted attempt) and later upgraded the system
# packages. The stale /usr/local files shadow the system libraries and the
# GStreamer plugin, causing "Algorithm 'Ccm' not found" or silent helper
# failures. We remove a /usr/local build if it's older than the minimum, OR if
# it's the *same* minor as the minimum but does NOT contain the OV02C10 helper
# (i.e. it's a vanilla source build, not the patched one we'd produce — keeping
# it would just shadow the system package for no benefit). A same-minor build
# that *does* carry the helper is our patched build and is left alone.
cleanup_stale_local_libcamera() {
    local stale_ver
    stale_ver=$(ls /usr/local/lib/x86_64-linux-gnu/libcamera.so.0.* \
                   /usr/local/lib/aarch64-linux-gnu/libcamera.so.0.* \
                   /usr/local/lib64/libcamera.so.0.* \
                   /usr/local/lib/libcamera.so.0.* 2>/dev/null \
              | grep -oP 'libcamera\.so\.0\.\K[0-9]+' | sort -n | tail -1)
    local min_minor
    min_minor=$(echo "$LIBCAMERA_MIN_VER" | cut -d. -f2)

    # Also check for orphaned binaries from a previous partial cleanup
    # (e.g. .so files already removed but /usr/local/bin/cam still exists)
    if [[ -z "$stale_ver" ]]; then
        for bin in cam qcam lc-compliance; do
            if [[ -x "/usr/local/bin/$bin" ]] && \
               ! "/usr/local/bin/$bin" --version &>/dev/null 2>&1; then
                sudo rm -f "/usr/local/bin/$bin"
                echo "  Removed orphaned /usr/local/bin/$bin (missing libraries)"
            fi
        done
        return
    fi

    if [[ "$stale_ver" -lt "$min_minor" ]] || \
       { [[ "$stale_ver" -eq "$min_minor" ]] && ! check_sensor_helper_local 2>/dev/null; }; then
        echo "  ⚠ Removing stale libcamera build (0.$stale_ver) from /usr/local..."
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

# camera-relay's pipeline IS gst-launch-1.0, and every libcamerasrc probe in this
# installer shells out to gst-inspect-1.0. On Debian/Ubuntu both live in
# gstreamer1.0-tools, which gstreamer1.0-libcamera does NOT depend on — so a
# desktop install can easily lack them. When they are missing every probe exits
# 127 and reads as "libcamerasrc is broken", which aborts the install below on a
# false premise and later makes the relay tell users to reinstall a libcamera
# plugin they already have (issue #65).
ensure_gst_tools() {
    if command -v gst-launch-1.0 &>/dev/null && command -v gst-inspect-1.0 &>/dev/null; then
        return 0
    fi
    echo "  Installing GStreamer command-line tools..."
    case "$DISTRO" in
        fedora) sudo dnf install -y gstreamer1 2>/dev/null || true ;;
        arch)   sudo pacman -S --needed --noconfirm gstreamer 2>/dev/null || true ;;
        ubuntu|debian) sudo apt-get install -y gstreamer1.0-tools 2>/dev/null || true ;;
    esac
    if ! command -v gst-launch-1.0 &>/dev/null || ! command -v gst-inspect-1.0 &>/dev/null; then
        echo ""
        echo "ERROR: gst-launch-1.0 / gst-inspect-1.0 are still not available."
        echo "       The camera relay is built on them and cannot run without them."
        echo "       Install manually and re-run:"
        echo "         Fedora:        sudo dnf install gstreamer1"
        echo "         Arch:          sudo pacman -S gstreamer"
        echo "         Ubuntu/Debian: sudo apt install gstreamer1.0-tools"
        exit 1
    fi
}

# Verify the libcamera setup is functional before continuing. Silent failures
# here are what created issue #45: a source build was installed to /usr/local
# but the gst plugin wouldn't load, so the relay was permanently broken.
verify_libcamerasrc() {
    if env -u LD_LIBRARY_PATH -u GST_PLUGIN_PATH -u LIBCAMERA_IPA_MODULE_PATH \
           gst-inspect-1.0 libcamerasrc &>/dev/null; then
        return 0
    fi
    if [[ -d /usr/local/lib/x86_64-linux-gnu/gstreamer-1.0 ]] && \
       GST_PLUGIN_PATH=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0 \
       LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu \
       gst-inspect-1.0 libcamerasrc &>/dev/null; then
        return 0
    fi
    return 1
}

case "$DISTRO" in
    fedora)
        if $LIBCAMERA_OK; then
            echo "  ✓ libcamera $LIBCAMERA_VER already installed (>= $LIBCAMERA_MIN_VER, with OV02C10 helper)"
            cleanup_stale_local_libcamera
        else
            # Fedora 41+ ships libcamera 0.4+ in repos
            echo "  Installing libcamera from Fedora repos..."
            sudo dnf install -y libcamera libcamera-gstreamer libcamera-ipa \
                pipewire-plugin-libcamera 2>/dev/null || true
            LIBCAMERA_VER=$(check_libcamera_version || true)
            if ! $FORCE_LIBCAMERA_REBUILD && check_libcamera_version >/dev/null 2>&1 && check_sensor_helper 2>/dev/null; then
                echo "  ✓ libcamera $LIBCAMERA_VER installed from repos with OV02C10 helper"
            else
                echo "  Building patched libcamera from source (repo version: ${LIBCAMERA_VER:-none})..."
                build_libcamera_from_source
            fi
        fi
        ;;
    arch)
        if $LIBCAMERA_OK; then
            echo "  ✓ libcamera $LIBCAMERA_VER already installed (>= $LIBCAMERA_MIN_VER, with OV02C10 helper)"
            cleanup_stale_local_libcamera
        else
            echo "  Installing libcamera from Arch repos (for deps; the OV02C10 helper comes from the source build below)..."
            sudo pacman -S --needed --noconfirm libcamera gst-plugin-libcamera libcamera-tools 2>/dev/null || true
            LIBCAMERA_VER=$(check_libcamera_version || true)
            # On Arch we don't trust the packaged libcamera's helper (symbol present
            # but factory registration dead-code-eliminated — see above / issue #50),
            # so unless a /usr/local source build with the helper already exists,
            # always build it from source.
            if ! $FORCE_LIBCAMERA_REBUILD && check_libcamera_version >/dev/null 2>&1 && check_sensor_helper_local 2>/dev/null; then
                echo "  ✓ libcamera $LIBCAMERA_VER with OV02C10 helper already present in /usr/local"
            else
                echo "  Building patched libcamera from source (Arch repo version: ${LIBCAMERA_VER:-none})..."
                build_libcamera_from_source
            fi
        fi
        ;;
    ubuntu|debian)
        if $LIBCAMERA_OK; then
            echo "  ✓ libcamera $LIBCAMERA_VER already installed (>= $LIBCAMERA_MIN_VER, with OV02C10 helper)"
            cleanup_stale_local_libcamera
        else
            if [[ -n "$LIBCAMERA_VER" ]]; then
                echo "  System libcamera ($LIBCAMERA_VER) lacks OV02C10 sensor helper (or version < $LIBCAMERA_MIN_VER)."
            else
                echo "  libcamera not found."
            fi
            echo ""
            echo "  Even Kubuntu 26.04's libcamera 0.7.0 ships without the OV02C10 helper,"
            echo "  which is required for proper exposure control on this sensor."
            echo "  libcamera $LIBCAMERA_BUILD_VER will be built from source and installed to /usr/local."
            echo "  This requires ~200MB of disk space and takes a few minutes."
            echo ""
            read -rp "  Proceed with source build? [Y/n] " REPLY
            REPLY=${REPLY:-Y}
            if [[ "$REPLY" =~ ^[Yy] ]]; then
                build_libcamera_from_source
            else
                echo "ERROR: libcamera with OV02C10 helper is required. Cannot continue."
                exit 1
            fi
        fi
        ;;
esac

# After installation (or skip), drop the GStreamer registry cache for the
# invoking user. If a previous run left a registry pointing at a now-stale
# plugin path, gst-inspect won't re-scan even though GST_PLUGIN_PATH points
# at a working .so — the original symptom of issue #45 in the systemd
# user service.
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/gstreamer-1.0" 2>/dev/null || true
if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "$USER" ]]; then
    sudo -u "$SUDO_USER" rm -rf "$(eval echo "~$SUDO_USER")/.cache/gstreamer-1.0" 2>/dev/null || true
fi

# Sanity check: after whichever path we took, libcamerasrc must actually load.
# This catches the issue #45 scenario where a source build silently produced an
# unloadable libgstlibcamera.so. Make sure gst-inspect-1.0 exists first, or the
# check below fails for the wrong reason (issue #65).
ensure_gst_tools
if ! verify_libcamerasrc; then
    echo ""
    echo "ERROR: GStreamer 'libcamerasrc' element is not loadable."
    echo "       libcamera was installed but the gst plugin failed to register."
    echo "       Diagnostics:"
    echo "         gst-inspect-1.0 --gst-debug=2 libcamerasrc 2>&1 | tail -20"
    if [[ -f /usr/local/lib/x86_64-linux-gnu/gstreamer-1.0/libgstlibcamera.so ]]; then
        echo "         ldd /usr/local/lib/x86_64-linux-gnu/gstreamer-1.0/libgstlibcamera.so"
        echo ""
        echo "       If a stale source build is shadowing the system package, remove"
        echo "       /usr/local/lib/x86_64-linux-gnu/{libcamera*.so*,gstreamer-1.0/libgstlibcamera.so}"
        echo "       and re-run this installer. See issue #45 for details."
    fi
    exit 1
fi

# Whoever put a libcamera under /usr/local, the linker has to prefer it — the
# source build above writes this file, but that branch is skipped when a good
# enough libcamera is already installed. uninstall.sh removes the file
# unconditionally, so an uninstall/reinstall cycle used to drop /usr/local out
# of the search path and leave the *system* libcamera winning.
#
# Nothing breaks at that moment, because the ldconfig cache still holds the old
# entries. It breaks at the next unrelated `ldconfig` — a package upgrade,
# another installer — and then camera-relay-gst, which deliberately does not
# propagate LD_LIBRARY_PATH, silently loads the unpatched build.
if compgen -G "/usr/local/lib*/libcamera.so.*" > /dev/null \
   || compgen -G "/usr/local/lib/*/libcamera.so.*" > /dev/null; then
    if [[ ! -f /etc/ld.so.conf.d/libcamera-local.conf ]]; then
        sudo tee /etc/ld.so.conf.d/libcamera-local.conf > /dev/null << 'EOF'
/usr/local/lib
/usr/local/lib64
/usr/local/lib/x86_64-linux-gnu
/usr/local/lib/aarch64-linux-gnu
EOF
        sudo ldconfig
        echo "  ✓ Restored /usr/local to the dynamic linker search path"
    fi
fi

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
    # 'pipewire --version' reports the version twice ("Compiled with libpipewire
    # X.Y.Z" and "Linked with libpipewire X.Y.Z"), so an unbounded grep yields
    # "1.0.5\n1.0.5". git rejects that as a branch name, the fallback clone below
    # then silently takes the default branch, and the SPA plugin gets built
    # against a completely different PipeWire ABI than the one running (master
    # 1.7.x vs a system 1.0.x). The result loads without complaint but delivers
    # zero frames, so PipeWire-native apps (GNOME Snapshot) show pure black while
    # the v4l2 relay path keeps working — a confusing split. Take the first match.
    PW_VER=$(pipewire --version 2>/dev/null | grep -oP 'libpipewire \K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    PW_VER=${PW_VER:-1.0.5}
    echo "  Rebuilding PipeWire SPA libcamera plugin (PipeWire $PW_VER)..."

    local SPA_BUILD_DIR="/tmp/pipewire-spa-build"
    rm -rf "$SPA_BUILD_DIR"
    if ! git clone --depth 1 --branch "$PW_VER" \
            https://gitlab.freedesktop.org/pipewire/pipewire.git "$SPA_BUILD_DIR" 2>/dev/null; then
        echo "  ⚠ No upstream PipeWire tag '$PW_VER' — falling back to the default branch."
        echo "    The plugin may then be built against a different PipeWire ABI than"
        echo "    yours; if PipeWire-native apps show black afterwards, start here."
        git clone --depth 1 \
            https://gitlab.freedesktop.org/pipewire/pipewire.git "$SPA_BUILD_DIR"
    fi

    cd "$SPA_BUILD_DIR"

    # libcamera 0.7 changed ControlList::get(properties::Model) to hand back a
    # std::optional<std::string_view>; PipeWire 1.0.x still returns it straight
    # into a std::string, so the plugin does not compile against our source-built
    # libcamera ("could not convert basic_string_view to std::string"). Convert
    # explicitly. This is a no-op on PipeWire versions that already handle it.
    if [[ -f spa/plugins/libcamera/libcamera-device.cpp ]]; then
        sed -i 's/return std::move(model\.value());/return std::string(model.value());/' \
            spa/plugins/libcamera/libcamera-device.cpp
    fi

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
        LOCAL_LIBCAMERA=$(ls /usr/local/lib/x86_64-linux-gnu/libcamera.so.0.* \
                             /usr/local/lib/x86_64-linux-gnu/libcamera.so 2>/dev/null | head -1)
        if [[ -n "$SPA_SO" ]]; then
            SPA_LIBCAMERA_VER=$(ldd "$SPA_SO" 2>/dev/null | grep -oP 'libcamera\.so\.\K[0-9]+\.[0-9]+' | head -1 || true)
            SPA_LIBCAMERA_MINOR=$(echo "$SPA_LIBCAMERA_VER" | cut -d. -f2)
            if [[ -n "$SPA_LIBCAMERA_MINOR" ]] && [[ "$SPA_LIBCAMERA_MINOR" -lt 7 ]] && \
               [[ -n "$LOCAL_LIBCAMERA" ]]; then
                echo "  SPA plugin links against libcamera $SPA_LIBCAMERA_VER (need >= 0.7)"
                # Non-fatal: step 12 disables the direct libcamera node anyway, so a
                # failure here costs nothing — apps reach the camera via the v4l2
                # relay. Aborting the whole install over it would be worse.
                rebuild_spa_plugin || \
                    echo "  ⚠ SPA plugin rebuild failed — continuing (the libcamera node is disabled; apps use the v4l2 relay)"
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

# Install OV02C10 tuning file for libcamera Simple ISP
for dir in /usr/local/share/libcamera/ipa/simple /usr/share/libcamera/ipa/simple; do
    if [[ -d "$(dirname "$dir")" ]]; then
        sudo mkdir -p "$dir"
        sudo cp "$SCRIPT_DIR/ov02c10.yaml" "$dir/ov02c10.yaml"
        echo "  ✓ Installed tuning file: $dir/ov02c10.yaml"
    fi
done

# Point apps at the source-built libcamera. meson's libdir under /usr/local is
# lib/<triplet> on Ubuntu/Debian, lib64 on Fedora and plain lib on Arch — detect
# whichever one actually received the IPA modules instead of hardcoding the
# Ubuntu path, otherwise the source build is ignored on Arch/Fedora and apps
# silently fall back to the (possibly unpatched) distro libcamera. (issue #52)
LOCAL_IPA_DIR=""
LOCAL_LIBDIR=""
for d in /usr/local/lib/x86_64-linux-gnu/libcamera /usr/local/lib/aarch64-linux-gnu/libcamera \
         /usr/local/lib64/libcamera /usr/local/lib/libcamera; do
    [[ -d "$d" ]] || continue
    # libcamera >= 0.7 installs the IPA modules into an 'ipa' subdirectory;
    # older builds drop them straight into <libdir>/libcamera. Check both — only
    # matching the flat layout leaves LOCAL_IPA_DIR empty on 0.7+, which silently
    # skips the whole block below and strands whatever stale
    # LIBCAMERA_IPA_MODULE_PATH a previous install wrote. (issue #71)
    for sub in "$d/ipa" "$d"; do
        if ls "$sub"/ipa_*.so >/dev/null 2>&1; then
            LOCAL_IPA_DIR="$sub"
            LOCAL_LIBDIR="$(dirname "$d")"
            break 2
        fi
    done
done
if [[ -n "$LOCAL_IPA_DIR" ]]; then
    LOCAL_GST_DIR="$LOCAL_LIBDIR/gstreamer-1.0"
    sudo mkdir -p /etc/environment.d
    {
        echo "# libcamera IPA module path for source-built libcamera"
        echo "export LIBCAMERA_IPA_MODULE_PATH=$LOCAL_IPA_DIR"
    } | sudo tee /etc/profile.d/libcamera-ipa.sh > /dev/null
    echo "LIBCAMERA_IPA_MODULE_PATH=$LOCAL_IPA_DIR" | \
        sudo tee /etc/environment.d/libcamera-ipa.conf > /dev/null
    # Set GST_PLUGIN_PATH so gst-launch/gst-inspect find libcamerasrc from any terminal
    if [[ -d "$LOCAL_GST_DIR" ]]; then
        echo "GST_PLUGIN_PATH=$LOCAL_GST_DIR" | \
            sudo tee -a /etc/environment.d/libcamera-ipa.conf > /dev/null
        {
            echo "# GStreamer plugin path for source-built libcamera"
            echo "export GST_PLUGIN_PATH=$LOCAL_GST_DIR"
        } | sudo tee /etc/profile.d/libcamera-gst.sh > /dev/null
        echo "  ✓ IPA module path ($LOCAL_IPA_DIR) and GStreamer plugin path configured"
    else
        echo "  ✓ IPA module path ($LOCAL_IPA_DIR) configured"
    fi
    export LIBCAMERA_IPA_MODULE_PATH="$LOCAL_IPA_DIR"
fi

# Ensure user is in video group. This is no longer what grants access to the
# raw camera nodes — those move to the memberless 'camera-relay' group in step
# 12, and both the loopback and /dev/media0 carry their own uaccess ACL. Kept
# because the group still covers other video devices and setups where uaccess
# does not apply (no logind seat).
CURRENT_USER="${SUDO_USER:-$USER}"
if ! groups "$CURRENT_USER" 2>/dev/null | grep -q '\bvideo\b'; then
    sudo usermod -aG video "$CURRENT_USER"
    echo "  ✓ Added $CURRENT_USER to video group (takes effect on next login)"
else
    echo "  ✓ User already in video group"
fi

# libcamera's software ISP allocates DMA-BUFs for frame buffers. If /dev/dma_heap
# is root-only (common — e.g. Arch/CachyOS ships /dev/dma_heap/system as 0600
# root:root) it falls back to /dev/udmabuf, which is typically group 'kvm'. Without
# that access libcamera uses memfd instead, and the GPU debayer's eglCreateImageKHR
# can't import a memfd → it fails → black frames (issue #50). Add the user to kvm.
if getent group kvm >/dev/null 2>&1; then
    if ! groups "$CURRENT_USER" 2>/dev/null | grep -q '\bkvm\b'; then
        sudo usermod -aG kvm "$CURRENT_USER"
        echo "  ✓ Added $CURRENT_USER to kvm group for /dev/udmabuf (takes effect after a full reboot)"
    else
        echo "  ✓ User already in kvm group"
    fi
fi

# On a hybrid laptop — Intel/AMD iGPU + NVIDIA dGPU, which is how the Galaxy
# Book4 Ultra ships, when the NVIDIA driver is actually bound to the dGPU (no
# driver bound means no render node, and the detection below correctly declines
# to pin) — GLVND loads the EGL vendor ICDs in /usr/share/glvnd/egl_vendor.d in
# filename order, and NVIDIA's ships as 10_nvidia.json, ahead of Mesa's
# 50_mesa.json. libcamera's Software ISP then runs its EGL debayer on NVIDIA's
# proprietary driver, which it is not compatible with:
#     ERROR eGL egl.cpp:134 glFrameBufferTexture2D error 36054
#     ERROR Debayer debayer_egl.cpp:639 debayerGPU failed
# The sensor still powers up (privacy LED on, relay says STREAMING) but not one
# frame reaches v4l2loopback, so apps show a black picture. Same failure the
# LIBCAMERA_SOFTISP_MODE=cpu block below was written for (#15, #50), but pinning
# the iGPU fixes it without giving up the framerate (#66).
#
# This only bites under systemd: a desktop session normally has EGL already
# resolved to Mesa, so running `cam` from a terminal works and the bug looks like
# it isn't there. camera-relay bakes the pin into its own service unit (see
# detect_egl_vendor_pin in ../camera-relay/camera-relay); detect the same thing
# here so the state is visible at install time.
#
# Deliberately NOT written to /etc/environment.d like LIBCAMERA_SOFTISP_MODE
# below: __EGL_VENDOR_LIBRARY_FILENAMES steers *every* GL client on the system,
# so setting it globally would take NVIDIA offload away from games and everything
# else. It belongs on the camera units only.
# Keep this block in sync with webcam-fix-book5/install.sh.
HYBRID_EGL_VENDOR=""
HYBRID_GPU=false
_nv_node=false
_mesa_node=false
_render_nodes=0
for _node in /dev/dri/renderD*; do
    [[ -e "$_node" ]] || continue
    _render_nodes=$((_render_nodes + 1))
    _drv=""
    _link=$(readlink -f "/sys/class/drm/$(basename "$_node")/device/driver" 2>/dev/null) || _link=""
    [[ -n "$_link" ]] && _drv=$(basename "$_link")
    case "$_drv" in
        nvidia|nvidia-drm) _nv_node=true ;;
        "")                ;;
        *)                 _mesa_node=true ;;
    esac
done
if $_nv_node && $_mesa_node && [[ "$_render_nodes" -ge 2 ]]; then
    HYBRID_GPU=true
    # Derive the vendor ICD from the iGPU that is actually present rather than
    # hardcoding 50_mesa.json: every non-NVIDIA render node here (i915, xe,
    # amdgpu, radeon) is driven by Mesa's EGL, so the file to pin is whichever
    # ICD dispatches to libEGL_mesa — whatever the distro numbered it.
    for _dir in /etc/glvnd/egl_vendor.d /usr/share/glvnd/egl_vendor.d; do
        [[ -d "$_dir" ]] || continue
        for _f in "$_dir"/*.json; do
            [[ -f "$_f" ]] || continue
            if grep -q 'libEGL_mesa' "$_f" 2>/dev/null; then
                HYBRID_EGL_VENDOR="$_f"
                break 2
            fi
        done
    done
fi
if [[ -n "$HYBRID_EGL_VENDOR" ]]; then
    echo "  ✓ Hybrid GPU (iGPU + NVIDIA) — camera-relay.service will pin EGL to"
    echo "    $HYBRID_EGL_VENDOR (keeps the GPU debayer off the NVIDIA driver)"
elif $HYBRID_GPU; then
    echo "  ⚠ Hybrid GPU detected but no Mesa EGL vendor file found in"
    echo "    /usr/share/glvnd/egl_vendor.d — if the camera LED lights but apps show"
    echo "    black, run 'camera-relay doctor' and check the GPU / EGL section"
fi
unset _node _link _drv _dir _f _nv_node _mesa_node _render_nodes

# If an NVIDIA GPU is present, libcamera's GPU (EGL) debayer is unreliable
# (debayer_egl.cpp is incompatible with NVIDIA's proprietary EGL driver, and on
# hybrid laptops EGL may pick the NVIDIA renderer even when the iGPU is active).
# camera-relay pins EGL to the iGPU and, failing that, forces CPU debayer on its
# own service unit — but the PipeWire-libcamera path (used by apps that pick that
# source directly) needs a fix too, and only the CPU one is safe to set globally,
# so set that here for all user services / sessions. (issue #50)
# Only force CPU debayer when NVIDIA is the *active EGL renderer* — merely having
# an NVIDIA card present is not enough. On a hybrid laptop rendering on the Intel
# iGPU, EGL never touches the NVIDIA driver, so GPU debayer works fine and forcing
# CPU costs a large chunk of framerate for nothing (issue #66). `prime-select` is
# Ubuntu-only, so it can't be the sole guard. This mirrors camera-relay's own
# detection — keep the two in sync.
NVIDIA_ACTIVE=""
if command -v glxinfo >/dev/null 2>&1; then
    # glxinfo is authoritative: it reports the renderer actually in use.
    if glxinfo 2>/dev/null | grep -qi "opengl renderer.*nvidia"; then
        NVIDIA_ACTIVE="yes"
    fi
elif [[ -d /proc/driver/nvidia ]] || lspci 2>/dev/null | grep -qi 'VGA.*NVIDIA\|3D controller.*NVIDIA'; then
    # No glxinfo — fall back to presence, unless prime-select puts Intel in charge.
    if ! { command -v prime-select >/dev/null 2>&1 && [[ "$(prime-select query 2>/dev/null)" == "intel" ]]; }; then
        NVIDIA_ACTIVE="maybe"
    fi
fi
if [[ -n "$NVIDIA_ACTIVE" ]]; then
    sudo mkdir -p /etc/environment.d
    echo "LIBCAMERA_SOFTISP_MODE=cpu" | \
        sudo tee /etc/environment.d/10-libcamera-softisp.conf > /dev/null
    echo "  ✓ NVIDIA is the active renderer — set LIBCAMERA_SOFTISP_MODE=cpu globally (CPU debayer)"
    [[ "$NVIDIA_ACTIVE" == "maybe" ]] && \
        echo "    (couldn't confirm via glxinfo — install mesa-utils/glx-utils if your camera framerate is low)"
else
    sudo rm -f /etc/environment.d/10-libcamera-softisp.conf
fi

# ──────────────────────────────────────────────
# [12/14] Hide raw IPU6 nodes from PipeWire
# ──────────────────────────────────────────────
echo ""
echo "[12/14] Hiding raw IPU6 nodes from applications..."

# The ISYS driver registers one capture node per possible stream — 48 on a
# Book4 — and the kernel flags each one V4L2_CAP_IO_MC: usable only once
# userspace has configured the media graph, never as a standalone camera.
# Nothing carries that bit into udev (systemd's v4l_id derives
# ID_V4L_CAPABILITIES from V4L2_CAP_VIDEO_CAPTURE alone and never looks at
# IO_MC), so all 48 advertise themselves as cameras.
#
# Applications split into two groups needing different answers:
#   - Chromium and friends enumerate through udev, so clearing the capability
#     properties is enough to drop them from those pickers.
#   - Firefox/libwebrtc walks /dev/video0..63 calling QUERYCAP, ignores udev
#     entirely, and only skips a node whose open() fails. Permissions are the
#     only lever that works there.
#
# Hence the dedicated group: the nodes move out of 'video' (which the desktop
# user is in, so it granted access no matter what happened to the uaccess tag)
# into a group with no members. The relay's pipeline gets it from the setgid
# launcher instead — see camera-relay-gst.c.
CAMERA_RELAY_SRC="$SCRIPT_DIR/../camera-relay"

sudo mkdir -p /usr/local/lib/sysusers.d
sudo tee /usr/local/lib/sysusers.d/camera-relay.conf > /dev/null << 'EOF'
# Owns the raw MC-centric camera nodes. Deliberately memberless: the relay
# pipeline acquires it through the setgid launcher, nothing else should hold it.
g camera-relay -
EOF
command -v systemd-sysusers >/dev/null 2>&1 && sudo systemd-sysusers >/dev/null 2>&1 || true
if ! getent group camera-relay >/dev/null 2>&1; then
    sudo groupadd -r camera-relay
fi
echo "  ✓ Group 'camera-relay' present (no members by design)"

# Writable state for the pipeline's own caches. The GStreamer registry maps
# elements to .so paths that get dlopen()ed, so it must not live anywhere the
# user can write — that would hand the group back through a poisoned cache.
sudo install -d -m 2770 -o root -g camera-relay /var/cache/camera-relay

MC_HELPER=/usr/local/lib/udev/camera-relay-v4l2-io-mc

# Ordering here is a safety property, not tidiness. The moment the rule below
# takes effect the raw nodes belong to 'camera-relay', and the only thing that
# can still open them is the setgid launcher — so the launcher has to exist
# first. Build both helpers up front and install the rule only if both are in
# place; if either fails, the nodes keep their old ownership and the camera
# keeps working with the spurious entries still listed. A degraded camera list
# beats a camera nothing can open.
MC_HELPER_OK=""
LAUNCHER_OK=""
if gcc -O2 -Wall -o /tmp/camera-relay-v4l2-io-mc "$CAMERA_RELAY_SRC/v4l2-io-mc.c" 2>/dev/null; then
    sudo install -d -m 755 /usr/local/lib/udev
    sudo install -m 755 /tmp/camera-relay-v4l2-io-mc "$MC_HELPER"
    rm -f /tmp/camera-relay-v4l2-io-mc
    MC_HELPER_OK=1
fi

if [[ -f "$CAMERA_RELAY_SRC/camera-relay-gst.c" ]] \
   && gcc -O2 -Wall -o /tmp/camera-relay-gst "$CAMERA_RELAY_SRC/camera-relay-gst.c" 2>/dev/null; then
    sudo install -o root -g camera-relay -m 755 \
        /tmp/camera-relay-gst /usr/local/bin/camera-relay-gst
    # After the group change: chgrp clears S_ISGID, so `install -m 2755 -g ...`
    # silently lands as plain 0755 and the launcher cannot reach the nodes.
    sudo chmod 2755 /usr/local/bin/camera-relay-gst
    rm -f /tmp/camera-relay-gst
    LAUNCHER_OK=1
    echo "  ✓ Installed /usr/local/bin/camera-relay-gst (setgid camera-relay)"
else
    echo "  ⚠ Failed to build the pipeline launcher (gcc required)."
fi

if [[ -n "$MC_HELPER_OK" && -n "$LAUNCHER_OK" ]]; then
    sudo tee /etc/udev/rules.d/74-camera-relay-mc-nodes.rules > /dev/null << 'EOF'
# Raw MC-centric V4L2 nodes are not standalone cameras. Keyed off the kernel's
# own V4L2_CAP_IO_MC rather than a driver-specific card name, so this covers
# IPU6, IPU7 and anything else media-controller based.
#
# The 74- prefix is load-bearing, pinned by three stock rule files:
#   60-persistent-v4l.rules  runs v4l_id, which sets the properties cleared below
#   73-seat-late.rules       queues RUN{builtin}+="uaccess", the session ACL
#   95-cd-devices.rules      hands anything with ID_V4L_PRODUCT to colord
#
# Note what does NOT work, because it looks like it should: TAG-="uaccess" on
# its own. 70-uaccess.rules tags every video4linux device unconditionally, and
# the TAG== test in 73 matches the *sticky* tag list, which TAG-= does not
# touch. So the ACL is granted no matter where this file sits, and the node
# stays openable — which is what kept the nodes visible in app pickers even
# with a rule that appeared to remove the tag. Stripping the ACL afterwards is
# the reliable option: RUN entries execute in the order rules added them, so
# the setfacl below lands after 73's builtin.
#
# TAG-= is still worth keeping. It clears the *current* tag list, which is what
# logind re-enumerates when a session becomes active — without it the ACL comes
# back on the next login.
ACTION=="remove", GOTO="camera_relay_mc_end"
SUBSYSTEM!="video4linux", GOTO="camera_relay_mc_end"

# Only probe when the classification is not already known. udev runs as root,
# so opening the node succeeds even after the group change below.
KERNEL=="video*", ENV{ID_V4L_IO_MC}=="", \
  IMPORT{program}="/usr/local/lib/udev/camera-relay-v4l2-io-mc $devnode"

# Out of 'video' (the desktop user is in it), and no longer claiming to be a
# camera. Clearing ID_V4L_PRODUCT is what stops colord: 95-cd-devices.rules
# keys on the product name, not on the capabilities.
ENV{ID_V4L_IO_MC}=="1", GROUP="camera-relay", MODE="0660", TAG-="uaccess", \
  ENV{ID_V4L_CAPABILITIES}="", ENV{ID_V4L_PRODUCT}="", \
  RUN+="/usr/bin/setfacl -b $devnode"

LABEL="camera_relay_mc_end"
EOF

    # Superseded: matched card names instead of the capability, and only
    # dropped the uaccess tag while the 'video' group kept granting access —
    # so it never actually hid anything.
    sudo rm -f /etc/udev/rules.d/90-hide-ipu6-v4l2.rules
    # Earlier revisions of this fix; both relied on TAG-= alone, which cannot
    # stop the uaccess ACL (see the header of the rule above).
    sudo rm -f /etc/udev/rules.d/90-camera-relay-mc-nodes.rules \
               /etc/udev/rules.d/72-camera-relay-mc-nodes.rules

    # The rule strips the session ACL with setfacl; without it the raw nodes
    # stay open to the desktop user and keep showing up in camera lists.
    if [[ ! -x /usr/bin/setfacl ]]; then
        echo "  ⚠ /usr/bin/setfacl missing — install the 'acl' package, otherwise"
        echo "    the raw nodes keep their session ACL and stay visible in apps."
    fi

    sudo udevadm control --reload-rules
    # The rule's own RUN strips the ACL, so this trigger fixes the running
    # session too — no reboot needed.
    sudo udevadm trigger --action=change --subsystem-match=video4linux
    echo "  ✓ Raw MC-centric nodes reassigned to the camera-relay group"
else
    # Deliberately leave the nodes alone. Reassigning them without a launcher
    # to reach them would take the camera out entirely.
    echo "  ⚠ Skipping the MC-node rule — the helpers did not build (gcc required)."
    echo "    Raw nodes stay visible in app camera lists; the camera still works."
fi

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
    sudo tee /etc/wireplumber/main.lua.d/52-disable-libcamera-node.lua > /dev/null << 'WPEOF'
-- Disable the direct libcamera node in PipeWire; apps use the v4l2 relay.
-- PipeWire's libcamera SPA plugin cannot stream this sensor on PipeWire 1.0.x
-- against a source-built libcamera 0.7.x: it negotiates a 640x480 fallback,
-- emits one black frame and then stalls. PipeWire-native apps (GNOME Snapshot)
-- pick that node over the relay and show pure black, while every v4l2 app works
-- — which reads as "the camera is broken" rather than "one node is broken".
rule = {
  matches = {
    {
      { "node.name", "matches", "libcamera_input.*" },
    },
  },
  apply_properties = {
    ["node.disabled"] = true,
  },
}
table.insert(libcamera_monitor.rules, rule)
WPEOF
    echo "  ✓ WirePlumber Lua rules installed (raw v4l2 + libcamera nodes hidden)"
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
    sudo tee /etc/wireplumber/wireplumber.conf.d/52-disable-libcamera-node.conf > /dev/null << 'WPEOF'
# Disable the direct libcamera node in PipeWire; apps use the v4l2 relay.
# PipeWire's libcamera SPA plugin cannot stream this sensor on PipeWire 1.0.x
# against a source-built libcamera 0.7.x: it negotiates a 640x480 fallback,
# emits one black frame and then stalls. PipeWire-native apps (GNOME Snapshot)
# pick that node over the relay and show pure black, while every v4l2 app works
# — which reads as "the camera is broken" rather than "one node is broken".
monitor.libcamera.rules = [
  {
    matches = [
      { node.name = "~libcamera_input.*" }
    ]
    actions = {
      update-props = {
        node.disabled = true
      }
    }
  }
]
WPEOF
    echo "  ✓ WirePlumber conf.d rules installed (raw v4l2 + libcamera nodes hidden)"
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

# ── Detect active session ─────────────────────────────────────────────────────
_relay_user=$(loginctl list-sessions --no-legend 2>/dev/null \
    | awk '$4 == "seat0" {print $3}' | head -1)
_relay_home=$(getent passwd "$_relay_user" | cut -d: -f6)

RELAY_DIR="$SCRIPT_DIR/../camera-relay"

if [[ -d "$RELAY_DIR" ]]; then
    # gst-launch-1.0/gst-inspect-1.0 must exist before the probe below, or it
    # exits 127 and misreads as "libcamerasrc missing" (issue #65).
    ensure_gst_tools

    # Install GStreamer libcamerasrc element if not present
    if ! gst-inspect-1.0 libcamerasrc &>/dev/null 2>&1; then
        echo "  Installing GStreamer libcamera plugin..."
        case "$DISTRO" in
            fedora)
                sudo dnf install -y gstreamer1-plugins-bad-free-extras 2>/dev/null || \
                sudo dnf install -y gstreamer1-plugins-bad-free 2>/dev/null || true
                ;;
            arch)
                sudo pacman -S --needed --noconfirm gst-plugin-libcamera 2>/dev/null || true
                ;;
            ubuntu|debian)
                # libcamerasrc ships in gstreamer1.0-libcamera on Ubuntu/Debian,
                # not in gstreamer1.0-plugins-bad — try the correct package first.
                sudo apt-get install -y gstreamer1.0-libcamera 2>/dev/null || \
                sudo apt-get install -y gstreamer1.0-plugins-bad 2>/dev/null || true
                ;;
        esac
    fi

    # Install v4l2loopback if not present
    if ! modinfo v4l2loopback &>/dev/null 2>&1; then
        echo "  Installing v4l2loopback..."
        case "$DISTRO" in
            fedora)
                # Fedora doesn't ship v4l2loopback in main repos — it lives in
                # RPM Fusion (free) as `akmod-v4l2loopback` (auto-builds against
                # the running kernel). Enable the repo if needed, then install.
                if ! dnf repolist --enabled 2>/dev/null | grep -qE '^rpmfusion-free(\s|$)'; then
                    FEDORA_VER=$(rpm -E %fedora 2>/dev/null || true)
                    if [[ -n "$FEDORA_VER" ]]; then
                        echo "  Enabling RPM Fusion (free) — required for akmod-v4l2loopback..."
                        sudo dnf install -y \
                            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm" \
                            || echo "  ⚠ Could not enable RPM Fusion automatically — see fallback hint below."
                    fi
                fi
                # akmod auto-builds against running kernel and needs matching kernel headers.
                sudo dnf install -y akmod-v4l2loopback kernel-devel-"$(uname -r)" 2>/dev/null \
                    || sudo dnf install -y akmod-v4l2loopback kernel-devel 2>/dev/null \
                    || true
                # Trigger immediate build so the module is usable without a reboot.
                if command -v akmods &>/dev/null; then
                    echo "  Building v4l2loopback akmod against current kernel (this may take a minute)..."
                    sudo akmods --force 2>/dev/null || true
                    sudo depmod -a 2>/dev/null || true
                fi
                ;;
            arch)
                sudo pacman -S --needed --noconfirm v4l2loopback-dkms 2>/dev/null || true
                ;;
            ubuntu|debian)
                sudo apt-get install -y v4l2loopback-dkms 2>/dev/null || true
                ;;
        esac

        # Re-check that the module is now installed; warn loudly if not.
        # Without this the relay crash-loops forever and the only symptom the
        # user sees is "the browser can't find my camera". (issue #51)
        if ! modinfo v4l2loopback &>/dev/null 2>&1; then
            echo "  ⚠ v4l2loopback kernel module still not available after install attempt."
            if [[ "$DISTRO" == "fedora" ]]; then
                echo "    On Fedora, ensure RPM Fusion (free) is enabled, then run:"
                echo "      sudo dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-\$(rpm -E %fedora).noarch.rpm"
                echo "      sudo dnf install -y akmod-v4l2loopback kernel-devel"
                echo "      sudo akmods --force && sudo depmod -a"
            fi
            echo "    Camera relay will not function until v4l2loopback is available."
        fi
    fi

    # ---------------------------------------------------------------
    # Neutralize the Intel OEM "v4l2-relayd" camera stack if present.
    #
    # On Ubuntu/Zorin (Noble base) the pre-installed Intel IPU6 OEM
    # stack ships its own /etc/modprobe.d/v4l2loopback.conf with
    # `exclusive_caps=1 card_label="Intel MIPI Camera"` plus an enabled
    # v4l2-relayd.service that auto-loads v4l2loopback at boot. modprobe.d
    # files are merged in lexical order and the LAST value of a duplicate
    # key wins, so "v4l2loopback.conf" overrides our
    # "99-camera-relay-loopback.conf" — the loopback comes up
    # capture-only (no VIDEO_OUTPUT), GStreamer's v4l2sink can't write
    # into it, and the relay shows a black screen. (issue #54)
    # ---------------------------------------------------------------
    OEM_V4L2_CONF="/etc/modprobe.d/v4l2loopback.conf"
    if systemctl list-unit-files 2>/dev/null | grep -q '^v4l2-relayd\.service' \
       || { [[ -f "$OEM_V4L2_CONF" ]] \
            && grep -q 'Intel MIPI Camera' "$OEM_V4L2_CONF" 2>/dev/null \
            && ! grep -q 'Camera Relay' "$OEM_V4L2_CONF" 2>/dev/null; }; then
        echo "  ⚠ Detected the Intel OEM 'v4l2-relayd' camera stack — it"
        echo "    grabs v4l2loopback at boot with exclusive_caps=1, which"
        echo "    breaks the camera relay. Neutralizing it (reversible via"
        echo "    uninstall.sh)."

        # Stop, disable and mask the competing service so it can't
        # re-load v4l2loopback with its own options or hold the device.
        if systemctl list-unit-files 2>/dev/null | grep -q '^v4l2-relayd\.service'; then
            sudo systemctl stop v4l2-relayd.service 2>/dev/null || true
            sudo systemctl disable v4l2-relayd.service 2>/dev/null || true
            sudo systemctl mask v4l2-relayd.service 2>/dev/null || true
            sleep 1
            echo "    ✓ v4l2-relayd.service stopped, disabled and masked"
        fi

        # Move the OEM modprobe.d file aside (only if it's the OEM one,
        # not ours) so our 99-camera-relay-loopback.conf is the only
        # `options v4l2loopback` line and reliably wins.
        if [[ -f "$OEM_V4L2_CONF" ]] \
           && grep -q 'Intel MIPI Camera' "$OEM_V4L2_CONF" 2>/dev/null \
           && ! grep -q 'Camera Relay' "$OEM_V4L2_CONF" 2>/dev/null; then
            sudo mv -f "$OEM_V4L2_CONF" \
                "${OEM_V4L2_CONF}.disabled-by-camera-relay"
            echo "    ✓ Moved $OEM_V4L2_CONF aside"
            echo "      (restored on uninstall from"
            echo "       ${OEM_V4L2_CONF}.disabled-by-camera-relay)"
        fi
    fi

    # Deploy v4l2loopback config (always overwrite — Fedora's v4l2loopback-akmods
    # can drop its own config that overrides ours, causing wrong card_label;
    # also fixes stale exclusive_caps=1 configs from older installs — issue #54)
    sudo cp "$RELAY_DIR/99-camera-relay-loopback.conf" /etc/modprobe.d/
    echo "  ✓ Installed v4l2loopback config (/etc/modprobe.d/99-camera-relay-loopback.conf)"

    # Ensure v4l2loopback loads at boot (modprobe.d only sets options, doesn't trigger load)
    echo "v4l2loopback" | sudo tee /etc/modules-load.d/v4l2loopback.conf > /dev/null
    echo "  ✓ Installed v4l2loopback autoload (/etc/modules-load.d/v4l2loopback.conf)"

    # v4l_id (60-persistent-v4l.rules) tags the node ONCE at device creation —
    # while the relay monitor holds the writer fd and no capture format is
    # negotiated yet — so ID_V4L_CAPABILITIES can come up without ":capture:"
    # and udev-based consumers misread the node. Normalise it here.
    #
    # This was originally added believing it was what made Chrome list the
    # camera (issue #54). It is not: Chromium enumerates with base::FileEnumerator
    # over /dev/video* and opens each node with VIDIOC_QUERYCAP — it never reads
    # a udev property. Chrome stays blind to the relay with this rule applied and
    # ID_V4L_CAPABILITIES=":capture:" set, because the node reports VIDEO_OUTPUT
    # alongside VIDEO_CAPTURE. That is handled by the PipeWire flag below.
    # The rule is kept because other udev consumers do read the property.
    sudo tee /etc/udev/rules.d/70-camera-relay-capabilities.rules > /dev/null << 'EOF'
# Normalise ID_V4L_CAPABILITIES for the Camera Relay loopback: v4l_id tags the
# node before any capture format is negotiated, so the property can come up
# without ":capture:". Runs after 60-persistent-v4l.
#
# Note: this does NOT affect Chromium. It enumerates /dev/video* directly and
# never reads udev properties — see the PipeWire camera flag instead.
SUBSYSTEM=="video4linux", ATTR{name}=="Camera Relay", ENV{ID_V4L_CAPABILITIES}=":capture:"
EOF
    sudo udevadm control --reload-rules
    sudo udevadm trigger --action=change --subsystem-match=video4linux
    echo "  ✓ Installed Camera Relay udev capabilities rule"

    # Rebuild initramfs so it picks up the new v4l2loopback config.
    # Without this, v4l2loopback may load from initramfs with stale
    # defaults (e.g. "OBS Virtual Camera") before /etc/modprobe.d/ is read.
    if command -v dracut &>/dev/null; then
        # (initramfs rebuilt once at end of script)
        NEEDS_INITRAMFS=1
        echo "  ✓ Initramfs rebuild with Camera Relay config deferred until end of script"
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

    # The setgid launcher is built in step 12, before the udev rule hands the
    # raw nodes to the camera-relay group — it has to exist before anything
    # depends on it. Nothing to do here.

    # Install CLI tool
    sudo cp "$RELAY_DIR/camera-relay" /usr/local/bin/camera-relay
    sudo chmod 755 /usr/local/bin/camera-relay
    echo "  ✓ Installed /usr/local/bin/camera-relay"

    # The browser helper has to outlive this source tree. Its running-browser
    # guard skips any profile whose browser is open — the common case during an
    # install — so "quit the browser and re-run it" is the normal path, not the
    # exception, and by then the extracted tarball is usually gone.
    if [[ -f "$RELAY_DIR/chromium-pipewire-camera.sh" ]]; then
        sudo install -m 755 "$RELAY_DIR/chromium-pipewire-camera.sh" \
            /usr/local/bin/chromium-pipewire-camera
        echo "  ✓ Installed /usr/local/bin/chromium-pipewire-camera"
    fi

    # Install systray runtime dependency (Python AppIndicator binding).
    # Without this, camera-relay-systray.py falls back to Gtk.StatusIcon,
    # which is non-functional on GNOME >= 40 / Wayland and the icon never
    # shows up in the tray.
    case "$DISTRO" in
        ubuntu|debian)
            sudo apt-get install -y --no-install-recommends \
                gir1.2-ayatanaappindicator3-0.1 2>/dev/null \
                && echo "  ✓ Installed gir1.2-ayatanaappindicator3-0.1 (systray binding)" \
                || echo "  ⚠ Could not install gir1.2-ayatanaappindicator3-0.1 — systray icon will not appear"
            ;;
        fedora)
            sudo dnf install -y libayatana-appindicator-gtk3 2>/dev/null \
                && echo "  ✓ Installed libayatana-appindicator-gtk3 (systray binding)" \
                || echo "  ⚠ Could not install libayatana-appindicator-gtk3 — systray icon will not appear"
            ;;
        arch)
            sudo pacman -S --needed --noconfirm libayatana-appindicator 2>/dev/null \
                && echo "  ✓ Installed libayatana-appindicator (systray binding)" \
                || echo "  ⚠ Could not install libayatana-appindicator — systray icon will not appear"
            ;;
    esac

    # Install systray GUI
    sudo mkdir -p /usr/local/share/camera-relay
    sudo cp "$RELAY_DIR/camera-relay-systray.py" /usr/local/share/camera-relay/
    sudo chmod 755 /usr/local/share/camera-relay/camera-relay-systray.py
    echo "  ✓ Installed systray GUI"

    # Install desktop file (app menu entry)
    sudo cp "$RELAY_DIR/camera-relay-systray.desktop" /usr/share/applications/
    echo "  ✓ Installed desktop entry"

    # Install autostart entry so the systray launches on login
    sudo install -m 644 "$RELAY_DIR/camera-relay-systray.desktop" \
        /etc/xdg/autostart/camera-relay-systray.desktop
    echo "  ✓ Installed autostart entry (/etc/xdg/autostart/)"

    # Auto-enable persistent on-demand relay
    echo "  Enabling on-demand relay (auto-starts on login)..."
    /usr/local/bin/camera-relay enable-persistent --yes 2>/dev/null && \
        echo "  ✓ On-demand relay enabled (near-zero idle CPU)" || \
        echo "  ⚠ Could not enable persistent relay — run 'camera-relay enable-persistent' after reboot"

    if [[ -n "$_relay_user" ]]; then
        ICON_DEST="${_relay_home}/.local/share/icons/hicolor/symbolic/apps"
        sudo mkdir -p "$ICON_DEST"
        sudo chown -R "$_relay_user":"$_relay_user" "${_relay_home}/.local/share/icons"
        for icon in camera-disabled-symbolic camera-switch-symbolic camera-video-symbolic; do
            if [[ -f "$RELAY_DIR/yaru-icons/${icon}.svg" ]]; then
                sudo -u "$_relay_user" cp "$RELAY_DIR/yaru-icons/${icon}.svg" "$ICON_DEST/"
                echo "✓ Installed ${icon}.svg"
            else
                echo "${icon}.svg not found in $RELAY_DIR — skipping"
            fi
        done
        sudo -u "$_relay_user" \
            gtk-update-icon-cache -f -t \
            "${_relay_home}/.local/share/icons/hicolor" 2>/dev/null \
            && echo "✓ GTK icon cache updated" \
            || echo "gtk-update-icon-cache failed — icons may not appear until next login"
    else
        echo "Could not detect logged-in user — icons not installed"
    fi

    # Chromium-family browsers cannot see the relay node at all. Their V4L2
    # enumeration accepts a device only when it reports VIDEO_CAPTURE and *not*
    # VIDEO_OUTPUT, and the relay under exclusive_caps=0 reports both — so
    # Chrome, Brave, Edge and every Electron app list zero cameras while Firefox
    # (which accepts dual caps) works. Point them at PipeWire instead, where
    # WirePlumber already publishes the relay as an ordinary camera source.
    # Advisory: never fail the install over a browser preference.
    if [[ -x "$RELAY_DIR/chromium-pipewire-camera.sh" ]]; then
        echo ""
        echo "  Configuring Chromium-family browsers..."
        "$RELAY_DIR/chromium-pipewire-camera.sh" enable || true
    fi
else
    echo "  ⚠ camera-relay directory not found — skipping"
fi

# ──────────────────────────────────────────────
# [14/14] Restart PipeWire and verify
# ──────────────────────────────────────────────
echo ""
echo "[14/14] Restarting PipeWire and verifying camera..."

# Restarting PipeWire is not cosmetic: every application holding a stream loses
# it, and most do not reconnect — browsers and Spotify in particular go silent
# until restarted. Running a *camera* script and losing your speakers points
# nowhere near its cause; during #80 testing it read as "the uninstall broke my
# audio" and took a speaker-test to rule out. (issue #81)
#
# The restart is still load-bearing here, so this asks rather than dropping it:
# the libcamera SPA plugin is loaded by the pipewire daemon itself, so bouncing
# only wireplumber would not pick up a freshly built libcamera and the check
# below would report a false negative. Skipping is safe — it degrades into the
# "PipeWire hasn't picked it up yet, reboot" branch, which is already correct.
pipewire_stream_apps() {
    command -v pactl &>/dev/null || return 1
    # One type per call. `pactl list sink-inputs source-outputs` exits 0 and
    # prints NOTHING — it takes a single type and silently ignores the rest — so
    # the combined form looks like "no streams are active" on every machine.
    { pactl list sink-inputs 2>/dev/null
      pactl list source-outputs 2>/dev/null
    } | sed -n 's/^[[:space:]]*application\.name = "\(.*\)"/\1/p' | sort -u
}

PIPEWIRE_RESTARTED=false
_RESTART=true
if [[ "$NO_RESTART" == true ]]; then
    echo "  – Skipping PipeWire restart (--no-restart)."
    _RESTART=false
else
    _IN_USE=$(pipewire_stream_apps || true)
    if [[ -n "$_IN_USE" ]]; then
        echo "  ⚠ A PipeWire restart drops the audio/video streams these apps hold,"
        echo "    and most will not reconnect on their own:"
        sed 's/^/      /' <<< "$_IN_USE"
        echo ""
        echo "    Skipping is safe — a reboot (which this script recommends anyway)"
        echo "    achieves the same thing. It only defers the camera check below."
        # `|| _ans=""` because this script runs under `set -e` and read returns 1
        # on EOF, which would otherwise kill the install for a piped stdin.
        read -rp "  Restart PipeWire now and interrupt them? [y/N] " _ans || _ans=""
        case "$_ans" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "  – Skipped. Reboot to finish, then check: camera-relay doctor"
               _RESTART=false ;;
        esac
    fi
fi

if [[ "$_RESTART" == true ]]; then
    # Restart PipeWire so it picks up the libcamera SPA plugin
    systemctl --user restart pipewire wireplumber 2>/dev/null || true
    sleep 3
    PIPEWIRE_RESTARTED=true
fi

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

# ──────────────────────────────────────────────
# Rebuild initramfs (once, if needed)
# ──────────────────────────────────────────────
if [[ "$NEEDS_INITRAMFS" == "1" ]]; then
    echo ""
    echo "  Rebuilding initramfs (this may take a moment)..."
    if command -v dracut >/dev/null 2>&1; then
        sudo dracut --force 2>/dev/null && echo "  ✓ initramfs rebuilt" || true
    elif command -v update-initramfs >/dev/null 2>&1; then
        sudo update-initramfs -u 2>/dev/null && echo "  ✓ initramfs rebuilt" || true
    elif command -v mkinitcpio >/dev/null 2>&1; then
        sudo mkinitcpio -P 2>/dev/null && echo "  ✓ initramfs rebuilt" || true
    else
        echo "  ⚠ Could not detect initramfs tool — rebuild manually before rebooting"
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
    if ! $PIPEWIRE_RESTARTED; then
        echo "  (expected — the PipeWire restart was skipped, so it has not"
        echo "   reloaded the libcamera plugin yet.)"
    fi
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
echo "    /etc/udev/rules.d/74-camera-relay-mc-nodes.rules"
[[ -f /usr/local/lib/udev/camera-relay-v4l2-io-mc ]] && \
    echo "    /usr/local/lib/udev/camera-relay-v4l2-io-mc"
echo "    /usr/local/lib/sysusers.d/camera-relay.conf"
[[ -f /etc/initramfs-tools/modules ]] && echo "    /etc/initramfs-tools/modules (updated)"
[[ -f /etc/dracut.conf.d/ivsc-camera.conf ]] && echo "    /etc/dracut.conf.d/ivsc-camera.conf"
[[ -f /etc/mkinitcpio.conf.d/ivsc-camera.conf ]] && echo "    /etc/mkinitcpio.conf.d/ivsc-camera.conf"
if [[ -f /etc/wireplumber/main.lua.d/51-disable-ipu6-v4l2.lua ]]; then
    echo "    /etc/wireplumber/main.lua.d/51-disable-ipu6-v4l2.lua"
elif [[ -f /etc/wireplumber/wireplumber.conf.d/50-disable-ipu6-v4l2.conf ]]; then
    echo "    /etc/wireplumber/wireplumber.conf.d/50-disable-ipu6-v4l2.conf"
fi
if [[ -f /etc/profile.d/libcamera-ipa.sh ]]; then
    echo "    /etc/profile.d/libcamera-ipa.sh"
    echo "    /etc/environment.d/libcamera-ipa.conf"
fi
[[ -f /etc/environment.d/10-libcamera-softisp.conf ]] && \
    echo "    /etc/environment.d/10-libcamera-softisp.conf"
echo "    /usr/local/share/libcamera/ipa/simple/ov02c10.yaml"
if [[ -f /usr/local/bin/camera-relay ]]; then
    echo "    /usr/local/bin/camera-relay"
    echo "    /usr/local/bin/camera-relay-monitor"
    [[ -f /usr/local/bin/camera-relay-gst ]] && \
        echo "    /usr/local/bin/camera-relay-gst"
    echo "    /etc/modprobe.d/99-camera-relay-loopback.conf"
fi
echo ""
echo "  Browser setup:"
echo "    Firefox:  Works out of the box (no flags needed)"
echo "    Chrome/Chromium/Brave: cannot see the V4L2 relay at all — they only"
echo "      accept a device that reports capture WITHOUT output, and the relay"
echo "      reports both. They go through PipeWire instead, which is what the"
echo "      flag above enables. If it was skipped because the browser was open,"
echo "      quit it and run: chromium-pipewire-camera"
echo "    Edge:     edge://flags does not expose the entry, so nothing can be"
echo "      written to its profile — launch it with"
echo "      --enable-features=WebRtcPipeWireCamera instead."
echo "    Electron apps (Slack, Discord, Teams): same V4L2 filter, but the"
echo "      switch does not help — PipeWire camera is not wired into Electron."
echo "    Run 'camera-relay doctor' to see the flag state per browser."
echo ""
echo "  Cheese fix (if needed):"
echo "    Cheese crashes with this camera. A standalone fix is available:"
echo "    cd ../camera-relay && ./cheese-fix.sh"
echo ""
echo "  *** IMPORTANT: A full system reboot is required! ***"
echo ""
echo "  The installer ensured your user is in the 'video' group (camera access)"
echo "  and, where available, the 'kvm' group (for /dev/udmabuf, used by"
echo "  libcamera's buffer allocator). Group changes only take effect after a"
echo "  FULL REBOOT — logging out and back in is NOT sufficient, because"
echo "  PipeWire, WirePlumber, and the camera relay all need to start fresh."
echo ""
echo "  Please reboot now:  sudo reboot"
echo "=============================================="
