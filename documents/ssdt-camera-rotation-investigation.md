# ACPI SSDT Camera Rotation Fix — Investigation Notes

**Date:** March 2026  
**Hardware:** Samsung Galaxy Book 5 Pro 940XHA (Lunar Lake / IPU7)  
**Status:** Proof of concept — working but not yet integrated into main install flow

---

## Background

The Samsung Galaxy Book 5 Pro 940XHA and 960XHA have their OV02E10 camera sensor mounted upside-down, but Samsung's BIOS incorrectly reports `rotation=0` in the ACPI SSDB (Sensor-Specific Data Buffer). This causes the webcam image to appear upside-down on Linux.

Andy's `webcam-fix-book5` fix addresses this via a DKMS-patched `ipu-bridge.ko` that adds Samsung DMI quirk entries to the kernel's upside-down sensor table. This investigation explored an alternative approach: patching the ACPI SSDT table directly so that ipu-bridge reads the correct rotation from the firmware without needing a kernel module patch.

---

## How the Rotation Value Flows

```
ACPI SSDT3 (MiCaTb/MiCaTabl)
  └── \_SB_.LNK0.SSDB() method
        └── PAR[0x54] = CDEG(L0DG)   ← degree value from NVS region
              └── ipu_bridge_parse_rotation() reads ssdb->degree
                    └── IPU_SENSOR_ROTATION_INVERTED (1) → returns 180°
                          └── libcamera sets HFlip+VFlip transform
                                └── bayer order recalculation needed
```

**Key findings:**
- `OVTI02E1` (OV02E10) is mapped to `\_SB_.LNK0` in SSDT3
- The SSDB is a `Method` (not a static buffer) that builds a 0x6C byte buffer
- The degree value is at `PAR[0x54]`, set via `CDEG(L0DG)` where `L0DG` is read from the `MNVS` NVS OperationRegion at physical address `0x6C05D000`, byte offset `0x182`
- `CDEG()` is a lookup table: index `0x04` → `0xB4` (180°), but ipu-bridge doesn't read the degree output of CDEG — it reads the raw index value
- ipu-bridge `ipu_bridge_parse_rotation()` only accepts `0` (normal) or `1` (inverted = 180°)
- Samsung's BIOS writes `L0DG = 0x00` (normal) — this is the bug

---

## The SSDT Override Approach

Rather than patching the kernel module, we override SSDT3 via the initramfs ACPI override mechanism (same infrastructure used by the fan speed fix).

**Patch:** In `\_SB_.LNK0.SSDB`, change:
```
PAR [0x54] = CDEG (L0DG)
```
to:
```
PAR [0x54] = 0x01
```

This hardcodes `IPU_SENSOR_ROTATION_INVERTED` directly, bypassing the NVS value entirely. ipu-bridge reads `degree=1` and correctly reports `rotation=180°` to libcamera.

### Steps to Recreate the Patch

```bash
mkdir -p ~/ssdb-investigate
sudo cat /sys/firmware/acpi/tables/SSDT3 > ~/ssdb-investigate/ssdt3.aml
cd ~/ssdb-investigate
iasl -d ssdt3.aml 2>/dev/null

# Verify line 4270 (may vary if BIOS updates)
sed -n '4270p' ssdt3.dsl

# Apply patch
sed '4270s/PAR \[0x54\] = CDEG (L0DG)/PAR [0x54] = 0x01/' ssdt3.dsl > ssdt3_patched.dsl
sed -i 's/0x00001000/0x00001001/' ssdt3_patched.dsl

# Compile
iasl -tc ssdt3_patched.dsl 2>/dev/null | grep -E "Error|Warning|successful"

# Verify before deploying
iasl -d ssdt3_patched.aml 2>/dev/null
grep -n "PAR \[0x54\]" ssdt3_patched.dsl | head -3
# Should show: PAR [0x54] = One

# Deploy into existing fan fix acpi_override directory
sudo cp ssdt3_patched.aml /etc/acpi_override/cam-rot.aml

# Rebuild initramfs (uses existing /etc/dracut.conf.d/acpi.conf from fan fix)
sudo dracut --force
```

### Important Notes
- The filename must be **18 characters or less** — the kernel's CPIO format rejects longer names silently
- The OEM revision must be bumped (`0x00001000` → `0x00001001`) for the kernel to prefer our table
- Both the fan fix DSDT (`dsdt_fixed.aml`) and camera fix SSDT (`cam-rot.aml`) coexist in `/etc/acpi_override/` — dracut loads them both
- The patch line number (4270) is specific to this BIOS version — verify after any BIOS update
- `/tmp` is tmpfs and is cleared on reboot — always work from `~/ssdb-investigate/`

---

## Limitations vs Andy's ipu-bridge DKMS Fix

| | SSDT Override | ipu-bridge DKMS |
|---|---|---|
| **Mechanism** | Patches firmware data at source | Adds DMI quirk to kernel driver |
| **Models supported** | 940XHA/960XHA only (BIOS-specific) | 940XHA/960XHA only (DMI-specific) |
| **Kernel updates** | Unaffected — ACPI override is kernel-agnostic | Needs DKMS rebuild on kernel update |
| **BIOS updates** | May need re-patching if line numbers change | Unaffected |
| **Secure Boot** | Works (ACPI overrides don't need signing) | Needs MOK key enrollment |
| **Portability** | Tied to this specific SSDT structure | Portable to any system with matching DMI |
| **Upstream path** | Could inform a proper BIOS fix report to Samsung | Ready to submit as upstream kernel patch |

---

## Colour Fix Still Required

Regardless of which rotation fix is used, the bayer order fix and tuning file are still needed:

- **Why:** The OV02E10 driver sets `V4L2_CTRL_FLAG_MODIFY_LAYOUT` on flip controls but never updates the media bus format code. libcamera's SoftISP debayer uses the wrong bayer order after rotation, producing purple/magenta tint.
- **Fix:** Patched libcamera (`libcamera-bayer-fix/build-patched-libcamera.sh`) + `ov02e10.yaml` tuning file
- **Note:** The `ov02e10.yaml` CCM was tuned specifically for the post-rotation-fix state. Without the rotation fix active, colours are correct without any yaml.

---

## Changes Made to `webcam-fix-book5/install.sh`

Three changes were made to Andy's install script to accommodate the SSDT approach and speed up installs on Fedora with RPM Fusion:

### 1. intel_cvs system package detection (Step 6)
Added `elif modinfo intel_cvs &>/dev/null` check before the DKMS download/build block. On Fedora with RPM Fusion's `intel-vision-drivers` package, this skips the entire DKMS process since the module is already available.

### 2. Skip ipu-bridge DKMS when SSDT fix is present (Step 7)
Added check after the DMI model detection:
```bash
SSDT_ROTATION_AML="/etc/acpi_override/cam-rot.aml"
if $NEEDS_ROTATION_FIX && [[ -f "$SSDT_ROTATION_AML" ]]; then
    NEEDS_ROTATION_FIX=false
fi
```
If `/etc/acpi_override/cam-rot.aml` exists, `NEEDS_ROTATION_FIX` is set to `false`, skipping the ipu-bridge DKMS build and its initramfs rebuild.

### 3. Bayer fix triggers on SSDT fix too (Step 8)
The bayer fix condition was extended from `$NEEDS_ROTATION_FIX` to also check for the SSDT override:
```bash
SSDT_ROTATION_ACTIVE=false
[[ -f "${SSDT_ROTATION_AML:-/etc/acpi_override/cam-rot.aml}" ]] && SSDT_ROTATION_ACTIVE=true

if [[ "$SENSOR" == "ov02e10" ]] && { $NEEDS_ROTATION_FIX || $SSDT_ROTATION_ACTIVE; }; then
```
This ensures the bayer fix and tuning file are still installed regardless of which rotation fix method is active.

### 4. Camera relay skipped by default (Step 13)
Added `INSTALL_CAMERA_RELAY` flag defaulting to `false`. To install the camera relay:
```bash
INSTALL_CAMERA_RELAY=true ./install.sh
```

---

## Current System State (940XHA test machine)

- `/etc/acpi_override/cam-rot.aml` — SSDT rotation fix deployed ✅
- `/etc/acpi_override/dsdt_fixed.aml` — fan speed fix (unchanged) ✅
- `/etc/dracut.conf.d/acpi.conf` — loads both AML files via dracut ✅
- ipu-bridge DKMS — not installed ✅
- intel_cvs — installed via RPM Fusion `intel-vision-drivers` ✅
- bayer fix (patched libcamera) — pending install ⬅️
- `ov02e10.yaml` tuning file — pending install ⬅️
