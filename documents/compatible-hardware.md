# Samsung Galaxy Book — Linux Fix Compatibility


| Symbol | Meaning |
|--------|---------|
| ✅ | Confirmed working |
| 🔵 | Likely works — reported by users but not hardware-verified |
| 🟡 | Untested — fix is available, results unknown |
| ➖ | Not applicable to this model |
| 🔕 | Not needed — works without the fix |

---

## Galaxy Book 5 — Lunar Lake (Core Ultra 2xx) · IPU7

| Model | Name | Fn Keys | Fan Speed | Fingerprint | Webcam Toggle | Webcam Fix | Speaker | Mic | Copilot Key |
|-------|------|:-------:|:---------:|:-----------:|:-------------:|:----------:|:-------:|:---:|:-----------:|
| 940XHA | Book 5 Pro 14" | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 🔕 | ✅ |
| 960XHA | Book 5 Pro 16" | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 🔕 | ✅ |
| 960QHA | Book 5 Pro 360 | 🟡 | 🟡 | 🟡 | 🟡 | 🔵 | 🟡 | 🟡 | 🟡 |
| 750XHD | Book 5 15" | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 |
| 754XHD | Book 5 15" | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 |
| 750QHA | Book 5 360 15" | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 |
| 754QHA | Book 5 360 15" | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 |

**Notes:**
- 940XHA / 960XHA: mic confirmed working after speaker fix — mic fix not needed (hidden in GUI)
- 960QHA: webcam rotation fix reported working by Book 5 360 users but not hardware-verified (🔵)
- Function Key Fix is Book 5 specific — patches ACPI notification codes unique to Lunar Lake hardware
- Copilot Key Fix is part of the Function Key Fix — applied automatically on Book 5 installs
- Webcam Fix uses the `webcam-fix-book5` (IPU7 / intel_cvs) path
- OV02C10 Clock Fix not applicable — Book 5 uses IPU7 with OV02E10 sensor

---

## Galaxy Book 4 — Meteor Lake (14th Gen) · IPU6

| Model | Name | Fn Keys | Fan Speed | Fingerprint | Webcam Fix | OV02C10 Fix | Speaker | Mic |
|-------|------|:-------:|:---------:|:-----------:|:----------:|:-----------:|:-------:|:---:|
| 940XGK | Book 4 Pro 14" | 🔕 | ✅ | ✅ | ✅ | 🟡 | ✅ | ✅ |
| 944XGK | Book 4 Pro 14" (Ultra 9) | 🔕 | ✅ | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 |
| 960XGK | Book 4 Pro 16" | 🔕 | ✅ | ✅ | ✅ | 🟡 | ✅ | ✅ |
| 964XGK | Book 4 Pro 16" (Ultra 9) | 🔕 | ✅ | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 |
| 960QGK | Book 4 Pro 360 | 🔕 | ✅ | ✅ | ✅ | 🟡 | ✅ | ✅ |
| 750QGK | Book 4 360 15" | 🔕 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 |
| 940QGK | Book 4 360 14" | 🔕 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 |
| 960XMB | Book 4 Ultra | 🔕 | ✅ | 🟡 | 🟡 | 🟡 | ✅ | ✅ |
| 960XMA | Book 4 Ultra | 🔕 | ✅ | 🟡 | 🟡 | 🟡 | ✅ | ✅ |
| 960XGL | Book 4 Ultra | 🔕 | ✅ | 🟡 | ✅ | ✅ | ✅ | ✅ |

**Notes:**
- Function Key Fix not needed on Book 4 — function keys are handled by the mainline `samsung-galaxybook` kernel driver (Joshua Grisham's work, merged upstream). Shown as 🔕 not ➖ because the keys do work, just not via our fix
- 960XGL confirmed to need the OV02C10 26 MHz Clock Fix and the camera rotation fix
- 960QGK (Book 4 Pro 360) — webcam fix and camera rotation fix confirmed working (community-confirmed, Ubuntu 24.04.2, kernel 6.17.0)
- 750QGK / 940QGK (non-Pro base models) — fingerprint sensor may be Elan instead of Egis depending on region/SKU
- Webcam Fix uses the `webcam-fix-libcamera` (IPU6) path

---

## Galaxy Book 3 — Raptor Lake (13th Gen) · IPU6

| Model | Name | Fn Keys | Fan Speed | Fingerprint | Webcam Fix | OV02C10 Fix | Speaker | Mic |
|-------|------|:-------:|:---------:|:-----------:|:----------:|:-----------:|:-------:|:---:|
| 940XFG | Book 3 Pro 14" | ➖ | ➖ | ✅ | ✅ | 🟡 | ➖ | ➖ |
| 960XFG | Book 3 Pro 16" | ➖ | ➖ | ✅ | ✅ | 🟡 | ➖ | ➖ |
| 965XFG | Book 3 Pro 16" (i9) | ➖ | ➖ | 🟡 | 🟡 | 🟡 | ➖ | ➖ |
| 960QFG | Book 3 Pro 360 16" | ➖ | ➖ | ✅ | ✅ | 🟡 | ➖ | ➖ |
| 965QFG | Book 3 Pro 360 16" (i9) | ➖ | ➖ | 🟡 | 🟡 | 🟡 | ➖ | ➖ |
| 960XFH | Book 3 Ultra | ➖ | ➖ | 🟡 | 🟡 | 🟡 | ➖ | ➖ |
| 950XFG | Book 3 Pro | ➖ | ➖ | 🟡 | 🟡 | 🟡 | ➖ | ➖ |
| 930XED | Book 3 360 | ➖ | ➖ | 🟡 | 🟡 | 🟡 | ➖ | ➖ |
| 950XED | Book 3 360 | ➖ | ➖ | 🟡 | 🟡 | 🟡 | ➖ | ➖ |
| 960XED | Book 3 360 | ➖ | ➖ | 🟡 | 🟡 | 🟡 | ➖ | ➖ |
| 930QED | Book 3 360 | ➖ | ➖ | 🟡 | 🟡 | 🟡 | ➖ | ➖ |
| 950QED | Book 3 360 | ➖ | ➖ | 🟡 | 🟡 | 🟡 | ➖ | ➖ |
| 930MBE | Book 3 | ➖ | ➖ | 🟡 | 🟡 | 🟡 | ➖ | ➖ |
| 950XDB | Book 3 | ➖ | ➖ | 🟡 | 🟡 | 🟡 | ➖ | ➖ |

**Notes:**
- Function Key Fix not applicable — the Book 3 ACPI notification codes differ from Book 5 and are not yet researched
- Speaker fix not applicable — Book 3 uses ALC298 HDA codec, handled by the kernel quirk (see below)
- Fan Speed fix not yet confirmed on Book 3 — excluded until tested
- Mic fix not yet confirmed on Book 3 — excluded until tested
- OV02C10 26 MHz Clock Fix may be needed if webcam fails to probe — check `dmesg | grep ov02c10`
- Webcam Fix uses the `webcam-fix-libcamera` (IPU6) path

---

## Galaxy Book 6 — Arrow Lake (15th Gen) · IPU8

Not yet supported. IPU8 camera stack not yet available in mainline Linux.

| Model | Name |
|-------|------|
| 760VJG | Book 6 |
| 940XJG | Book 6 Pro 14" |
| 960XJG | Book 6 Pro 16" |
| 964XJG | Book 6 Pro 16" |
| 960UJH | Book 6 Pro 360 |

---

## Fix Summary by Series

| Fix | Book 5 | Book 4 | Book 3 |
|-----|:------:|:------:|:------:|
| Function Key Fix | ✅ / 🟡 | 🔕 | ➖ |
| Copilot Key Fix | ✅ / 🟡 | ➖ | ➖ |
| Fan Speed Fix | ✅ / 🟡 | ✅ / 🟡 | ➖ |
| Fingerprint Fix | ✅ / 🟡 | ✅ / 🟡 | ✅ / 🟡 |
| Webcam Toggle | ✅ / 🟡 | ➖ | ➖ |
| Webcam Fix (libcamera IPU6) | ➖ | ✅ / 🟡 | ✅ / 🟡 |
| Webcam Fix (intel_cvs IPU7) | ✅ / 🟡 | ➖ | ➖ |
| OV02C10 26 MHz Fix | ➖ | ✅ / 🟡 | 🟡 |
| Speaker Fix (MAX98390) | ✅ / 🟡 | ✅ / 🟡 | ➖ |
| Mic Fix | 🔕 / 🟡 | ✅ / 🟡 | ➖ |

---

## Speaker Fix — Book 3

Galaxy Book 3 uses a **Realtek ALC298 HDA codec** rather than the MAX98390 I2C chip used in Book 4 and Book 5. The kernel contains the fix (`ALC298_FIXUP_SAMSUNG_AMP_V2_4_AMPS` quirk, merged ~kernel 6.12), but not all Book 3 subsystem IDs are in the quirk table yet.

The fix is a single modprobe line:

```
options snd-hda-intel model=alc298-samsung-amp-v2-4-amps
```

**Important:** This requires a full power off and back on (cold boot), not just a reboot.

| Subsystem ID | Model | In kernel? |
|---|---|:---:|
| 0x144d:0xc886 | Book 3 Pro 16" (960XFG) | ✅ |
| 0x144d:0xc1ca | Book 3 Pro 360 (960QFG) | ✅ |
| 0x144d:0xc1cb | Book 3 Pro 360 (965QFG) | ✅ |
| 0x144d:0xc1cc | Book 3 Ultra (960XFH) | ✅ |
| 0x144d:0xc882 | Book 3 Pro 14" (940XFG) | ❌ Missing — modprobe fix essential |

---

## Hardware Sensor Reference

### Fingerprint Sensors

| USB ID | Chip | Series |
|--------|------|--------|
| 1c7a:05a5 | Egismoc ETU905A80-E (MoC) | Book 5, some Book 4 Ultra |
| 1c7a:05a1 | Egismoc ETU905A80-E (MoC) | Book 4 Pro/360, some Book 3 |

### Camera Sensors

| Sensor | Driver | Series | IPU |
|--------|--------|--------|-----|
| OV02C10 | ov02c10 | Book 3, Book 4 | IPU6 |
| OV02E10 | ov02e10 | Book 5 Pro | IPU7 |

### Speaker Amplifiers

| Chip | Interface | Series | Fix |
|------|-----------|--------|-----|
| MAX98390 | I2C | Book 4, Book 5 | Speaker Fix (DKMS) |
| ALC298 | HDA | Book 3 | Kernel quirk / modprobe |

---

*If your model is missing or you can confirm a fix works on an untested model, please open an issue on the GitHub repository.*
