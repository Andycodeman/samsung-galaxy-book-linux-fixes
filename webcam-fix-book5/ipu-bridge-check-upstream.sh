#!/bin/bash
# Check which installed kernels' in-tree ipu-bridge module already has the
# Samsung camera rotation DMI quirk entries. The DKMS workaround is removed
# from each kernel that has them; once every installed kernel (the running one
# included) has them, this script auto-removes the whole workaround.
#
# On the boot where upstream is first detected on every kernel:
#   - Camera already works (our DKMS module loaded earlier in boot)
#   - This script removes DKMS package, services, check script
#   - Next reboot uses the native kernel module instead

DKMS_NAME="ipu-bridge-fix"

log() { echo "ipu-bridge-check: $*"; }

# Detect installed version from DKMS rather than hardcoding — the installed
# version may differ from what this script was originally shipped with.
DKMS_VER=$(dkms status 2>/dev/null \
    | grep "^${DKMS_NAME}" \
    | grep -oP "${DKMS_NAME}/\K[0-9.]+" \
    | head -1 || true)
[ -n "$DKMS_VER" ] || { log "${DKMS_NAME} not installed via DKMS — nothing to check"; exit 0; }

# Decompress and check for Samsung DMI string
decompress_module() {
    local mod="$1"
    case "$mod" in
        *.zst)  zstdcat "$mod" 2>/dev/null ;;
        *.xz)   xzcat "$mod" 2>/dev/null ;;
        *.gz)   zcat "$mod" 2>/dev/null ;;
        *)      cat "$mod" 2>/dev/null ;;
    esac
}

DMI_PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "940XHA")

# Check every kernel the DKMS module is installed for, not just the running
# one: remove it only from kernels whose own (in-tree) ipu-bridge has the
# Samsung quirk. Another installed kernel, such as an older LTS kernel in the
# boot menu, keeps it until it gets the fix too. The running kernel is always
# checked, so the whole workaround is never removed while it lacks the fix.
STILL_NEEDED=""
for kdir in /lib/modules/*/; do
    k=$(basename "$kdir")
    # A DKMS entry left behind by a removed kernel doesn't count
    [ -d "/lib/modules/$k/kernel" ] || continue
    INSTALLED=false
    dkms status "${DKMS_NAME}/${DKMS_VER}" -k "$k" 2>/dev/null | grep -q ": installed" && INSTALLED=true
    $INSTALLED || [ "$k" = "$(uname -r)" ] || continue

    # The kernel's own ipu-bridge module (in kernel/ tree, NOT updates/)
    NATIVE_MODULE=$(find "/lib/modules/$k/kernel" -name "ipu-bridge*" 2>/dev/null | head -1)
    if [ -n "$NATIVE_MODULE" ] && decompress_module "$NATIVE_MODULE" | strings | grep -q "$DMI_PRODUCT"; then
        if $INSTALLED; then
            log "In-tree ipu-bridge in $k has the Samsung rotation fix — removing the DKMS copy for $k"
            dkms remove "${DKMS_NAME}/${DKMS_VER}" -k "$k" 2>/dev/null || true
        fi
    else
        log "In-tree ipu-bridge in $k does not have Samsung rotation fix — DKMS still needed there"
        STILL_NEEDED="$STILL_NEEDED $k"
    fi
done

if [ -n "$STILL_NEEDED" ]; then
    log "Keeping the DKMS workaround for:$STILL_NEEDED"
    exit 0
fi

# --- Every installed kernel has the fix: auto-remove DKMS workaround ---
log "=== SAMSUNG ROTATION FIX DETECTED in native ipu-bridge of every installed kernel ==="
log "Auto-removing DKMS workaround..."

# Disable this check service (remove ourselves)
systemctl disable ipu-bridge-check-upstream.service 2>/dev/null || true

# Remove ipu-bridge-fix DKMS module
if dkms status "${DKMS_NAME}/${DKMS_VER}" 2>/dev/null | grep -q "${DKMS_NAME}"; then
    log "Removing ipu-bridge-fix DKMS module..."
    dkms remove "${DKMS_NAME}/${DKMS_VER}" --all 2>/dev/null || true
fi

# Remove legacy ov02e10-fix DKMS if present (no longer installed by installer)
if dkms status "ov02e10-fix/1.0" 2>/dev/null | grep -q "ov02e10-fix"; then
    log "Removing legacy ov02e10-fix DKMS module..."
    dkms remove "ov02e10-fix/1.0" --all 2>/dev/null || true
fi
rm -rf "/usr/src/ov02e10-fix-1.0"

# Remove installed files
rm -f /etc/systemd/system/ipu-bridge-check-upstream.service
rm -f /usr/local/sbin/ipu-bridge-check-upstream.sh
rm -rf "/usr/src/${DKMS_NAME}-${DKMS_VER}"

# Rebuild module dependency map so kernel's original modules are used
depmod -a

systemctl daemon-reload

log "Done. Native kernel ipu-bridge will take over on next reboot."
log "Camera continues working this session via already-loaded module."
