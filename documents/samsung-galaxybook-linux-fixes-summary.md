# Samsung Galaxy Book 5, Book 4 and Book 3 — Linux Fixes Summary

Quick reference for the fixes in this repo. For full technical detail see [samsung-galaxybook-linux-fixes.md](samsung-galaxybook-linux-fixes.md).

---

## Quick Install

```bash
git clone https://github.com/david-bartlett/samsung-galaxybook5-fixes
cd samsung-galaxybook5-fixes
bash samsung-galaxybook-gui
```

The GUI launcher will:
1. Check for required dependencies (`python3-gobject`, `pkexec`)
2. On **first run only**, prompt for authentication to install a polkit policy file — a one-time step
3. Prompt for authentication to launch the GUI with elevated privileges
4. Open the graphical interface

The GUI shows the install status of each fix and lets you install or uninstall them individually or all at once. Terminal output from each operation is shown in the output panel. Use the **Copy** button to copy output to clipboard.

<p align="center"><img src="../documents/screenshot.png" width="50%"></p>

---

## What's Installed

### [1] Function Key Fix
Enables F1 (Settings), F4 (Display Switch), F9 (Keyboard Backlight), F10 (Mic Mute), and F11 (Webcam Toggle) via a patched DKMS kernel module. Downloads the `samsung-galaxybook` driver from kernel.org at install time and auto-rebuilds on kernel updates.

Also includes the **Copilot Key Fix** — enables the dedicated Copilot key (between right Alt and Ctrl) to be bound as a custom shortcut (`Meta+Shift+F23`) in KDE and other desktop environments.

> **Galaxy Book 5 only** — Book 4 uses the mainline kernel driver (6.14+).

### [2] Hardware Webcam Toggle
Physically enables and disables the camera sensor at driver level by binding/unbinding the sensor driver. Sends notifications via KDE OSD or `notify-send`. Resets to unblocked state on boot. Will not disable if the camera is actively streaming. Lockfile prevents double-press race condition.

> **Galaxy Book 5 only** — Book 4 has built-in camera/mic block via Fn+F10 in the mainline driver.

### [2b] Webcam Fix — IPU6 / IPU7 Pipeline
Installs the full camera pipeline required for the webcam to work in applications.
- **Book 5 (IPU7 / Lunar Lake)** — `intel_cvs` DKMS vision driver + IPU7 libcamera pipeline + bayer order fix + ACPI rotation fix
- **Book 4 (IPU6 / Meteor Lake)** — IVSC kernel modules + IPU6 libcamera stack
- **Book 3 (IPU6 / Raptor Lake)** — IVSC kernel modules + IPU6 libcamera stack

### [2c] OV02C10 26 MHz Clock Fix
Fixes camera sensor failing to probe on some Galaxy Book 4 (Raptor Lake / IPU6) models. Installs a patched `ov02c10` DKMS module that accepts both 19.2 MHz and 26 MHz external clocks.

> **Book 4 (Raptor Lake) only.**

### [3] Fan Speed Fix
Patches the ACPI DSDT to fix a Samsung BIOS bug that prevents fan RPM from reporting correctly on kernels 6.11+. Reads the firmware's own `FANT` speed table dynamically at runtime.

> **Secure Boot must be disabled.** Linux kernel lockdown mode blocks ACPI table overrides.

### [4] Fingerprint Fix
Builds the `feature/sdcp-v2` branch of libfprint from source to fix SDCP handshake failures on the egismoc sensor (`1c7a:05a5` / `1c7a:05a1`). A monitor service detects if a package manager update overwrites the fix.

### [5] Speaker Fix
Installs the `max98390-hda` DKMS kernel module to enable the built-in speakers on Galaxy Book 4 and Book 5. Only installed if MAX98390 hardware is detected.

### [6] Mic Fix
Updates Intel SOF firmware to v2025.12.1+ and sets `dsp_driver=3` to enable the internal DMIC. Automatically skipped if the installed SOF firmware is already new enough.

### [7] KDE Power Profile OSD
Monitors the `net.hadess.PowerProfiles` D-Bus interface and shows an OSD notification whenever the power profile changes (e.g. switching to Power Saver on AC unplug). Uses native KDE OSD via `qdbus6`, falling back to `notify-send`.

> **KDE only** — the service detects the desktop environment at runtime and exits silently on other DEs. The fix card is hidden in the GUI on non-KDE desktops.

---

## Compatible Hardware

| Model | Status |
|-------|--------|
| Galaxy Book 5 Pro 940XHA (14") | ✅ Confirmed working — all fixes |
| Galaxy Book 5 Pro 960XHA (16") | ✅ Confirmed working — webcam confirmed (community) |
| Galaxy Book 5 Pro 360 960QHA | 🔵 Expected working — same hardware family |
| Galaxy Book 5 15" 750XHD, 754XHD | 🔵 Expected working — same IPU7 family |
| Galaxy Book 5 360 15" 750QHA, 754QHA | 🔵 Expected working — same IPU7 family |
| Galaxy Book 4 Pro 360 960QGK | ✅ Confirmed working — webcam + rotation fix confirmed (community) |
| Galaxy Book 4 Pro 940XGK, 960XGK, 964XGK | 🔵 Expected working — same IPU6 code path |
| Galaxy Book 4 Ultra 960XGL | 🔵 OV02C10 clock fix + rotation fix expected |
| Galaxy Book 3 940XFG, 960XFG, 960QFG | 🔵 Webcam + fingerprint code paths in place |
| Galaxy Book 6 | ❌ Not supported (IPU8 not yet in mainline Linux) |

For the full model-by-model compatibility matrix see `documents/compatible-hardware.md` or open the hardware compatibility editor (`python3 lib/hardware-compat-editor.py`).

## Supported Distributions

| Distro | Status |
|--------|--------|
| Fedora (kernel 6.13+) | ✅ Tested |
| Ubuntu / Debian-based (kernel 6.13+) | ⚠️ Untested — expected to work |
| Arch Linux (rolling) | ⚠️ Untested — code paths included |

Minimum kernel: **6.13** for all fixes. Exception: webcam toggle on Galaxy Book 5 requires **6.17+**.

---

## Required Actions After Reboot

### All users — Keyboard Shortcuts (Function Key Fix)

After installing the Function Key Fix, shortcuts must be configured in **System Settings → Shortcuts → Custom Shortcuts**:

| Key | Action | Command |
|-----|--------|---------|
| F1  | System Settings | `systemsettings` |
| F11 | Webcam Toggle *(if installed)* | `/usr/local/bin/webcam-toggle.sh` |
| Copilot | Any action *(bind as* `Meta+Shift+F23`*)* | e.g. `claude-desktop` |

### All users — Fan Speed Check (Fan Speed Fix)

```bash
cat $(find /sys/bus/acpi/devices/PNP*/ -name "fan_speed_rpm" | head -1)
```

### Fedora — Enable Fingerprint Authentication

```bash
sudo authselect enable-feature with-fingerprint
```

### Ubuntu — Enable Fingerprint Authentication

```bash
sudo pam-auth-update
```

### Arch — Enable Fingerprint Authentication

Manually add `auth sufficient pam_fprintd.so` to the top of the auth section in `/etc/pam.d/sudo`, `/etc/pam.d/system-local-login`, and `/etc/pam.d/kde-fingerprint`.

### All users — Enrol Fingerprints

```bash
fprintd-enroll
```

Or via **System Settings → Users → Fingerprint Login**

---

## Warnings

> ⚠️ **Fingerprint fix and dual-booting with Windows** — Remove enrolled fingerprints and disable Windows Hello fingerprint in Device Manager before installing. Failing to do so may cause Windows to crash on first boot.

> ⚠️ **Fan Speed Fix requires Secure Boot to be disabled.** Kernel lockdown mode blocks the ACPI DSDT override.

> ⚠️ **Webcam Fix (Book 5) and Secure Boot** — The webcam fix installs with Secure Boot enabled but falls back automatically from the ACPI SSDT rotation fix to the `ipu-bridge` DKMS module. To use the preferred ACPI method, disable Secure Boot, uninstall, and reinstall.

> ⚠️ **BitLocker users** — Save your recovery key before disabling Secure Boot: https://account.microsoft.com/devices/recoverykey

> ⚠️ **Do not select Webcam Toggle while the webcam is in use.** The script checks the privacy LED and will refuse to disable if the camera is actively streaming.
