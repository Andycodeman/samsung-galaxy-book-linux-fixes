#!/bin/bash
# cam-rot-check-upstream.sh
# Samsung Galaxy Book — camera rotation ACPI override upstream monitor
#
# Checks whether the running kernel's in-tree ipu-bridge module already has
# the Samsung camera rotation DMI quirk entries. When upstream merges the fix,
# this script auto-removes the cam-rot.aml ACPI SSDT override and rebuilds
# the initramfs so the native kernel handles rotation correctly.
#
# On the boot where upstream is first detected:
#   - Camera rotation still works (cam-rot.aml loaded earlier in boot)
#   - This script removes cam-rot.aml, cleans up initramfs config if empty,
#     rebuilds initramfs, and disables itself
#   - Next reboot uses the native kernel rotation fix instead

SSDT_ROTATION_AML="/etc/acpi_override/cam-rot.aml"

log() { echo "cam-rot-check: $*"; logger -t cam-rot-check-upstream "$*"; }

# Only run if our ACPI override is actually installed
if [[ ! -f "$SSDT_ROTATION_AML" ]]; then
    log "cam-rot.aml not installed — nothing to check"
    exit 0
fi

# Find the kernel's own ipu-bridge module (in kernel/ tree, NOT updates/)
NATIVE_MODULE=$(find "/lib/modules/$(uname -r)/kernel" -name "ipu-bridge*" 2>/dev/null | head -1)

if [[ -z "$NATIVE_MODULE" ]]; then
    log "No in-tree ipu-bridge module found in $(uname -r) — ACPI override still needed"
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
    log "In-tree ipu-bridge in $(uname -r) does not have Samsung rotation fix — ACPI override still needed"
    exit 0
fi

# --- Upstream has the fix: auto-remove ACPI override ---
log "=== SAMSUNG ROTATION FIX DETECTED in native ipu-bridge ($(uname -r)) ==="
log "Auto-removing cam-rot.aml ACPI override..."

# Remove cam-rot.aml
rm -f "$SSDT_ROTATION_AML"
log "Removed $SSDT_ROTATION_AML"

# Clean up initramfs ACPI config if acpi_override dir is now empty
# (guard: don't remove if fan fix's dsdt_fixed.aml is still present)
if [[ -z "$(ls /etc/acpi_override/ 2>/dev/null)" ]]; then
    rmdir /etc/acpi_override 2>/dev/null || true
    rm -f /etc/dracut.conf.d/acpi.conf
    rm -f /etc/mkinitcpio.conf.d/acpi_override.conf
    rm -f /etc/initcpio/hooks/acpi_override
    rm -f /etc/initcpio/install/acpi_override
    log "Removed ACPI override initramfs config (no other AML files present)"
else
    log "/etc/acpi_override/ still has files (fan fix present) — initramfs config kept"
fi

# Rebuild initramfs
log "Rebuilding initramfs..."
if command -v dracut >/dev/null 2>&1; then
    dracut --force 2>/dev/null && log "initramfs rebuilt (dracut)" || log "WARNING: dracut rebuild failed"
elif command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k "$(uname -r)" 2>/dev/null && log "initramfs rebuilt (update-initramfs)" || log "WARNING: update-initramfs failed"
elif command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P 2>/dev/null && log "initramfs rebuilt (mkinitcpio)" || log "WARNING: mkinitcpio failed"
else
    log "WARNING: Could not find initramfs tool — rebuild manually"
fi

# Notify the user
_user=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 == "seat0" {print $3}' | head -1)
_uid=$(id -u "$_user" 2>/dev/null)
if [[ -n "$_uid" ]]; then
    _msg="The upstream kernel ($(uname -r)) now includes the Samsung camera rotation fix natively. The ACPI override (cam-rot.aml) has been removed. Camera rotation will continue to work via the kernel on next reboot."
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_uid}/bus" \
        sudo -u "$_user" notify-send "Samsung Galaxy Book — Camera Rotation Fix" "$_msg" 2>/dev/null || true
fi

# Disable and remove this service
systemctl disable cam-rot-check-upstream.service 2>/dev/null || true
rm -f /etc/systemd/system/cam-rot-check-upstream.service
rm -f /usr/local/sbin/cam-rot-check-upstream.sh
systemctl daemon-reload 2>/dev/null || true

log "Done. Native kernel ipu-bridge rotation fix will be active on next reboot."
