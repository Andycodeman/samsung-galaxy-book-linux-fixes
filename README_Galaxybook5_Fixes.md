## Samsung Galaxy Book 5, Book 4 and Book 3 — Linux Fixes

Fixes for hardware that doesn't work out of the box on Linux for the Samsung Galaxy Book 5, Book 4, and Book 3 laptops. Confirmed working on **Galaxy Book 5 Pro 940XHA** (Fedora 43 KDE) — should also work on the 960XHA, 360 960QHA, Galaxy Book 4 series, and Galaxy Book 3 series with the same hardware, but only the 940XHA has been directly verified.

> **Disclaimer:** These fixes involve patching ACPI tables, loading kernel modules, and running scripts with root privileges. While they are designed to be safe and reversible, they are provided **as-is with no warranty**. **Use at your own risk.** It is recommended to have a recent backup and know how to access recovery mode before proceeding.

---

## Quick Install

```bash
git clone https://github.com/david-bartlett/samsung-galaxybook5-fixes
cd samsung-galaxybook5-fixes
bash samsung-galaxybook-gui
```

Or after downloading the repository, click the **samsung-galaxybook-fixes.desktop** file.

The GUI launcher will:
1. Check for required dependencies (`python3-gobject`, `pkexec`)
2. On **first run only**, prompt for authentication to install a polkit policy file — a one-time step that allows the GUI to run with elevated privileges for the session
3. Prompt for authentication (password or fingerprint) to launch the GUI
4. Open the graphical interface shown below

<p align="center"><img src="documents/screenshot.png" width="50%"></p>

The app will give you the option to install and uninstall the **samsung-galaxybook-fixes.desktop** shortcut to your system menu and desktop.

The GUI shows the install status of each fix and lets you install or uninstall them individually or all at once. Terminal output from each operation is shown in the output panel. Use the **Copy** button to copy the output to the clipboard.

---

## What's Included

### [1] Function Key Fix — DKMS Kernel Module

Five function keys do not work under Linux out of the box:

| Key | Function |
|-----|----------|
| F1  | Settings |
| F4  | Display Switch |
| F9  | Keyboard Backlight Cycle |
| F10 | Mic Mute |
| F11 | Webcam Toggle |

This fix downloads the `samsung-galaxybook` driver source from kernel.org, applies a patch to handle the missing ACPI notify codes and i8042 scancode sequence for F4, and installs it via DKMS. The module auto-rebuilds on kernel updates and auto-removes itself when the patches are merged upstream.

Also includes the **Copilot Key Fix** — the dedicated Copilot key between right Alt and Ctrl can be bound as `Meta+Shift+F23` in KDE and other DEs.

> **Galaxy Book 5 only** — Book 4 uses the mainline kernel driver (6.14+).

> **After rebooting**, two keyboard shortcuts must be configured manually in **System Settings → Shortcuts → Custom Shortcuts**:
>
> | Key | Action | Command |
> |-----|--------|---------|
> | F1  | System Settings | `systemsettings` |
> | F11 | Webcam Toggle *(if installed)* | `/usr/local/bin/webcam-toggle.sh` |
> | Copilot | Any action | bind as `Meta+Shift+F23` |

### [2] Hardware Webcam Toggle

Physically enables and disables the camera sensor at driver level by binding and unbinding the sensor driver. The camera is genuinely inaccessible to all applications when disabled.

- Checks the privacy LED before disabling — will not disable if the camera is actively streaming
- Lockfile prevents double-press race condition on F11
- Sends notifications via KDE OSD (`qdbus6`) or `notify-send`
- Resets to unblocked state on boot via a systemd service

> **Galaxy Book 5 only.** Requires kernel **6.17+** due to the IPU7 camera stack.

### [2b] Webcam Fix — IPU6 / IPU7 Pipeline

Installs the full camera pipeline required for the webcam to function in applications:

- **Book 5 (IPU7 / Lunar Lake)** — `intel_cvs` DKMS vision driver, ACPI SSDT rotation fix (or ipu-bridge DKMS fallback when Secure Boot is on), patched libcamera bayer order fix, and libcamera pipeline
- **Book 4 (IPU6 / Meteor Lake)** — IVSC kernel modules + IPU6 libcamera stack
- **Book 3 (IPU6 / Raptor Lake)** — IVSC kernel modules + IPU6 libcamera stack

### [2c] OV02C10 26 MHz Clock Fix — Galaxy Book 4 (Raptor Lake)

On some Galaxy Book 4 models (Raptor Lake / IPU6), the camera sensor fails to probe at boot with the error `external clock 26000000 is not supported`. This fix installs a patched `ov02c10` DKMS module that accepts both 19.2 MHz and 26 MHz external clocks.

### [3] Fan Speed Fix — ACPI DSDT Override

The Samsung BIOS contains a bug in the `_FST` ACPI method that causes fan speed reporting to fail on Linux kernels 6.11+. This fix patches the DSDT at install time and embeds the corrected table into the initramfs. The patch reads the firmware's own `FANT` speed table dynamically at runtime.

> **Secure Boot must be disabled** for the fan speed fix — kernel lockdown blocks ACPI table overrides from the initramfs.

> **BitLocker users:** Save your recovery key before disabling Secure Boot: https://account.microsoft.com/devices/recoverykey

### [4] Fingerprint Fix — libfprint sdcp-v2

The egismoc fingerprint sensor (`1c7a:05a5` on Book 5, `1c7a:05a1` on Book 4) uses the SDCP handshake protocol which is not supported by the stable libfprint release. This fix builds the `feature/sdcp-v2` branch from source and installs it. A monitor service watches for package manager updates that would overwrite the fix.

> **Dual-boot Windows users:** Remove enrolled fingerprints from Windows Hello and disable the fingerprint driver in Device Manager before installing this fix.

After rebooting, enable fingerprint authentication:
- **Fedora:** `sudo authselect enable-feature with-fingerprint`
- **Ubuntu:** `sudo pam-auth-update`
- **Arch:** See [full documentation](documents/samsung-galaxybook-linux-fixes.md)

Then enrol fingerprints: `fprintd-enroll` or **System Settings → Users → Fingerprint Login**

### [5] Speaker Fix — MAX98390 HDA Driver

Galaxy Book 4 and Book 5 use Maxim MAX98390 amplifiers which the standard HDA codec driver does not support. This fix installs a DKMS kernel module (`max98390-hda`) that provides HDA codec support for these amplifiers. Only installed if MAX98390 hardware is detected.

### [6] Mic Fix — SOF Firmware Update

The internal DMIC on Galaxy Book 4 (Meteor Lake) and Book 5 (Lunar Lake) requires a recent version of Intel SOF firmware. This fix downloads SOF firmware v2025.12.1+ and sets `dsp_driver=3`. Automatically skipped if the installed SOF firmware is already new enough.

### [7] KDE Power Profile OSD

KDE Plasma does not show an on-screen notification for automatic power profile changes (e.g. switching to Power Saver when unplugging AC). This fix installs a lightweight systemd service that monitors the `net.hadess.PowerProfiles` D-Bus interface and triggers the native KDE OSD.

> **KDE only** — hidden automatically on other desktop environments.

---

## Compatible Hardware

| Model | Status |
|-------|--------|
| Galaxy Book 5 Pro 940XHA (14") | ✅ Confirmed — all fixes |
| Galaxy Book 5 Pro 960XHA (16") | ✅ Confirmed — webcam fix (community) |
| Galaxy Book 5 Pro 360 960QHA | 🔵 Expected working |
| Galaxy Book 5 15" 750XHD, 754XHD | 🔵 Expected working |
| Galaxy Book 5 360 15" 750QHA, 754QHA | 🔵 Expected working |
| Galaxy Book 4 Pro 360 960QGK | ✅ Confirmed — webcam + rotation fix (community) |
| Galaxy Book 4 Pro 940XGK, 960XGK, 964XGK | 🔵 Expected working |
| Galaxy Book 4 Ultra 960XGL | 🔵 OV02C10 clock fix + rotation fix expected |
| Galaxy Book 3 940XFG, 960XFG, 960QFG | 🔵 Webcam + fingerprint code paths in place |
| Galaxy Book 6 | ❌ Not supported (IPU8) |

## Supported Distributions

| Distro | Status |
|--------|--------|
| Fedora (kernel 6.13+) | ✅ Tested |
| Ubuntu / Debian-based (kernel 6.13+) | ⚠️ Expected to work |
| Arch Linux (rolling) | ⚠️ Code paths included |

Minimum kernel: **6.13**. Exception: webcam toggle on Galaxy Book 5 requires **6.17+**.

---

## Boot Monitor Services

Each fix installs an independent systemd service that self-removes when no longer needed:

| Service | Trigger | Action |
|---------|---------|--------|
| `samsung-galaxybook-fkeys-monitor.service` | Kernel update | Removes DKMS module if patches merged upstream |
| `samsung-galaxybook-fan-monitor.service` | BIOS update | Removes DSDT override if Samsung natively fixed `_FST` |
| `samsung-galaxybook-fprint-monitor.service` | libfprint update | Removes fix if system libfprint gains native sensor support |
| `max98390-hda-check-upstream.service` | Kernel update | Removes DKMS module if native MAX98390 HDA support lands upstream |
| `ipu-bridge-check-upstream.service` | Kernel update (Book 5) | Removes DKMS module if IPU7 bridge fix is merged upstream |

---

## Documentation

- [samsung-galaxybook-linux-fixes-summary.md](documents/samsung-galaxybook-linux-fixes-summary.md) — overview and quick reference
- [samsung-galaxybook-linux-fixes.md](documents/samsung-galaxybook-linux-fixes.md) — full technical documentation

---

## Credits

- **[Joshua Grisham](https://github.com/joshuagrisham)** — `feature/sdcp-v2` branch of libfprint providing SDCP support for the egismoc fingerprint sensor

- **[Andycodeman](https://github.com/Andycodeman)** — Extensive work on speaker and webcam fixes for the Samsung Galaxy Book series, documented at [samsung-galaxy-book4-linux-fixes](https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes). The MAX98390 HDA speaker driver, IPU6 webcam fix, IPU7 webcam fix, mic fix, and OV02C10 clock fix are incorporated from his repo.

## Related

- [samsung-galaxybook-extras](https://github.com/joshuagrisham/samsung-galaxybook-extras) — Samsung Galaxy Book platform driver and DSDT fan speed fix research
- [samsung-galaxy-book4-linux-fixes](https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes) — Speaker and webcam fixes for Galaxy Book 4/5

## License

GPL-2.0 — Free to use, modify, and redistribute. Derivative works must use the same license.
