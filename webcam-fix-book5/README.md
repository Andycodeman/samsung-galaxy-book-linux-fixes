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
curl -sL https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book-linux-fixes-main/webcam-fix-book5 && ./install.sh && sudo reboot
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

Some Samsung Galaxy Book5 models (940XHA, 960XHA) have the OV02E10 sensor mounted upside-down, but Samsung's BIOS incorrectly reports `camera_sensor_rotation=0`. The installer now includes a **DKMS patched `ipu-bridge.ko`** that adds Samsung DMI quirk entries to the kernel's upside-down sensor table, so libcamera sets the correct flip controls automatically.

**This fix is installed automatically** on affected Samsung models (940XHA, 960XHA). It will **auto-remove itself** when a future kernel includes the Samsung entries upstream. On non-Samsung systems, this step is skipped.

If you still see a flipped image on a different model, the rotation metadata for that platform may be incorrect or missing.

### OV02E10 purple / magenta tint

Samsung Book5 models with the OV02E10 sensor mounted upside-down (940XHA, 960XHA, …) can get a purple/magenta tint once the sensor is flipped. This happens because the bayer pattern shifts when the sensor is flipped, but the OV02E10 kernel driver doesn't update the media bus format code to reflect the new pattern. The SoftISP debayer then uses the wrong bayer order, producing incorrect colors.

**The installer automatically builds and installs a patched libcamera** for OV02E10 systems where the sensor is flipped — that's true both when this repo's `ipu-bridge` rotation fix is installed *and* when a newer kernel already carries the Samsung rotation quirk upstream. The patch overrides the bayer order in the Simple pipeline handler based on the actual sensor transform (HFlip-only XOR). Original library files are backed up to `/var/lib/libcamera-bayer-fix-backup/` and can be restored with the uninstaller.

If you need to reinstall or update the bayer fix manually:
```bash
sudo ./libcamera-bayer-fix/build-patched-libcamera.sh
```

To uninstall just the bayer fix (restore original libcamera):
```bash
sudo ./libcamera-bayer-fix/build-patched-libcamera.sh --uninstall
```

**System updates overwrite the patch.** Ordinary upgrades (`dnf upgrade`, `apt upgrade`, `pacman -Syu`) replace `libcamera.so` with the stock distro build, which silently brings the purple tint back. Re-running `./install.sh` detects this — it compares the libcamera version currently installed against the one recorded when the patch was built — and rebuilds the patch automatically. You can also just re-run `sudo ./libcamera-bayer-fix/build-patched-libcamera.sh` yourself. To check whether the fix is in place:
```bash
ls -l /var/lib/libcamera-bayer-fix-backup/      # backup dir exists ⇒ patch was applied at some point
cat /var/lib/libcamera-bayer-fix-backup/version # libcamera version the patch was built against
pkg-config --modversion libcamera               # version installed now — must still match the line above
```
After (re)building, restart PipeWire so apps pick up the new library: `systemctl --user restart pipewire wireplumber` (and `camera-relay.service` if you use the relay).

**`tune-ccm.sh` cannot fix this.** If you've tried the CCM presets and none of them removes the purple, that's expected — the tint is a bayer-pattern shift, not a colour-matrix error. Flipping the sensor folds the red and blue samples onto the same positions, so the information needed to separate them is gone; no 3×3 matrix can recover it. Only the patched libcamera above corrects it. Once the bayer fix is active, `tune-ccm.sh` is still useful for any remaining mild green/warm cast (and it now warns you up front on OV02E10 if the bayer fix doesn't look active).

### Concurrent camera access (only one app at a time)

libcamera on IPU7 currently supports only one client at a time. If Firefox is using the camera, qcam (or any other app) cannot access it simultaneously — and vice versa. This is the root cause of "Firefox conflicts with qcam" reports. Close the first app before opening another, or reboot if the camera becomes unresponsive.

**Note:** Multiple V4L2 apps can share the camera relay's `/dev/videoX` device simultaneously, but only one libcamera client can access the sensor at a time. If the relay is running and a PipeWire app tries to access the camera directly, it will fail (or vice versa).

### Browser & App Compatibility

Apps split into two groups, and which group a browser lands in is not a matter of
configuration — see [Chromium can't use the V4L2 relay](#chromium-cant-use-the-v4l2-relay) below.

| App | Status | Notes |
|-----|--------|-------|
| **Firefox** | Working | Reads the V4L2 relay directly; also works via PipeWire. No flags needed |
| **Chrome / Chromium / Brave** | Working | **Only** via PipeWire — the installer enables the flag for you |
| **Edge** | Not working | Same V4L2 filter as Chrome, but no PipeWire flag exists to work around it |
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

#### Firefox: `NotAllowedError` on every camera request (stale portal permission)

If you've set `media.webrtc.camera.allow-pipewire = true` and Firefox then fails on *every*
camera request with:

```
NotAllowedError: The request is not allowed by the user agent or the platform in the current context.
```

…while other apps (Chrome, OBS) have camera access fine, you have a **stale "denied" entry** for
Firefox in the xdg-desktop-portal permission store. It gets left behind when the portal crashes
mid-negotiation (e.g. the glib2 `g_weak_ref_get` race in xdg-desktop-portal 1.21.0 on Fedora 44):
the permission grant fails and is recorded as a *denial*, which then silently blocks every future
request — even after the portal is fixed.

Check for it:

```bash
busctl call --user org.freedesktop.impl.portal.PermissionStore \
  /org/freedesktop/impl/portal/PermissionStore \
  org.freedesktop.impl.portal.PermissionStore \
  Lookup ss "devices" "camera"
```

If you see `"org.mozilla.firefox" 1 "no"` in the output, delete it:

```bash
busctl call --user org.freedesktop.impl.portal.PermissionStore \
  /org/freedesktop/impl/portal/PermissionStore \
  org.freedesktop.impl.portal.PermissionStore \
  DeletePermission sss "devices" "camera" "org.mozilla.firefox"
```

Restart Firefox; it will prompt for camera access on the next request and grant it normally. No
restart of xdg-desktop-portal is needed.

*Note:* if you don't specifically need the PipeWire path, setting
`media.webrtc.camera.allow-pipewire = false` also avoids this entirely — Firefox will then use the
V4L2 camera relay, which needs no flags. Thanks to
[@david-bartlett](https://github.com/david-bartlett) ([#37](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/37)).

**Chrome / Chromium / Brave:** see the next section — these need the PipeWire
flag, which the installer sets for you. If Chrome shows "waiting for your
permission" without a prompt but *does* list the camera, try:
1. Go to `chrome://settings/content/camera` and ensure the correct camera is selected
2. Clear site permissions for the page you're testing
3. Try an Incognito window (to rule out extension conflicts)

### Chromium can't use the V4L2 relay

Chrome, Chromium, Brave, Edge and every Electron app filter the camera relay out
of their device list before you ever see a permission prompt —
`navigator.mediaDevices.enumerateDevices()` simply returns no `videoinput`.

This is not a permission, sandbox or relay problem. Chromium's V4L2 enumeration
([`video_capture_device_factory_v4l2.cc`](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/media/capture/video/linux/video_capture_device_factory_v4l2.cc))
accepts a node only when it reports capture and **not** output:

```c
(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE &&
 !(cap.capabilities & V4L2_CAP_VIDEO_OUTPUT)) ||
(cap.capabilities & V4L2_CAP_DEVICE_CAPS &&
 cap.device_caps & V4L2_CAP_VIDEO_CAPTURE &&
 !(cap.device_caps & V4L2_CAP_VIDEO_OUTPUT))
```

The relay is created with `exclusive_caps=0`, so it advertises both
(`v4l2-ctl -d /dev/videoN --info` shows `Video Capture` *and* `Video Output`
under `Device Caps`) and every branch fails. Firefox accepts dual caps and reads
the node directly, which is exactly why Firefox works out of the box and Chrome
shows nothing. Snap and flatpak browsers are additionally sandboxed away from
`/dev/video*`.

**The fix** is to route those browsers through PipeWire, where WirePlumber
publishes the relay as an ordinary camera source. The installer does this, and
you can run it any time:

```bash
chromium-pipewire-camera          # installed to /usr/local/bin by the installer
```

You will usually need to, because it skips any profile whose browser is open —
which it normally is during an install. (From an unpacked source tree the same
script is `camera-relay/chromium-pipewire-camera.sh`.)

It enables `chrome://flags/#enable-webrtc-pipewire-camera` in each browser's
`Local State` (backing the file up first); you can also set that flag by hand.
Either way the browser must be **fully quit** first — Chromium rewrites
`Local State` from memory on exit and would discard the change — and restarted
afterwards, since it caches its device list at startup. Confirmed on a
960QHA / Kubuntu 26.04 in [issue #65](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/65).

`camera-relay doctor` reports the node's actual capabilities, whether PipeWire
publishes a camera source, and whether the flag is set per browser.

#### The second half: WirePlumber's stale format list

The flag alone is not enough, because a second timing bug sits behind it.

`v4l2loopback` is loaded at boot with no producer attached, so it advertises a
generic catch-all format set — `BGRx`/`xRGB` at any size from 2x1 to 8192x8192,
expressed as a `Choice:Range`. The relay's monitor only pins `YUYV 1920x1080`
when it starts at login, and `camera-relay.service` is ordered
`After=wireplumber.service` — so WirePlumber has already probed the unconfigured
device, cached that generic list, and will never look again.

Firefox never notices, because it reads `/dev/video0` directly. WebRTC's PipeWire
camera path needs a *discrete* rectangle out of `SPA_PARAM_EnumFormat`; a range
yields no usable resolution, so the camera arrives with zero capabilities. Chrome
logs the camera and then offers no device — indistinguishable from no camera:

```
camera_portal.cc:215]    Camera access granted by the XDG portal.
pipewire_session.cc:99]  Found Camera: Camera Relay (V4L2)
```
```js
await navigator.mediaDevices.getUserMedia({video:true})
// NotFoundError: Requested device not found
```

Compare the two views to spot it:

```bash
v4l2-ctl -d /dev/videoN --list-formats-ext   # what the device really offers
pw-cli enum-params <node-id> EnumFormat      # what PipeWire thinks it offers
```

There is no lighter re-probe available — the V4L2 monitor is udev-driven, nodes
are built at discovery, and WirePlumber exposes no "re-probe this device" call.
Restarting it is the documented answer; see *"`device.capabilities` is read-only
in PipeWire"* in [the legacy fix](../webcam-fix/README.md#step-9-fix-pipewire-device-classification),
which hit the same class of bug.

The relay handles this itself, from `ExecStartPost`: it waits for the monitor to
pin the format, compares it against what PipeWire advertises, and restarts
WirePlumber **only** when they disagree — so restarting the relay by hand costs
no audio glitch when things are already correct. Run it manually with:

```bash
camera-relay nudge-wireplumber
```

Two things this does **not** fix:

- **Edge** has no such flag. It stays blind to the relay.
- **libcamera 0.2.0** (Ubuntu 24.04 Noble / Zorin) has no IPU6/IPU7 support, so
  the PipeWire path produces no frames either. Check with
  `pkg-config --modversion libcamera`; the script refuses below 0.7, and that is
  where the older "keep the flag disabled" advice came from.

> **Why not `exclusive_caps=1`?** It would make the node advertise capture only
> and fix every Chromium app at once, with no flag. The relay deliberately moved
> away from it: with `exclusive_caps=1` WirePlumber classifies the node as an
> output at boot, before the relay attaches, and the PipeWire path breaks instead
> — trading one broken set of apps for another. See the note above
> `nudge_wireplumber` in `camera-relay/camera-relay`.

If enabling it makes things worse, set it back to Disabled — it is a per-browser
setting and changes nothing system-wide.

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
| Samsung Galaxy Book5 Pro 16" (960XHA) | Lunar Lake | NixOS | 7.0.10 | **Working** | OV02E10. Correct colors + orientation with bayer fix v0.7. |
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
| `/usr/src/ipu-bridge-fix-1.0/` | DKMS source for patched ipu-bridge (Samsung 940XHA/960XHA only) |
| `/usr/local/sbin/ipu-bridge-check-upstream.sh` | Auto-removes ipu-bridge DKMS when upstream kernel has the fix |
| `/etc/systemd/system/ipu-bridge-check-upstream.service` | Runs upstream check on boot |
| `/var/lib/libcamera-bayer-fix-backup/` | Backup of original libcamera files (OV02E10 bayer fix only) |
| `/usr/local/bin/camera-relay` | On-demand camera relay CLI tool |
| `/usr/local/bin/camera-relay-monitor` | V4L2 event monitor for on-demand activation |
| `/etc/modules-load.d/v4l2loopback.conf` | Load v4l2loopback module at boot |
| `/etc/modprobe.d/99-camera-relay-loopback.conf` | v4l2loopback config for camera relay |
| `/usr/local/share/camera-relay/camera-relay-systray.py` | System tray GUI for camera relay |

The ipu-bridge-fix and bayer-fix files are only installed on Samsung 940XHA/960XHA models with OV02E10 sensor. The ipu-bridge fix auto-removes when the kernel includes the Samsung rotation entries. All files are removed by `uninstall.sh`.

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

### Start here: `camera-relay doctor`

```bash
camera-relay doctor
```

One command, one block of output, covering every layer between the sensor and
the browser: tools, libcamera, the loopback device, relay state, the systemd
unit, recent GStreamer logs, and browser sandboxing. The section that matters
most is **Frames on the loopback**, which grabs a live frame and reports one of:

| Result | Meaning |
| --- | --- |
| `NO FRAMES` | The device exists but nothing is writing to it — the relay is not running or its pipeline died. Read the logs printed below it. |
| `BLANK FRAMES` | Apps can open the device but the picture is uniform black — the relay holds the device, the camera pipeline is not producing. |
| `REAL PICTURE` | The relay works end to end. If a browser still shows no camera, the problem is browser-side (snap/flatpak confinement, or the browser needs restarting). |

This is worth running *before* anything else below, and worth pasting in full
into a bug report. `gst-launch-1.0 ... autovideosink` showing a picture proves
the camera works but says nothing about the loopback, which is the part
browsers actually read. (issue #65)

### LED on but black image, on RTX models

The Book5 Pro ships in RTX dGPU configurations, and those run the same
libcamera Software ISP as the Book4 Ultra — so they hit the same hybrid-GPU
bug. The privacy LED lights, `camera-relay status` says `STREAMING`, and apps
get a black picture, because GLVND loads `10_nvidia.json` ahead of
`50_mesa.json` and the EGL debayer lands on NVIDIA's driver:

```
ERROR eGL egl.cpp:134 glFrameBufferTexture2D error 36054
ERROR Debayer debayer_egl.cpp:639 debayerGPU failed
```

It only shows up under systemd — `cam` from a terminal works, because a desktop
session usually has EGL already resolved to Mesa.

`camera-relay enable-persistent` detects the hybrid setup and pins the vendor
ICD to the iGPU in `camera-relay.service`, and `camera-relay doctor` reports the
whole picture under **GPU / EGL debayer**. On an install from before this
landed, regenerate the unit:

```bash
camera-relay disable-persistent && camera-relay enable-persistent
```

Full write-up, including the manual drop-in and the PipeWire-path caveat:
[../webcam-fix-libcamera/README.md](../webcam-fix-libcamera/README.md) →
*"LED on but black image, on laptops with a dedicated GPU"*.

### `camera-relay start` says `libcamerasrc element not found` — but it's installed

If the plugin package is already the newest version and
`gst-launch-1.0 libcamerasrc ! videoconvert ! autovideosink` shows a working
picture, the missing piece is the **GStreamer command-line tools**, not the
libcamera plugin. `gst-launch-1.0` *is* the relay pipeline, and it ships
separately from `gstreamer1.0-libcamera`:

```bash
sudo apt install gstreamer1.0-tools     # Ubuntu/Debian
sudo dnf install gstreamer1             # Fedora
sudo pacman -S gstreamer                # Arch
camera-relay start
```

Current installers pull this in automatically; installs made before that need it
by hand. (issue #65)

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
- **[ang3lo-azevedo](https://github.com/ang3lo-azevedo)** — Testing and verification on 960XHA (NixOS, CachyOS kernel)
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
