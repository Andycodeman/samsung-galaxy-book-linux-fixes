#!/bin/bash
set -e

#
# install.sh — Samsung Galaxy Book3 Pro 14" (940XFG) speaker fix installer.
#
# This installs a userspace fix for the missing ALC298 quirk on subsystem ID
# 0x144dc882 (Samsung NP940XFG-KC1*). Speakers are silent on Linux until
# the codec's internal class-D amps are initialized via Realtek COEF writes.
#
# What gets installed:
#   /usr/local/sbin/alc298-amp-init.sh            (the init script)
#   /etc/systemd/system/alc298-amp-init.service   (runs at boot)
#   /lib/systemd/system-sleep/alc298-amp-init     (runs after resume from sleep)
#

FORCE=false
[ "$1" = "--force" ] && FORCE=true

echo "=== Samsung Galaxy Book3 Pro 14\" (940XFG) Speaker Fix Installer ==="
echo ""

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo" >&2
    exit 1
fi

# Detect package manager (used only to install alsa-tools if missing)
if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf";    PKG_INSTALL="dnf install -y";   ALSA_TOOLS_PKG="alsa-tools"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"; PKG_INSTALL="pacman -S --noconfirm"; ALSA_TOOLS_PKG="alsa-tools"
elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt";    PKG_INSTALL="apt-get install -y"; ALSA_TOOLS_PKG="alsa-tools"
else
    PKG_MGR="unknown"; PKG_INSTALL=""; ALSA_TOOLS_PKG="alsa-tools"
fi

# ---------------------------------------------------------------------------
# Hardware guard: refuse to install on the wrong board.
# ---------------------------------------------------------------------------
# The fix is specific to the 14" Book3 Pro (DMI product family 940XFG, ALC298
# subsystem ID 0x144dc882). The 16" sibling (NP964XFG) and the Book2/Book3
# Ultra all have working upstream support and must not run this installer.

PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo unknown)"

if [ "$VENDOR" != "SAMSUNG ELECTRONICS CO., LTD." ]; then
    if $FORCE; then
        echo "WARNING: not a Samsung machine (vendor=$VENDOR), continuing under --force"
    else
        echo "ERROR: this fix is for Samsung Galaxy Book3 Pro 14\" only." >&2
        echo "       DMI vendor: $VENDOR (expected: SAMSUNG ELECTRONICS CO., LTD.)" >&2
        exit 1
    fi
fi

if [ "$PRODUCT" != "940XFG" ]; then
    if $FORCE; then
        echo "WARNING: DMI product is $PRODUCT, not 940XFG — continuing under --force"
    else
        echo "ERROR: DMI product name is '$PRODUCT', expected '940XFG'." >&2
        echo "" >&2
        echo "  This fix is specific to the Samsung Galaxy Book3 Pro 14\" (NP940XFG-*)." >&2
        echo "  If you have a different model, the wrong fix can put your codec into" >&2
        echo "  an inconsistent state." >&2
        echo "" >&2
        echo "  - 16\" Book3 Pro (NP964XFG):       upstream ALC298_FIXUP_SAMSUNG_AMP_V2_4_AMPS, no fix needed" >&2
        echo "  - Book4 Pro/Ultra, Book5 Pro:    use ../speaker-fix/ (MAX98390 DKMS)" >&2
        echo "" >&2
        echo "  If you genuinely have a 940XFG variant DMI is reading wrong, use --force." >&2
        exit 1
    fi
fi

# Codec subsystem-ID check — the load-bearing match. DMI alone is not enough;
# Samsung sometimes uses the same chassis name across board revisions.
SSID_FOUND=false
for d in /sys/class/sound/hwC*D*; do
    [ -r "$d/subsystem_id" ] || continue
    if [ "$(cat "$d/subsystem_id")" = "0x144dc882" ]; then
        SSID_FOUND=true
        break
    fi
done

if ! $SSID_FOUND; then
    if $FORCE; then
        echo "WARNING: no codec with SSID 0x144dc882 found, continuing under --force"
    else
        echo "ERROR: no audio codec with subsystem ID 0x144dc882 found." >&2
        echo "       This fix targets the ALC298 variant on NP940XFG-KC1*." >&2
        echo "       Check 'cat /sys/class/sound/hwC*D*/subsystem_id' for your codec ID." >&2
        exit 1
    fi
fi

echo "Hardware check passed: $VENDOR $PRODUCT, ALC298 SSID 0x144dc882"
echo ""

# ---------------------------------------------------------------------------
# Dependency: alsa-tools (provides hda-verb)
# ---------------------------------------------------------------------------
if ! command -v hda-verb >/dev/null 2>&1; then
    echo "Installing alsa-tools (provides hda-verb)..."
    if [ -n "$PKG_INSTALL" ]; then
        $PKG_INSTALL $ALSA_TOOLS_PKG || {
            echo "ERROR: failed to install $ALSA_TOOLS_PKG. Install it manually and re-run." >&2
            exit 1
        }
    else
        echo "ERROR: unknown package manager — install $ALSA_TOOLS_PKG manually and re-run." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Install files
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing init script..."
install -m 755 "${SCRIPT_DIR}/alc298-amp-init.sh"        /usr/local/sbin/alc298-amp-init.sh

echo "Installing systemd boot service..."
install -m 644 "${SCRIPT_DIR}/alc298-amp-init.service"   /etc/systemd/system/alc298-amp-init.service

echo "Installing system-sleep resume hook..."
mkdir -p /lib/systemd/system-sleep
install -m 755 "${SCRIPT_DIR}/alc298-amp-init-sleep.sh"  /lib/systemd/system-sleep/alc298-amp-init

echo "Installing udev rule..."
install -m 644 "${SCRIPT_DIR}/99-alc298-amp-init.rules" /etc/udev/rules.d/99-alc298-amp-init.rules

systemctl daemon-reload
udevadm control --reload-rules

# ---------------------------------------------------------------------------
# Fire once now so the user has working speakers without rebooting
# ---------------------------------------------------------------------------
echo "Activating speaker amps now..."
if /usr/local/sbin/alc298-amp-init.sh; then
    echo "✓ Speaker amps initialized"
else
    echo "WARNING: amp init failed — check 'journalctl -t alc298-amp-init'"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Internal speakers should now be working. Test with:"
echo "    speaker-test -D plughw:0,0 -c 2 -t pink -l 1"
echo ""
echo "The init will re-run automatically:"
echo "    - at every boot              (alc298-amp-init.service)"
echo "    - after resume from suspend  (system-sleep hook)"
echo ""
echo "If you upgrade to a kernel that includes upstream support for SSID"
echo "0x144dc882 (planned for submission to alsa-devel), you can remove this"
echo "workaround with:  sudo bash $(cd "$(dirname "$0")" && pwd)/uninstall.sh"
