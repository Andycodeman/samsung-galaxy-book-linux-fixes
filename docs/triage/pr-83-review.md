# PR #83 review — "camera-relay: make Chromium-family browsers actually see the camera"

Reviewed: 2026-08-04. Author: **@4nrry** (Anrry Petrin). Base `main`,
`MERGEABLE`, no CI on the repo. 1 commit, 13 files, +1874/−105.
Head `0bf0f534`, parent `4dc3825` (rebase claim verified — see below).
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/83>

## Verdict: 🟢 **Merge** — with one fix landed as a follow-up

Status: **POSTED and MERGED 2026-08-04.** Approved on the PR, merged as
`b919c24`. Finding 🟠 1 (the helper script was never installed) was fixed
directly on `main` rather than round-tripped through the author — it is
mechanical, needs no hardware, and the bug it unblocks is live.

Both diagnoses are correct, and I confirmed each of them independently rather
than taking the PR's word for it: Bug 1 against the current Chromium source,
Bug 2 by reproducing it live on Andy's own Book4 Ultra, where it is happening
*right now*. The fix path runs end to end on this machine. Nothing here touches
the kernel patches, speaker/mic fixes, sensor tuning YAML or `nixos/`, so the
blast radius is confined to the camera-relay browser story.

One item I would fix before merging (🟠 1): the new script is executed from the
source tree but never installed anywhere, and its own primary recovery path
depends on that tree still existing.

| | |
|---|---|
| Blocking | 0 |
| Should fix (would land in this PR) | 1 |
| Non-blocking | 3 |
| Nits | 3 |
| Bug 1 diagnosis correct? | **Yes** — verified against Chromium source |
| Bug 2 diagnosis correct? | **Yes** — reproduced on this machine |
| Tests | **126 assertions, 7 suites, 0 failures** |
| Hardware validation | **Real** — Book4 Ultra 960XGL, libcamera 0.7.2 |

---

## What I verified

Everything below was actually run, on Andy's Galaxy Book4 Ultra (960XGL,
kernel 7.0.0-28, libcamera 0.7.2, `camera-relay.service` active for 5 days).

### Bug 1 — Chromium's V4L2 filter. Confirmed from the source.

I fetched the current
[`video_capture_device_factory_v4l2.cc`](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/media/capture/video/linux/video_capture_device_factory_v4l2.cc).
`GetDevicesInfo()` enumerates with

```cpp
base::FileEnumerator enumerator(path, false, base::FileEnumerator::FILES, "video*");
```

— no udev anywhere in that path — and gates each candidate on

```cpp
((cap.capabilities & V4L2_CAP_VIDEO_CAPTURE &&
  !(cap.capabilities & V4L2_CAP_VIDEO_OUTPUT)) ||
 (cap.device_caps & V4L2_CAP_VIDEO_CAPTURE &&
  !(cap.device_caps & V4L2_CAP_VIDEO_OUTPUT)))
```

Devices reporting capture *and* output are rejected as memory-to-memory. And on
this machine the relay reports exactly the numbers the PR quotes:

```
$ v4l2-ctl -d /dev/video0 --info
	Card type        : Camera Relay
	Capabilities     : 0x85200003     Video Capture + Video Output + ...
	Device Caps      : 0x05200003     Video Capture + Video Output + ...
```

So the correction to #54 stands: the udev property was never the mechanism, and
`70-camera-relay-capabilities.rules` was never what made Chrome work. Keeping
the rule while rewriting its comments is the right call.

One small discrepancy: today's upstream second branch has **no**
`cap.capabilities & V4L2_CAP_DEVICE_CAPS` guard, but the PR (and the evaluator
in `doctor`) adds one. Behaviourally identical for any real device, since
`device_caps` is only populated when that bit is set — but the snippet is quoted
as verbatim source in four places, so it is worth matching what is actually
there.

### Bug 2 — WirePlumber's stale format list. Reproduced live.

This is not a hypothetical. On this machine, with the relay healthy and up for
five days:

```
$ v4l2-ctl -d /dev/video0 --list-formats-ext
	[0]: 'YUYV' (YUYV 4:2:2)
		Size: Discrete 1920x1080

$ pw-cli enum-params 38 EnumFormat
      Id 8        (Spa:Enum:VideoFormat:BGRx)
      Choice: type Spa:Enum:Choice:Range, flags 00000000 40 8
        Rectangle 2x1
        Rectangle 2x1
        Rectangle 8192x8192
```

Exactly the failure the PR describes — PipeWire is publishing v4l2loopback's
unconfigured catch-all range, not the format the relay pins. Andy's own machine
is currently in the state where Chrome cannot use this camera.

Also worth recording, because the fix depends on it: the device reports
`1920x1080` **discrete while the relay is idle** (pipeline stopped, no client).
So the monitor really does pin the format at startup, and the bounded wait in
`cmd_nudge_wireplumber` converges rather than always timing out.

### The fix path, end to end on real hardware

I extracted `loopback_real_format`, `pipewire_node_for`, `nudge_wireplumber` and
`cmd_nudge_wireplumber` from the branch and ran the real `ExecStartPost` path
against the live device with **only** `systemctl` stubbed:

```
  [info] WirePlumber has stale formats for /dev/video0 (sees 2x1, device offers 1920x1080)
  [info] Restarting WirePlumber so PipeWire-based apps (Chrome, Brave) see a usable camera
rc=0
--- stubbed systemctl calls ---
STUB systemctl --user restart --no-block wireplumber
```

Correct detection, correct invocation (`--user`, `--no-block`, `wireplumber`),
exit 0. I also checked the relay journal across that run: **no client-connect
event, no pipeline start.** The polling does not wake the camera, so it does not
cost a privacy-LED flash at every login. (`camera-relay doctor` *does* wake it,
but that is pre-existing — the doctor streams 60 frames off the loopback.)

### `camera-relay doctor` on this machine

```
── Browsers ──
  firefox: snap — confined; needs 'snap connect firefox:camera'
  brave-browser: /usr/bin/brave-browser
  google-chrome: /usr/bin/google-chrome

  Direct V4L2: Chromium CANNOT see /dev/video0.
    It reports VIDEO_CAPTURE and VIDEO_OUTPUT together
    (caps 0x85200003, device caps 0x05200003), and Chromium
    only accepts a node that reports capture WITHOUT output.
  PipeWire camera source: Camera Relay (V4L2)
  PipeWire format:        STALE — PipeWire says 2x1, device offers 1920x1080
    → fix with: camera-relay nudge-wireplumber
  Chrome PipeWire flag: not set
  Brave PipeWire flag: DISABLED
```

Both bugs correctly identified, plus the per-profile flag state. This is a large
improvement over "consider enabling the flag and hope".

### Tests, syntax, rebase

- **7 suites, 126 assertions, 0 failures** (41 + 18 + 10 + 29 + 5 + 22 + 1).
  Two skips in `test-gst-tools-check.sh` because a real relay holds the
  loopback. The PR says "125 total" — the delta is environment-dependent skips,
  not a discrepancy worth chasing.
- **`bash -n` clean** on all 8 touched shell scripts. `shellcheck` is not
  installed here, so I could not reproduce the "no new warnings" claim.
- **Rebase verified.** `git merge-base --is-ancestor 4dc3825 pr83` → yes, and
  `pr83^` *is* `4dc3825`, so the branch is a clean single commit on current
  `main` — the setgid-launcher concern the PR raises is genuinely resolved.
- **The README really was lying.** On `main`, the only
  `enable-webrtc-pipewire-camera` matches in either installer are `echo` lines.
  No installer ever set the flag. The PR's jab is fair.

---

## Findings

### 🟠 1. `chromium-pipewire-camera.sh` is run from the source tree but never installed

`webcam-fix-libcamera/install.sh:1999` and the matching block in
`webcam-fix-book5/install.sh` execute `"$RELAY_DIR/chromium-pipewire-camera.sh"
enable`, but the installers only `cp` `camera-relay`, `camera-relay-monitor`,
the systray, the `.desktop` file and the icons into system paths. The new script
stays in the extracted tarball.

That matters more than it looks, because **the running-browser guard makes
"skipped, re-run it later" the common case** — most people install with a
browser open. And every one of the three places that tells them how to re-run it
points at a path that may no longer exist:

- the installers' closing message: `quit it and run: camera-relay/chromium-pipewire-camera.sh`
- both READMEs: `cd camera-relay && ./chromium-pipewire-camera.sh`
- `doctor` (`camera-relay/camera-relay:1428`): `Set it with: camera-relay/chromium-pipewire-camera.sh`

— all relative paths into a tree the documented install flow
(`curl -sL …/archive/main.tar.gz | tar xz`) invites the user to delete.

**Fixed on `main`** (follow-up commit): both installers now
`sudo install -m 755 "$RELAY_DIR/chromium-pipewire-camera.sh"
/usr/local/bin/chromium-pipewire-camera` alongside the `camera-relay` copy;
`doctor`, both READMEs and both installers' closing messages reference the
installed command when it is present; both uninstallers prefer the installed
copy over the relative path, remove it, and say what to do about a profile the
running-browser guard skipped. Verified on this machine: installs, runs from
`PATH`, and `doctor` now prints `Set it with: chromium-pipewire-camera`.

### 🟡 2. `enable` silently reverses an explicit "Disabled"

Andy's Brave currently holds `enable-webrtc-pipewire-camera@2` — explicitly
Disabled, almost certainly set on purpose, quite possibly following this
project's *own* earlier "leave it OFF" advice. `enable` rewrites that to `@1`
and reports:

```
  ✓ Brave: PipeWire camera flag enabled
```

On libcamera 0.7+ that is the right end state, and the backup is taken first, so
this is not a data-loss issue. But the message should say a user preference was
reversed — e.g. `(was explicitly Disabled — overridden; original in Local
State.camera-relay.bak)`. As written, `enable_case "explicitly disabled"` in the
test suite locks in the silent behaviour.

### 🟡 3. Two vocabularies for the same fact

Verified side by side on this machine, same profile:

```
$ ./chromium-pipewire-camera.sh status
  Brave:               other
$ camera-relay doctor
  Brave PipeWire flag: DISABLED
```

`other` is the least useful word available for the one state a user most needs
to see. Have `status` reuse doctor's `ENABLED` / `DISABLED` / `not set`.

### 🟡 4. `doctor`'s profile list and its gate are narrower than the script's

`doctor` iterates 5 profiles (Chrome, Chromium, snap Chromium, Brave, Vivaldi);
`chromium_profile_dirs` writes 10 — it adds Chrome Beta, Chrome Unstable and the
three flatpaks. Separately, the whole new browser block is gated on
`chromium_family`, derived from `command -v` over `firefox chromium
chromium-browser brave-browser google-chrome` (`camera-relay:1396`), so a
Vivaldi-only, Edge-only or flatpak-only machine gets **none** of the new
diagnostics even though the installer edited its profile.

Two hand-maintained copies of one list will drift. Cleanest fix is to have
`doctor` shell out to `chromium-pipewire-camera.sh status` — which is exactly
what finding 1's install fix would make possible.

### 🔵 5. Nit — `local … info …` shadows the logging function

`camera-relay:1420` declares `local caps_hex devcaps_hex info visible=1`. Bash
keeps functions and variables in separate namespaces so this is harmless today,
but `info` is the script's own logger and someone will eventually trip over it.
`caps_info` costs nothing.

### 🔵 6. Nit — the backup is never cleaned up

`Local State.camera-relay.bak` is written into the profile directory and
`disable` leaves it there. By uninstall time it is a stale copy of a config the
browser has rewritten hundreds of times. Consider removing it on `disable`.

### 🔵 7. Nit — uninstall inherits the running-browser guard

Uninstalling with a browser open leaves the flag set, pointing it at a PipeWire
camera that is about to disappear. The warning does get printed, so this is
fine — just worth one line in the uninstall output saying to re-run
`chromium-pipewire-camera.sh disable` after quitting the browser.

---

## Question for follow-up — does the second fix retire the need for the first?

The PR's stated reason for not using `exclusive_caps=1` — which would fix
Chrome, Edge **and** every Electron app at once, with no browser-profile edits
at all — is that WirePlumber classifies the node as an output at boot, before
the relay attaches.

But that is a *probe-ordering* problem, and `nudge_wireplumber` is precisely a
fix for probe-ordering. It re-probes after the monitor holds the writer fd, at
which point an `exclusive_caps=1` node reports capture-only. So the second half
of this PR arguably dissolves the objection the first half is built on.

I am not asking to change it here — there is a separate historical reason to be
wary (v4l2loopback 0.12.7 could not switch caps via `write()`, which is why the
project moved to `exclusive_caps=0` in the first place), and the shipped fix is
verified working. But it is worth an experiment, because it is the only route
that would help **Edge and Electron apps**, which this PR explicitly leaves
broken.

---

## Scope and hygiene

Clean. One commit, 13 files, all on one theme — no unrelated fixes bundled.
Both triage documents are amended with dated corrections rather than quietly
rewritten, which is the right way to handle "the previous root cause was wrong".
The compatibility tables now say Edge is not working, which is the honest
answer given the finding.

Nothing outside the camera-relay browser story is touched: no
`linux-6.17/sound/`, no `speaker-fix*/`, no `mic-fix/`, no sensor tuning YAML, no
`nixos/`. The duplicate-tuning-file hazard (`ov02c10.yaml` in two trees,
`ov02e10.yaml` vs `ov02e10-0.5.2.yaml`) does not apply to this diff.
