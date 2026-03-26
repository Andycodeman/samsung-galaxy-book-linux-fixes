# Fix: Samsung Galaxy Book5 Webcam on Arch / Fedora / Ubuntu (Intel IPU7 / OV02C10 / OV02E10 / Lunar Lake)

> **Confirmed working** on Samsung Galaxy Book5 Pro 940XHA (Fedora 43), 960XHA (Ubuntu 24.04), Galaxy Book5 360 (Fedora 42), Dell XPS 13 9350 (Arch), and Lenovo X1 Carbon Gen13 (Fedora 42). If you test on another model, please open an issue with your results.

**Status:** Confirmed working
**Supported distros:** Arch-based (CachyOS, Manjaro, EndeavourOS), Fedora 42+, and Ubuntu (with libcamera 0.5.2+ built from source)
**Hardware:** Intel IPU7 (Lunar Lake, PCI ID `8086:645d` or `8086:6457`), OV02C10 (`OVTI02C1`) or OV02E10 (`OVTI02E1`) sensor

---

## What This Fixes

The Samsung Galaxy Book5 (Lunar Lake) webcam doesn't work on Linux because:

1. **Missing `intel_cvs` kernel module** — The Intel Computer Vision Subsystem (CVS) module is required to power the camera sensor on IPU7, but it's not yet in the mainline kernel. Intel provides it via DKMS from their [vision-drivers](https://github.com/intel/vision-drivers) repo.
2. **LJCA modules don't auto-load** — The Lunar Lake Joint Controller for Accessories (`usb_ljca`, `gpio_ljca`) provides GPIO/USB control needed by the vision subsystem. These must load before `intel_cvs` and the sensor, but aren't auto-loaded on all systems.
3. **Missing userspace pipeline** — IPU7 uses libcamera (not the IPU6 camera HAL). The `pipewire-libcamera` plugin connects libcamera to PipeWire so apps can access the camera.
This installer packages all of those pieces into a single script.

---

## How It Works

The IPU7 camera pipeline uses the open-source libcamera stack with PipeWire, plus an on-demand V4L2 relay for apps that don't support PipeWire:

```
usb_ljca + gpio_ljca  →  intel_cvs (DKMS)  →  OV02C10/OV02E10  →  libcamera  →  PipeWire  →  Apps
(LJCA GPIO/USB)           (powers sensor)      (kernel sensor)      (userspace)   (pipewire-    (Firefox,
                                                                                   libcamera)    Chromium, etc.)
                                                                                      ↓
                                                                              camera-relay (on-demand)
                                                                              libcamerasrc → v4l2loopback
                                                                                      ↓
                                                                              /dev/videoX (V4L2)  →  Zoom, OBS, VLC
```

**On-demand camera relay:** Apps that don't support PipeWire (Zoom, OBS, VLC) access the camera through an on-demand V4L2 relay. The relay uses near-zero CPU when idle — the camera only activates when an app opens the V4L2 device, and stops automatically when the app closes it. The installer automatically enables the relay on login.

**Key difference from Book4 (IPU6) fix:** Both fixes use the same open-source libcamera stack and on-demand camera relay. The main differences are hardware-level: Book5 (IPU7) needs the `intel_cvs` DKMS module and LJCA GPIO drivers, while Book4 (IPU6) needs IVSC module loading and initramfs configuration to fix the boot race condition. No initramfs changes are needed for Book5.

---

## Supported Distros

| Distro | Status | Notes |
|--------|--------|-------|
| **Arch / CachyOS / Manjaro** | Confirmed working | libcamera 0.5.2+ in repos |
| **Fedora 42+** | Confirmed working | libcamera 0.5.2+ in repos (0.5.2 on F43, 0.7.0 on F44) |
| **Ubuntu** | Confirmed working (manual steps) | Requires libcamera 0.5.2+ built from source and kernel 6.18+. See [Ubuntu instructions](#ubuntu-specific-setup) below. |

---

## Requirements

- **Kernel 6.18+** — IPU7, USBIO, and OV02C10 drivers are all in-tree starting from 6.18
- **Lunar Lake hardware** — Intel IPU7 (PCI ID `8086:645d` or `8086:6457`)
- **libcamera 0.5.2+** — Available in Arch/Fedora repos; must be built from source on Ubuntu
- **Internet connection** — To download the intel_cvs DKMS module from GitHub

---

## Ubuntu-Specific Setup

Ubuntu 24.04 ships kernel 6.17 and libcamera 0.2.x — both too old for IPU7. To use this fix on Ubuntu, you need to manually provide:

1. **Kernel 6.18+** — Compile from source or install a [mainline kernel build](https://kernel.ubuntu.com/mainline/). One user confirmed kernel 6.19.2 works.
2. **libcamera 0.5.2+** — Build from source following the [libcamera getting started guide](https://libcamera.org/getting-started.html). Ubuntu's apt packages are too old.

The installer will detect Ubuntu and **check your libcamera version** at runtime. If libcamera 0.5.2+ is found (however you installed it), the script will proceed — it skips the package install step and only sets up the DKMS module and configuration files.

**Reference:** The [Arch Wiki Dell XPS 13 9350 camera page](https://wiki.archlinux.org/title/Dell_XPS_13_(9350)_2024#Camera) has a detailed walkthrough for the same hardware. The steps can be adapted for Ubuntu.

---

## Quick Install

**No git?** Download, install, and reboot in one step:

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book4-linux-fixes-main/webcam-fix-book5 && ./install.sh && sudo reboot
```

**Already cloned?**

```bash
./install.sh
sudo reboot
```

**Skip hardware check** (for testing on non-Lunar Lake systems):

```bash
./install.sh --force
```

---

## Uninstall

```bash
./uninstall.sh
sudo reboot
```

The uninstaller removes the DKMS module, source files, and all configuration files. It does **not** remove distro packages (libcamera, etc.) since you may need them for other purposes.

---

## Known Issues

### Desaturated / grayscale / green-tinted image

libcamera's Software ISP uses `uncalibrated.yaml` by default, which has **no color correction matrix (CCM)** — producing near-grayscale or green-tinted images. The installer now installs a sensor-specific tuning file (`ov02e10.yaml` or `ov02c10.yaml`) with a light CCM that restores reasonable color.

If your image still looks desaturated after installing, verify the tuning file is in place:
```bash
ls /usr/share/libcamera/ipa/simple/ov02*.yaml /usr/local/share/libcamera/ipa/simple/ov02*.yaml 2>/dev/null
```

**Interactive tuning:** If the default colors aren't right, use the interactive tuning tool to find the best preset:
```bash
./tune-ccm.sh
```
This cycles through 10 CCM presets (from no correction to strong green boost) with a live qcam preview. Press Enter to try the next preset, `s` to save your choice.

**Note:** The included CCM is a "light touch" correction — image quality won't match Windows, which uses Intel's proprietary ISP tuning. Full sensor calibration files are [being developed upstream](https://patchwork.libcamera.org/cover/22762/) by the libcamera project.

### Vertically flipped image

Some Samsung Galaxy Book5 models (940XHA, 960XHA) have the OV02E10 sensor mounted upside-down, but Samsung's BIOS incorrectly reports `camera_sensor_rotation=0`. The installer automatically applies a rotation fix on affected models; non-Samsung systems skip this step.

**Two rotation fix methods are used, in priority order:**

1. **ACPI SSDT override (preferred)** — The installer patches `SSDT3` from the live firmware to set `camera_sensor_rotation=1` (inverted) directly in the ACPI table, then embeds the patched table in the initramfs via `/etc/acpi_override/cam-rot.aml`. This method requires no additional kernel module. It is used whenever `iasl` (acpica-tools) is available and Secure Boot / kernel lockdown is **not** active.

2. **ipu-bridge DKMS fallback** — If the ACPI method is unavailable (Secure Boot / kernel lockdown active, `iasl` missing, or any SSDT patch step fails), the installer builds and installs a patched `ipu-bridge.ko` DKMS module that adds Samsung DMI quirk entries to the kernel's upside-down sensor table, so libcamera sets the correct flip controls automatically. This module will **auto-remove itself** when a future kernel includes the Samsung rotation entries upstream.

> **Secure Boot users:** The ACPI SSDT override is blocked by kernel lockdown. The installer automatically falls back to the ipu-bridge DKMS module (which can be signed for Secure Boot via MOK). To switch to the preferred ACPI method later, disable Secure Boot, uninstall, and reinstall the webcam fix.

If you still see a flipped image on a different model, the rotation metadata for that platform may be incorrect or missing.

### OV02E10 purple / magenta tint

Samsung Book5 models with the OV02E10 sensor mounted upside-down (940XHA, 960XHA) can get purple/magenta tint after the rotation fix is applied. This happens because the bayer pattern shifts when the sensor is flipped horizontally, but the OV02E10 kernel driver doesn't update the media bus format code to reflect the new pattern. The SoftISP debayer then uses the wrong bayer order, producing incorrect colors.

**The installer automatically builds and installs a patched libcamera** for OV02E10 systems that need the rotation fix. The patch overrides the bayer order in the Simple pipeline handler based on the actual sensor transform (HFlip-only XOR). Original library files are backed up to `/var/lib/libcamera-bayer-fix-backup/` and can be restored with the uninstaller.

If you need to reinstall or update the bayer fix manually:
```bash
sudo ./libcamera-bayer-fix/build-patched-libcamera.sh
```

To uninstall just the bayer fix (restore original libcamera):
```bash
sudo ./libcamera-bayer-fix/build-patched-libcamera.sh --uninstall
```

**Note:** System package updates may overwrite the patched library. If purple tint returns after an update, re-run the bayer fix script.

### Concurrent camera access (only one app at a time)

libcamera on IPU7 currently supports only one client at a time. If Firefox is using the camera, qcam (or any other app) cannot access it simultaneously — and vice versa. This is the root cause of "Firefox conflicts with qcam" reports. Close the first app before opening another, or reboot if the camera becomes unresponsive.

**Note:** Multiple V4L2 apps can share the camera relay's `/dev/videoX` device simultaneously, but only one libcamera client can access the sensor at a time. If the relay is running and a PipeWire app tries to access the camera directly, it will fail (or vice versa).

### Browser & App Compatibility

With `exclusive_caps=0` (the default), browsers work best using V4L2 directly through the camera relay:

| App | Status | Notes |
|-----|--------|-------|
| **Firefox** | Working | Works via PipeWire (no flags needed) |
| **Chrome / Chromium / Brave** | Working | Works via V4L2 camera relay |
| **Edge** | Working | Works via V4L2 camera relay only |
| **Zoom / OBS / VLC** | Working | Uses V4L2 camera relay |
| **Cheese** | Crashes | Use standalone fix: `cd ../camera-relay && ./cheese-fix.sh` |

### Browsers / apps don't see the camera (Ubuntu source builds)

On Ubuntu, if you built PipeWire and libcamera from source (installed to `/usr/local`), PipeWire may not find the libcamera SPA plugin. The installer auto-detects this and sets `SPA_PLUGIN_DIR` in `/etc/environment.d/libcamera-ipa.conf`. **A reboot is required** for PipeWire's systemd user service to pick up the new environment variable.

If apps still don't see the camera after reboot, verify PipeWire found the plugin:
```bash
wpctl status | grep -A 15 "Video"
# Should show a libcamera device, not just v4l2 entries
```

### Browser doesn't show camera / no permission prompt

Browsers require explicit PipeWire camera support to be enabled:

**Firefox:** Navigate to `about:config` and set:
```
media.webrtc.camera.allow-pipewire = true
```

To get full resolution (Firefox defaults to 640x480 over WebRTC/PipeWire), also set:
```
media.navigator.video.default_width = 1920
media.navigator.video.default_height = 1080
```

**Chrome / Chromium / Edge:** These browsers work via the V4L2 camera relay without any special flags. Make sure the relay is running:
```bash
camera-relay status
camera-relay enable-persistent --yes  # if not enabled
```

If Chrome still shows "waiting for your permission" without a prompt, try:
1. Go to `chrome://settings/content/camera` and ensure the correct camera is selected
2. Clear site permissions for the page you're testing
3. Try an Incognito window (to rule out extension conflicts)

**Note:** The PipeWire camera flag (`chrome://flags/#enable-webrtc-pipewire-camera`) is **not recommended** — community testing found it can prevent Chromium browsers from seeing the camera, and Edge doesn't support it at all. Only try it as a last resort, and disable it if it causes problems.

### VLC / Zoom / OBS don't see the camera

These apps use V4L2 directly, not PipeWire. The installer automatically enables the on-demand camera relay, which provides a standard V4L2 device. If it's not working, check the relay status:

```bash
camera-relay status
```

If the relay was disabled, re-enable it:
```bash
camera-relay enable-persistent --yes
```

### PipeWire doesn't see the camera

If the camera works with `cam -l` but PipeWire apps don't see it:

```bash
systemctl --user restart pipewire wireplumber
```

If that doesn't help, verify that `pipewire-libcamera` (Arch) or `pipewire-plugin-libcamera` (Fedora) is installed. On Ubuntu, you may need to build the PipeWire libcamera SPA plugin from source.

---

## Tested Hardware

| Device | Platform | Distro | Kernel | Status | Notes |
|--------|----------|--------|--------|--------|-------|
| Samsung Galaxy Book5 Pro (940XHA) | Lunar Lake | Fedora 43/44 | 6.18+ | **Working** | OV02E10. Correct colors + orientation with bayer fix. |
| Samsung Galaxy Book5 Pro 16" (960XHA) | Lunar Lake | Ubuntu 24.04 | 6.19.2 | **Working** | OV02E10. Correct colors + orientation with bayer fix. Cheese also works. |
| Samsung Galaxy Book5 360 | Lunar Lake | Fedora 42 | 6.18+ | **Working** | Community report (browsers) |
| Dell XPS 13 9350 | Lunar Lake | Arch | 6.18+ | **Working** | OV02C10 sensor |
| Lenovo X1 Carbon Gen13 | Lunar Lake | Fedora 42 | 6.18+ | **Working** | Confirmed by community |
| Samsung Galaxy Book5 Pro 360 | Lunar Lake | — | — | **Untested** | Please report if you try |

**If you test this on a Galaxy Book5, please open an issue with:**
- Your exact model
- Distro and kernel version
- Output of `cam -l`
- Whether apps (Firefox, Zoom, etc.) can see the camera
- Any error messages from `journalctl -b -k | grep -i "ipu\|cvs\|ov02c10\|ov02e10\|libcamera"`

---

## Comparison with Book4 (Meteor Lake / IPU6) Webcam Fix

| | Book4 (IPU6) | Book5 (IPU7) |
|---|---|---|
| **Camera ISP** | IPU6 (Meteor Lake) | IPU7 (Lunar Lake) |
| **Userspace pipeline** | libcamera (open source) | libcamera (open source) |
| **PipeWire bridge** | pipewire-libcamera (direct) + on-demand V4L2 relay | pipewire-libcamera (direct) + on-demand V4L2 relay |
| **Out-of-tree module** | None (IVSC modules are in-tree) | `intel_cvs` via DKMS |
| **Initramfs changes** | Yes (IVSC boot race fix) | No |
| **Supported distros** | Ubuntu, Fedora, Arch | Arch, Fedora, Ubuntu (source build) |
| **Maturity** | Tested and confirmed | Tested and confirmed |
| **Directory** | `webcam-fix-libcamera/` | `webcam-fix-book5/` |

---

## Configuration Files

The install script creates these files:

| File | Purpose |
|------|---------|
| `/etc/modules-load.d/intel-ipu7-camera.conf` | Load LJCA + intel_cvs modules at boot |
| `/etc/modprobe.d/intel-ipu7-camera.conf` | Softdep: LJCA -> intel_cvs -> sensor load order |
| `/etc/wireplumber/wireplumber.conf.d/50-disable-ipu7-v4l2.conf` | Hide raw IPU7 V4L2 nodes from PipeWire (WirePlumber 0.5+) |
| `/etc/wireplumber/main.lua.d/51-disable-ipu7-v4l2.lua` | Hide raw IPU7 V4L2 nodes from PipeWire (WirePlumber 0.4) |
| `/usr/share/libcamera/ipa/simple/ov02e10.yaml` | Sensor color tuning file with CCM (OV02E10) |
| `/usr/share/libcamera/ipa/simple/ov02c10.yaml` | Sensor color tuning file with CCM (OV02C10) |
| `/etc/environment.d/libcamera-ipa.conf` | Set LIBCAMERA_IPA_MODULE_PATH + SPA_PLUGIN_DIR (systemd sessions) |
| `/etc/profile.d/libcamera-ipa.sh` | Set LIBCAMERA_IPA_MODULE_PATH + SPA_PLUGIN_DIR (login shells) |
| `/usr/src/vision-driver-1.0.0/` | DKMS source for intel_cvs module |
| `/usr/src/ipu-bridge-fix-1.0/` | DKMS source for patched ipu-bridge (fallback rotation fix, used when ACPI override is blocked) |
| `/etc/acpi_override/cam-rot.aml` | Patched SSDT3 table with corrected camera rotation (preferred rotation fix, initramfs-embedded) |
| `/usr/local/sbin/cam-rot-check-upstream.sh` | Auto-removes cam-rot.aml ACPI override when upstream kernel has the Samsung rotation fix |
| `/etc/systemd/system/cam-rot-check-upstream.service` | Runs cam-rot upstream check on every boot |
| `/usr/local/sbin/ipu-bridge-check-upstream.sh` | Auto-removes ipu-bridge DKMS when upstream kernel has the fix |
| `/etc/systemd/system/ipu-bridge-check-upstream.service` | Runs ipu-bridge upstream check on every boot |
| `/var/lib/libcamera-bayer-fix-backup/` | Backup of original libcamera files (OV02E10 bayer fix only) |
| `/usr/local/bin/camera-relay` | On-demand camera relay CLI tool |
| `/usr/local/bin/camera-relay-monitor` | V4L2 event monitor for on-demand activation |
| `/etc/modules-load.d/v4l2loopback.conf` | Load v4l2loopback module at boot |
| `/etc/modprobe.d/99-camera-relay-loopback.conf` | v4l2loopback config for camera relay |
| `/usr/local/share/camera-relay/camera-relay-systray.py` | System tray GUI for camera relay |

The rotation fix files installed depend on the method used: the ACPI SSDT override (`cam-rot.aml`) is used when `iasl` is available and Secure Boot is off; otherwise the ipu-bridge DKMS fallback is used. Both rotation methods install an upstream monitor service that checks on every boot whether the native kernel's `ipu-bridge` module has gained the Samsung DMI rotation entries — when detected, the relevant fix auto-removes itself and the initramfs is rebuilt. The bayer-fix files are only installed on OV02E10 systems with an active rotation fix. All files are removed by `uninstall.sh`.

---

## Tips

### Low-latency video preview with mpv / ffplay

By default, `mpv` and `ffplay` buffer video frames which adds ~2 seconds of lag. Use these flags for real-time preview:

```bash
mpv av://v4l2:/dev/video0 --profile=low-latency --untimed --no-correct-pts
ffplay -f video4linux2 -tune zerolatency -vf "setpts=0" /dev/video0
```

The `--no-correct-pts` flag tells MPV to ignore v4l2loopback frame timestamps, which prevents stutter and a cosmetic timer drift on some distros (notably Fedora with v4l2loopback 0.15.x).

Replace `/dev/video0` with your camera device (e.g. `/dev/video32` for the relay). VLC and Zoom don't need these flags — they handle latency correctly by default.

---

## Troubleshooting

### `cam -l` shows no cameras

1. Verify LJCA modules are loaded: `lsmod | grep ljca`
2. Verify intel_cvs is loaded: `lsmod | grep intel_cvs`
3. Check kernel messages: `journalctl -b -k | grep -i "cvs\|ov02c10\|ov02e10\|ljca\|ipu"`
4. Verify IPU7 hardware: `lspci -d 8086:645d` or `lspci -d 8086:6457`
5. Try loading manually in order: `sudo modprobe usb_ljca && sudo modprobe gpio_ljca && sudo modprobe intel_cvs`
6. Try rebooting — some module loading sequences only work on fresh boot

### DKMS build fails

- Ensure kernel headers are installed:
  - Arch: `sudo pacman -S linux-headers`
  - Fedora: `sudo dnf install kernel-devel`
  - Ubuntu: `sudo apt install linux-headers-$(uname -r)`
- Check DKMS build log: `cat /var/lib/dkms/vision-driver/1.0.0/build/make.log`

### Secure Boot: module not loading

If Secure Boot is enabled, the DKMS module must be signed. On Fedora, the installer handles this with the akmods MOK key. You may need to:

1. Enroll the MOK key: `sudo mokutil --import /etc/pki/akmods/certs/public_key.der`
2. Reboot and complete the enrollment at the blue MOK Manager screen

If modules still won't load after enrollment, verify DKMS knows where your signing keys are:

```bash
cat /etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf 2>/dev/null | grep mok_
```

If no `mok_signing_key` / `mok_certificate` lines appear, create a drop-in config (see [speaker-fix troubleshooting](../speaker-fix/README.md#troubleshooting) for details).

On Arch with Secure Boot, you'll need to sign the module manually or use a tool like `sbsigntools`.

---

## Credits

- **[Andycodeman](https://github.com/Andycodeman)** — Installer script, packaging, bayer fix, documentation
- **[david-bartlett](https://github.com/david-bartlett)** — CCM color tuning, testing on 940XHA (Fedora)
- **[jn-simonnet](https://github.com/jn-simonnet)** — Testing and verification on 960XHA (Ubuntu)
- **[Intel vision-drivers](https://github.com/intel/vision-drivers)** — CVS kernel module (DKMS)
- **libcamera project** — Open-source camera stack with IPU7 support

---

## Related Resources

- [Intel vision-drivers (CVS module)](https://github.com/intel/vision-drivers)
- [Arch Wiki — Dell XPS 13 9350 Camera](https://wiki.archlinux.org/title/Dell_XPS_13_(9350)_2024#Camera) — Same Lunar Lake + OV02C10 setup
- [libcamera documentation](https://libcamera.org/docs.html)
- [Samsung Galaxy Book Extras (platform driver)](https://github.com/joshuagrisham/samsung-galaxybook-extras)
- [Speaker fix (Galaxy Book4/5)](../speaker-fix/) — MAX98390 HDA driver (DKMS)
- [Webcam fix (Galaxy Book3/Book4)](../webcam-fix-libcamera/) — IPU6 / Meteor Lake / Raptor Lake / libcamera

### Galaxy Book3 / Book4 Webcam Fix

If you have a **Galaxy Book3 or Book4** (Meteor Lake / Raptor Lake / IPU6), you need the **[webcam-fix-libcamera](../webcam-fix-libcamera/)** directory instead. That fix uses the same open-source libcamera stack but targets IPU6 hardware with IVSC module loading and initramfs configuration. Supports Ubuntu, Fedora, and Arch-based distros.
