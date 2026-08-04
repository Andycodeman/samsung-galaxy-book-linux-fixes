# Issue #65 — "Webcam doesn't work on Galaxy Book5 Pro 360 960QHA" (@seshf)

**Status:** first fix landed (`646d668`); **the issue is not closed** — the
relay now starts but the reporter says the camera still does not appear in the
browser. Round 2 (below) adds the measurement needed to find out why.

Round 1 reply **posted** 2026-07-21 with maintainer sign-off —
[comment-5039649723](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/65#issuecomment-5039649723).

Hardware: Galaxy Book5 Pro 360 **960QHA**, IPU7 + **OV02E10**, Kubuntu 26.04,
kernel 7.1.1-070101-generic, Wayland.

---

## What the thread actually established

The reporter's own commands rule out every layer we'd normally suspect:

| Evidence | Conclusion |
| --- | --- |
| `bind ov02e10 3-0010`, `All sensor registration completed` | kernel + IPU7 fine |
| `cam -l` → `1: Internal front camera (\_SB_.LNK0)` | libcamera enumerates fine |
| `[BAYER-FIX] transform=3 … override=auto` | our patched libcamera **is** loaded |
| `gst-launch-1.0 libcamerasrc ! videoconvert ! autovideosink` → **working picture**, 30 fps | the whole camera stack works |
| `gst-inspect-1.0 libcamerasrc` → found, `/usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstlibcamera.so` | the plugin is installed |
| `lsmod` → `v4l2loopback 61440 0` | loopback module loaded |
| Firefox/Brave/Chromium → `NotFoundError` | **nothing is feeding the loopback** |

And the failure itself:

```
$ camera-relay start
ERROR: GStreamer 'libcamerasrc' element not found. Install it:
  ...
  Ubuntu/Debian: sudo apt install gstreamer1.0-libcamera

$ sudo apt install gstreamer1.0-libcamera
gstreamer1.0-libcamera ist schon die neueste Version (0.7.0-1ubuntu2).
```

So the relay refused to start, claiming a package was missing that was already
installed — and the element it claimed was missing demonstrably worked.

The `intel-ipu7-psys … -22` and `Unable to get rectangle` messages in the
original report are noise; they appear on working systems (already answered in
the thread).

## Root cause

`gst-inspect-1.0` and `gst-launch-1.0` ship in **`gstreamer1.0-tools`** on
Debian/Ubuntu (`gstreamer1` on Fedora, `gstreamer` on Arch). Verified locally:

```
$ dpkg -S $(command -v gst-inspect-1.0)   → gstreamer1.0-tools
$ dpkg -S $(command -v gst-launch-1.0)    → gstreamer1.0-tools
$ apt-cache depends gstreamer1.0-libcamera   → no dependency on gstreamer1.0-tools
```

**No installer in this repo ever installs that package**, and nothing else in
the dependency graph pulls it in. Yet `gst-launch-1.0` *is* the relay pipeline
(`camera-relay/camera-relay:456`), and `gst-inspect-1.0` is how the relay and
both installers probe for `libcamerasrc`.

When the binary is absent, `gst-inspect-1.0 libcamerasrc &>/dev/null` exits
**127**, which is indistinguishable from "element not found" to a bare `if !`.
The recovery ladder in `setup_environment()` then retries three times — clear
the registry cache, drop the `/usr/local` overrides — and all three fail
identically, because none of them make the missing binary appear. The relay dies
pointing at the wrong package, which is the dead end the reporter spent the
thread in.

### Why the reporter's paste pins this down

Their output is *only* the `ERROR:` block — no `[camera-relay] Using GStreamer
plugin: …` and no `WARNING: Source-built libcamerasrc … failed to load`. Those
two lines are emitted whenever `detect_gst_plugin_path` / `detect_libcamera_lib_path`
find anything under `/usr/local`. Their absence proves there were **no
`/usr/local` overrides in play**, so all three ladder attempts ran in a pristine
environment — the same environment in which their own `gst-inspect-1.0
libcamerasrc` succeeded 90 minutes later. A missing binary is the only
explanation that fails in that environment and is unaffected by all three
recovery steps.

Reproduced locally by running the pre-fix `camera-relay` with an empty `PATH`;
it emits the reporter's error text verbatim.

**Residual uncertainty:** the reporter's later commands show `gst-inspect-1.0`
working, so they installed `gstreamer1.0-tools` at some point between 20:13 and
21:56 UTC without pasting it (their pasted `apt install gstreamer1.0-libcamera`
installed nothing). The reply asks them to confirm with
`dpkg -l gstreamer1.0-tools`. If it turns out to have been installed all along,
the diagnostics added here will print GStreamer's real complaint on the next
attempt, which is the information the current message throws away.

## Fix

**`camera-relay/camera-relay`**

- `require_gst_tools()` — checks `gst-inspect-1.0` **and** `gst-launch-1.0` up
  front and names `gstreamer1.0-tools` / `gstreamer1` / `gstreamer`. Called
  from `setup_environment()` and `cmd_enable_persistent()` (the latter also
  probes with `gst-inspect-1.0`; with the tools missing it silently baked
  system-only paths into a unit for a relay that could not run).
- `find_libcamera_gst_plugin()` — when `libcamerasrc` genuinely won't load but
  `libgstlibcamera.so` is on disk, say *that* and print `gst-inspect-1.0`'s real
  stderr plus the three commands worth running, instead of telling the user to
  install a package they already have.
- `cmd_status()` — the `Loopback:` line read only the runtime cache, so it
  printed `(not loaded)` whenever the relay had never started, even with the
  module loaded and a device present. Now falls back to
  `detect_loopback_device`, mirroring the `Camera:` line. This actively misled
  the reporter, whose `lsmod` contradicted it.

**`webcam-fix-book5/install.sh`, `webcam-fix-libcamera/install.sh`**

- Install the GStreamer CLI tools before any `gst-inspect-1.0` probe. In
  `webcam-fix-libcamera` this is `ensure_gst_tools()`, called before the
  `verify_libcamerasrc` gate — that gate is a hard `exit 1`, so a host without
  the tools previously aborted the whole install with a false diagnosis.
- Corrected the Ubuntu/Debian remedy package for a genuinely missing
  `libcamerasrc`: `gstreamer1.0-libcamera` (was `gstreamer1.0-plugins-bad`,
  which does not contain the element on Ubuntu), keeping the old package as a
  fallback.

NixOS needs no change — `nixos/webcam-fix-book5.nix:130` already wraps the relay
with `pkgs.gst_all_1.gstreamer`, which provides both binaries.

## Verification

`camera-relay/tests/test-gst-tools-check.sh` (new, 7 assertions, no camera
hardware required, no system state touched — it redirects `XDG_CACHE_HOME` so the
recovery ladder cannot clear the real GStreamer registry):

1. with the tools unreachable, `start` fails naming `gstreamer1.0-tools` and
   **not** `gstreamer1.0-libcamera`;
2. `find_libcamera_gst_plugin` locates an installed plugin;
3. with a stub `gst-inspect-1.0` that always fails, the error says the plugin
   *is* installed and echoes GStreamer's own stderr;
4. `status` reports the live loopback device instead of `(not loaded)`.

Results — **7/7 pass** on the fixed code. Against `HEAD:camera-relay/camera-relay`
the suite fails, and the old run reproduces the reporter's error text verbatim
(including the absence of the `WARNING: Source-built libcamerasrc …` line when no
`/usr/local` build is present). All modified scripts pass `bash -n`.

Running the new diagnostic branch caught a `set -euo pipefail` bug in the fix
itself: `inspect_err=$(gst-inspect-1.0 … | tail -5)` aborted the script before it
could print, since `gst-inspect-1.0` exits non-zero there by definition. Fixed
with `|| true`; the branch was only proven by executing it, not by reading it.

**Not verified:** nothing here was run on a 960QHA. There is no Book5 hardware
in this environment, so "the reporter's camera now works in Firefox" is a
hypothesis, not a result. What is verified is that the relay no longer
misdiagnoses a missing `gstreamer1.0-tools`, and that new installs get the
package.

## Reply posted to #65 (2026-07-21, signed off)

> Your last three comments cracked it — thank you, that was exactly the missing
> signal.
>
> `gst-launch-1.0 libcamerasrc ! videoconvert ! autovideosink` giving you a good
> picture means the camera, the kernel, IPU7, our patched libcamera and the bayer
> fix are all working. The only broken piece is `camera-relay`, the little daemon
> that copies frames into the v4l2loopback device that Firefox/Brave/Chromium
> actually look at. It refused to start, so nothing was feeding that device —
> hence `NotFoundError` in every browser.
>
> **And it refused to start for a silly reason: our own bug.**
>
> `camera-relay` checks for `libcamerasrc` by running `gst-inspect-1.0`. On
> Debian/Ubuntu that binary — and `gst-launch-1.0`, which *is* the relay's
> pipeline — comes from **`gstreamer1.0-tools`**, a package that
> `gstreamer1.0-libcamera` does not depend on and that **none of our installers
> ever installed**. When it's missing, the check exits 127, which our code could
> not tell apart from "element not found", so it told you to install
> `gstreamer1.0-libcamera` — which you already had. Sorry for the runaround; you
> were being sent to fix the one thing that wasn't broken.
>
> **On your machine, right now:**
>
> ```bash
> sudo apt install gstreamer1.0-tools
> camera-relay start
> ```
>
> Then reload the webcam test page. If `camera-relay start` prints
> `Relay started (PID …)`, you should have a camera in Firefox and Chromium.
> To have it come back automatically at login: `camera-relay enable-persistent`.
>
> Could you also paste `dpkg -l gstreamer1.0-tools` before you install anything?
> Your later comments show `gst-inspect-1.0` working, so you may have installed
> it in between — if it was there all along my diagnosis is wrong and I want to
> know that rather than guess.
>
> **What I've fixed** (in review, landing on `main` shortly — the install
> commands pull from `main`, so re-running the installer once it's pushed will
> pick all of this up):
>
> - both installers now install `gstreamer1.0-tools` / `gstreamer1` / `gstreamer`
>   before they probe for anything, so this can't happen on a fresh install;
> - `camera-relay` now reports a missing `gst-inspect-1.0`/`gst-launch-1.0` as
>   exactly that, and when `libcamerasrc` really won't load it prints GStreamer's
>   own error plus the plugin path it found instead of guessing a package name;
> - `camera-relay status` no longer says `Loopback: (not loaded)` when the module
>   is loaded — your `lsmod` output disagreed with it, and `lsmod` was right;
> - fixed the Ubuntu remedy package for a genuinely missing `libcamerasrc`
>   (`gstreamer1.0-libcamera`, not `gstreamer1.0-plugins-bad`).
>
> **Honesty note:** I have no Book5 to test on, so I have verified this against
> the failure mode, not against your laptop. I reproduced your exact error text
> locally by hiding `gst-inspect-1.0`, and there's a regression test covering it —
> but whether your camera appears in Firefox afterwards is the part only you can
> confirm. Please report back either way.

---

# Round 2 — the relay starts, the browser still sees nothing

## What changed in the thread

The reporter got past the original error (comment at 22:13 UTC):

```
$ camera-relay status
  State:      STOPPED
  Persistent: ENABLED (on-demand, auto-starts on login)
  Camera:     \_SB_.LNK0
  Loopback:   /dev/video0

$ camera-relay start
[camera-relay] Relay started (PID 190348)
[camera-relay] Camera available as 'Camera Relay' in apps
```

> "Now i can start and stop the camera. But is not working in the Browser"

Two later comments add:

- `cam -c1 -C10` captures 10 frames at 40 fps, `bytesused: 8355840`
  (= 1920×1088×4, so their default libcamera stream is **1920x1088**);
- `pkg-config --modversion libcamera` → 0.7.0, and the bayer-fix backup at
  `/var/lib/libcamera-bayer-fix-backup/` holds only an empty `usr/` tree;
- `groups` → they **are** in `video`.

They still have not answered `dpkg -l gstreamer1.0-tools`, so round 1's
diagnosis remains unconfirmed. Note `Persistent: ENABLED` while `State: STOPPED`
— the systemd on-demand unit was enabled but not running, which round 1's
missing-`gstreamer1.0-tools` theory explains (the unit dies in
`setup_environment` and `Restart=on-failure` gives up).

## Hypotheses tested and rejected

Both were checked on the maintainer's Book4 (OV02C10, libcamera 0.7.2) rather
than argued about:

1. **Hardcoded `width=1920,height=1080` in the on-demand pipeline breaks a
   1088-tall sensor.** `camera-relay:631` and the monitor's `argv` both pin
   1920x1080, and the reporter's stream is 1920x1088, so a negotiation failure
   looked likely. **Rejected:** `libcamerasrc ! videoconvert !
   video/x-raw,format=YUY2,width=1280,height=720` negotiates fine — libcamera
   reconfigures the stream to whatever size is requested, confirmed by
   `gst-launch-1.0 -v` reporting `width=(int)1280, height=(int)720`. Asking a
   1088-native sensor for 1080 therefore works. The hardcoding is still
   fragile, but it is **not** this bug, so it was left alone.
2. **v4l2loopback advertises no formats until a writer sets one, so browsers
   skip it.** **Rejected:** with no writer at all, `v4l2-ctl --list-formats` on
   the loopback returns a full list (BGR4, RGB4, AR24, …).

## Root cause of round 2: we cannot see what is happening

The thread has now spent six round trips on "the relay starts but the browser
sees nothing" because **no command in this repo reports whether frames are
actually reaching the loopback**. `gst-launch-1.0 ... autovideosink` showing a
picture proves the camera works and says nothing about the device browsers read;
`lsmod` proves the module is loaded and says nothing about frames.

Worse, when the relay pipeline *does* fail, `cmd_start` printed an empty report.
Two stacked bugs:

1. it tailed `camera-relay.log` — the **on-demand daemon's** log — while
   `start_pipeline` writes `camera-relay-gst.log`;
2. even with the path corrected, `tail -20 "$gst_log" 2>/dev/null >&2` applies
   redirections left to right: fd 2 goes to `/dev/null`, then `>&2` duplicates
   *that* onto fd 1, so tail's output was discarded.

So the user saw:

```
ERROR: Relay failed to start. GStreamer output:
───────────────────────────────────────────────
───────────────────────────────────────────────
```

Both bugs had to be fixed for the block to print anything; fixing only the path
(the obvious one) still yields an empty banner. Caught by writing the test
first, not by reading the code.

## Fix

**`camera-relay/camera-relay`**

- `cmd_doctor()` — new `camera-relay doctor` command. One paste-able report:
  system/kernel/session, `video` group membership, tool presence, libcamera
  version + camera name + plugin path + whether `libcamerasrc` loads, module
  and device state with the negotiated format, relay/service/monitor-binary
  state, browser packaging (snap and flatpak confinement), and recent GStreamer
  and journal logs.
  The decisive section is **Frames on the loopback**: it streams 60 frames,
  keeps the last 256 KB (skipping the monitor's black start-up placeholders)
  and classifies the result as `NO FRAMES` / `BLANK FRAMES` / `REAL PICTURE`
  by counting distinct byte values. That single line separates "our relay is
  broken" from "your browser cannot see a working device".
- `cmd_start()` — corrected the log path and the redirection order so a failed
  pipeline actually shows GStreamer's error.

Two bugs in `cmd_doctor` were themselves caught by running it, not reading it:
`lsmod | grep -q v4l2loopback` reported the module as absent (grep exits on the
first match, SIGPIPEs `lsmod`, and `set -o pipefail` fails the whole test — it
now reads `/proc/modules` directly), and `systemctl is-active ... || echo
inactive` printed `inactive` twice, since `is-active` prints its answer *and*
exits non-zero.

**Not changed:** the hardcoded 1920x1080 (see rejected hypothesis 1) and the
same `find | grep -q .` pipefail pattern in `detect_ipa_path()`, which is
pre-existing and unrelated to this issue.

## Verification

`camera-relay/tests/test-gst-tools-check.sh` grew from 7 to 11 assertions.
The new ones:

5. a pipeline failure (forced by seeding the camera-name cache with a
   non-existent camera) reports the failure **and** includes GStreamer's own
   output — asserted by matching on the empty-banner shape, so it fails if
   either of the two stacked bugs is present;
6. `doctor` classifies a synthetic all-black stream (`videotestsrc
   pattern=black ! v4l2sink`) as `BLANK FRAMES` rather than success, and runs
   to completion with exit 0.

Results — **11/11 pass** on the fixed code; against `HEAD:camera-relay/camera-relay`
the three new assertions fail. `doctor` was additionally run by hand in all
three frame states on the maintainer's Book4: relay stopped → `NO FRAMES`,
synthetic black stream → `BLANK FRAMES`, relay running → `REAL PICTURE — 262144
bytes captured, 122 distinct byte values`.

**Not verified:** still nothing on a 960QHA. Round 2 does not claim to fix the
reporter's camera — it makes the next report diagnostic instead of anecdotal.

## Round 2 reply posted to #65 (2026-07-21)

[comment-5040240218](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/65#issuecomment-5040240218).
Confirms the camera and permissions are fine and the backup directory is a
red herring, then asks for the one measurement nobody has taken: a live frame
off `/dev/video0` with its distinct-byte-value count, plus
`camera-relay status` after start, the GStreamer log, `systemctl --user status`,
and `snap list` (snap-confined browsers would explain all three failing at
once). `doctor` itself is not on `main` yet, so the reply spells out the raw
`v4l2-ctl` equivalent instead of pointing at the new command.

---

# Round 3 — `STREAMING` with a loopback refcount of 0

Reporter comment 2026-07-21 23:51 (written before they saw the round 2
questions), plus their guess that stale device nodes are to blame:

> "The many /dev/video are from older test installs. I don't known how i can
> remove the /dev/video that don't exists physical. Maybe this is the problem
> why that don't work in the Browser and VCL."

```
$ camera-relay status
  State:      STREAMING (PID 207442)
  Loopback:   /dev/video0

$ ls -l /dev/video*      → video0 … video32   (33 nodes)
$ lsmod | grep v4l2loopback
v4l2loopback           61440  0
```

## Their theory is wrong, and the paste contains the real anomaly

**The 33 nodes are normal.** Checked against the maintainer's working Book4:
it has **49** — `video0: Camera Relay` plus `video1…video48: Intel IPU6 ISYS
Capture 0…47`. IPU6/IPU7 ISYS registers one node per virtual stream; they are
not leftovers, cannot be removed, and are not the problem. Their layout matches
a healthy machine, `video0` included: v4l2loopback loads before the IPU driver
and takes the first minor.

**The anomaly is `v4l2loopback 61440 0` while `status` says STREAMING.** The
third column is the module reference count. Measured on Book4:

| Relay state | refcount | holder |
| --- | --- | --- |
| stopped | 0 | — |
| streaming | 1 | `gst-launch-1.0` (`fuser -v /dev/video0`) |

So on a working system a streaming relay holds the device and the count is 1.
The reporter's count is **0 while the relay claims to be streaming**: no process
has the loopback open, therefore nothing has written a frame to it, therefore
browsers correctly report no camera. Whatever PID 207442 is, its pipeline is not
attached to `/dev/video0`.

This is possible because `is_running()` only does `kill -0` on the PID from
`$PID_FILE`, and `cmd_status` prints `STREAMING` from `$STATE_CACHE`. Neither
looks at the device. A pipeline that exits, or never opens the sink, leaves both
saying everything is fine.

## Fix

`cmd_doctor()` now prints the module reference count and, when it is 0, says
plainly that nothing has the device open and that a `STREAMING` line below it is
therefore false. One `awk` on `/proc/modules`; no new dependency. Verified in
both states on Book4 (`refcount 0` + warning when stopped, `refcount 1` and no
warning when streaming). Suite still 11/11.

Still open: *why* the pipeline detaches on the 960QHA. `doctor`'s frame check
plus the GStreamer log it prints should answer that in one paste — the reporter
has not run it yet.

---

# Round 4 — RESOLVED on the reporter's hardware

Reporter, 2026-07-22 00:07 (before reading rounds 2–3):

> "I do not have make any updates, i see your comments right now. But i have
> reboot my System an now the camera works in firefox."

Firefox reports `Camera Relay (V4L2)`, 1920x1080, 21 fps. **Issue #65's symptom
is gone**, and the round 1 diagnosis holds: the missing `gstreamer1.0-tools` was
the root cause. They installed it, but the camera did not come back until a
reboot — and the reason for that is a second bug, now found and fixed.

## Why a reboot was required

`is_running()` treats "the PID in `$PID_FILE` is alive" as "the relay is
working". Nothing checks the device. So this state is reachable and sticky:

1. a relay start leaves `$PID_FILE` pointing at a `gst-launch-1.0` that later
   lets go of the loopback but keeps running (their `v4l2loopback 61440 0`
   alongside `State: STREAMING (PID 207442)`);
2. `cmd_status` prints `STREAMING` from `$STATE_CACHE` — no contradiction visible;
3. the on-demand systemd unit starts, `is_running()` returns true, it prints
   `Already running` and **exits 0**. `Restart=on-failure` reads a clean exit as
   success, so systemd never retries;
4. nothing recovers. `$PID_FILE` lives in `$XDG_RUNTIME_DIR`, which is wiped on
   reboot — which is why only a reboot fixed it.

Reproduced exactly on Book4 by pointing `$PID_FILE` at a plain `sleep`:
`camera-relay start --on-demand` printed `Already running (PID …)` and exited 0,
and `status` reported `STREAMING` for a process that was doing nothing.

## Fix

- `relay_holds_loopback()` — reads the v4l2loopback refcount from
  `/proc/modules`. Both relay modes hold the device for their whole lifetime
  (the always-on pipeline via `v4l2sink`, the on-demand monitor via the writer
  fd it never releases), so a refcount of 0 proves nothing is attached.
- `already_running_healthy()` — replaces the bare `is_running` guard in both
  `cmd_start` and `cmd_start_on_demand`. A live-but-detached relay is now
  reported and cleared via `cmd_stop` instead of being trusted, so the service
  starts fresh rather than no-opping. A healthy relay is still recognised and
  left alone.

Measured on Book4: refcount 0 stopped, 1 while streaming, holder confirmed as
`gst-launch-1.0` by `fuser -v /dev/video0`.

## Verification

Suite now **13/13**. The two new assertions (a live non-relaying PID must not
count as running; stale state must be cleared, not silently accepted) fail
against the previous commit. A genuinely running relay is still correctly
reported as `Already running`.

**Verified on the reporter's hardware:** the original symptom only — they
confirm the camera works in Firefox. The stale-PID fix is verified on Book4 and
prevents the reboot they needed; it has not been exercised on a 960QHA.

---

# Round 5 — working, but Chromium-family browsers need the PipeWire flag

Reporter, 2026-07-22: camera confirmed working in Firefox and VLC (screenshot of
a real picture posted), then after installing v0.3.56:

> "The camera in brave and cromium works only when i enable this"

Both screenshots show the same setting, in Brave and in Chromium:

```
chrome://flags/#enable-webrtc-pipewire-camera   →  Enabled
```

Also disclosed, from before their reboot:

```
sudo modprobe v4l2loopback video_nr=0 card_label="Virtuelle_Webcam" exclusive_caps=1
```

— they had manually loaded v4l2loopback with **`exclusive_caps=1`** and a
non-default card label, both of which conflict with
`99-camera-relay-loopback.conf` (`exclusive_caps=0`, `card_label="Camera Relay"`).
That is a second reason the reboot changed things: it reloaded the module from
our modprobe.d config. Worth remembering when a report includes hand-run
`modprobe` lines.

## Our docs said the opposite of what they needed

Three places told users to keep that flag off:

- `webcam-fix-book5/README.md` — "**not recommended** … only try it as a last resort"
- `webcam-fix-libcamera/README.md` — "**not recommended** … browsers work reliably without this flag"
- `webcam-fix-libcamera/README.md` (troubleshooting) — "**Keep … DISABLED**"

plus the same line printed by both installers. Following that advice would have
left this reporter with no camera in Brave or Chromium.

The "keep it disabled" rule is real but **version-specific**, and only one of the
three places said so: on Ubuntu 24.04 (Noble) / Zorin the system libcamera is
**0.2.0**, which has no IPU6 support, so the flag routes Chrome down a broken
path and bypasses the working V4L2 relay. The reporter is on libcamera **0.7.0**,
where that reason does not apply.

## Why Firefox works without the flag and Chromium does not

The relay node is created with `exclusive_caps=0`, so it advertises **both**
capture and output. Verified on Book4:

```
$ v4l2-ctl -d /dev/video0 --info
Device Caps      : 0x05200003
    Video Capture
    Video Output
    ...
```

Firefox accepts that and reads the device directly over V4L2. Chromium-family
browsers are stricter, and snap/flatpak builds are sandboxed away from
`/dev/video*` altogether; the flag routes them through PipeWire instead, where
WirePlumber presents the relay as an ordinary camera. The dual-caps fact is
measured; that it is *the* reason Chromium skips the node is a strong inference,
not something confirmed from Chromium's side, and the docs are worded to match.

## Fix (documentation + one diagnostic line)

- `webcam-fix-book5/README.md` — replaced the blanket "not recommended" note
  with a symptom-first section: *Firefox sees the camera but Brave / Chromium
  don't* → enable the flag, fully restart the browser, plus the two exceptions
  (libcamera 0.2.0, and Edge which has no such flag).
- `webcam-fix-libcamera/README.md` — both mentions now key the advice off
  `pkg-config --modversion libcamera` rather than stating a blanket rule.
- both installers' post-install hints rewritten the same way.
- `camera-relay doctor` — when a Chromium-family browser is installed, the
  Browsers section now names the flag and its version caveat.

No code path changed; `bash -n` clean on all three scripts and the suite is
still 13/13.

---

# Round 6 — the dual-caps inference is now confirmed from Chromium's side

**2026-08-04.** Round 5 ends with:

> The dual-caps fact is measured; that it is *the* reason Chromium skips the
> node is a strong inference, not something confirmed from Chromium's side, and
> the docs are worded to match.

It is confirmed. `media/capture/video/linux/video_capture_device_factory_v4l2.cc`
gates every candidate node on:

```c
(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE &&
 !(cap.capabilities & V4L2_CAP_VIDEO_OUTPUT)) ||
(cap.capabilities & V4L2_CAP_DEVICE_CAPS &&
 cap.device_caps & V4L2_CAP_VIDEO_CAPTURE &&
 !(cap.device_caps & V4L2_CAP_VIDEO_OUTPUT))
```

Both branches require `!VIDEO_OUTPUT`, and the relay reports `0x05200003` —
capture *and* output — so both fail. Enumeration itself is a `base::FileEnumerator`
walk of `/dev/video*`, which also settles issue #54: no udev property is consulted
anywhere in that path.

## Consequences for how this was worded

The docs said Chromium-family browsers "often will not" accept dual caps and are
"stricter". Both understate it. The check is unconditional, so:

- It is not setup-dependent and not a "some setups" problem. **No** Chromium-family
  browser can ever see the relay node under `exclusive_caps=0`.
- The flag is **required**, not a fallback for when Firefox works and Brave
  doesn't. Round 5 already found users who needed it; every Chrome user needs it.
- It applies to Edge and to Electron apps (Slack, Teams, Discord, VS Code), which
  share the capture code. Edge has no such flag and cannot be fixed this way.

Reproduced on a Book4 Ultra, Ubuntu 26.04, libcamera 0.7.2, Chrome 151 (deb, not
snap, so sandboxing is not a factor): `enumerateDevices()` returns
`videoinput: []` while audio devices enumerate normally, with the relay running
and `ID_V4L_CAPABILITIES=:capture:` correctly set.

## What changed

- `camera-relay/chromium-pipewire-camera.sh` — sets the flag in every
  Chromium-family profile (Chrome, Chromium incl. snap, Brave, Vivaldi, flatpaks),
  gated on libcamera 0.7+, refusing while the browser is running because Chromium
  rewrites `Local State` on exit. Both installers call it; both uninstallers call
  `disable`. Covered by `camera-relay/tests/test-chromium-pipewire-flag.sh`.
- `camera-relay doctor` — evaluates Chromium's expression against the live node
  and reports the per-profile flag state instead of suggesting the user try it.
- The top-level README claimed the installer already enabled this flag. No
  installer did; now one does.

---

# Round 7 — the flag was necessary but not sufficient

**2026-08-04.** Enabling `enable-webrtc-pipewire-camera` on the Book4 Ultra above
did **not** make the camera appear. Chrome still returned:

```js
await navigator.mediaDevices.getUserMedia({video:true})
// NotFoundError: Requested device not found
```

The flag itself was working — `--enable-features=WebRtcPipeWireCamera` reached
every Chrome child process, and with `--vmodule=*pipewire*=3`:

```
camera_portal.cc:135]    Successfully created proxy for the portal.
camera_portal.cc:215]    Camera access granted by the XDG portal.
pipewire_session.cc:99]  Found Camera: Camera Relay (V4L2)
pipewire_session.cc:427] Enumerating PipeWire camera devices complete.
```

Chrome **finds** the camera and then offers no device. The portal was fine too:
`IsCameraPresent` was `true`, the permission store held
`{'com.google.Chrome': ['yes']}`, and `media.role=Camera` was set on the node.

## The node's format list is stale

```
$ pw-cli enum-params <node> EnumFormat        $ v4l2-ctl -d /dev/video0 --list-formats-ext
  VideoFormat:BGRx                              [0]: 'YUYV' (YUYV 4:2:2)
  Rectangle 2x1  →  8192x8192  (Choice:Range)        Size: Discrete 1920x1080
```

PipeWire is advertising v4l2loopback's unconfigured catch-all set, not the format
the relay actually pins. WebRTC's PipeWire camera path needs a discrete rectangle
out of `SPA_PARAM_EnumFormat`; a `Choice:Range` yields no resolution, so the
device is built with zero capabilities — found, unusable.

**Why:** v4l2loopback loads at boot from `modules-load.d` with no producer. The
relay's monitor pins `YUYV 1920x1080` only at login, and `camera-relay.service`
is ordered `After=wireplumber.service`, so WirePlumber always probes the
unconfigured device and never re-probes. Firefox is immune because it reads
`/dev/video0` directly and never consults PipeWire's format list.

Confirmed by an actual reboot mid-investigation: the flag survived, the node
regressed to `BGRx / Rectangle 2x1`, and Chrome went back to finding nothing.

## Fix

`nudge_wireplumber` is back in `camera-relay`, called from `ExecStartPost`. It
waits for the monitor to pin the format (ExecStartPost runs as soon as
`Type=simple` ExecStart *forks*, which is too early — the first attempt read no
format at all and silently did nothing), compares it against what PipeWire
advertises, and restarts WirePlumber only when they disagree.

The two reasons it was removed in the first place do not apply where it now runs:

- *"sudo prompt blocks/confuses users"* — that was `udevadm trigger`, needed
  because the legacy `v4l2-relayd` is a **system** service. `camera-relay` is a
  user service, so `systemctl --user` needs no privileges, and the restart alone
  is sufficient; the udev event only ever mattered for the caps flip.
- *"restart disrupts active camera streams"* — at relay start nothing is
  streaming yet.

`ExecStartPost` carries a `-` prefix: this is a browser-only correction and must
never take down a relay that works for every V4L2 app.

Verified by simulating the boot race — stop relay, restart WirePlumber (node goes
to `BGRx 2x1`), start relay → `YUY2 1920x1080`, relay still active. Covered by
`camera-relay/tests/test-wireplumber-format-nudge.sh` (22 assertions).

## Note for future triage

Two independent bugs stacked here, and each one alone fully explains the symptom
"Chrome has no camera". Fixing only the first leaves the symptom unchanged, which
is exactly how #54 and #65 both landed on the wrong mechanism. `camera-relay
doctor` now checks both.
