# Fix: Samsung Galaxy Book3/Book4 Webcam (Intel IPU6 / OV02C10 / libcamera)

> **Recommended webcam fix for Galaxy Book3 and Book4.** Uses the open-source libcamera stack with PipeWire. Supports **Ubuntu, Fedora, and Arch-based distros**. Includes an on-demand camera relay for apps that don't support PipeWire (Zoom, OBS, VLC) with near-zero idle CPU usage. The installer auto-detects your distro.

> **Galaxy Book5 (Lunar Lake / IPU7):** Use [webcam-fix-book5](../webcam-fix-book5/) instead — the installer will detect Lunar Lake and direct you there.

**Tested on:** Samsung Galaxy Book4 Ultra, Ubuntu 24.04 LTS, Kernel 6.17.0-14-generic (HWE)
**Date:** February 2026
**Hardware:** Intel IPU6 (Meteor Lake `8086:7d19` or Raptor Lake `8086:a75d`), OV02C10 sensor (`OVTI02C1`), Intel Visual Sensing Controller (IVSC)

---

## Quick Install

**No git?** Download, install, and reboot in one step:

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book-linux-fixes-main/webcam-fix-libcamera && ./install.sh && sudo reboot
```

**Already cloned?**

```bash
./install.sh
sudo reboot
```

To uninstall:

```bash
./uninstall.sh
sudo reboot
```

The on-demand camera relay for non-PipeWire apps (Zoom, OBS, VLC) is automatically enabled during install and starts on login with near-zero idle CPU usage.

---

## How It Works

The fix uses the open-source libcamera Simple pipeline handler with Software ISP, accessed through PipeWire. An on-demand camera relay provides a standard V4L2 device for apps that don't support PipeWire:

```
IVSC firmware  →  OV02C10 sensor  →  IPU6 ISYS  →  libcamera  →  PipeWire  →  Apps
(mei-vsc, ivsc-*)   (kernel driver)    (kernel)      (Simple ISP)   (pipewire-    (Firefox,
                                                                      libcamera)    Chromium, etc.)
                                                                         ↓
                                                                 camera-relay (on-demand)
                                                                 libcamerasrc → v4l2loopback
                                                                         ↓
                                                                 /dev/videoX (V4L2)  →  Zoom, OBS, VLC
```

**PipeWire-native apps** (Firefox, Chromium, GNOME Camera) access the camera directly through PipeWire's libcamera SPA plugin — no relay needed.

**Non-PipeWire apps** (Zoom, OBS, VLC) access the camera through the on-demand V4L2 relay. The relay uses **near-zero CPU when idle** — it monitors the v4l2loopback device for client connections using kernel V4L2 events, and only starts the GStreamer pipeline when an app opens the device. When the app closes, the pipeline stops automatically.

### On-Demand Camera Relay

The camera relay is an event-driven bridge between libcamera and V4L2:

- **Idle state:** A lightweight C monitor (`camera-relay-monitor`) holds the v4l2loopback device open and writes black frames to keep it in a ready state. Uses ~0 CPU.
- **App opens device:** The monitor detects the V4L2 client event and signals the relay to start a GStreamer pipeline: `libcamerasrc → videoflip method=none → videoconvert → v4l2sink`.
- **App closes device:** The monitor detects the disconnect and the pipeline stops. The camera LED turns off.
- **`videoflip method=none`:** Forces a CPU buffer copy — required because libcamera 0.7.0's GPU ISP produces DMA-BUF buffers that read as zeros through v4l2loopback's mmap interface.

To manage the relay:

```bash
camera-relay status          # Show current state
camera-relay start               # Start relay (always-on, foreground)
camera-relay start --on-demand   # Start on-demand mode (idle until app opens device)
camera-relay stop            # Stop relay
camera-relay enable-persistent   # Enable on-demand mode at login (recommended)
camera-relay disable-persistent  # Disable auto-start
```

A system tray icon is also available for GUI control.

---

## What the Installer Does

The install script performs these steps:

1. **Detects distro** (Ubuntu, Fedora, Arch) and hardware (IPU6 Meteor Lake or Raptor Lake)
2. **Checks kernel version** (6.10+ required for IPU6 ISYS driver)
3. **Verifies kernel modules** (IVSC, IPU6, OV02C10)
4. **Checks sensor probe status** — detects the 26 MHz external clock issue (some Book3/Book4 Ultra with Raptor Lake) and offers to auto-install the [DKMS fix](../ov02c10-26mhz-fix/)
5. **Loads IVSC modules** and adds them to initramfs (fixes the boot race condition where the OV02C10 sensor probes before IVSC is ready)
6. **Installs libcamera** (from repos on Fedora/Arch, builds from source on Ubuntu)
7. **Installs PipeWire libcamera plugin** (rebuilds SPA plugin on Ubuntu if needed)
8. **Installs sensor tuning file** (`ov02c10.yaml` with color correction matrix)
9. **Hides raw IPU6 V4L2 nodes** (udev rules + WirePlumber rules to prevent ~48 unusable "ipu6" entries in app camera lists)
10. **Installs camera relay** (v4l2loopback, GStreamer plugin, on-demand monitor, CLI tool, systray GUI)
11. **Restarts PipeWire** and verifies the camera is detected

---

## Supported Hardware

This fix works for any laptop with:

- Intel IPU6 on **Meteor Lake** (PCI ID `8086:7d19`) or **Raptor Lake** (PCI ID `8086:a75d`)
- **OV02C10** camera sensor (`OVTI02C1`)
- **Linux** with kernel 6.10+

This includes Samsung Galaxy Book3, Book4 Ultra, Book4 Pro, Book4 Pro 360, and possibly other laptops with the same IPU6 + OV02C10 combination (Dell, Lenovo, etc.). The core issue — IVSC modules not auto-loading — is not Samsung-specific.

**Not supported:** Galaxy Book5 (Lunar Lake / IPU7) — use [webcam-fix-book5](../webcam-fix-book5/) instead.

---

## Supported Distros

| Distro | Status | Notes |
|--------|--------|-------|
| **Ubuntu / Ubuntu-based** | Supported | Builds libcamera from source if system version is too old |
| **Fedora** | Supported | libcamera from repos |
| **Arch / CachyOS / Manjaro** | Supported | libcamera from repos |

---

## Known App Issues

### Cheese -- Crashes (standalone fix available)

GNOME Cheese crashes with a segfault (`SIGSEGV` in `libgstvideoconvertscale.so`) when receiving frames from the v4l2loopback device. This is a Cheese/Clutter bug, not a camera issue.

A standalone fix is available:

```bash
cd camera-relay && ./cheese-fix.sh       # Install
cd camera-relay && ./cheese-fix-uninstall.sh  # Uninstall
```

### GNOME Camera (snapshot) -- May crash on some systems

GNOME Camera may crash with `SIGSEGV` in `gst_video_frame_copy_plane`. **Workaround:** `LIBGL_ALWAYS_SOFTWARE=1 snapshot`

### What works

The webcam works correctly with: **Firefox**, **Chrome/Chromium/Brave**, **Zoom**, **Microsoft Teams**, **OBS Studio**, **mpv**, **VLC**, and most other apps.

### Browser & App Compatibility

Apps split into two groups, and which group a browser lands in is not a matter of
configuration — see [Chromium can't use the V4L2 relay](#chromium-cant-use-the-v4l2-relay) below.

| App | Status | Notes |
|-----|--------|-------|
| **Firefox** | Working | Reads the V4L2 relay directly; also works via PipeWire. No flags needed |
| **Chrome** | Working | **Only** via PipeWire — the installer enables the flag for you |
| **Chromium** | Working | Same as Chrome |
| **Brave** | Working | Same as Chrome |
| **Edge** | Works, but not automatically | Same V4L2 filter as Chrome. `edge://flags` does not expose the entry, so the installer cannot set it — launch with `--enable-features=WebRtcPipeWireCamera` instead |
| **Zoom** | Working | Uses V4L2 camera relay |
| **OBS Studio** | Working | Uses V4L2 camera relay |
| **VLC** | Working | Uses V4L2 camera relay |
| **Cheese** | Crashes | Use standalone fix: `cd ../camera-relay && ./cheese-fix.sh` |
| **GNOME Camera** | May crash | Workaround: `LIBGL_ALWAYS_SOFTWARE=1 snapshot` |

**`chrome://flags/#enable-webrtc-pipewire-camera` is required for Chromium-family
browsers, not optional** — with one version-specific exception. Check with
`pkg-config --modversion libcamera`:

- **libcamera 0.7+: enable it.** This is what the installer does automatically,
  and what `chromium-pipewire-camera` does on demand.
- **libcamera 0.2.0 (Ubuntu 24.04 Noble / Zorin): leave it Disabled.** That
  libcamera has no IPU6 support, so the flag sends Chrome down a path that
  produces no frames either. Neither setting gives you a camera there; fix the
  libcamera version instead.

Electron apps (Slack, Teams, Discord, VS Code) use the same Chromium capture
code and are affected the same way. Launch them with
`--enable-features=WebRTCPipeWireCamera` if they can't see the camera.

Quick test:

```bash
# PipeWire-native test
gst-launch-1.0 libcamerasrc ! videoconvert ! autovideosink

# V4L2 test (requires camera-relay running)
mpv av://v4l2:/dev/video0 --profile=low-latency --untimed --no-correct-pts
```

---

## Configuration Files

The install script creates these files:

| File | Purpose |
|------|---------|
| `/etc/modules-load.d/ivsc.conf` | IVSC module auto-loading at boot |
| `/etc/modprobe.d/ivsc-camera.conf` | Softdep: IVSC loads before sensor |
| `/etc/udev/rules.d/74-camera-relay-mc-nodes.rules` | Move MC-centric V4L2 nodes to the `camera-relay` group, strip their session ACL, and stop them advertising as cameras (the `74-` prefix is load-bearing — see the comment in the file) |
| `/usr/local/lib/udev/camera-relay-v4l2-io-mc` | udev helper: reports `V4L2_CAP_IO_MC` for a node |
| `/usr/local/lib/sysusers.d/camera-relay.conf` | Declares the memberless `camera-relay` group |
| `/etc/wireplumber/wireplumber.conf.d/50-disable-ipu6-v4l2.conf` | Hide raw IPU6 nodes from PipeWire (WP 0.5+) |
| `/etc/wireplumber/main.lua.d/51-disable-ipu6-v4l2.lua` | Hide raw IPU6 nodes from PipeWire (WP 0.4) |
| `/usr/share/libcamera/ipa/simple/ov02c10.yaml` | Sensor color tuning with CCM |
| `/usr/local/bin/camera-relay` | On-demand camera relay CLI tool |
| `/usr/local/bin/camera-relay-monitor` | V4L2 event monitor for on-demand activation |
| `/usr/local/bin/camera-relay-gst` | setgid launcher: the only thing that can open the raw camera nodes |
| `/var/cache/camera-relay/` | GStreamer/Mesa caches for the pipeline (root-owned, group-writable) |
| `/etc/modules-load.d/v4l2loopback.conf` | Load v4l2loopback module at boot |
| `/etc/modprobe.d/99-camera-relay-loopback.conf` | v4l2loopback config for camera relay |
| `/usr/local/share/camera-relay/camera-relay-systray.py` | System tray GUI |
| `/usr/share/applications/camera-relay-systray.desktop` | Desktop entry for systray |
| Initramfs entries | IVSC modules (Ubuntu: `/etc/initramfs-tools/modules`, Fedora: `/etc/dracut.conf.d/`, Arch: `/etc/mkinitcpio.conf.d/`) |

Source-built libcamera (Ubuntu) also creates:

| File | Purpose |
|------|---------|
| `/etc/profile.d/libcamera-ipa.sh` | IPA module path (login shells) |
| `/etc/environment.d/libcamera-ipa.conf` | IPA module path (systemd sessions) |

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

### Camera not detected after reboot

Check that IVSC modules loaded:

```bash
lsmod | grep -E 'ivsc|mei.vsc'
```

If missing, verify they're in the initramfs:

```bash
# Ubuntu
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E "ivsc|mei.vsc"
# Fedora
lsinitrd | grep -E "ivsc|mei.vsc"
```

### Installer says "kernel modules couldn't be found" (`mei-vsc`, `ivsc-csi`, …)

On most systems the IVSC bridge is shipped as loadable modules (`mei-vsc`,
`mei-vsc-hw`, `ivsc-ace`, `ivsc-csi`). On Ubuntu install
`linux-modules-ipu6-generic-hwe-24.04` (match your HWE variant); on Fedora
`sudo dnf install kernel-modules-extra kernel-modules`.

Some recent kernels (e.g. Fedora kernel 7.x) build the IVSC bridge **into the
kernel** or ship it under a consolidated module name, so there is no `.ko` file
to find — the installer now treats a module as present if it's built-in or
discoverable via `modinfo`. If you still hit the warning and the camera works
after a reboot, it's harmless; you can also re-run with `--skip-module-check`.
To check what your kernel actually provides:

```bash
find /lib/modules/$(uname -r) -iname '*vsc*'
modinfo mei_vsc ivsc_csi ivsc_ace 2>&1 | head
grep -i vsc /lib/modules/$(uname -r)/modules.builtin
```

### "external clock 26000000 is not supported" in dmesg

Some Galaxy Book3/Book4 models have a 26 MHz external clock instead of the expected 19.2 MHz. This is a **per-board property, not a platform one** — it is confirmed on both Raptor Lake and Meteor Lake IPU6, including the Book4 Ultra `NP960XGL-XG1BR` (Meteor Lake, `8086:7d19`). It is not model-determined either: a different `960XGL` board, same model and same Meteor Lake IPU6, runs the stock driver with no clock error and does not need the fix. Don't rule it in or out from your platform or your model number; go by the dmesg error. The installer detects it automatically and offers to install the [DKMS-patched ov02c10 driver](../ov02c10-26mhz-fix/). If you skipped the prompt during install, run the fix manually:

```bash
cd ov02c10-26mhz-fix && sudo ./install.sh
```

### Too many "ipu6" entries in camera list

Log out and back in for the udev rules and WirePlumber config to take effect, then check with:

```bash
camera-relay doctor
```

The `MC nodes` line reports whether any raw node is still reachable from your session — those are exactly the ones that show up as spurious "ipu6" cameras.

The ISYS driver registers one capture node per possible stream (48 on a Book4), and the kernel marks each `V4L2_CAP_IO_MC`: usable only after userspace configures the media graph, never as a standalone camera. Nothing carries that bit into udev, so they all claim to be cameras. The installer therefore moves them into a memberless `camera-relay` group and clears the bogus properties, which covers both kinds of application — the ones that enumerate through udev (Chromium and friends) and the ones that walk `/dev/video*` calling `QUERYCAP` and only skip what they cannot open (Firefox, Zoom, OBS).

One consequence: `cam` and `qcam` can no longer open the camera as your user. Run them through the launcher, which holds the group:

```bash
camera-relay-gst --list-cameras
```

### Zoom / OBS / VLC don't see the camera

Enable the on-demand camera relay:

```bash
camera-relay enable-persistent
```

### Firefox: `NotAllowedError` on every camera request (stale portal permission)

Only affects you if you've set `media.webrtc.camera.allow-pipewire = true` in `about:config`.
Firefox then fails on *every* camera request with `NotAllowedError`, while other apps (Chrome, OBS)
work fine.

Cause: a stale **"denied"** entry for Firefox in the xdg-desktop-portal permission store, left
behind when the portal crashed mid-negotiation (e.g. the glib2 `g_weak_ref_get` race in
xdg-desktop-portal 1.21.0 on Fedora 44). The denial persists and silently blocks every later
request, even once the portal itself is fixed.

```bash
# Check — look for "org.mozilla.firefox" 1 "no"
busctl call --user org.freedesktop.impl.portal.PermissionStore \
  /org/freedesktop/impl/portal/PermissionStore \
  org.freedesktop.impl.portal.PermissionStore \
  Lookup ss "devices" "camera"

# Fix, then restart Firefox
busctl call --user org.freedesktop.impl.portal.PermissionStore \
  /org/freedesktop/impl/portal/PermissionStore \
  org.freedesktop.impl.portal.PermissionStore \
  DeletePermission sss "devices" "camera" "org.mozilla.firefox"
```

If you don't specifically need the PipeWire path, setting
`media.webrtc.camera.allow-pipewire = false` avoids this entirely — Firefox then uses the V4L2
camera relay, which needs no flags. Thanks to
[@david-bartlett](https://github.com/david-bartlett) ([#37](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/37)).

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

The relay is created with `exclusive_caps=0`, so it advertises both and every
branch fails:

```bash
v4l2-ctl -d /dev/videoN --info    # Device Caps: Video Capture AND Video Output
```

Firefox accepts dual caps and reads the node directly, which is exactly why
Firefox works out of the box and Chrome shows nothing.

**The fix** is to route those browsers through PipeWire, where WirePlumber
publishes the relay as an ordinary camera source. The installer does this, and
you can run it any time:

```bash
chromium-pipewire-camera          # installed to /usr/local/bin by the installer
```

You will usually need to, because it skips any profile whose browser is open —
which it normally is during an install. (From an unpacked source tree the same
script is `camera-relay/chromium-pipewire-camera.sh`.)

It edits each browser's `Local State` to enable
`chrome://flags/#enable-webrtc-pipewire-camera` (backing the file up first), or
you can set that flag by hand. Either way the browser must be **fully quit**
first — Chromium rewrites `Local State` from memory on exit and would discard the
change — and restarted afterwards, since it caches its device list at startup.

`camera-relay doctor` reports all of this: the node's actual capabilities, whether
PipeWire publishes a camera source, and whether the flag is set per browser.

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

- **Edge** does not expose the entry in `edge://flags`, so there is nothing for
  the installer to write into its profile. The underlying Chromium feature is
  still compiled in, so the command-line switch works — edit the `Exec=` line of
  `microsoft-edge.desktop`, or launch it as:

  ```bash
  microsoft-edge --enable-features=WebRtcPipeWireCamera
  ```

- **Electron apps** (Slack, Discord, Teams, VS Code) are a different case: they
  hit the same V4L2 filter, but the switch does **not** help, because PipeWire
  *camera* support is not wired into Electron — only the screen-share capturer
  is ([electron#45058](https://github.com/electron/electron/issues/45058) is a
  closed, unimplemented request). Nothing in this repo fixes them today.
- **libcamera 0.2.0** (Ubuntu 24.04 Noble / Zorin) has no IPU6 support, so the
  PipeWire path produces no frames either. The script refuses to enable the flag
  below 0.7 for that reason.

> **Why not `exclusive_caps=1`?** It would make the node advertise capture only
> and fix every Chromium app at once, with no flag. The relay deliberately moved
> away from it: with `exclusive_caps=1` WirePlumber classifies the node as an
> output at boot, before the relay attaches, and the PipeWire path breaks instead
> — trading one broken set of apps for another. See the note above
> `nudge_wireplumber` in `camera-relay/camera-relay`.

### Black screen in apps / "v4l2loopback ... não é um dispositivo de saída"

On Ubuntu/Zorin (Noble base) the pre-installed **Intel OEM camera stack**
(`v4l2-relayd` + `ipu6-camera-*`) ships its own
`/etc/modprobe.d/v4l2loopback.conf` with `exclusive_caps=1
card_label="Intel MIPI Camera"` and an enabled `v4l2-relayd.service` that
loads v4l2loopback at boot. Because modprobe.d files merge in lexical order
and the **last** value of a duplicate key wins, that file overrides the
relay's `99-camera-relay-loopback.conf`, so the loopback comes up
**capture-only** (no `VIDEO_OUTPUT`). GStreamer's `v4l2sink` then can't write
into it and apps show a black screen, often with
`O dispositivo "/dev/videoN" não é um dispositivo de saída`.

Check for it:

```bash
lsmod | grep v4l2loopback
cat /sys/module/v4l2loopback/parameters/exclusive_caps   # Y = wrong
systemctl status v4l2-relayd
```

The installer now detects and **neutralizes** this automatically — it stops,
disables and masks `v4l2-relayd.service` and moves the OEM
`/etc/modprobe.d/v4l2loopback.conf` aside (restored by `uninstall.sh`). Just
re-run `sudo bash install.sh` and reboot. The change is fully reversible:
`uninstall.sh` restores the OEM file and re-enables the service.

### LED on but black image, on laptops with a dedicated GPU

**Symptom.** The webcam privacy LED lights up, `camera-relay status` reports
`STREAMING`, and apps still get a black picture — Google Meet says *"Your camera
may be blocked"*. Affects hybrid-GPU laptops (Intel or AMD iGPU + NVIDIA dGPU)
— the Galaxy Book4 Ultra and the RTX variants of the Book5 Pro ship in this
configuration.

Having the dGPU is not by itself enough: what matters is whether the **NVIDIA
kernel driver is bound to it**. If nothing is bound — no `nvidia`/`nouveau`
module loaded, no `/dev/dri/renderD*` node for it — then NVIDIA's EGL driver
cannot claim a device, GLVND falls through to Mesa, and you are not affected
even on a machine that has the hardware. Check with:

```bash
ls /dev/dri/renderD*      # two nodes = hybrid and affected; one = not
camera-relay doctor       # the "GPU / EGL debayer" section reports the topology
```

**Cause.** libcamera's Software ISP converts Bayer→RGB on the GPU through EGL.
Which GPU that is comes from GLVND, which loads the vendor ICDs in
`/usr/share/glvnd/egl_vendor.d` in filename order — and NVIDIA's ships as
`10_nvidia.json`, ahead of Mesa's `50_mesa.json`. The debayer therefore runs on
NVIDIA's proprietary EGL driver, which it is not compatible with:

```
ERROR eGL egl.cpp:134 glFrameBufferTexture2D error 36054
ERROR Debayer debayer_egl.cpp:639 debayerGPU failed
```

The sensor powers up — hence the LED — but every frame dies in the conversion
and nothing ever reaches v4l2loopback.

**Why it is so easy to misdiagnose.** Run `cam` from a terminal and it usually
works: a desktop session normally has EGL already resolved to Mesa. The failure
only appears inside the systemd user service, which inherits none of that.

Confirm it directly:

```bash
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json cam -c 1 -C5
```

That should report a Mesa renderer and ~30 fps. Swapping `50_mesa.json` for
`10_nvidia.json` hangs and dies at the timeout without a single frame.

**Fix.** Handled automatically — `camera-relay enable-persistent` detects the
hybrid setup and bakes the pin into `camera-relay.service`:

```
Environment=__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
```

If you are on an install from before this landed, re-run the installer, or just
regenerate the unit:

```bash
camera-relay disable-persistent && camera-relay enable-persistent
```

`camera-relay doctor` now prints a **GPU / EGL debayer** section that lists the
render nodes and their drivers, the vendor ICDs in GLVND's load order, the pin
actually in effect, and any `debayerGPU failed` lines from the pipeline log.

To apply it by hand instead — e.g. to a unit you maintain yourself — drop in:

```bash
mkdir -p ~/.config/systemd/user/camera-relay.service.d
printf '[Service]\nEnvironment=__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json\n' \
  > ~/.config/systemd/user/camera-relay.service.d/10-force-intel-gpu.conf
systemctl --user daemon-reload && systemctl --user restart camera-relay.service
```

Do **not** put `__EGL_VENDOR_LIBRARY_FILENAMES` in `/etc/environment.d`: unlike
`LIBCAMERA_SOFTISP_MODE` it steers every GL client on the machine, so a global
setting would take NVIDIA offload away from games and everything else.

**Known gap.** The pin covers the camera-relay path. Apps that read the camera
through **PipeWire's libcamera source** directly (Chromium with
`#enable-webrtc-pipewire-camera`) run the debayer inside `pipewire.service`,
which has no pin, so they can still hit this. Workaround — same drop-in, on
PipeWire:

```bash
mkdir -p ~/.config/systemd/user/pipewire.service.d
printf '[Service]\nEnvironment=__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json\n' \
  > ~/.config/systemd/user/pipewire.service.d/10-force-intel-gpu.conf
systemctl --user daemon-reload && systemctl --user restart pipewire.service
```

The slower but unconditionally safe alternative for that path is CPU debayer
(`LIBCAMERA_SOFTISP_MODE=cpu`), which the installer already sets globally when
NVIDIA is the *active* renderer.

### Desaturated, green-tinted or purple image (colour tuning)

The bundled `ov02c10.yaml` ships a conservative colour-correction matrix (CCM).
It is **not** a full sensor calibration, so depending on your panel and lighting
the image can still read green/cool (most common) or, on models where the sensor
is mounted upside-down, purple/magenta. You can tune the CCM yourself.

The easy way — an interactive tuner that cycles through presets with a live
preview and writes the one you pick to every copy of the tuning file:

```bash
cd webcam-fix-libcamera
./tune-ccm.sh
```

To do it by hand, edit the matrix in `ov02c10.yaml` (rows should each sum to
~1.0 so neutral greys stay neutral) — but see the next entry first, because hand
edits often *look* like they do nothing.

### Editing `ov02c10.yaml` has no effect

Two things bite people here:

1. **The tuning file is read once, when the camera is opened.** `camera-relay`
   and PipeWire keep a libcamera instance alive, so an edit isn't picked up until
   they're restarted (or you reboot):

   ```bash
   systemctl --user restart camera-relay.service pipewire.service wireplumber.service
   ```

   Then close and reopen the app you're testing with. `./tune-ccm.sh` does this
   for you.

2. **There can be two copies of the file.** The distro one is at
   `/usr/share/libcamera/ipa/simple/ov02c10.yaml`; if libcamera was built from
   source (the installer does this on Ubuntu, and on any distro with
   `--force-libcamera-rebuild`) there's a second copy at
   `/usr/local/share/libcamera/ipa/simple/ov02c10.yaml`. Whichever libcamera is
   actually loaded reads *its own* copy — edit the wrong one and nothing changes.
   Check which file is in use:

   ```bash
   LIBCAMERA_LOG_LEVELS=IPAProxy:INFO cam -c1 -C1 2>&1 | grep -i "tuning file"
   ```

   Edit the path it prints, or edit both, or just use `./tune-ccm.sh` (it writes
   to all of them).

If no matrix you try makes any difference and you also see this in the log:

```
WARN IPASoft soft_simple.cpp:... IPASoft: Failed to create camera sensor helper for ov02c10
```

then your libcamera doesn't have the OV02C10 sensor helper, so auto-exposure and
auto-white-balance fall back to a generic path and the colours will be wrong no
matter what the CCM says. Rebuild libcamera with the helper patched in:

```bash
sudo ./install.sh --force-libcamera-rebuild
```

> **Note (Arch/Fedora):** `cam` and `qcam` may keep printing the
> "Failed to create camera sensor helper" warning *even after* a successful
> `--force-libcamera-rebuild`. Those tools load the distro's packaged libcamera
> (its `.so` is a higher patch version, so the dynamic linker prefers it), not
> the patched build in `/usr/local`. The **camera relay** runs its pipeline with
> `LD_LIBRARY_PATH=/usr/local/lib`, so it *does* use the patched build — which is
> what every app that goes through the relay (Firefox, Chrome, Zoom, OBS, VLC,
> mpv, …) actually sees. Apps that talk to libcamera directly without the relay
> (`cam`, `qcam`, GNOME Snapshot, Chromium with the `enable-webrtc-pipewire-camera`
> flag) are the exception and may still get the unpatched system libcamera on
> those distros. To confirm the *relay* picked up the patched build:
>
> ```bash
> camera-relay status
> journalctl --user -u camera-relay -b | grep -i 'libcamera\|GStreamer plugin'
> ```

### Camera upside-down after running `cam` or `qcam`

Opening the sensor directly with `cam`/`qcam` resets the V4L2 flip controls when
it exits. A relay that's already streaming doesn't re-apply them, so on models
with an inverted sensor (e.g. Galaxy Book3 Ultra 960XFH) the relay's image ends
up upside-down until you restart it:

```bash
systemctl --user restart camera-relay.service
```

Avoid poking the camera with `cam`/`qcam` while the relay is running.

---

## Legacy Webcam Fix

There is an older webcam fix in [`webcam-fix/`](../webcam-fix/) that uses Intel's proprietary camera HAL (`icamerasrc`) with `v4l2-relayd`. **This is not recommended** — it's kept only as a fallback if the libcamera stack doesn't work on your hardware. The libcamera fix is open-source, supports more distros, and includes on-demand activation with near-zero idle CPU.

---

## Credits

- **[Andycodeman](https://github.com/Andycodeman)** -- Root cause analysis, fix script, on-demand camera relay, PipeWire/WirePlumber configuration, and documentation

---

## Related Resources

- [Samsung Galaxy Book Extras (platform driver)](https://github.com/joshuagrisham/samsung-galaxybook-extras)
- [Ubuntu Intel MIPI Camera Wiki](https://wiki.ubuntu.com/IntelMIPICamera)
- [libcamera documentation](https://libcamera.org/docs.html)
- [Speaker fix (Galaxy Book4/5)](../speaker-fix/) -- MAX98390 HDA driver (DKMS)
- [Webcam fix -- Galaxy Book5 / Lunar Lake](../webcam-fix-book5/) -- IPU7 + libcamera
- [Webcam fix -- Legacy](../webcam-fix/) -- IPU6 / icamerasrc (not recommended)
