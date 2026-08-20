# PR #91 review — "webcam-fix-libcamera: detects Fedora as Arch when pacman is installed"

Reviewed: 2026-08-20. Author: **@dpol1** (Davide Polato). Base `main`,
`MERGEABLE` / `CLEAN`, no CI on the repo. 1 commit, 2 files, +239/−21.
Head `abc99612`, parent `116f4a44` — which *is* the current `main` tip, so this
is a clean fast-forward: no rebase, no conflicts (`git merge-tree` reports 0).
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/91>

## Verdict: 🟢 **Merge**

No blockers. The diagnosis is correct, I verified it independently from Fedora's
own package metadata rather than taking the PR's word for it, and the fix is a
strict improvement — every input that used to be classified correctly still is,
and several that weren't now are. The test suite is real: I mutated
`detect_distro()` to reintroduce the pacman-first probe and the Fedora case
failed, so it is not a suite that passes against the bug it claims to guard.

Three nits below, none of which should hold the merge. The follow-up section is
the more interesting part: the same class of bug is live in four sibling scripts,
and one of them is the mirror image the PR body records as "unaffected."

| | |
|---|---|
| Blocking | 0 |
| Should fix (would land in this PR) | 0 |
| Nits | 3 |
| Build artifacts in diff (`builddir`, `node_modules`) | **None** — 2 files only |
| Scope creep | **None** — no drive-by refactors, no unrelated edits |
| Subsystems touched | `webcam-fix-libcamera/install.sh`, `camera-relay/tests/` |
| Correct model directory? | **N/A** — distro detection, not a per-model fix |
| Kernel / codec patches touched | **No** |
| Camera sensor YAML touched | **No** |
| `nixos/` packaging affected | **No** — `nixos/` never references `webcam-fix-libcamera` |
| Diagnosis correct? | **Yes** — confirmed against Fedora's package DB |
| Hardware validation | **Not by me** — no Fedora box here; see below |

### On hardware validation

I did **not** boot-test this. I have no Fedora 43 machine, and nothing in this
diff needs one: it is pure shell logic with no kernel, DKMS, libcamera or
PipeWire component, and it is fully exercisable from fixture files. What I ran
is inspection-level plus the test suites — that is the appropriate bar here, but
it is a weaker signal than "installed on the affected hardware," and @dpol1's
report that detection now prints `Fedora/DNF-based` on the live machine is the
only on-hardware evidence in play.

---

## What I verified

### 1. Fedora really does ship `pacman` — confirmed from Fedora's package DB

The whole PR rests on this claim, so I checked it rather than assuming it:

```
$ curl -s https://mdapi.fedoraproject.org/f43/pkg/pacman
{"epoch":"0","version":"7.0.0","release":"5.fc43","arch":"x86_64",
 "repo":"updates-testing",
 "summary":"Package manager for the Arch distribution",
 "description":"Pacman is the package manager used by the Arch distribution.
  It can be used to install Arch into a container or to recover an Arch
  installation from a Fedora system ..."}
```

`pacman-7.0.0-5.fc43.x86_64` — the exact NEVRA the PR body cites. So a Fedora 43
user who has ever wanted to bootstrap an Arch container has `/usr/bin/pacman`,
and the old `command -v pacman` probe fired first and won. The failure mode the
reporter describes (`✓ Arch-based detected`, then `error: target not found: git`
at `[9/14]`) follows directly.

Precision note: mdapi shows it in `updates-testing` for f43 and returns nothing
for f41/f42, so the blast radius is narrower than "every Fedora user." It does
not change the verdict — probing for a binary to identify an OS is wrong whether
or not any given distro currently exploits the wrongness.

### 2. The tests actually catch the bug (mutation-tested)

A suite that passes against the broken code is worth nothing. I reintroduced the
bug by hoisting the pacman probe above the os-release mapping inside
`detect_distro()`:

```
Fedora with pacman installed stays Fedora
  ✗ Fedora 43 with both dnf and pacman: want 'fedora|Fedora/DNF-based*', got 'arch|Arch-based'
...
15 passed, 1 failed        (exit 1)
```

It fails, and only that case fails. Restored, it is 16/16.

The stubs are also honest. My standing worry with this pattern is a stub that
ignores its arguments and ends up validating the test instead of the code — here
the stubs exist purely so `command -v` finds a name on a `PATH` containing
nothing else, which is exactly and only what the fallback consults. `detect_distro()`
is pure builtins, so the emptied `PATH` costs nothing and the host system cannot
leak into a result.

### 3. Full test suite, on the PR head

Every suite in `camera-relay/tests/`, not just the two the PR claims:

```
test-chromium-pipewire-flag.sh         61 passed, 0 failed
test-distro-detection.sh               16 passed, 0 failed   (new)
test-egl-vendor-pin.sh                 18 passed, 0 failed
test-gst-tools-check.sh                10 passed, 0 failed
test-launcher-validation.sh            29 passed, 0 failed
test-monitor-exit-propagation.sh        5 passed, 0 failed
test-pipewire-restart-guard.sh         17 passed, 0 failed
test-unit-regeneration.sh              15 passed, 0 failed
test-wireplumber-format-nudge.sh       26 passed, 0 failed
test-writer-format-check.sh            (C bench, not a suite)
```

`bash -n webcam-fix-libcamera/install.sh` is clean.

### 4. Test file placement matches existing convention

`camera-relay/tests/test-distro-detection.sh` testing a file in
`webcam-fix-libcamera/` looks misfiled at a glance, but it is exactly what
`test-pipewire-restart-guard.sh` already does — same `ROOT="$(... /../..)"`
idiom, same `INSTALL="$ROOT/webcam-fix-libcamera/install.sh"` line. This repo
uses `camera-relay/tests/` as the one shell-test directory. Consistent; leave it.

### 5. Behavioural equivalence — no classification regressions

I walked every path of the old block against the new one. The new code is a
superset; there is no input the old code got right and the new one gets wrong.

| Input | Old | New |
|---|---|---|
| `ID=fedora` + pacman installed | **arch** ✗ | fedora ✓ |
| `ID=ubuntu` + pacman installed | **arch** ✗ | ubuntu ✓ |
| `ID=arch` + dnf installed | arch ✓ | arch ✓ |
| `ID=endeavouros ID_LIKE=arch` | arch ✓ | arch ✓ |
| `ID=pop ID_LIKE="ubuntu debian"` | ubuntu ✓ | ubuntu ✓ |
| `ID=debian` | debian ✓ | debian ✓ |
| unrecognised `ID`, apt present | debian | debian ✓ |
| no os-release, apt present | debian | debian ✓ |
| `ID=gentoo`, no supported pm | error | error ✓ |

Note the `ID=arch` + `dnf` row: Arch's `extra` repo ships `dnf 4.24.0` **and**
`apt 3.3.3` (verified via `archlinux.org/packages/search/json/`). The old
pacman-first order happened to survive that by luck. The new code survives it by
construction. That matters for the follow-up section.

I also ran the extracted function against real-world-shaped os-release files:
this host's Ubuntu 24.04, quoted `ID="fedora"`, `HOME_URL` containing an `=`,
mixed-case `ID=Zorin ID_LIKE="Ubuntu Debian"`, RHEL's `ID=rhel ID_LIKE=fedora`,
and a file led by a comment and a blank line. All correct.

### 6. Scope, artifacts, packaging, docs

- Two files. No `builddir/`, no `node_modules/`, no stray reformatting, no
  "while I was in here" refactor. The `detect_distro()` extraction is load-bearing
  for the tests, not cosmetic.
- `nixos/` contains no reference to `webcam-fix-libcamera` at all, so packaging
  cannot drift from this change.
- `webcam-fix-libcamera/install.sh` carries no version string; releases are
  tagged separately, so there is nothing to bump in the diff.
- No open issue tracks this. It is a fresh field report from @dpol1
  ("*a real gap found while using the script … I use Fedora btw*").

---

## Nits (non-blocking, fine to merge without)

**N1 — `while read` drops a final line with no trailing newline.**
`while IFS='=' read -r key value; ... done < "$os_release"` never processes the
last line if the file lacks a terminating newline. Confirmed: an os-release
ending `...\nID=fedora` (no newline) is classified `debian` on this box, because
it silently falls through to the package-manager probe — i.e. straight back into
the bug being fixed. Every real distro ships a newline-terminated os-release, so
this is theoretical, but the *failure mode* is the one thing worth hardening
against. One-word fix:

```bash
while IFS='=' read -r key value || [[ -n "$key" ]]; do
```

**N2 — CRLF line endings fall through the same way.** `ID=fedora\r\n` yields
`value="fedora\r"`, matches no `case` arm, probe wins. Same one-line class of
fix (`value="${value%$'\r'}"`), same near-zero likelihood. Mentioning it only
because it shares N1's silent-fallback shape.

**N3 — the wiring guard is brittle.** `grep -qE '^detect_distro$'` fails if the
call is ever indented or given an explicit argument. That is a false *failure*,
not a false pass, so it is the safe direction to be brittle in. Leave it.

---

## Follow-up (separate PRs — do not expand #91)

@dpol1 correctly flagged the sibling scripts and correctly left them out to keep
the diff reviewable. Confirmed by inspection, with one correction:

| Script | Probe order | Status |
|---|---|---|
| `webcam-fix/install.sh` | pacman → dnf → apt | same bug |
| `webcam-fix/uninstall.sh` | pacman → dnf → apt | same bug |
| `webcam-fix-book5/install.sh` | pacman → dnf → apt | same bug |
| `webcam-fix-libcamera/uninstall.sh` | — | no probe, unaffected |
| `mic-fix/install.sh` | dnf → pacman → apt-get | **mirror bug** |
| `speaker-fix/install.sh` | dnf → pacman → apt-get | **mirror bug** |
| `speaker-fix-940xfg/install.sh` | dnf → pacman → apt-get | **mirror bug** |

The PR body calls the last three "unaffected." They are unaffected by the
*Fedora-with-pacman* case only. Because Arch's `extra` repo ships `dnf`, a
dnf-first probe misdetects an Arch host as Fedora — the exact same defect
pointing the other way. Worth saying out loud so nobody reads "checks dnf first"
as "safe."

Two things to decide before the follow-up:

1. **Where the function lives.** Copy-pasting `detect_distro()` into six scripts
   is how the current mess started. There is no shared shell library in the repo
   today, so this is a real design call, not a mechanical port.
2. **Issue #70** ("Installer drift: `webcam-fix-libcamera` and `webcam-fix-book5`
   diverge silently") — merging #91 alone *widens* that drift by one more
   behaviour. Not a reason to hold #91; a reason to land the Book5 half soon.

I would take @dpol1 up on the offer.

---

## Recommendation

Merge as-is, tag a patch release. N1/N2 are a two-line hardening that can ride
along in the sibling-script follow-up rather than round-tripping this PR.

*Not posted to GitHub — draft for Andy to review and send.*
