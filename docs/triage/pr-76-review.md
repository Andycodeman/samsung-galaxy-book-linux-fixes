# PR #76 review — "camera-relay: fix black camera on hybrid-GPU laptops (EGL debayer lands on NVIDIA)"

Reviewed: 2026-08-03. Author: **@4nrry** (Anrry Petrin). Base `main`,
`MERGEABLE`, `mergeStateStatus=CLEAN`, no CI on the repo.
4 commits, 5 files, +484/−13. Head `d934a6fc`.
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/76>

## Verdict: 🟡 **Merge with one change — not as-is**

Status: **POSTED 2026-08-03** as a `CHANGES_REQUESTED` review, with an explicit
merge checklist (see [What needs to change to merge](#what-needs-to-change-to-merge)).

The diagnosis, the fix, and the detection logic are all correct; I verified the
detection against 12 topologies and it matches the PR's table exactly. **One
blocking finding:** on a hybrid box the installers still write a *global*
`LIBCAMERA_SOFTISP_MODE=cpu`, which systemd's user manager feeds into
`camera-relay.service` and which silently overrides the new EGL pin — the exact
"both set, CPU wins, pin dead" outcome the PR's own comment says the design
prevents. It is a one-line fix.

| | |
|---|---|
| Blocking | 1 (measured) |
| Non-blocking / nit | 4 |
| Diagnosis correct? | **Yes** |
| Detection logic correct? | **Yes** — 12/12 topologies pass |
| Blast radius on non-NVIDIA machines | **None** — `detect_egl_vendor_pin` returns 1, nothing changes |

---

## What I verified

Everything below was actually run, on Andy's Ubuntu box (systemd 255,
`renderD128 → i915` only, but **both** `10_nvidia.json` and `50_mesa.json`
present in `/usr/share/glvnd/egl_vendor.d` — a useful accidental test case).

- **`bash -n` clean** on all three changed scripts.
- **Detection logic — 12/12.** I extracted `render_node_drivers` /
  `find_mesa_egl_vendor` / `detect_egl_vendor_pin` from the branch, mocked the
  render-node enumeration, and ran the real `find_mesa_egl_vendor` against this
  machine's ICDs:

  ```
  i915 only            nopin  PASS      i915 + nvidia        pin    PASS
  xe only              nopin  PASS      amdgpu + nvidia      pin    PASS
  amdgpu only          nopin  PASS      xe + nvidia-drm      pin    PASS
  nvidia only          nopin  PASS      i915 + nouveau       nopin  PASS
  ```

  Plus four cases the PR's table doesn't mention, all behaving sensibly:
  no render nodes → nopin; `nvidia + unknown` → nopin; two NVIDIA nodes → nopin;
  `i915 + nvidia + unknown` → pin.

- **This box is correctly read as single-GPU** despite `10_nvidia.json` being
  installed — the detection keys on render nodes, not on ICD presence, which is
  the right call and is exactly the trap a naive implementation would fall into.

- **`doctor` runs clean** off the branch: exit 0, 110 lines, no unbound
  variables, no `set -e` casualties, and the new section reads correctly:

  ```
  ── GPU / EGL debayer ──
    render node: /dev/dri/renderD128 (driver i915)
    EGL vendor ICD: /usr/share/glvnd/egl_vendor.d/10_nvidia.json (libEGL_nvidia.so.0)
    EGL vendor ICD: /usr/share/glvnd/egl_vendor.d/50_mesa.json (libEGL_mesa.so.0)
    topology: single Mesa-driven GPU — no vendor pin needed
  ```

- **`set -e` audit.** The new code adds several `cond && echo` statements under
  `set -euo pipefail`. Confirmed these are safe mid-function (bash exempts the
  non-final command of an AND-list) — they'd only bite as the *last* statement of
  a function, which none of them are. `count=$((count + 1))` is used rather than
  `((count++))`, which would have returned 1 on the first increment.

- **No duplicate drift.** The ~40-line detection block is copied into both
  installers; stripped of comments the two are **byte-identical**. Given this
  repo's `ov02c10.yaml` history that was worth checking.

- **README cross-reference resolves** — `webcam-fix-book5/README.md:448` points
  at *"LED on but black image, on laptops with a dedicated GPU"*, which exists at
  `webcam-fix-libcamera/README.md:368`.

- **`LIBCAMERA_SOFTISP_MODE=gpu` is a real value**, so the fix below is available:
  `strings libcamera.so.0.7` → `", must be "cpu" or "gpu"`.

---

## Blocking

### B1. The installers' global CPU debayer silently overrides the new pin
`webcam-fix-libcamera/install.sh:1447-1450`, `webcam-fix-book5/install.sh` (same
block), interacting with `camera-relay/camera-relay` `cmd_enable_persistent`

The PR makes the pin and CPU debayer exclusive **inside `cmd_enable_persistent`**
— on a hybrid box `softisp_mode` is left empty, so the unit gets
`Environment=__EGL_VENDOR_LIBRARY_FILENAMES=…` and no `LIBCAMERA_SOFTISP_MODE`.
Correct as far as it goes.

But the installers' pre-existing block is **unchanged by this PR** and writes the
mode globally:

```bash
if [[ -n "$NVIDIA_ACTIVE" ]]; then
    sudo mkdir -p /etc/environment.d
    echo "LIBCAMERA_SOFTISP_MODE=cpu" | \
        sudo tee /etc/environment.d/10-libcamera-softisp.conf > /dev/null
```

`/etc/environment.d` is read by `30-systemd-environment-d-generator`, which is a
**user**-environment generator — so it lands in `camera-relay.service`. Measured:

```
# ~/.config/environment.d/99-pr76-probe.conf  ->  PR76_PROBE_SOFTISP=cpu
$ systemctl --user start pr76-envprobe.service
inherited=cpu                 <-- environment.d reaches a user service

# + drop-in with Environment=PR76_PROBE_SOFTISP=UNIT_WINS
inherited=UNIT_WINS           <-- a unit-level Environment= beats it
```

So on a hybrid machine where `NVIDIA_ACTIVE` is set, `LIBCAMERA_SOFTISP_MODE=cpu`
reaches the relay from the global file, CPU debayer wins (it touches no EGL at
all), and the pin sits inert in the unit. That is verbatim the failure the PR's
own comment says it is avoiding:

> Deliberately exclusive. Setting both would leave CPU mode winning (it uses no
> EGL at all) and the pin dead in the unit on exactly the hybrid machines it was
> written for.

**This is not a narrow edge case.** `NVIDIA_ACTIVE` is set when *either* glxinfo
reports an NVIDIA renderer, **or** glxinfo is absent and `/proc/driver/nvidia`
exists and `prime-select query != intel`. Neither installer installs
`mesa-utils`/`glx-utils` — they only probe for it — and Ubuntu's default hybrid
mode is `on-demand`, not `intel`. So **hybrid box + no glxinfo installed** takes
the fallback branch and gets the global CPU file. The existing message on that
path even reads *"couldn't confirm via glxinfo — install mesa-utils/glx-utils if
your camera framerate is low"*, which is precisely the population this PR set out
to give the framerate back to.

Not a breakage — the camera works, on CPU debayer. It is a silent no-op of the
feature on a chunk of the target hardware, and `doctor` will report
`vendor pin (service unit): /usr/share/…/50_mesa.json` while it is having no
effect, which makes the new section misleading in exactly the scenario it was
added for.

**Fix.** Since a unit-level `Environment=` beats the inherited one (measured
above), have the hybrid branch pin the mode as well as the vendor:

```diff
 local egl_vendor=""
 egl_vendor=$(detect_egl_vendor_pin) || egl_vendor=""
 if [[ -n "$egl_vendor" ]]; then
+    # Beat any global LIBCAMERA_SOFTISP_MODE=cpu from /etc/environment.d — it is
+    # inherited by this user service and would otherwise make the pin inert.
+    softisp_mode="gpu"
     info "Hybrid GPU detected — service will pin EGL to $egl_vendor (GPU debayer on the iGPU)"
```

The global file should stay as-is: it is what fixes the PipeWire-libcamera path,
which the PR correctly documents as still unpinned.

---

## Non-blocking / nit

**N1. `doctor` should print the effective `LIBCAMERA_SOFTISP_MODE`.**
The GPU/EGL section prints the vendor pin from the unit but not the debayer mode,
so B1 is invisible to it. One more line next to `vendor pin (service unit):`
would have surfaced B1 immediately, and it is the natural companion field.

**N2. "Keep this block in sync" comment is one-sided.**
`webcam-fix-book5/install.sh` has it; `webcam-fix-libcamera/install.sh` does not.
Given the `ov02c10.yaml` drift history, put it on both copies.

**N3. Dead `|| echo '?'` fallback.**
`camera-relay` doctor: `$(grep -oP '"library_path"…' "$vf" | head -1 || echo '?')`
— the `||` binds to `head`, which exits 0 on empty input, so `?` never prints. A
vendor JSON without a `library_path` renders as empty parens. Cosmetic.

**N4. ~40 lines duplicated into two installers purely to print one line.**
The installer block only `echo`s; the real work is in `camera-relay`. That is a
lot of copied detection for an informational message. The PR already names #70's
shared `lib/common.sh` as the right home — worth keeping that link explicit.

**N5. No tests, though there is now a place for them.**
`camera-relay/tests/` exists (`relay-loop-bench.c`, from #60). `detect_egl_vendor_pin`
is pure bash with an injectable seam — mocking `render_node_drivers` gave me all
12 cases above in a few minutes. A small harness would lock the topology table in
permanently.

---

## What could not be verified without the hardware

- **No NVIDIA machine was involved at all.** This box is `i915`-only. Every
  hybrid result above comes from mocking the render-node enumeration; the logic
  is confirmed, the *behaviour on real hybrid silicon* is not.
- **The core claim is untested here** — that GLVND hands the debayer
  `10_nvidia.json` and that pinning Mesa fixes it. That rests on @4nrry's
  Book4 Ultra evidence, which is specific and credible (both directions of the
  `__EGL_VENDOR_LIBRARY_FILENAMES` A/B, with fps and error text).
- **`prime-select nvidia` on a hybrid box** — the author flags this as untested
  and asks for a second tester. B1 makes it worse than they realised: that
  configuration is also the one that gets the global CPU file, so today it would
  get the pin *and* have it overridden.
- **AMD iGPU + NVIDIA** — detection covers it (verified in the harness), no such
  Samsung model exists to test on.
- **Whether Mesa EGL on the iGPU render node works while NVIDIA drives the
  display.** Plausible — the debayer renders offscreen — but unproven, and it is
  the assumption the `prime-select nvidia` case rests on.

---

## What needs to change to merge

Sent to @4nrry 2026-08-03 as the merge checklist.

1. **`softisp_mode="gpu"` in the hybrid branch of `cmd_enable_persistent`** — the
   B1 fix. Blocking.
2. **Print the effective debayer mode in `doctor`'s GPU / EGL section**, next to
   `vendor pin (service unit):`. Blocking only in the sense that it is what stops
   B1 recurring silently.
3. **"Keep this block in sync" comment on both installer copies** (N2).
   Non-blocking.
4. **A test for `detect_egl_vendor_pin`** in `camera-relay/tests/` (N5).
   Requested, explicitly not a merge gate.

Plus the dead `|| echo '?'` nit (N3), offered as take-it-or-leave-it.

Told them 1 + 2 gets it merged. Also asked for a second tester on
`prime-select nvidia` before we call that configuration solved, since B1 makes
that gap worse than they realised — it is the same configuration that gets the
global CPU file.

---

## Round 2 — 2026-08-04: all four addressed, verified

@4nrry pushed `f5d6fed..a4ba63f` (head `a4ba63f`, now +753/−13 over 6 files).
Re-checked each item independently rather than on the strength of the reply.

| # | Item | Commit | Verified |
|---|------|--------|----------|
| 1 | `softisp_mode="gpu"` in the hybrid branch | `f5d6fed` | ✅ present, with a comment explaining the environment.d precedence |
| 2 | Effective debayer mode in `doctor` | `e082b2a` | ✅ three layers (unit / inherited / effective) + `→ PIN IS INERT` block |
| — | Dead `\|\| echo '?'` nit | `e082b2a` | ✅ restructured to `${vlib:-no library_path}` |
| 3 | Sync marker on both installers | `636347f` | ✅ 1 occurrence in each |
| 4 | Test for `detect_egl_vendor_pin` | `a4ba63f` | ✅ 18/18, hermetic |

**The test is a real guard, not a tautology.** They claimed it fails on the bug;
I checked by mutation — reverting `softisp_mode="gpu"` in a throwaway worktree:

```
  ✓ hybrid: unit pins the EGL vendor
  ✗ hybrid: unit does not state LIBCAMERA_SOFTISP_MODE=gpu — pin would be inert
  17 passed, 1 failed          SUITE EXIT=1
```

Test hygiene is good: `mktemp -d` with a cleanup trap, `SERVICE_DIR` pointed at
the temp dir, `systemctl` stubbed to a no-op. Confirmed the real
`~/.config/systemd/user/camera-relay.service` was byte-identical before and
after the run.

**`doctor` on this box after the change:**

```
  debayer mode (service unit): none
  debayer mode (inherited):    none
  debayer mode (effective):    gpu (libcamera default, nothing set)
  debayer throughput: Debayer processed 30 frames in 86043us, 2868 us/frame
```

**Their `test-gst-tools-check.sh` claim checks out.** They said the
`10 passed, 1 failed` is pre-existing and environment-dependent. Ran the same
suite from a base-`main` worktree (`6c205ba`, without the PR): identical
`10 passed, 1 failed`. The relay here is producing a real picture, so `doctor`
correctly declines to flag black frames and the test's assumption doesn't hold.
Not this PR's problem — worth its own issue.

Also re-confirmed at head: `bash -n` clean on all four scripts, and the
duplicated installer block is still byte-identical across the two files.

### Verdict: ✅ **APPROVE — merge**

The one blocking finding is fixed and now has a regression test that fails
without the fix. The `prime-select nvidia` caveat remains, correctly left
documented in the PR body rather than claimed solved — it is a pre-existing
untested configuration that this PR makes *reachable* rather than regressing,
and it needs a tester with a hybrid box running on the dGPU.

**Note for that gap:** Andy's own 960XGL is a Book4 Ultra with an RTX 4070 Max-Q
at `01:00.0`, NVIDIA userspace fully installed and DKMS modules already built for
the running kernel — but nothing bound to the device (no `driver` symlink, no
module loaded, runtime-`suspended`), hence a single `renderD128`/i915 render node
and `EGL_VENDOR=Mesa Project` today. It is one module load away from being the
hybrid test rig this caveat needs.

---

## Merged and released — 2026-08-04

- **Approved** (with thanks) and **merged** as `8a708f1f` (plain merge commit,
  branch retained).
- **Released as `v0.3.57`** — "black camera on hybrid-GPU laptops (EGL debayer
  lands on NVIDIA)", tagged at the merge commit, marked latest.
  <https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/releases/tag/v0.3.57>

Pre-tag sanity on merged `main`: `bash -n` clean on all four scripts, and
`test-egl-vendor-pin.sh` 18/18.

Release notes carry the three known gaps forward rather than burying them —
PipeWire's libcamera source is still unpinned, `prime-select nvidia` is untested,
and AMD iGPU + NVIDIA is unit-tested only.

### Follow-ups worth filing

1. **`test-gst-tools-check.sh` assumes a broken camera.** `10 passed, 1 failed`
   on any machine where the relay is actually working — confirmed identical at
   base `main` (`6c205ba`), so it predates #76. @4nrry offered to file it.
2. **`prime-select nvidia` tester.** Andy's 960XGL is a Book4 Ultra with an RTX
   4070 Max-Q, NVIDIA userspace installed and DKMS modules already built, but
   nothing bound to the device — one module load from being the test rig this
   gap needs.
3. **Docs precision:** the READMEs say the bug affects "all Galaxy Book4 Ultra".
   Affectedness actually depends on the NVIDIA driver being *bound*, not on the
   model — Andy's own Book4 Ultra is unaffected today. Risks sending unaffected
   owners after a fix they don't need.
