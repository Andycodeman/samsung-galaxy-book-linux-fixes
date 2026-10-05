# PR #102 review — "Book5 webcam fixes and libcamera patches"

Reviewed: 2026-10-04. Author: **@ang3lo-azevedo** (Ângelo Azevedo), the
established NixOS Book5 contributor (PR #60, PR #30, issue #59; most of
`nixos/webcam-fix-book5.nix`'s history). Base `main`, head is the fork's `main`
at `f2a20e76`. 25 commits (two of them merges from upstream), 14 files,
+860/−300. `maintainerCanModify: true`. No CI on the repo.
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/102>

## Verdict: 🟡 **Request changes + split** (not merged)

> **Merged 2026-10-05:** approved at `8fb2085` and merged as `4bae9c1`,
> released as **v0.3.75**. See [Merged + released](#merged--released) at the end.

> **Updated 2026-10-05:** after the author's rework at `56adfc0`, the verdict is
> 🟢 **MERGE AFTER #104 + #105**. See [Re-review 2026-10-05](#re-review-2026-10-05--head-56adfc0)
> at the end of this file.

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

> **Correction (2026-10-05, [#105 review](pr-105-review.md) F1):** Ubuntu is no
> longer only 0.12.7. This machine runs `0.15.3-1ubuntu2`, which queues the same
> payload under the `_OLD` ID as well. The monitor subscribes `_OLD` first, so
> the change is *inert* on Ubuntu 0.13+, not "unaffected by design".

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

---

## Re-review 2026-10-05 — head `56adfc0`

On 2026-10-05 the author split out **#104** (`!` fix + test) and **#105**
(monitor usage events), pushed `56adfc0` to #102, and replied listing the
changes ([comment](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/102#issuecomment-5995932265)).
I checked every claim against the code. I didn't take the summary on trust.
Base is now `main` at `1df6dae`, and `git merge-tree` is clean. 14 files,
+991/−265. Still no Book5 here, so everything below is build, test, eval and
source reading. **Not hardware-tested.**

### Verdict: 🟢 **MERGE AFTER #104 + #105**

For non-NixOS users (Ubuntu/Fedora/Arch shell installs, Book3/4/5), `56adfc0`
is **safe**. Every original blocker and should-fix is resolved. Once you leave
out the NixOS files and the patch files that only Nix reads, the PR changes
three things for shell users:

1. the `!` fix, the same hunk as #104;
2. `camera-relay-monitor.c`, byte-identical to #105;
3. `camera-relay` L19, which resolves to the same directory as `main` unless
   systemd sets `$RUNTIME_DIRECTORY`, and no shell-installed unit does that.

The only reason not to merge it today: merging #102 as-is also lands #105's
behaviour change for v4l2loopback 0.13+ users (Fedora/Arch, and Nix's 0.15.4),
which we wanted to review on its own. It would also land the `!` fix without
#104's regression test. Recommended order:

1. Merge **#104**. It has the regression test.
2. Review **#105** and merge it if it's OK.
3. Ask the author to merge `main` back into #102. Its non-Nix diff then drops to
   L19 plus the `#ifdef` block. Then merge **#102**.

`merge-tree` simulation: `main`+#104+#105+#102 merges clean at each step, and
the reverse order (#102 first) gives an **identical final tree**. So the order
doesn't change the result, only what lands before review. If #105 is rejected,
the author must drop the monitor change from #102 before it merges.

### Original items → status

| Item | Status | Evidence |
|---|---|---|
| **B1** setgid launcher cache from env | ✅ Resolved | See §R1 |
| **B2** shared `ov02e10.yaml` CCM | ✅ Resolved | See §R2 |
| **S1** `nixpkgsUnpatched` without `mkRemovedOptionModule` | ✅ Resolved | eval prints the friendly message (§R6) |
| **S2** session `LIBCAMERA_IPA_MODULE_PATH`; dead pipewire/wireplumber rotation env | ✅ Resolved | eval: no session var, pipewire/wireplumber env `{}`, rotation only in the relay unit and wrapper (§R6) |
| **S3** patches pinned to libcamera 0.7.2 | ✅ Resolved | `libcameraPatchedVersion = "0.7.2"` assertion; overlaid 0.7.3 → clear eval error (§R6) |
| **S4** `camera-relay` L19 moved the cache for everyone | ✅ Resolved | See §R4 |
| **S5** README | ✅ Resolved | `nixos/README.md:205-242` covers `ipuBridgeFix`, `lowNoise.*`, `loopbackVideoNr`, the disabled libcamera monitor, the 0.7.2 pin and the removed option |
| **N1** toolchain flags | 🟡 Partial | `ov02c10-26mhz-fix.nix` now uses `kernel.commonMakeFlags`; `max98390-hda-module.nix:37-45` still uses `llvmPackages.lld`. Nit, Nix-only |
| **N2** duplicate `extra/ipu-bridge.ko` | ✅ Resolved | mutual-exclusion assertion fires (§R6) |
| **N3** PR body | ✅ | The reply comment documents the changes |
| Split | ✅ Done | #104, #105 open from the author |

### R1. `camera-relay-gst.c`: default build is `main` + the #104 fix

The env-derived block is now `append_user_cache()` behind
`#ifdef CAMERA_RELAY_USER_CACHE`. The fixed `CACHE_DIR` is behind `#ifndef`.

```
# Preprocess (no -D) and drop blank lines, then compare.
$ diff pr102.i pr104.i            → IDENTICAL
$ diff pr102.i main.i             → only:  >    argv[argc++] = tok;   (the ! fix)
```

Both shell installers compile with `gcc -O2 -Wall` and no `-D`
(`webcam-fix-book5/install.sh:1130`, `webcam-fix-libcamera/install.sh:1597`,
the setgid one), so they get exactly the `main` logic. The env harness
(`build_environment()` printed from the PR's file) with a hostile environment:

```
$ env -i HOME=/home/victim CACHE_DIRECTORY=/home/victim/evil \
         GST_PLUGIN_SYSTEM_PATH=/evil GST_REGISTRY=/evil/r.bin ./h-default
PATH=/usr/local/bin:/usr/bin:/bin
HOME=/var/cache/camera-relay
GST_REGISTRY=/var/cache/camera-relay/gst-registry.bin
MESA_SHADER_CACHE_DIR=/var/cache/camera-relay/mesa
```

Nothing from the caller reaches the default build, so the setgid invariant
holds. `strings` on the default binary shows only `/var/cache/camera-relay`,
with no `CACHE_DIRECTORY`. With `-DCAMERA_RELAY_USER_CACHE`, the same env gives
`HOME=/home/victim/evil`, which is the intended Nix behaviour. It is safe only
because the Nix build isn't setgid. I checked: no `security.wrappers` in the
module, `install -Dm755` (`webcam-fix-book5.nix:252`).

Builds:

| build | result |
|---|---|
| default, `-O2 -Wall -Wextra -Werror` | ✅ clean |
| `-DCAMERA_RELAY_USER_CACHE`, `-O2 -Wall -Wextra -Werror` | ✅ clean (the old `-Wformat-truncation` errors are gone) |
| Nix derivation (`$CC -O2 -Wall -DCAMERA_RELAY_USER_CACHE`) | ✅ built in `nixos/nix` (§R6) |

### R2. `webcam-fix-book5/ov02e10.yaml` is byte-identical to `main`

```
$ git diff --quiet main pr-102-check -- webcam-fix-book5/ov02e10.yaml   → no diff
$ sha256sum (main) (PR)  → 8617962b…5d8ec7  both
```

The shell installer copies `$SCRIPT_DIR/${TUNING_SENSOR}.yaml` from
`webcam-fix-book5/` (`install.sh:864-880`). Nothing outside `nixos/` references
`nixos/ov02e10.yaml`. Its only consumer is `webcam-fix-book5.nix:85`
(`install -Dm644 ${./ov02e10.yaml}` into `libcamera-book5`). In the Nix build,
the patched libcamera's `share/libcamera/ipa/simple/ov02e10.yaml` carries the
new "NixOS variant" header. Its matrices are the ones @david-bartlett tested
(identical to `3bc641d`'s shared-file version apart from the header). So
**shell users keep the current tuning and won't get the green tint**.

### R3. CRITICAL: do the 4 new patches reach shell installs? **No.**

The new files are `blc-channel-levels`, `agc-min-gain-step`,
`awb-skip-saturated` and `agc-exposure-target.patch` in
`webcam-fix-book5/libcamera-bayer-fix/`, next to the existing
`bayer-fix-v0.{5,6,7}.patch` and `build-patched-libcamera.sh`.

- `build-patched-libcamera.sh` (the only shell script in that directory, and
  unchanged by the PR) applies its fix with **sed/python** (`apply_patch_sed`,
  L385+). It never reads a `.patch` file: `SCRIPT_DIR` is defined at L24 and
  never used again, and there is no `patch`, `git apply` or `git am`.
- `git grep` over the PR tree, excluding `nixos/`, `docs/` and `*.md`, for
  `libcamera-bayer-fix`, `\.patch`, `patch -p`, `git apply`, `git am`, `quilt`,
  `*.yaml` globs or a directory copy: the hits are only `install.sh` /
  `uninstall.sh` / `tune-ccm.sh` invoking `build-patched-libcamera.sh` by name,
  and comments. No glob, no copy.
- `install.sh`, `uninstall.sh`, `tune-ccm.sh` and `build-patched-libcamera.sh`
  are byte-identical to `main`.
- The only consumer is `nixos/webcam-fix-book5.nix:33-37`, the `patches` list
  of `libcamera-book5`.

**Not a blocker.** One leftover point: the patch files live in a shell-installer
directory but only Nix uses them. `nixos/ov02e10.yaml` does say so; the
patches don't. A one-line README note would help, but it's optional.

### R4. `camera-relay` L19

`CACHE_DIR="${RUNTIME_DIRECTORY:-${XDG_RUNTIME_DIR:-/tmp}}"`:

| env | `main` | PR |
|---|---|---|
| `XDG_RUNTIME_DIR=/run/user/1000` (shell install, terminal or unit) | `/run/user/1000` | `/run/user/1000` |
| nothing | `/tmp` | `/tmp` |
| `+ RUNTIME_DIRECTORY=/run/user/1000/camera-relay` (Nix unit) | `/run/user/1000` | `/run/user/1000/camera-relay` |

`git grep RuntimeDirectory|RUNTIME_DIRECTORY` over the PR tree outside `docs/`
finds only L19 and `webcam-fix-book5.nix:556`. The installed
`camera-relay.service` on Andy's box has no `RuntimeDirectory=`. So non-Nix
installs keep the same cache dir as before. The previous round's `mkdir -p` is
gone (systemd creates the Nix dir). `test-gst-tools-check.sh` seeds
`$XDG_RUNTIME_DIR/camera-relay-*` (§5 `:127`, §7 `:205`), which matches again.
Those two sections still **skip** on this host, because a live relay holds the
loopback. That's the same as last round. The fixture location is now provably
the one the script reads.

### R5. #104 / #105 equivalence

```
$ git diff pr-105-check pr-102-check -- camera-relay/camera-relay-monitor.c   → empty (identical)
$ git diff main pr-104-check -- camera-relay/camera-relay-gst.c               → the same 3-comment + 1-deletion hunk as #102
```

#104 = `9a470e3`, #105 = `3aab9dc`, both based on `main` `1df6dae`. #104
additionally adds a stub-gst-launch argv test to `test-launcher-validation.sh`,
which #102 doesn't carry. That's one more reason to merge #104 first.
**Merging #102 alone would land #105's 0.13+ behaviour change unreviewed.**

### R6. NixOS side (`nixos/nix` 2.35.2 container, nixos-unstable, libcamera 0.7.2)

Harness `$SP/nixeval/eval.nix` (outside the repo) imports the PR's
`nixos/webcam-fix-book5.nix` via `eval-config.nix`.

| case | result |
|---|---|
| `nix-instantiate --parse` all 6 `nixos/*.nix` | ✅ OK |
| `enable = true` | ✅ toplevel `.drv` instantiates. Modules `vision-driver`, `ipu-bridge-fix-1.1`, `v4l2loopback-0.15.4`. **No** session `LIBCAMERA_IPA_MODULE_PATH`. pipewire/wireplumber env `{}`. Unit has `CacheDirectory`/`RuntimeDirectory = camera-relay` |
| module imported, not enabled | ✅ no modules, no unit, no loopback conf (still opt-in) |
| `videoFlip + lowNoise + loopbackVideoNr=42 + chained relayColorFilter` | ✅ adds `ov02e10-lownoise`, `options ov02e10 max_again=64 dgain=1020`, `video_nr=42`, `LIBCAMERA_FORCE_OV02E10_ROTATION` + `RELAY_COLOR_FILTER` in the **relay unit only** |
| `ipuBridgeFix` alone | ✅ only `ipu-bridge-fix-1.1` |
| old config `nixpkgsUnpatched = true` | ✅ `Failed assertions: - The option definition … nixpkgsUnpatched' … no longer has any effect; please remove it. The patched libcamera is now a package used only by the camera relay …` |
| `webcamFixBook5` + `ipuBridgeFix` | ✅ `Failed assertions: - … already ships the ipu-bridge override. Disable hardware.samsungGalaxyBook.ipuBridgeFix, both install extra/ipu-bridge.ko.` |
| overlay libcamera `version = "0.7.3"` | ✅ `Failed assertions: - … the libcamera patches only apply to 0.7.2, but nixpkgs provides 0.7.3. Pin nixpkgs' libcamera …` |

**Full `nix-build`** of the relay package (`full` case, `videoFlip = true`):
✅ exit 0. The output `c6nhr86y…-camera-relay-1.0` matches the eval's
`ExecStart` path. The `libcamera-0.7.2` derivation lists all five patches
(`bayer-fix-v0.7`, `blc-channel-levels`, `agc-min-gain-step`,
`awb-skip-saturated`, `agc-exposure-target`), and the build applied and
compiled them. Every `--replace-fail` matched. The built `camera-relay-gst`
contains `CACHE_DIRECTORY`, `camera-relay-cache`,
`LIBCAMERA_FORCE_OV02E10_ROTATION=180`, the store `gst-launch-1.0` and the
store `cam`, and **no** `/var/cache/camera-relay`. The built script's L19 is the
new line.

**Not run:** a full system `nix-build` of the toplevel (kernel modules etc.).
I instantiated it but didn't build it. I didn't evaluate a clang kernel for the
`kernel.commonMakeFlags` path. And there's no runtime test of anything, since
we have no hardware.

### New findings (all Nix-only, none blocking)

- **R-N1** `camera-relay status`/`stop` from a terminal on NixOS look in
  `$XDG_RUNTIME_DIR`. The unit writes its camera/device/state caches to
  `$XDG_RUNTIME_DIR/camera-relay/` (table in §R4). `status` (`camera-relay:1046-1056`)
  then falls back to live probes for camera and device, but reports the
  state as `stopped` while the relay is running (`state` defaults to
  "stopped" when `STATE_CACHE` is missing). Found by reading the code, not
  run on NixOS. Cosmetic. Possible fixes: drop `RuntimeDirectory=` from the
  unit, or have the wrapper default `RUNTIME_DIRECTORY` to
  `$XDG_RUNTIME_DIR/camera-relay`.
- **R-N2** In the `USER_CACHE` build, when both `CACHE_DIRECTORY` and `HOME`
  are unset, the fallback is a fixed `/tmp/camera-relay-cache`. Another local
  user could pre-create it and plant a registry. It's unreachable from the
  unit (which sets `CacheDirectory=`) and from a login shell (which has
  `HOME`). Failing instead would be stricter. Nit.
- **R-N3** `max98390-hda-module.nix` still takes `lld` from `llvmPackages`
  (the remaining half of N1). There are also `substituteInPlace --replace`
  deprecation warnings in the `camera-relay` derivation (pre-existing).

### R7. @david-bartlett's green-tint test (recorded, out of scope)

[Comment](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/102#issuecomment-5991491457),
2026-10-05: Book5 Pro **940XHA**, Fedora 44, **libcamera 0.7.1** (stock, so
without the four patches), Kamoso, an overcast day. The *proposed* (old PR)
yaml brings the **green tint back**, worse at higher colour temperature and
intensity. That confirms B2 was the right call. The author agrees the new
matrices assume the patches. With `webcam-fix-book5/ov02e10.yaml` reverted
(§R2), shell users keep the current tuning, so **this PR does not deliver the
green tint to them**.

He also says the **current** yaml "has some issues after the sensor flip has
been applied". That's **out of scope** for #102, a separate tuning thread worth
an issue of its own if he wants to pursue it. His evidence was low-light and
overcast, so it isn't conclusive yet.

### Commands run (reproducible)

```
git fetch origin pull/102/head:pr-102-check pull/104/head:pr-104-check pull/105/head:pr-105-check
git worktree add --detach $SP/wt102 pr-102-check        # removed afterwards
for t in camera-relay/tests/test-*.sh; do bash $t; done  # in the worktree
gcc -E -P {pr,pr104,main}.c | diff                      # R1
gcc -O2 -Wall -Wextra -Werror [-DCAMERA_RELAY_USER_CACHE]
docker run nixos/nix …  nix-instantiate --eval --strict --json eval.nix --argstr case <case>
docker run nixos/nix …  nix-build eval.nix --argstr case full -A relay
git merge-tree --write-tree (main → +104 → +105 → +102, and reverse)
```

Test suites on PR head (`56adfc0`):

| suite | result |
|---|---|
| test-launcher-validation | **29/0** (was a build failure last round) |
| chromium-pipewire-flag | 61/0 |
| distro-detection | 16/0 |
| egl-vendor-pin | 18/0 |
| firefox-pipewire-pref | 15/0 |
| gst-tools-check | 8/0, 3 skipped (live relay holds the loopback, same as last round) |
| monitor-exit-propagation | 5/0 |
| pipewire-restart-guard | 17/0 |
| unit-regeneration | 15/0 |
| wireplumber-format-nudge | 26/0 |
| writer-format-check | 1/0, 1 skipped (no idle loopback) |

### Draft reply (NOT posted, for Andy to send)

> **Posted 2026-10-05 (trimmed):** a shorter version went up as a plain comment
> (not an approval):
> https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/102#issuecomment-6001923107.
> I checked first that the head was still `56adfc0` and that nothing new had been posted.
> The merge-order paragraph was cut: the author already heard it on #105 and
> acknowledged it, and #104 and #105 have both merged since. The per-item
> verification list was cut down to one paragraph. The Nix follow-ups went up
> as drafted below.
>
> **Edited 2026-10-05 (19:57Z), same comment, no new one:** Andy cut the
> request for @david-bartlett to open a separate issue, since he had already
> been through that with him. The last paragraph now reads only: "@david-bartlett,
> thanks for testing the proposed file on the 940XHA. Your result is why the
> shared yaml stays as it is." I checked the before/after bodies, and only that
> paragraph changed.

Suggested as a PR **comment**, not an approval yet. Approve after #104/#105 land
and `main` is merged back.

> Thanks @ang3lo-azevedo, that's a really thorough turnaround, and thanks for splitting out #104 and #105!
>
> I went through `56adfc0` item by item, and everything from the review is addressed:
>
> - **Launcher:** without `-DCAMERA_RELAY_USER_CACHE`, `camera-relay-gst.c` preprocesses to exactly `main` plus the `!` fix. With a hostile `CACHE_DIRECTORY`/`HOME`, the default build still hands gst-launch `/var/cache/camera-relay`. Both builds pass `-Wall -Wextra -Werror`, and `test-launcher-validation.sh` is back to 29/0.
> - **Tuning:** `webcam-fix-book5/ov02e10.yaml` is byte-identical to `main`, and `nixos/ov02e10.yaml` only goes into `libcamera-book5`. The four new patches aren't picked up by any shell installer either: `build-patched-libcamera.sh` still applies its fix with sed and never reads `.patch` files.
> - **`camera-relay` L19:** it resolves to the same directory as before everywhere except the Nix unit.
> - **NixOS:** evaluated against nixos-unstable (libcamera 0.7.2). `nixpkgsUnpatched` now gives the friendly removal message, and both assertions fire with clear messages (an overlaid 0.7.3, and `ipuBridgeFix` + `webcamFixBook5`). There's no session IPA path any more, and a `nix-build` of the relay with `videoFlip` applies all five patches and produces a launcher without `/var/cache`. (All of that is build/eval only; I don't have a Book5 to run it on.)
>
> On merge order: I'll take #104 first since it has the test, then review #105 on its own. Once those are in, could you merge `main` back into this branch? Then it's just the NixOS rework plus the `#ifdef`, and I'll merge it.
>
> A few optional Nix-side follow-ups, none of them blocking:
> - With `RuntimeDirectory=camera-relay`, running `camera-relay status` from a terminal looks in `$XDG_RUNTIME_DIR` while the unit writes to `$XDG_RUNTIME_DIR/camera-relay/`. From reading the code, the state would show as "stopped" while the relay is running.
> - In the `USER_CACHE` build, the `/tmp/camera-relay-cache` fallback (no `CACHE_DIRECTORY` and no `HOME`) is a shared, predictable path. Failing there would be safer, though the unit never hits it.
> - `max98390-hda-module.nix` still takes `lld` from `llvmPackages`.
>
> @david-bartlett, thanks for testing the proposed file on the 940XHA. Your result is exactly why the shared yaml stays as it is. If you'd like to chase the issues you're seeing with the **current** yaml after the flip, could you open a separate issue (ideally with a daylight shot too)? That way it doesn't get lost in this PR.

### Next step (2026-10-05)

- **#104 merged** (v0.3.73), **#105 merged** (v0.3.74). Re-review reply posted (above).
- Waiting on the author to merge `main` back into #102, keeping `main`'s
  `camera-relay-monitor.c`. Then do a final check that the non-Nix diff is only
  `camera-relay` L19 + the `#ifdef` block, and merge #102. No release is needed
  for #102 itself (Nix-only, and a no-op for shell users).

## Final check 2026-10-05 — head `8fb2085` (main merged back)

The author merged `main` back in ([comment](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/102#issuecomment-6001988917),
20:01Z). `8fb2085` is a merge commit with parents `56adfc0` and `c6eebfa`, which
is the current `main` tip. I checked each of his claims against the code.
Still no Book5 here, so this is build, test, eval-evidence and source reading
only. **Not hardware-tested.**

### Verdict: 🟢 **READY TO MERGE**

The non-Nix diff against `main` is exactly the two expected pieces: L19 and the
`#ifdef` block. The default launcher build preprocesses byte-identical to `main`,
and the merge reverts nothing. The Nix files and patches are unchanged since
the `56adfc0` eval/build evidence (§R6), and nixos-unstable is still on libcamera
0.7.2. One new non-blocking note, F-N4: stable nixos-26.05 ships 0.7.0, see §F4.

GitHub: `MERGEABLE`, `CLEAN`, no CI checks configured. `reviewDecision` is still
`CHANGES_REQUESTED` from the 2026-10-04 review, so **approve before merging** to
clear it.

### F1. Diff vs `main` and merge integrity

```
$ git merge-base origin/main pr-102-final                → c6eebfa (= origin/main)
$ git diff origin/main...pr-102-final --stat             → 13 files, +939/−255
$ git diff origin/main pr-102-final --stat               → identical (base is main's tip)
$ git diff --name-only origin/main pr-102-final \
    | grep -v -e '^nixos/' -e '^webcam-fix-book5/libcamera-bayer-fix/.*\.patch$'
camera-relay/camera-relay
camera-relay/camera-relay-gst.c
```

- `camera-relay`: one line, L19 →
  `CACHE_DIR="${RUNTIME_DIRECTORY:-${XDG_RUNTIME_DIR:-/tmp}}"` (same as §R4).
- `camera-relay-gst.c`: only `#ifndef CAMERA_RELAY_USER_CACHE` around
  `CACHE_DIR`, the `append_user_cache()` function, and the `#ifdef`/`#else`
  in `build_environment()`. Additions only. The #104 `!` fix is untouched.
- Byte-identical to `main`: `camera-relay/camera-relay-monitor.c` (so main's #105
  version, as he said), `webcam-fix-book5/ov02e10.yaml`, and
  `webcam-fix-book5/libcamera-bayer-fix/build-patched-libcamera.sh`. That's the
  only `build-patched-libcamera.sh` in the repo, and there's no `installers/` copy.
- `git merge-tree --write-tree origin/main pr-102-final` → exit 0, tree
  `f15eab3`, **equal to the PR's own tree**. Every path outside the 13 files above
  is therefore `main`'s: #104 fix and test, #105 monitor, #103 upstream-check,
  and all `docs/triage/*`.
- No conflict markers anywhere in the tree (`git grep` for `<<<<<<<`, `>>>>>>>`,
  `=======` outside `*.md`).

### F2. Nix side unchanged since `56adfc0`

```
$ git diff --stat 56adfc0 8fb2085 -- nixos/ webcam-fix-book5/libcamera-bayer-fix/   → empty
$ git diff --stat 56adfc0 8fb2085
 camera-relay/camera-relay-monitor.c, camera-relay/tests/test-launcher-validation.sh,
 docs/triage/pr-10{2,4,5}-review.md        (= what main gained from #104/#105 + docs)
```

So the §R6 evidence (eval cases, assertions, full relay `nix-build` with all
five patches) still applies. I didn't re-run the docker eval.

### F3. Builds and tests on the PR tree (throwaway worktree, removed)

| check | result |
|---|---|
| `gcc -E -P` default build vs `main`, blank lines dropped | ✅ **identical**, sha256 `0c9d659e…` both |
| default, `-O2 -Wall -Wextra -Werror` | ✅ clean. `strings`: only `/var/cache/camera-relay`, no `CACHE_DIRECTORY` |
| `-DCAMERA_RELAY_USER_CACHE`, `-O2 -Wall -Wextra -Werror` | ✅ clean. `strings`: `CACHE_DIRECTORY`, `%s/.cache/camera-relay`, `/tmp/camera-relay-cache` |

So the setgid invariant holds, since shell installers build without `-D`.

| suite | result |
|---|---|
| test-launcher-validation | **30/0** (29 + #104's argv test, now on the branch) |
| chromium-pipewire-flag | 61/0 |
| distro-detection | 16/0 |
| egl-vendor-pin | 18/0 |
| firefox-pipewire-pref | 15/0 |
| gst-tools-check | 8/0, 3 skipped (live relay holds the loopback, as before) |
| monitor-exit-propagation | 5/0 |
| pipewire-restart-guard | 17/0 |
| unit-regeneration | 15/0 |
| wireplumber-format-nudge | 26/0 |
| writer-format-check | 1/0, 1 skipped (no idle loopback) |

11 suites, all pass. That matches the author's claim. The live relay and the
installed files were not touched.

### F4. libcamera version in nixpkgs today

From `pkgs/by-name/li/libcamera/package.nix`, fetched through the GitHub API
and decoded:

| branch | libcamera |
|---|---|
| `nixos-unstable` (`494ce7f`, 2026-10-05 05:43Z) | **0.7.2** ✅ |
| `master` | 0.7.2 |
| `nixos-26.05` (current stable) | **0.7.0** |
| `nixos-25.11` | 0.6.0 |

Upstream libcamera's newest tag is still `v0.7.2`, and I found no open nixpkgs
PR bumping it. So the 0.7.2 assertion **doesn't fire for unstable users today**.

**F-N4 (new, non-blocking, Nix-only):** on **stable nixos-26.05** the module
now fails evaluation, with the clear assertion message. On `main` it would have
worked there. I checked with `git apply`, applying the patches in the PR's order
to libcamera git tags:

| tag | bayer-fix-v0.7 | blc-channel-levels | agc-min-gain-step | awb-skip-saturated | agc-exposure-target |
|---|---|---|---|---|---|
| v0.7.0 | ✅ | ✅ | ❌ | (not reached) | (not reached) |
| v0.7.2 | ✅ | ✅ | ✅ | ✅ | ✅ |

`main`'s module applies only `bayer-fix-v0.7`, which applies to 0.7.0. This
check is source-level only: I didn't build `main`'s module against 26.05. It
fails loudly rather than at build time, and the README says "0.7.2 only". The
README's flake example already uses `nixos-unstable`, but it doesn't say that
stable won't work. Worth a README line in the follow-up PR. It isn't a reason
to hold this one: an eval-time failure with a clear message is exactly what S3
asked for, and the four new patches can't be applied to 0.7.0 anyway.

### F5. Release

Precedent: both earlier Nix-only merges were released, **v0.3.69** (#95,
`speaker-fix-940xfg.nix`) and **v0.3.70** (#96, `ov02c10-26mhz-fix.nix`),
each with NixOS-focused notes. This reverses the "no release needed" line in
the previous Next step.

- **Shell users:** no change. L19 resolves the same without
  `$RUNTIME_DIRECTORY`, the `#ifdef` is compiled out, and the yaml and
  installers are byte-identical.
- **NixOS users of `webcam-fix-book5.nix`:** a real, partly **breaking** change.
  - `nixpkgsUnpatched` was removed, so old configs get an eval error telling them to drop it.
  - libcamera is no longer patched system-wide.
  - PipeWire's libcamera monitor is disabled, so the camera is visible only through the relay's loopback node.
  - The 0.7.2 pin means stable 26.05 fails eval (F-N4).
  - Also new: the `ipuBridgeFix` / `lowNoise.*` / `loopbackVideoNr` options and the NixOS-only tuning.

**Recommendation:** cut **v0.3.75**, NixOS-only notes, leading with the
breaking points above. Andy decides.

### Draft approve/merge comment (POSTED 2026-10-05 as the APPROVE review, verbatim)

Post it as the **approval** review body. That clears the `CHANGES_REQUESTED`
state. Then merge.

> Thanks @ang3lo-azevedo, and thanks for taking main's `camera-relay-monitor.c` rather than resolving the duplicate by hand.
>
> I checked `8fb2085`. Apart from the NixOS files and the Nix-only patches, the diff against main is just `camera-relay` L19 and the `#ifdef CAMERA_RELAY_USER_CACHE` block. The default launcher build preprocesses identical to main, both builds pass `-Wall -Wextra -Werror`, and all 11 `camera-relay/tests` suites pass on the merged tree. The Nix files are unchanged from `56adfc0`, so the earlier eval and relay `nix-build` still hold. nixos-unstable is still on libcamera 0.7.2. As before, this is build, test and eval only; I don't have a Book5.
>
> A follow-up PR for the three optional points is fine. One more for that PR if you're up for it: stable nixos-26.05 ships libcamera 0.7.0, so the module now stops at the 0.7.2 assertion there. A line in `nixos/README.md` saying it needs nixos-unstable (for now) would save someone a confused rebuild.
>
> Merging, thanks again!

### Commands run (reproducible)

```
git fetch origin pull/102/head:pr-102-final            # branch deleted afterwards
git diff origin/main{...,} pr-102-final --stat
git merge-tree --write-tree origin/main pr-102-final   # == pr-102-final^{tree}
git diff --stat 56adfc0 8fb2085 -- nixos/ webcam-fix-book5/libcamera-bayer-fix/
git worktree add --detach $SP/wt102f pr-102-final      # removed afterwards
gcc -E -P {main,pr}.c | grep -v '^\s*$' | diff
gcc -O2 -Wall -Wextra -Werror [-DCAMERA_RELAY_USER_CACHE]
for t in camera-relay/tests/test-*.sh; do bash $t; done
gh api repos/NixOS/nixpkgs/contents/pkgs/by-name/li/libcamera/package.nix?ref=<branch>
git clone --depth 1 --branch v0.7.{0,2} https://git.libcamera.org/libcamera/libcamera.git
git apply <5 patches in PR order>                      # scratchpad, removed afterwards
gh release view v0.3.69 / v0.3.70
```

### Next step (2026-10-05, final)

- ~~Andy: approve with the draft above, merge #102, and cut v0.3.75 (NixOS notes).~~
  Done 2026-10-05, see below.
- After that: the author's follow-up PR for R-N1..R-N3 plus the F-N4 README line.

## Merged + released

- **Head re-checked** just before approving: still `8fb2085`, `MERGEABLE`, and
  no new comments after his 2026-10-05T20:01Z one.
- **Review:** the draft above was posted verbatim as an APPROVE review
  ([#pullrequestreview-5420754819](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/102#pullrequestreview-5420754819)).
  `reviewDecision` went from `CHANGES_REQUESTED` to `APPROVED`.
- **Merge:** `gh pr merge 102 --merge --match-head-commit 8fb2085…` →
  merge commit `4bae9c1` (2026-10-05T21:27:03Z). The pull fast-forwarded with
  13 files, +939/−255, the same as §F1.
- **On `main` after the merge:** the only difference from the PR tree is this
  file (`git diff --stat 8fb2085 4bae9c1`). `webcam-fix-book5/ov02e10.yaml` and
  `camera-relay/camera-relay-monitor.c` are unchanged from the pre-merge `main`
  `462ac83`. All 11 `camera-relay/tests/test-*.sh` scripts pass (same counts as
  §F3, launcher-validation 30/0). The live relay and installed files were not
  touched.
- **Release:** [v0.3.75](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/releases/tag/v0.3.75),
  tagged on the commit that adds this section. The notes are NixOS-only and lead
  with the breaking points from §F5. They say shell users have nothing to do,
  and that testing was build, test and eval only. @david-bartlett is credited
  for the 940XHA test (§R7) that kept the new tuning NixOS-only.

### Follow-ups expected from the author (one PR, none blocking)

- **R-N1** `camera-relay status`/`stop` from a terminal on NixOS read
  `$XDG_RUNTIME_DIR`, but the unit writes to `RuntimeDirectory=`. `status`
  then reports `stopped` while the relay runs. Cosmetic.
- **R-N2** In the `USER_CACHE` build, the `/tmp/camera-relay-cache` fallback
  (no `CACHE_DIRECTORY` and no `HOME`) should fail instead. Nit, unreachable
  from the unit or a login shell.
- **R-N3** `max98390-hda-module.nix` still takes `lld` from `llvmPackages`.
  There are also `substituteInPlace --replace` deprecation warnings in the
  `camera-relay` derivation.
- **F-N4** A `nixos/README.md` line saying `webcam-fix-book5.nix` needs
  nixos-unstable for now, because stable 26.05 ships libcamera 0.7.0 and stops
  at the 0.7.2 assertion. Asked for in the approval review.
