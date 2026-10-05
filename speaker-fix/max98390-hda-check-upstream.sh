#!/bin/bash
# Check if the running kernel has native MAX98390 HDA support.
# When upstream merges PR #5616, the stock kernel modules will handle
# everything — this script auto-removes the DKMS workaround.
#
# On the boot where upstream is first detected:
#   - Speakers already work (our modules loaded earlier in boot)
#   - This script removes DKMS, services, autoload config
#   - Next reboot uses the native kernel driver instead

DKMS_NAME="max98390-hda"
DKMS_VER="1.0"
UPSTREAM_READY=true

log() { echo "max98390-hda-check: $*"; }

if ! dkms status "${DKMS_NAME}/${DKMS_VER}" 2>/dev/null | grep -q "${DKMS_NAME}"; then
    log "${DKMS_NAME}/${DKMS_VER} not installed via DKMS — nothing to check"
    exit 0
fi

# Check 1: Does serial-multi-instantiate know about MAX98390?
SMI_MODULE=$(find "/lib/modules/$(uname -r)/kernel/drivers/platform/x86" -name "serial-multi-instantiate*" 2>/dev/null | head -1)
if [ -n "$SMI_MODULE" ]; then
    if ! modinfo "$SMI_MODULE" 2>/dev/null | grep -q "alias.*MAX98390"; then
        UPSTREAM_READY=false
        log "serial-multi-instantiate: missing MAX98390 support"
    fi
else
    UPSTREAM_READY=false
    log "serial-multi-instantiate: module not found"
fi

# Check 2: Does snd_hda_codec_alc269 have the max98390 fixup?
ALC_MODULE=$(find "/lib/modules/$(uname -r)/kernel/sound" -name "snd-hda-codec-alc269*" 2>/dev/null | head -1)
if [ -n "$ALC_MODULE" ]; then
    if ! zstdcat "$ALC_MODULE" 2>/dev/null | strings | grep -q "alc298-samsung-max98390"; then
        UPSTREAM_READY=false
        log "snd_hda_codec_alc269: missing MAX98390 quirk entries"
    fi
else
    UPSTREAM_READY=false
    log "snd_hda_codec_alc269: module not found"
fi

# Check 3: Is there a native snd-hda-scodec-max98390 in the kernel tree?
NATIVE_MODULE=$(find "/lib/modules/$(uname -r)/kernel/sound" -name "snd-hda-scodec-max98390*" 2>/dev/null | head -1)
if [ -z "$NATIVE_MODULE" ]; then
    UPSTREAM_READY=false
    log "snd-hda-scodec-max98390: not in kernel tree"
fi

if ! $UPSTREAM_READY; then
    log "upstream not available yet in $(uname -r) — DKMS workaround still needed"
    exit 0
fi

# --- All checks passed: native support is in this kernel ---
log "=== NATIVE SUPPORT DETECTED in $(uname -r) ==="
log "Auto-removing DKMS workaround..."

# Stop the I2C device setup service (speakers stay working this session
# because modules are already loaded in memory)
systemctl stop max98390-hda-i2c-setup.service 2>/dev/null || true
systemctl disable max98390-hda-i2c-setup.service 2>/dev/null || true

# Disable this check service too (remove ourselves)
systemctl disable max98390-hda-check-upstream.service 2>/dev/null || true

# Remove DKMS module
if dkms status "${DKMS_NAME}/${DKMS_VER}" 2>/dev/null | grep -q "${DKMS_NAME}"; then
    log "Removing DKMS module..."
    dkms remove "${DKMS_NAME}/${DKMS_VER}" --all 2>/dev/null || true
fi

# Remove installed files
rm -f /etc/systemd/system/max98390-hda-i2c-setup.service
rm -f /etc/systemd/system/max98390-hda-check-upstream.service
rm -f /etc/modules-load.d/max98390-hda.conf
rm -f /usr/local/sbin/max98390-hda-i2c-setup.sh
rm -f /usr/local/sbin/max98390-hda-check-upstream.sh
rm -rf "/usr/src/${DKMS_NAME}-${DKMS_VER}"

systemctl daemon-reload

log "Done. Native kernel driver will take over on next reboot."
log "Speakers continue working this session via already-loaded modules."
