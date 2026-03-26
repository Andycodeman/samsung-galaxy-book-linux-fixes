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

# Check if already installed — marker file or DKMS entry
MARKER_FILE="/var/lib/samsung-galaxybook/speaker-fix.installed"
DKMS_PRESENT=false
dkms status "${DKMS_NAME}/${DKMS_VER}" 2>/dev/null | grep -q "${DKMS_NAME}" && DKMS_PRESENT=true

if { [ -f "$MARKER_FILE" ] || $DKMS_PRESENT; } && ! $FORCE; then
    echo "ERROR: Speaker fix is already installed." >&2
    echo "  To reinstall, uninstall first:" >&2
    echo "    sudo bash $(cd "$(dirname "$0")" && pwd)/uninstall.sh" >&2
    echo "  Or use --force to override this check." >&2
    exit 1
fi

# Hardware compatibility is determined by hardware-compat.json (via samsung-galaxybook-setup.sh).
# When called from the setup script, applicability is already confirmed before this script runs.
# The MAX98390 ACPI presence check below is the authoritative runtime hardware guard.
if $FORCE; then
    echo "NOTE: --force specified — skipping vendor check"
else
    _vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "unknown")
    if [[ "${_vendor,,}" != *"samsung"* ]]; then
        echo "ERROR: System vendor is '${_vendor}', not Samsung." >&2
        echo "This driver is for Samsung Galaxy Book laptops with MAX98390 amplifiers." >&2
        echo "Use --force to override this check." >&2
        exit 1
    fi
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

# Check prerequisites — install dkms and kernel headers if missing
if ! command -v dkms >/dev/null 2>&1; then
    echo "Installing dkms and kernel headers..."
    if [ "$PKG_MGR" = "dnf" ]; then
        dnf install -y dkms kernel-devel-$(uname -r) kernel-headers || {
            echo "ERROR: Failed to install dkms. Run: sudo dnf install dkms kernel-devel" >&2
            exit 1
        }
    elif [ "$PKG_MGR" = "pacman" ]; then
        ARCH_KERNEL_PKG="linux-headers"
        uname -r | grep -q "\-lts"      && ARCH_KERNEL_PKG="linux-lts-headers"
        uname -r | grep -q "\-zen"      && ARCH_KERNEL_PKG="linux-zen-headers"
        uname -r | grep -q "\-hardened" && ARCH_KERNEL_PKG="linux-hardened-headers"
        pacman -S --noconfirm --needed dkms "$ARCH_KERNEL_PKG" || {
            echo "ERROR: Failed to install dkms. Run: sudo pacman -S dkms linux-headers" >&2
            exit 1
        }
    elif [ -n "$PKG_INSTALL" ]; then
        apt-get update -q
        apt-get install -y dkms linux-headers-$(uname -r) || {
            echo "ERROR: Failed to install dkms. Run: sudo apt install dkms linux-headers-$(uname -r)" >&2
            exit 1
        }
    else
        echo "ERROR: dkms not installed and package manager unknown. Install dkms manually." >&2
        exit 1
    fi
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

# On Fedora with Secure Boot, configure DKMS to use the akmods MOK key for signing
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

        # Check if the key is already enrolled
        if ! mokutil --test-key "$MOK_CERT" 2>/dev/null | grep -q "is already enrolled"; then
            echo ""
            echo ">>> Secure Boot: You need to enroll the MOK key. <<<"
            echo ">>> Run: sudo mokutil --import ${MOK_CERT}        <<<"
            echo ">>> Then reboot and follow the MOK enrollment prompt. <<<"
            echo ""
            mokutil --import "$MOK_CERT" 2>/dev/null || true
        fi
    fi
fi

# Register, build, and install with DKMS
echo "Building DKMS module..."
dkms add "${DKMS_NAME}/${DKMS_VER}"
dkms build "${DKMS_NAME}/${DKMS_VER}"
dkms install "${DKMS_NAME}/${DKMS_VER}"

# Verify module signing when Secure Boot is enabled
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
# Write installed marker
mkdir -p /var/lib/samsung-galaxybook
touch "$MARKER_FILE"
