#!/bin/bash
set -e

DKMS_NAME="max98390-hda"
DKMS_VER="1.0"
SRC_DIR="/usr/src/${DKMS_NAME}-${DKMS_VER}"

FORCE=false
[ "$1" = "--force" ] && FORCE=true

echo "=== MAX98390 HDA Speaker Driver Installer ==="
echo "Samsung Galaxy Book4 Ultra (and similar)"
echo ""

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo" >&2
    exit 1
fi

# Detect package manager
if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    PKG_INSTALL="dnf install -y"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
    PKG_INSTALL="pacman -S --noconfirm"
elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    PKG_INSTALL="apt-get install -y"
else
    PKG_MGR="unknown"
    PKG_INSTALL=""
fi

# Check prerequisites
if ! command -v dkms >/dev/null 2>&1; then
    if [ "$PKG_MGR" = "dnf" ]; then
        echo "ERROR: dkms not installed. Run: sudo dnf install dkms kernel-devel" >&2
    elif [ "$PKG_MGR" = "pacman" ]; then
        # The running kernel's own headers package (linux-cachyos-headers on
        # CachyOS), not always stock Arch's linux-headers
        kpkg=$(pacman -Qqo "/usr/lib/modules/$(uname -r)/vmlinuz" 2>/dev/null || true)
        echo "ERROR: dkms not installed. Run: sudo pacman -S dkms ${kpkg:-linux}-headers i2c-tools" >&2
    else
        echo "ERROR: dkms not installed. Run: sudo apt install dkms" >&2
    fi
    exit 1
fi

# i2c-tools is needed for dynamic amp detection on boot
if ! command -v i2cget >/dev/null 2>&1; then
    echo "Installing i2c-tools (needed for amplifier detection)..."
    if [ -n "$PKG_INSTALL" ]; then
        $PKG_INSTALL i2c-tools >/dev/null 2>&1 || {
            echo "ERROR: Failed to install i2c-tools. Install manually: i2c-tools" >&2
            exit 1
        }
    else
        echo "ERROR: i2c-tools not installed. Please install it manually." >&2
        exit 1
    fi
fi

# Check hardware: MAX98390 must be present via ACPI
if ! ls /sys/bus/acpi/devices/MAX98390:* &>/dev/null && \
   ! grep -rq "MAX98390" /sys/bus/i2c/devices/*/name 2>/dev/null; then
    if $FORCE; then
        echo "WARNING: No MAX98390 detected — installing anyway (--force)"
    else
        echo "ERROR: No MAX98390 amplifier detected on this system." >&2
        echo "This driver is for Samsung Galaxy Book4 (and similar) laptops" >&2
        echo "with MAX98390 HDA speaker amplifiers." >&2
        echo "" >&2
        echo "Use --force to install anyway." >&2
        exit 1
    fi
fi

# Check for SOF firmware (required for Intel audio DSP to function at all)
SOF_FW_MISSING=false
if [ "$PKG_MGR" = "dnf" ]; then
    if ! rpm -q alsa-sof-firmware &>/dev/null; then
        SOF_FW_MISSING=true
        SOF_PKG="alsa-sof-firmware"
    fi
elif [ "$PKG_MGR" = "pacman" ]; then
    if ! pacman -Q sof-firmware &>/dev/null 2>&1; then
        SOF_FW_MISSING=true
        SOF_PKG="sof-firmware"
    fi
elif [ "$PKG_MGR" = "apt" ]; then
    if ! dpkg -l firmware-sof-signed 2>/dev/null | grep -q "^ii" && \
       ! dpkg -l firmware-sof 2>/dev/null | grep -q "^ii"; then
        SOF_FW_MISSING=true
        SOF_PKG="firmware-sof-signed"
    fi
fi

if $SOF_FW_MISSING; then
    echo ""
    echo "WARNING: Sound Open Firmware (SOF) is not installed."
    echo "  Without it, the Intel audio DSP has no firmware to run and"
    echo "  audio will not work at all — regardless of this speaker fix."
    echo ""
    read -rp "  Install $SOF_PKG now? [Y/n] " REPLY
    REPLY=${REPLY:-Y}
    if [[ "$REPLY" =~ ^[Yy] ]]; then
        echo "  Installing $SOF_PKG..."
        $PKG_INSTALL "$SOF_PKG" || {
            echo "ERROR: Failed to install $SOF_PKG. Install it manually." >&2
            exit 1
        }
        echo "  ✓ $SOF_PKG installed (reboot needed to load firmware)"
    else
        echo "  Skipping — audio may not work without SOF firmware."
        echo "  Install later with: sudo $PKG_INSTALL $SOF_PKG"
    fi
    echo ""
fi

# Remove old version if present
if dkms status "${DKMS_NAME}/${DKMS_VER}" 2>/dev/null | grep -q "${DKMS_NAME}"; then
    echo "Removing existing DKMS module..."
    dkms remove "${DKMS_NAME}/${DKMS_VER}" --all 2>/dev/null || true
fi

# Copy source to DKMS tree
echo "Installing source to ${SRC_DIR}..."
rm -rf "${SRC_DIR}"
mkdir -p "${SRC_DIR}/src"
cp -a "$(dirname "$0")/src/"*.{c,h} "${SRC_DIR}/src/"
cp -a "$(dirname "$0")/src/Makefile" "${SRC_DIR}/src/"
cp -a "$(dirname "$0")/dkms.conf" "${SRC_DIR}/"

# Configure DKMS to sign modules with a MOK key when Secure Boot is enabled.
# Track the key path so we can verify enrollment after the build.
MOK_CERT=""
MOK_KEY=""

if [ "$PKG_MGR" = "dnf" ] && mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
    MOK_KEY="/etc/pki/akmods/private/private_key.priv"
    MOK_CERT="/etc/pki/akmods/certs/public_key.der"

    if [ ! -f "$MOK_KEY" ] || [ ! -f "$MOK_CERT" ]; then
        echo "Generating MOK key for Secure Boot module signing..."
        $PKG_INSTALL kmodtool akmods mokutil openssl >/dev/null 2>&1 || true
        kmodgenca -a 2>/dev/null || true
    fi

    if [ -f "$MOK_KEY" ] && [ -f "$MOK_CERT" ]; then
        echo "Configuring DKMS to sign modules with Fedora akmods MOK key..."
        mkdir -p /etc/dkms/framework.conf.d
        cat > /etc/dkms/framework.conf.d/akmods-keys.conf << SIGNEOF
# Fedora akmods MOK key for Secure Boot module signing
mok_signing_key=${MOK_KEY}
mok_certificate=${MOK_CERT}
SIGNEOF
    else
        MOK_KEY=""; MOK_CERT=""
    fi
fi

# Debian/Ubuntu: DKMS doesn't auto-sign with a MOK key on every distro version,
# so probe for the standard locations and configure framework.conf.d if found.
# Without this, modules silently build unsigned and the kernel rejects them
# under Secure Boot ("Loading of module with unavailable key is rejected").
if [ "$PKG_MGR" = "apt" ] && mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
    # Preference order:
    #   1. Debian default — /var/lib/dkms/mok.{key,pub}  (auto-generated by dkms 3.0.10+)
    #   2. Ubuntu shim-signed — /var/lib/shim-signed/mok/MOK.{priv,der}
    #      (created by `update-secureboot-policy --new-key` from shim-signed)
    if [ -f /var/lib/dkms/mok.key ] && [ -f /var/lib/dkms/mok.pub ]; then
        MOK_KEY="/var/lib/dkms/mok.key"
        MOK_CERT="/var/lib/dkms/mok.pub"
    elif [ -f /var/lib/shim-signed/mok/MOK.priv ] && [ -f /var/lib/shim-signed/mok/MOK.der ]; then
        MOK_KEY="/var/lib/shim-signed/mok/MOK.priv"
        MOK_CERT="/var/lib/shim-signed/mok/MOK.der"
    else
        echo "No MOK signing key found. Trying to set one up..."
        # shim-signed ships update-secureboot-policy which can generate a key.
        if ! command -v update-secureboot-policy >/dev/null 2>&1; then
            $PKG_INSTALL shim-signed >/dev/null 2>&1 || true
        fi
        if command -v update-secureboot-policy >/dev/null 2>&1; then
            # --new-key creates /var/lib/shim-signed/mok/MOK.{priv,der} non-interactively
            update-secureboot-policy --new-key 2>/dev/null || true
        fi
        if [ -f /var/lib/shim-signed/mok/MOK.priv ] && [ -f /var/lib/shim-signed/mok/MOK.der ]; then
            MOK_KEY="/var/lib/shim-signed/mok/MOK.priv"
            MOK_CERT="/var/lib/shim-signed/mok/MOK.der"
        elif [ -f /var/lib/dkms/mok.key ] && [ -f /var/lib/dkms/mok.pub ]; then
            MOK_KEY="/var/lib/dkms/mok.key"
            MOK_CERT="/var/lib/dkms/mok.pub"
        fi
    fi

    if [ -n "$MOK_KEY" ] && [ -n "$MOK_CERT" ]; then
        echo "Configuring DKMS to sign modules with MOK key: $MOK_CERT"
        mkdir -p /etc/dkms/framework.conf.d
        cat > /etc/dkms/framework.conf.d/max98390-mok-keys.conf << SIGNEOF
# MOK key for Secure Boot module signing (set up by speaker-fix install.sh)
mok_signing_key=${MOK_KEY}
mok_certificate=${MOK_CERT}
SIGNEOF
    else
        echo ""
        echo "WARNING: Could not locate or generate a MOK signing key on this system."
        echo "         Modules will build unsigned and won't load under Secure Boot."
        echo "         Either disable Secure Boot in BIOS, or set up MOK manually:"
        echo "           sudo apt install shim-signed"
        echo "           sudo update-secureboot-policy --new-key"
        echo "           sudo mokutil --import /var/lib/shim-signed/mok/MOK.der"
        echo "         Then reboot, complete MOK enrollment, and re-run this installer."
        echo ""
    fi
fi

# The module for every other installed kernel with headers: AUTOINSTALL only
# covers future kernels, so one already there would boot without it until its
# next update. Arch-based only: elsewhere the extra kernels are older fallbacks.
# One DKMS can't build for is skipped with a warning.
dkms_other_kernels() {
    local kdir k
    [ "$PKG_MGR" = "pacman" ] || return 0
    for kdir in /lib/modules/*/build; do
        [ -e "$kdir" ] || continue
        k="${kdir%/build}"; k="${k##*/}"
        [ "$k" = "$(uname -r)" ] && continue
        # Headers can outlive their kernel (leftover linux-headers)
        [ -e "/lib/modules/$k/vmlinuz" ] || continue
        if dkms install "${DKMS_NAME}/${DKMS_VER}" -k "$k" >/dev/null 2>&1; then
            echo "Also installed for kernel $k"
        else
            echo "WARNING: Not installed for kernel $k (DKMS couldn't build it there)"
        fi
    done
}

# Register, build, and install with DKMS
echo "Building DKMS module..."
dkms add "${DKMS_NAME}/${DKMS_VER}"
dkms build "${DKMS_NAME}/${DKMS_VER}"
dkms install "${DKMS_NAME}/${DKMS_VER}"
dkms_other_kernels

# Verify module signing AND key enrollment when Secure Boot is enabled.
# Two failure modes need to be distinguished:
#   1. Modules unsigned             → `modinfo` shows no signature  → rebuild after fixing key config
#   2. Modules signed but rejected  → `mokutil --test-key` says "not enrolled"
# The second mode is the one BIOS updates trigger: enrollment lives in EFI NVRAM,
# which some Samsung BIOS updates wipe (issue #48 — Galaxy Book4 Ultra P10ALX).
if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
    MOD_PATH=$(find /lib/modules/$(uname -r) -name "snd-hda-scodec-max98390.ko*" 2>/dev/null | head -1)
    if [ -n "$MOD_PATH" ]; then
        if ! modinfo "$MOD_PATH" 2>/dev/null | grep -qi "^sig"; then
            echo ""
            echo "WARNING: Secure Boot is enabled but the modules are NOT signed."
            echo "         This can happen when the MOK signing key was just configured."
            echo "         Rebuilding modules with signing..."
            dkms remove "${DKMS_NAME}/${DKMS_VER}" --all 2>/dev/null || true
            dkms add "${DKMS_NAME}/${DKMS_VER}"
            dkms build "${DKMS_NAME}/${DKMS_VER}"
            dkms install "${DKMS_NAME}/${DKMS_VER}"
            dkms_other_kernels

            # Check again
            MOD_PATH=$(find /lib/modules/$(uname -r) -name "snd-hda-scodec-max98390.ko*" 2>/dev/null | head -1)
            if [ -n "$MOD_PATH" ] && modinfo "$MOD_PATH" 2>/dev/null | grep -qi "^sig"; then
                echo "         ✓ Modules are now signed"
            else
                echo ""
                echo "WARNING: Modules are still unsigned. They will NOT load with Secure Boot."
                echo "         After rebooting and completing MOK enrollment, run the installer again:"
                echo "         sudo bash $(cd "$(dirname "$0")" && pwd)/install.sh"
                echo "         Or manually rebuild: sudo dkms remove ${DKMS_NAME}/${DKMS_VER} --all && sudo dkms install ${DKMS_NAME}/${DKMS_VER}"
            fi
        else
            echo "✓ Modules are signed for Secure Boot"
        fi
    fi

    # Now confirm the signing certificate is actually enrolled in MokListRT.
    # If not, the kernel will reject the (correctly-signed) module on load.
    # Walk every plausible cert location so we catch akmods (Fedora),
    # shim-signed (Ubuntu), and dkms (Debian) installs.
    MOK_ENROLL_PENDING=false
    for CERT in \
        "$MOK_CERT" \
        /var/lib/dkms/mok.pub \
        /var/lib/shim-signed/mok/MOK.der \
        /etc/pki/akmods/certs/public_key.der; do
        [ -n "$CERT" ] && [ -f "$CERT" ] || continue
        if mokutil --test-key "$CERT" 2>/dev/null | grep -q "is already enrolled"; then
            echo "✓ MOK signing key is enrolled: $CERT"
            MOK_ENROLL_PENDING=false
            break
        fi
        # Pending-enrollment isn't a hit, but it means a previous import already
        # queued this exact cert — treat as good enough. Compare SHA-1 fingerprints
        # (mokutil --list-new prints them with colons, openssl outputs the same).
        FP=$(openssl x509 -in "$CERT" -inform DER -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//')
        if [ -n "$FP" ] && mokutil --list-new 2>/dev/null | grep -qi "$FP"; then
            echo "✓ MOK signing key import is queued (pending reboot): $CERT"
            MOK_ENROLL_PENDING=false
            break
        fi
        MOK_ENROLL_PENDING=true
        LAST_CERT="$CERT"
    done

    if $MOK_ENROLL_PENDING; then
        echo ""
        echo "WARNING: Secure Boot is on, but the MOK signing key is NOT enrolled in firmware."
        echo "         The kernel will reject the (signed) modules on load with:"
        echo "             'Loading of module with unavailable key is rejected'"
        echo ""
        echo "         A common cause is a recent BIOS update wiping EFI NVRAM —"
        echo "         the modules and on-disk key are intact, but the firmware no"
        echo "         longer trusts the key. (See issue #48.)"
        echo ""
        echo ">>> Queuing MOK enrollment now. You'll be asked for a one-time password;"
        echo ">>> remember it — you'll need to enter it again on the blue MOK Manager"
        echo ">>> screen on the next boot. Cert: ${LAST_CERT}"
        echo ""
        # Run interactively — mokutil prompts on stdin/stdout for the password.
        if ! mokutil --import "$LAST_CERT"; then
            echo ""
            echo "         Enrollment NOT queued. To retry:"
            echo "             sudo mokutil --import ${LAST_CERT}"
            echo "         Then reboot and follow the MOK Manager prompt."
        fi
        echo ""
    fi
fi

# Install helper scripts and systemd services
echo "Installing services..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
install -m 755 "${SCRIPT_DIR}/max98390-hda-i2c-setup.sh" /usr/local/sbin/
install -m 755 "${SCRIPT_DIR}/max98390-hda-check-upstream.sh" /usr/local/sbin/
install -m 644 "${SCRIPT_DIR}/max98390-hda-i2c-setup.service" /etc/systemd/system/
install -m 644 "${SCRIPT_DIR}/max98390-hda-check-upstream.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable max98390-hda-i2c-setup.service
systemctl enable max98390-hda-check-upstream.service

# Module autoload
echo "Configuring module autoload..."
cat > /etc/modules-load.d/max98390-hda.conf << 'EOF'
# MAX98390 HDA speaker amplifier driver (Galaxy Book4)
snd-hda-scodec-max98390
snd-hda-scodec-max98390-i2c
EOF

echo ""
echo "=== Installation complete ==="
echo "The driver will auto-load and auto-rebuild on kernel updates."
echo "Reboot to verify everything works on a fresh boot."
echo ""
echo "To test now (without reboot):"
echo "  sudo systemctl start max98390-hda-i2c-setup.service"
echo "To uninstall:"
echo "  sudo bash $(cd "$(dirname "$0")" && pwd)/uninstall.sh"
