# Issue #95 follow-up — "is there support planned for the webcam on nixos?"

@hayden-xyz confirmed the speakers work (2026-09-13). Shipped as **v0.3.69**.
Remaining question: a NixOS webcam module for his Book3 Pro 14" (NP940XFG,
Raptor Lake IPU6 `8086:a75d`, OV02C10).

## Assessment

**Short version: yes, and it's the *easy* one — but it needs a tester, and he
is the first Book3/Book4 NixOS user we've had.**

### 1. nixpkgs already ships something he can try today

`hardware.ipu6.enable` exists in nixpkgs (`nixos/modules/hardware/video/webcam/ipu6.nix`),
with `platform = "ipu6ep"` covering Raptor Lake. It pulls `ipu6-drivers`,
`ipu6-camera-bins` + `ivsc-firmware`, and wires up `services.v4l2-relayd`.

But it is the **icamerasrc / proprietary-HAL route** — the equivalent of this
repo's older [`webcam-fix/`](../../webcam-fix/), not the recommended
[`webcam-fix-libcamera/`](../../webcam-fix-libcamera/). Two things worth telling him:

- `services.v4l2-relayd` hardcodes **`input.width = 1280`, `input.height = 720`**
  as option defaults, and the ipu6 module does not override them. Those values
  go straight into the appsrc caps. This repo's hardest-won IPU6 lesson is that
  a relay resolution that doesn't match the HAL's native output gives you a
  running service and **zero frames** — which is why our relay auto-detects and
  never hardcodes. If his image is black, that is the first knob.
- The output pipeline *is* `appsrc(NV12) ! videoconvert ! YUY2 ! v4l2sink`, so
  the NV12 conversion is handled. Our "`icamerasrc` needs `! videoconvert`"
  finding does **not** apply here — different config shape. Don't repeat it at him.

### 2. A proper `nixos/webcam-fix-libcamera.nix` is very tractable

Materially **simpler than `webcam-fix-book5.nix`**, which already works. The
libcamera route needs *no out-of-tree kernel modules at all*:

| Book5 module needs | IPU6 equivalent |
| --- | --- |
| `intel_cvs` built from intel/vision-drivers | — not needed |
| `ipu-bridge` override built from tree | — not needed |
| `bayer-fix-v0.7.patch` (OV02E10 rotation) | — not needed, OV02C10 is fine |
| `usb_ljca` / `gpio_ljca` / `intel_cvs` chain | `mei-vsc`, `mei-vsc-hw`, `ivsc-ace`, `ivsc-csi` — **all upstream** |
| libcamera overlay + sensor helper + tuning yaml | same, and the OV02C10 helper is *already* in the Book5 overlay; `webcam-fix-libcamera/ov02c10.yaml` exists |
| `camera-relay` + `v4l2loopback` packaging | reusable verbatim |
| WirePlumber rule matching `ipu7` | same rule, match `ipu6` |

So it is largely `webcam-fix-book5.nix` minus the hard parts, plus IPU6
modprobe softdeps. The shared machinery (camera-relay derivation, libcamera
overlay, the `nixpkgsUnpatched` escape hatch for the pipewire rebuild cascade)
should be factored out rather than copy-pasted.

### 3. The one genuine unknown — firmware path

The installer checks for `/lib/firmware/intel/vsc/ivsc_pkg_ovti02c1_0.bin`.
`pkgs.ivsc-firmware` ships that blob at **`lib/firmware/vsc/`** — no `intel/`
segment:

```
/nix/store/...-ivsc-firmware-unstable-2024-06-14/lib/firmware/vsc/ivsc_pkg_ovti02c1_0.bin
```

Whether `mei_vsc` on a current kernel finds it there, or whether NixOS's
`linux-firmware` also provides the `intel/vsc/` path, is **unverified**. That is
the first thing to check when writing the module, and it is exactly the class of
detail that cannot be settled without the hardware.

### 4. Recommendation

Don't promise a date, and don't ship an untested IPU6 module the way the README
once advertised a `nixos/webcam-fix-libcamera.nix` that never existed. Instead:
tell him what exists today, be honest that the libcamera module isn't written,
and **offer to write it if he'll test it**. That is precisely how
`webcam-fix-book5.nix` came about (@ang3lo-azevedo on a 960XHA).

Suggest opening a tracking issue for the IPU6 Nix module so it isn't buried in
a closed thread — hold until he accepts.

### Status

Offer posted 2026-09-13 with the full gotcha list (Andy approved the offer,
asked that the gotchas be spelled out ahead of time):
https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/95#issuecomment-5655006925

Awaiting @hayden-xyz. If he accepts: open the tracking issue, start from
`nixos/webcam-fix-book5.nix`, and resolve the `ivsc-firmware` path question
first.

---

## Draft reply

Glad it works — thanks for confirming, that's the one part I couldn't check from
here. It's tagged as
[v0.3.69](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/releases/tag/v0.3.69)
now.

Not a bother at all. Two halves to the answer: something you can try today, and
an offer.

## 1. Try nixpkgs' own IPU6 module first

NixOS ships its own, independent of this repo. For your Raptor Lake Book3 Pro:

```nix
hardware.ipu6 = {
  enable = true;
  platform = "ipu6ep";      # Raptor Lake. (Meteor Lake would be ipu6epmtl)
};
```

One rebuild to find out, so it's worth doing before anything else.

It takes the **icamerasrc route** — Intel's proprietary camera HAL driving
`v4l2-relayd` — which is the older of the two approaches here, equivalent to
this repo's [`webcam-fix/`](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/tree/main/webcam-fix)
rather than the recommended
[`webcam-fix-libcamera/`](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/tree/main/webcam-fix-libcamera).

**If you get a camera device but a black image** (as opposed to no device at
all), check the relay resolution before anything else. `services.v4l2-relayd`
defaults to 1280x720 and the ipu6 module doesn't override it:

```nix
services.v4l2-relayd.instances.ipu6.input = { width = 1920; height = 1080; };
```

A relay resolution that doesn't match what the HAL actually outputs gives you a
service that runs happily and delivers **zero frames**. That one cost me a long
time to track down, and it's why our own relay auto-detects the resolution
rather than hardcoding it.

## 2. The libcamera module isn't written — but I'll write it if you'll test it

There's no `nixos/webcam-fix-libcamera.nix`. Saying that plainly rather than
leaving it implied, because the README used to claim that file existed, which is
part of what your issue turned up.

The good news: it's the *easier* of the two Nix modules, not the harder one. The
libcamera route needs **no out-of-tree kernel modules at all** on a current
kernel — `mei-vsc`, `mei-vsc-hw`, `ivsc-ace`, `ivsc-csi`, `intel-ipu6` and
`ov02c10` are all upstream — so it's largely the existing Book5 module with the
IPU7-specific parts *removed*: no `intel_cvs` build, no `ipu-bridge` override,
no Bayer patch. The libcamera overlay, the OV02C10 sensor helper, the tuning
file and the camera relay already exist and are reusable.

What's missing is hardware. You'd be the first Book3/Book4 NixOS user I've had,
so if you're willing to test and iterate a bit, I'll write it.

### Before you say yes — what you'd be signing up for

I'd rather you know these up front than discover them at 1am.

**① The libcamera overlay triggers a very large rebuild.** This is the big one.
Patching libcamera cascades through the Nix fixed-point into everything that
links libpipewire — chromium, discord, qemu, webkitgtk, openal-soft — and they
all lose their binary-cache hits and rebuild **from source**. That can be hours.
The Book5 module has an escape hatch (`nixpkgsUnpatched`) that pins pipewire
back to the unpatched package set so only libcamera itself rebuilds, and the
IPU6 module would get the same thing — but you need to actually set it:

```nix
nixpkgsUnpatched = inputs.nixpkgs.legacyPackages.${pkgs.system};
```

If you try this on a laptop on battery with no time budget, you'll have a bad
evening. Plan the first build for when the machine can be busy for a while.

**② Do not `modprobe -r ov02c10` while IVSC is loaded.** This is a guaranteed
kernel oops — a page fault in `v4l2_fwnode_endpoint_alloc_parse` from stale
firmware nodes. When debugging it is very tempting to unload and reload the
camera modules instead of rebooting. Don't. Reboot. Relatedly, repeatedly
reloading the camera stack accumulates CSI-2 frame-sync errors and makes the
system *progressively worse*, so a run of failed experiments can look like a
regression that isn't one.

**③ Don't test with Cheese, and be careful what a black screen means.** Cheese
segfaults on this hardware with *every* pixel format (in
`libgstvideoconvertscale`) — that's a Cheese bug, not a camera bug, and it will
send you chasing the wrong thing. GNOME Snapshot has its own separate segfault
(workaround: `LIBGL_ALWAYS_SOFTWARE=1 snapshot`). Test with `cam -l`, then a
`gst-launch` pipeline, then Firefox. Also: a JPEG being a plausible size is not
proof of a real image — a 16KB frame can be pure black. Look at it.

**④ Browsers need their own flags, independently of whether the module works.**
Chromium-family needs `--enable-features=WebRtcPipeWireCamera` (that exact
spelling — the feature name is case-sensitive and a wrong case fails silently).
Firefox needs `media.webrtc.camera.allow-pipewire=true` on some distros. So
"the camera doesn't work in my browser" may not be the module's fault, and we
should check `cam -l` first every time.

**⑤ There's one unknown I genuinely can't resolve from here.** Our installer
expects the IVSC firmware at `/lib/firmware/intel/vsc/ivsc_pkg_ovti02c1_0.bin`,
while `pkgs.ivsc-firmware` ships that blob at `lib/firmware/vsc/` — no `intel/`
segment. Whether the kernel finds it there is exactly the kind of thing that
evaluates perfectly and then fails on the machine. It may be the first thing we
have to fix.

**⑥ If the sensor never probes at all**, the candidate is the 26 MHz clock
issue — and we've established that's **per-board, not per-model**: two machines
with the same model number can differ, one needing the fix and one not. So don't
assume your result generalises from anyone else's.

The reassuring part: this is NixOS, so every experiment is one generation you
can roll back from the boot menu. That's genuinely why you're a good person to
test this — the blast radius is smaller for you than for an Ubuntu tester.

### If you're in

Say so and I'll open a tracking issue and start from the Book5 module. To begin
with it'd help to see:

```bash
lspci -nn | grep -i -E 'image|ipu|camera'
dmesg | grep -i -E 'ipu6|vsc|ov02c10' | tail -30
ls -l /run/current-system/firmware/ | grep -i vsc
uname -r; nixos-version
```

And if you do try `hardware.ipu6.enable` first, tell me what happens either way
— a working icamerasrc setup is a useful data point, and a failing one tells us
where the stack breaks before libcamera is even in the picture.
