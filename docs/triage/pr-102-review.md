# PR #102 review — "Book5 webcam fixes and libcamera patches"

Reviewed: 2026-10-04. Author: **@ang3lo-azevedo** (Ângelo Azevedo), the
established NixOS Book5 contributor (PR #60, PR #30, issue #59; most of
`nixos/webcam-fix-book5.nix`'s history). Base `main`, head is the fork's `main`
at `f2a20e76`. 25 commits (two of them merges from upstream), 14 files,
+860/−300. `maintainerCanModify: true`. No CI on the repo.
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/102>

## Verdict: 🟡 **Request changes + split** (not merged)

Most of this PR is NixOS-only and in good shape. It evaluates and builds, and it
is opt-in. Two changes reach **every non-NixOS user**, though, and one of those is
a security regression in the setgid launcher. Several other parts are good and
unrelated to each other, so I asked for a split instead of a single fix-up round.

| | |
|---|---|
| Blocking | 2: setgid launcher trusts a user-controlled cache dir; shared OV02E10 CCM change backed only by one machine's measurements on the patched NixOS stack |
| Should fix | 5: removed option without `mkRemovedOptionModule`; system-wide patched-IPA path; patches pinned to libcamera 0.7.2; relay cache dir moved for everyone; README |
| Nits | 3 |
| Mergeable vs `main` | **Yes**: `git merge-tree` is clean. Merge base `5a8be0b`. `main`'s newer commits (62ca875 / v0.3.72, #103) touch only `speaker-fix/*check-upstream*` and `webcam-fix-book5/ipu-bridge-check-upstream.*`, which the PR doesn't touch, so it reverts nothing |
| Touches non-NixOS users? | **Yes**: `camera-relay-gst.c`, `camera-relay-monitor.c`, `camera-relay` (every install), `ov02e10.yaml` (every Book5 OV02E10 shell install) |
| Scope | Four unrelated changes in one PR (see split below) |
| Hardware validation | **Not by us.** No Book5 here. All evidence below is build, test, eval and source reading |

---

## What I verified

### 1. Mergeability

```
$ git merge-base pr-102 origin/main        → 5a8be0bb
$ git merge-tree --write-tree origin/main pr-102   → clean (rc=0)
$ git diff --name-only 5a8be0b origin/main | grep -v ^docs
speaker-fix/max98390-hda-check-upstream.{service,sh}
webcam-fix-book5/ipu-bridge-check-upstream.{service,sh}
```

None of these files are in the PR, and the PR doesn't touch any
`check-upstream` path, so the #103 fix is safe.

### 2. B1 — setgid launcher now takes its cache dir from the caller (BLOCKING)

`camera-relay/camera-relay-gst.c` at PR head, L285–305 (`build_environment`):

```c
const char *cache_dir = getenv("CACHE_DIRECTORY");
if (!cache_dir) { ... "%s/.cache/camera-relay", home ... }
snprintf(..., "HOME=%s", cache_dir);
snprintf(..., "GST_REGISTRY=%s/gst-registry.bin", cache_dir);
```

On `main` this was a compile-time `/var/cache/camera-relay`. The launcher is
installed **setgid `camera-relay`** by `webcam-fix-libcamera/install.sh:1598-1602`
(`chmod 2755`). That covers every Book3/Book4 shell install. The group is the only
way to open the raw IPU6 nodes, and the header comment (security property #2)
says nothing from the inherited environment may steer code loading. The
webcam-fix-book5 installer installs it as plain 755 (`install.sh:1131`), so
Book5 shell users aren't exposed. Book4 users are.

Launcher half, shown by compiling the PR's file into a harness that prints
`build_environment()`:

```
$ env -i HOME=/home/victim CACHE_DIRECTORY=/home/victim/evil ./envdump
HOME=/home/victim/evil
GST_REGISTRY=/home/victim/evil/gst-registry.bin
$ env -i HOME=/home/victim ./envdump
HOME=/home/victim/.cache/camera-relay
GST_REGISTRY=/home/victim/.cache/camera-relay/gst-registry.bin
```

GStreamer half: with the launcher's environment shape (no
`GST_PLUGIN_SYSTEM_PATH`, `HOME` set), GStreamer scans the user plugin dir under
`$HOME`:

```
$ env -i PATH=/usr/bin:/bin HOME=$SP/fakehome GST_REGISTRY=$SP/fakehome/reg.bin \
    GST_DEBUG=GST_REGISTRY:5 gst-inspect-1.0 --version
... scanning path .../fakehome/.local/share/gstreamer-1.0/plugins
... scanning path /usr/lib/x86_64-linux-gnu/gstreamer-1.0
```

So a `.so` dropped into `~/.cache/camera-relay/.local/share/gstreamer-1.0/plugins/`
runs as egid `camera-relay`, after `assume_group()`. I didn't build a working
plugin payload; the two halves are each shown directly.

The same change breaks the launcher test suite:

```
test-launcher-validation.sh (main)   29 passed, 0 failed
test-launcher-validation.sh (PR)     ✗ build failed:
  camera-relay-gst.c:300:48: error: '%s' directive output may be truncated ... [-Werror=format-truncation=]
  (also :302, :304)
```

Origin: commit `f2a20e7` ("address PR #102 review feedback") removed the Nix
`systemd.tmpfiles.rules = ["d /var/cache/camera-relay 1777 root root -"]`
after Copilot flagged it, which was a valid point, and moved per-user caching into
the C file. The fix belongs on the Nix side. The Nix build isn't setgid
(`webcam-fix-book5.nix:210-212`), so a compile-time define such as
`-DCAMERA_RELAY_USER_CACHE` set only by the Nix derivation keeps the FHS build
unchanged.

### 3. B2 — `ov02e10.yaml` CCM change hits every Book5 shell install (BLOCKING)

`webcam-fix-book5/install.sh:850-880` copies `ov02e10.yaml` into
`/usr{,/local}/share/libcamera/ipa/simple/` for every OV02E10 user on
libcamera ≥ 0.6. It also prints "CCM tuned by david-bartlett on Galaxy Book5
Pro", which would no longer be true. Those users don't get the four new patches:
`grep` finds no reference to them outside `nixos/webcam-fix-book5.nix:29-33`.

What the YAML change is, computed:

| ct | row sums `main` | row sums PR |
|---|---|---|
| 2700 | 1.38 / 1.137 / 1.204 | 1.09 / 1.00 / 1.031 |
| 4500 | 1.43 / 1.12 / 1.254 | 1.09 / 1.00 / 1.031 |
| 6500 | 1.27 / 0.91 / 1.276 | 1.09 / 1.00 / 1.029 |

Each row is the old row scaled to a fixed sum. For example, the 2700 R row
`[1.62, −0.14, −0.10] × 1.09/1.38 = [1.28, −0.111, −0.079]`. The arithmetic and
the PR comment's "1.09/1.0/1.03" agree. The evidence is one 960XHA on the
patched NixOS stack (and probably the low-noise driver). The file previously
documented the opposite tradeoff ("Normalising to 1.0 produces washed-out
colours"). Issue #49's purple is the bayer shift, which no CCM fixes (see
`tune-ccm.sh`), so this neither helps nor hurts that thread.

`exposureTarget: 1.5` is harmless on shell installs. Stock v0.7.2
`src/ipa/simple/algorithms/agc.h` has no `init()` override, so the key is never
read. That leaves the CCM rescale as the only change for those users.

Requested: before/after results from at least one Book5 owner on the shell
installer (@david-bartlett, @seshf, @hatchlof have all reported on Book5 colour
before). Until then, keep the new tuning in the Nix derivation. It already
rewrites `ov02e10.yaml` in `postInstall` (`webcam-fix-book5.nix:76-94`).

### 4. libcamera patches: apply and compile only on libcamera 0.7.2

Applied in the Nix order (`bayer-fix-v0.7`, `blc-channel-levels`,
`agc-min-gain-step`, `awb-skip-saturated`, `agc-exposure-target`) to libcamera
tags from git.libcamera.org:

| ref | result |
|---|---|
| v0.7.0 | `agc-min-gain-step` FAILED, `awb-skip-saturated` FAILED, `agc-exposure-target` FAILED |
| v0.7.1 | `agc-exposure-target` FAILED |
| **v0.7.2** | all clean |
| master (2026-10-01) | `blc`/`agc`/`awb` all fail: simple IPA reworked upstream (`d5d00b9c3` awb → libipa, `c875f0245` ccm → libipa) |

The ordering also matters: `awb-skip-saturated` has `blc-channel-levels`'s hunk
as context.

nixos-unstable ships **libcamera 0.7.2** (evaluated). A real build in the
`nixos/nix` container (nix 2.35.2) of the relay package with `videoFlip = true`
succeeded. All five patches applied, `ipa_soft_simple.so` compiled and signed,
every `substituteInPlace --replace-fail` in `cameraRelayGst` matched, and the
built launcher contains the store `gst-launch-1.0`, the store `cam`, and
`LIBCAMERA_FORCE_OV02E10_ROTATION=180`.

Because these are hard `patches`, the next nixpkgs libcamera bump fails
`nixos-rebuild` for every user of the module. That's a should-fix, either a version
guard or a prominent note. `build-patched-libcamera.sh` (shell path) doesn't
use them. That's fine as long as it's stated as intentional.

### 5. NixOS module: evaluation results

Evaluated with `eval-config.nix` against nixos-unstable (`$SP/nixeval/eval.nix`,
outside the repo):

| case | result |
|---|---|
| all 6 `nixos/*.nix` | `nix-instantiate --parse` OK |
| `enable = true` | evaluates. Modules: `vision-driver`, `ipu-bridge-fix-1.1`, `v4l2loopback-0.15.4`. Toplevel `.drv` instantiates |
| module imported, `enable = false` | no modules, no session vars, so **opt-in is preserved** (Copilot's high finding is addressed) |
| `videoFlip + lowNoise + loopbackVideoNr` | adds `ov02e10-lownoise`, `LIBCAMERA_FORCE_OV02E10_ROTATION=180` in the unit env |
| old config setting `nixpkgsUnpatched` | **`error: The option ... nixpkgsUnpatched' does not exist`** |
| `kernel.commonMakeFlags` | exists (passthru on the nixpkgs kernel) |

Should-fix items from the module (line numbers at PR head):

- **S1** `webcam-fix-book5.nix:361`: `nixpkgsUnpatched` was removed without
  `lib.mkRemovedOptionModule`, so existing configs break at evaluation with no
  hint (shown above).
- **S2** `webcam-fix-book5.nix:471-473`: `environment.sessionVariables.LIBCAMERA_IPA_MODULE_PATH`
  points every session at `libcamera-book5`'s IPA while system `pkgs.libcamera`
  is stock. `awb-skip-saturated.patch` adds `sumCount_` to `SwIspStats`
  (`include/libcamera/internal/software_isp/swisp_stats.h`), a struct shared
  between `libcamera.so`'s `swstats_cpu` and the IPA. A stock-libcamera consumer
  that honours the variable loads a patched IPA (isolated, because it's signed
  with a different key) that reads a different layout. The audience is small
  because the WirePlumber libcamera monitor is disabled, but the variable has no
  purpose, since the relay gets the path from its unit env and wrapper (`:292`, `:305`).
  Related: the `pipewire`/`wireplumber` `LIBCAMERA_FORCE_OV02E10_ROTATION` env
  (`:543-549`) is dead now.
- **S5** `nixos/README.md`: no docs for `ipuBridgeFix`, `lowNoise` or
  `loopbackVideoNr`, or for the behaviour change that `monitor.libcamera` is
  disabled (`:512-514`), which leaves PipeWire apps seeing only the relay node.

### 6. `camera-relay` script (every install)

`camera-relay:19` changes `CACHE_DIR` from `$XDG_RUNTIME_DIR` to
`${RUNTIME_DIRECTORY:-$XDG_RUNTIME_DIR/camera-relay}` and adds `mkdir -p`.
`bash -n` is clean, and shellcheck (koalaman/shellcheck:stable) reports the same
2 pre-existing findings on main and PR, none new. But it moves the
camera-name, device and state caches for every install, and
`test-gst-tools-check.sh` §5 (`:127`) and §7 (`:205`) still seed the old
location. Both were skipped on this host because a live relay holds the
loopback, so I couldn't show the fixture break at runtime. Reading the code,
the seeded file is never read under the PR. **S4**: use
`CACHE_DIR="${RUNTIME_DIRECTORY:-${XDG_RUNTIME_DIR:-/tmp}}"` so only the Nix
unit (which sets `RuntimeDirectory=`) moves.

### 7. Good parts, verified

**`append_color_filter` `!` fix (`camera-relay-gst.c:238-245`): a real bug on
`main`.** I hooked `execve` in a harness build to print argv:

```
[main] ... videoconvert ! videobalance saturation=0.9 ! ! videoflip method=vertical-flip ! video/x-raw,...
[PR]   ... videoconvert ! videobalance saturation=0.9 ! videoflip method=vertical-flip ! video/x-raw,...
```

On `main`, any chained `RELAY_COLOR_FILTER` produces `! !`, which gst-launch
rejects. The fix is one line and correct. No regression test was added.

**`camera-relay-monitor.c` usage events: consistent with v4l2loopback.** I checked
against upstream `v4l2loopback.c`. `V4L2_EVENT_PRI_CLIENT_USAGE` =
`PRIVATE_START + 0x08E00000 + 1` (matches the monitor's `_NEW`). The payload is
`count = !has_capture_token(dev->stream_tokens)`, queued on capture STREAMON
(`:2079`), STREAMOFF (`:2124`), on subscribe, and on close via `REQBUFS(0)` →
`vidioc_streamoff`. The replace and merge ops keep the latest state, so
`reader_streaming` can't get stuck at 1. The 0.12.x (`_OLD`) path is untouched,
since `note_usage_event` ignores it, so Ubuntu's 0.12.7 is unaffected. It does
change behaviour for 0.13+ (Fedora/Arch, Nix's 0.15.4). It compiles warning-free
with `-Wall -Wextra`.

**Test suites on PR head** (`camera-relay/tests/*.sh`): all pass except
`test-launcher-validation.sh` (B1). Results: chromium-pipewire-flag 61/0,
distro-detection 16/0, egl-vendor-pin 18/0, firefox-pipewire-pref 15/0,
gst-tools-check 8/0 (3 skipped, live relay), monitor-exit-propagation 5/0,
pipewire-restart-guard 17/0, unit-regeneration 15/0, wireplumber-format-nudge
26/0, writer-format-check 1/0.

**Style commits** (`samsung-speaker-fix.nix`, `max98390-hda-module.nix`,
`ov02c10-26mhz-fix.nix`): `inherit` refactors, semantically identical.

## Nits

- **N1** `ov02c10-26mhz-fix.nix:31-32` still builds clang flags from
  `pkgs.llvmPackages`, not `kernel.commonMakeFlags`, which is the toolchain
  mismatch the PR fixes elsewhere. `max98390-hda-module.nix` too.
- **N2** `ipu-bridge-fix.nix` and `webcam-fix-book5.nix` both ship
  `lib/modules/*/extra/ipu-bridge.ko`. nixpkgs' `aggregateModules` is a plain
  `buildEnv`. Whether two separately built `.ko`s collide wasn't tested. An
  assertion that the two modules are mutually exclusive would settle it.
- **N3** The PR body describes only the last ~4 commits. It doesn't mention the C
  relay changes. Also `substituteInPlace --replace` deprecation warnings (pre-existing).

## Split requested

1. `!` fix in `append_color_filter` plus a case in `test-launcher-validation.sh`. **Merge immediately.**
2. `camera-relay-monitor.c` usage-event tracking. Separate review and test on 0.13+.
3. NixOS rework (scoped libcamera, `ipu-bridge-fix.nix`, lowNoise, loopbackVideoNr, style/toolchain), with Nix-only cache handling, Nix-only tuning, `mkRemovedOptionModule`, no session IPA var, and README.
4. Shared `ov02e10.yaml` change, only with shell-installer reports from other Book5 owners.

When testers report on (3) or (4), ask them to report separately whether the
**sensor probes** and whether the **camera works** with correct colour. Per the
#96 lesson, those are different claims.

---

## What was posted

Review: **CHANGES_REQUESTED**, 2026-10-04.
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/102#pullrequestreview-5407442218>

Thank-you comment:
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/102#issuecomment-5982855210>

### Review body

> Thanks a lot for this, @ang3lo-azevedo, and for continuing to carry the NixOS Book5 side of the repo. The scoped `libcamera-book5` is the right direction: it removes the rebuild cascade without needing the `nixpkgsUnpatched` workaround. I checked that it holds up. The module evaluates against nixos-unstable, `enable`/`videoFlip` are still opt-in, and the relay package builds with all five patches applied to nixpkgs' libcamera 0.7.2 and every `--replace-fail` matching.
>
> I can't merge it as one PR, though. Two of the changes reach every non-NixOS user, and one of them is a security regression:
>
> **1. Blocking: `camera-relay-gst.c` cache directory (L285–305).** On Book3/Book4, `webcam-fix-libcamera/install.sh` installs this launcher **setgid `camera-relay`**. That group is the only thing that can open the raw IPU6 nodes, and the file header states the rule: nothing from the caller's environment may steer code loading. The new code takes `HOME`/`GST_REGISTRY` from `$CACHE_DIRECTORY`, or else from `$HOME/.cache/camera-relay`, and the user can write to both. When `GST_PLUGIN_SYSTEM_PATH` is unset, GStreamer scans `$HOME/.local/share/gstreamer-1.0/plugins` (confirmed with `GST_DEBUG=GST_REGISTRY:5`). So any local user can drop a `.so` into `~/.cache/camera-relay/.local/share/gstreamer-1.0/plugins/` and have it run with the group. The change also breaks `camera-relay/tests/test-launcher-validation.sh`, which builds with `-Werror` and now fails on `-Wformat-truncation` at L300–304.
>
> I think this came from Copilot's point about the 1777 `/var/cache/camera-relay` tmpfiles rule, which was valid. The fix belongs on the Nix side, because the Nix build isn't setgid. For example, put the env-derived block behind `#ifdef CAMERA_RELAY_USER_CACHE` and have the Nix derivation compile with `-DCAMERA_RELAY_USER_CACHE`. The FHS build then stays byte-for-byte the same.
>
> **2. Blocking: the CCMs in `webcam-fix-book5/ov02e10.yaml`.** This file isn't NixOS-only. `webcam-fix-book5/install.sh` copies it for every OV02E10 Book5 user on Ubuntu, Fedora and Arch, and those users don't get the four new patches. Stock 0.7.2's simple Agc has no `init()`, so `exposureTarget` is silently ignored there. The new matrices are the old ones rescaled per row to 1.09/1.00/1.03 (I checked the arithmetic). The measurements behind them come from one 960XHA on the patched NixOS stack. They replace @david-bartlett's tuning, which the installer still credits, and the file previously said normalising washes the colours out. Before this changes for everyone, I'd want before/after results from at least one Book5 owner on the shell installer. Until then, could the Nix derivation carry the new tuning and leave the shared file as it is? It already rewrites `ov02e10.yaml` in `postInstall`.
>
> **Should fix (NixOS side):**
> - `nixpkgsUnpatched` is removed outright. Every existing config that followed the old README now fails evaluation with "option does not exist" (I confirmed this). Adding `lib.mkRemovedOptionModule [ "hardware" "samsungGalaxyBook" "webcamFixBook5" "nixpkgsUnpatched" ] "…"` to `imports` gives people a clear message instead.
> - `environment.sessionVariables.LIBCAMERA_IPA_MODULE_PATH` (L471–473) now points every session at the *patched* IPA, while system libcamera is stock. `awb-skip-saturated.patch` changes the `SwIspStats` layout that `libcamera.so` and the IPA share, so any stock-libcamera program that honours the variable reads a mismatched struct. The relay already gets the path from its unit environment and wrapper, so the session variable can just go. Relatedly, the `pipewire`/`wireplumber` `LIBCAMERA_FORCE_OV02E10_ROTATION` env does nothing now that `monitor.libcamera` is disabled.
> - The patches only apply to libcamera **0.7.2**. They fail on 0.7.0, 0.7.1 and current master, which has since reworked the simple IPA. Because they're in `patches`, the next nixpkgs libcamera bump will hard-fail `nixos-rebuild`. A version guard or a prominent note would help whoever hits that.
> - `camera-relay` L19 moves the cache dir to `$XDG_RUNTIME_DIR/camera-relay/` for every install. The fixtures in `test-gst-tools-check.sh` (§5 and §7) still seed the old location. `CACHE_DIR="${RUNTIME_DIRECTORY:-${XDG_RUNTIME_DIR:-/tmp}}"` gives the Nix unit its private dir without moving anyone else's.
> - `nixos/README.md` doesn't mention `ipuBridgeFix`, `lowNoise` or `loopbackVideoNr`. It also doesn't say that PipeWire's libcamera monitor is now disabled, which changes behaviour for NixOS users because apps see only the relay's V4L2 node.
>
> **Proposed split.** Several pieces are good, and I'd like to land them quickly:
> 1. **The `!` fix in `append_color_filter`.** This is a real bug. On `main`, `videobalance saturation=0.9 ! videoflip method=vertical-flip` turns into `… videobalance saturation=0.9 ! ! videoflip …`, which gst-launch can't parse. Send it as its own PR with a case in `test-launcher-validation.sh` and I can merge it straight away.
> 2. **The usage-event tracking in `camera-relay-monitor.c`.** It matches v4l2loopback's own semantics: `count = !has_capture_token`, queued on capture STREAMON/STREAMOFF and on close via REQBUFS(0). It has no effect on 0.12.x. It does change behaviour for 0.13+ users on Fedora and Arch, so I'd like to review and test it on its own.
> 3. **The NixOS rework**: scoped libcamera, `ipu-bridge-fix.nix`, `lowNoise`, `loopbackVideoNr`, and the style and toolchain changes, plus the Nix-only cache handling and NixOS-only tuning.
> 4. **The shared `ov02e10.yaml` change**, once other Book5 reports back it up.
>
> Smaller things:
> - `ov02c10-26mhz-fix.nix` still builds its clang flags from `pkgs.llvmPackages` instead of `kernel.commonMakeFlags`.
> - `ipuBridgeFix` and `webcamFixBook5` both ship `extra/ipu-bridge.ko`, so an assertion that they're mutually exclusive would help.
> - The PR description only covers the last few commits.
>
> Thanks again, this is a lot of careful work!

### Thank-you comment

> Thanks again for all the work here, Ângelo, on this PR and on keeping the NixOS Book5 module going since #60. The scoped libcamera build and the colour-filter fix are real improvements. I've left a review asking to split this into smaller PRs so the parts that are ready can go in quickly. Happy to help with any of it, and thanks for your patience!

---

## Next step

- Wait for the split. Merge part (1) first. Past contributor PRs landed as merge
  commits, so use `gh pr merge <N> --merge`, then `git pull`.
- Independently of the contributor, the `! !` bug is live on `main` for anyone
  who sets a chained `RELAY_COLOR_FILTER`. If the split doesn't arrive, it's a
  one-line fix to land ourselves, crediting @ang3lo-azevedo.
- No release: nothing was merged.
