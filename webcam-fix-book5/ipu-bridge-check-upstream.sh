#!/bin/bash
# Check if the running kernel's in-tree ipu-bridge module already has the
# Samsung camera rotation DMI quirk entries. When upstream merges the fix,
# this script auto-removes the DKMS workaround.
#
# On the boot where upstream is first detected:
#   - Camera already works (our DKMS module loaded earlier in boot)
#   - This script removes DKMS package, services, check script
#   - Next reboot uses the native kernel module instead

DKMS_NAME="ipu-bridge-fix"
# Detect installed version from DKMS rather than hardcoding — the installed
# version may differ from what this script was originally shipped with.
DKMS_VER=$(dkms status 2>/dev/null     | grep "^${DKMS_NAME}"     | grep -oP "${DKMS_NAME}/\K[0-9.]+"     | head -1 || true)

log() { echo "ipu-bridge-check: $*"; }

# Find the kernel's own ipu-bridge module (in kernel/ tree, NOT updates/)
NATIVE_MODULE=$(find "/lib/modules/$(uname -r)/kernel" -name "ipu-bridge*" 2>/dev/null | head -1)

if [ -z "$NATIVE_MODULE" ]; then
    log "No in-tree ipu-bridge module found in $(uname -r) — DKMS still needed"
    exit 0
fi

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
if ! decompress_module "$NATIVE_MODULE" | strings | grep -q "$DMI_PRODUCT"; then
    log "In-tree ipu-bridge in $(uname -r) does not have Samsung rotation fix — DKMS still needed"
    exit 0
fi

# --- Upstream has the fix: auto-remove DKMS workaround ---
log "=== SAMSUNG ROTATION FIX DETECTED in native ipu-bridge ($(uname -r)) ==="
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
