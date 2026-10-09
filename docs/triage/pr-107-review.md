# PR #107 review — "webcam-fix-book5: use the SoftISP tuning patches on libcamera 0.7.2"

VERDICT: CHANGES REQUESTED

**Review POSTED 2026-10-09** as REQUEST_CHANGES on head `c7e48f5` (unchanged
since the review; no prior comments or reviews on the PR):
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/107#pullrequestreview-5468715276>
(review id 5468715276). Awaiting the author's fix for B1.

The only blocker is B1: the commit drops the executable bit on
`build-patched-libcamera.sh`. The fix is a one-line `chmod +x`. The logic is
otherwise sound, and every claim in the PR body that could be checked off-hardware
holds.

Reviewed: 2026-10-09. Author: **@david-bartlett** (David Bartlett). Head
`c7e48f5` (1 commit), base `main` at `e9a3738`, `MERGEABLE`, no CI, no comments
or reviews yet. 3 files: `webcam-fix-book5/install.sh` +7,
`webcam-fix-book5/libcamera-bayer-fix/build-patched-libcamera.sh` +55/−26,
`webcam-fix-book5/ov02e10-0.7.2.yaml` +84 (new).
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/107>

Context: this is the shell-installer port of the four libcamera patches that
#102 added for NixOS (`pr-102-review.md`). Before this PR the shell installer
shipped the `.patch` files but never applied them. Step 4 still uses `sed`.

## What I verified

| # | Check | Result |
|---|---|---|
| 1 | Moved install-strategy block | The conditions are byte-identical to `main` apart from the `info` lines, which became `INSTALL_MODE_MSG=`. Its inputs (`USE_SRPM` from step 3; `DISTRO` and `LIBCAMERA_LIB_DIR` from step 1) are all set before the new location, and nothing between there and step 8 reassigns them. `USE_FULL_INSTALL` has exactly 2 readers (step 4c L888/L892, step 8 L969), both after L857. `[[ -n "$INSTALL_MODE_MSG" ]] && info …` (L967) is safe under `set -e` because it is an `&&` list and not the last command. A libraries-only install printed no mode line before and prints none now. |
| 1 | `grep` / `pipefail` | Neither new `grep` is in a pipeline: `grep -m1 -oP … meson.build \|\| true` (L887) and `grep -qas … ` inside an `elif` (install.sh L873). The SIGPIPE-141 gotcha cannot fire. |
| 2 | Snapshot / restore | Run for real on **master** (see row 3): all 4 patches attempted, `git apply` failed, `[WARN] … building with the bayer fix only`. The restored tree's `git status` showed only the 2 `sed` edits from steps 4/4b, with no `??`, so the restore is exact. On v0.7.2 the snapshot was discarded after success. The subshell `cd` does not leak, and step 6 `cd`s again anyway. *Caveat:* Claude Code's safety check refused to run a harness containing the PR's literal `rm -rf "$BUILD_DIR/libcamera"`. I ran the same code with each `rm -rf` replaced by `mv` to a side directory, which gives the same end state. |
| 3 | Patches vs versions | I ran the PR's real steps 4 + 4b + 4c, extracted from the script, on `git archive` trees. **v0.7.2: all 4 apply** (11 files changed). **v0.7.0:** blc applies, then min-gain-step, awb and exposure-target fail. **v0.7.1:** blc and min-gain-step apply, then awb and exposure-target fail. **master (`8103c3f`, 2026-10-06): all fail** (`src/ipa/simple` was renamed to `src/ipa/softisp`). Pristine v0.7.2 + `bayer-fix-v0.7.patch` + the 4 patches (the NixOS order) also applies. So the claim "applies only to 0.7.2" holds. On 0.7.0/0.7.1, *some* patches apply individually, which is why the all-or-nothing restore matters (see N5). |
| 3 | Version detection | `^\s*version\s*:\s*'\K[0-9.]+` does not match `meson_version : '>= 0.63'`. It reads `0.7.0`/`0.7.1`/`0.7.2` correctly from the three tags. **master's `meson.build` still says `0.7.2`**, so the gate passes on master and the snapshot is what saves it (N5). |
| 4 | `exposureTarget` marker | `git grep exposureTarget` finds nothing under `src/ipa include` in v0.7.0, v0.7.1, v0.7.2 or master. The only source is the patch's `tuningData["exposureTarget"]` literal, so a stock IPA cannot false-positive today. |
| 4 | IPA path list | libcamera installs IPAs at `<libdir>/libcamera/ipa/` (`src/meson.build:5`, `src/ipa/meson.build:7`). The full install's `detect_build_options` uses `-Dlibdir=lib64`, `lib/x86_64-linux-gnu` or the default `lib`, under `/usr` or `/usr/local`. All 6 resulting paths are in the `grep` list (install.sh L873–875). The globs need no `nullglob`/`failglob` (neither is set): an unmatched glob stays literal and `-s` silences it. `grep -q` exits 0 on a match even if other files are missing. |
| 4 | Other yaml paths | The 0.5.x branch comes first and is unchanged. OV02C10 has no `ov02c10-0.7.2.yaml`, so the `-f` test falls through to the standard file. An unflipped OV02E10 (no bayer fix) has a stock IPA and gets the standard file. A libraries-only install skips 4c, so it also gets the standard file. Ordering is fine: the bayer fix runs at [8/15], before the tuning selection at [12/15]. |
| 5 | Cleanup | The new yaml is **installed under the same name** (`$TUNING_DIR/ov02e10.yaml`), so `uninstall.sh` L134–141 already removes it. `--uninstall` restores the backed-up IPA dir (step 7 copies `$LIBCAMERA_IPA_DIR/*`), which puts the stock `ipa_soft_simple.so` back. The NixOS module uses `nixos/ov02e10.yaml` and is untouched. See N3 for the manual `--uninstall`-only case. |
| 6 | yaml vs `nixos/ov02e10.yaml` | CCMs, `blackLevel: 4096` and the algorithm list are identical. The only value change is `exposureTarget` 1.5 → 1.7. The rest are header/comment edits, but **two comments say 1.8** (N1). The shell file has no `channelLevels`, which is fine: the patched BLC falls back to `blackLevel` when it is absent. |
| 7 | `bash -n` | Both changed scripts pass. |
| 7 | shellcheck (`koalaman/shellcheck:stable`) | install.sh: 8 → 8 findings. build-patched-libcamera.sh: 8 → 7. **No new findings.** |
| 7 | File mode | **`old mode 100755` → `new mode 100644`** on build-patched-libcamera.sh. See B1. |
| 8 | Docs | The README does not mention the 0.7.2 patches or the new yaml (N2). |
| — | Tests | No suite in `camera-relay/tests/` covers `webcam-fix-book5`. I did not compile the patched tree: the patches touch none of the files the `sed` steps edit, and the author built it on Fedora 45. |

## Findings

### Blocking

**B1. `build-patched-libcamera.sh` loses its executable bit, which breaks the bayer fix for everyone.**
`git diff main...pr-107` shows `old mode 100755 / new mode 100644`. Every caller
runs the file directly:

- `install.sh:552` and `:567`: `sudo "$BAYER_FIX_SCRIPT"`
- `uninstall.sh:151`: `sudo "$SCRIPT_DIR/libcamera-bayer-fix/build-patched-libcamera.sh" --uninstall`
- README L144/L149: `sudo ./libcamera-bayer-fix/build-patched-libcamera.sh`
- `tune-ccm.sh:53`: the same command

I ran a 0644 copy directly and got `Permission denied`, exit 126. Under `sudo` it
is `command not found`. `install.sh` then prints "Bayer fix build FAILED" and
every OV02E10 install on a git checkout is left purple. This hits every distro,
not only 0.7.2. The mode change was probably caused by the author's editor or a
Windows/FAT checkout.
**Fix:** `git update-index --chmod=+x webcam-fix-book5/libcamera-bayer-fix/build-patched-libcamera.sh`
(or `chmod +x`) and amend or push.

### Non-blocking

**N1. The yaml comments say 1.8, but the value is 1.7.** `ov02e10-0.7.2.yaml:6`
says "only exposureTarget differs (1.8 here, 1.5 in the NixOS file)". `:81` says
"1.8 rather than the NixOS module's 1.5". `:83` is `exposureTarget: 1.7`. The PR
body also says 1.7. Fix both comments.

*On 1.7 vs 1.5:* I'd accept 1.7 for the shell file. Shell users today run the
**stock** AGC target of 2.5 (`kExposureOptimal = kExposureBinsCount / 2.0`). So
1.7 is a smaller visible step down than 1.5, which reduces "the camera got darker
after updating" reports. It is also the only value tested on the shell path
(Fedora 45). Both 1.5 and 1.7 are one person's preference on one machine. Keeping
the NixOS file at 1.5 is fine, and the header records the difference.

**N2. README.** One short paragraph in the bayer-fix section (~L140) would help.
It should say that on libcamera 0.7.2 with a full install, the build also applies
the four SoftISP tuning patches and the installer picks `ov02e10-0.7.2.yaml`.
**Existing 0.7.2 users will not get this from re-running `./install.sh`**: the
installed version still matches the backup's `version`, so it reports "already
installed" and never rebuilds. They need
`sudo ./libcamera-bayer-fix/build-patched-libcamera.sh --uninstall` and then
`./install.sh`. Re-running the build script directly over an existing install is
a pre-existing hazard: step 7 copies the *patched* libs over the stock backup.
Keep that out of this PR, but don't recommend it as the upgrade path.

**N3. The patch-dependent yaml can outlive the patched IPA.** The yaml is selected
only when `install.sh` runs. Two cases leave `ov02e10-0.7.2.yaml` on a stock IPA,
which the yaml header says gives a green tint, until `./install.sh` is re-run:

- A distro update replaces the IPA.
- The user runs the README's standalone `--uninstall`, which restores libcamera
  but leaves the yaml.

The first case already loses the bayer fix (the image is purple anyway), and
re-running install.sh restores both. The second case is new. A README sentence
("after `--uninstall`, re-run `./install.sh` or `./uninstall.sh`") is enough.

**N4. `tune-ccm.sh` is unaware of the patched path.** It overwrites
`ov02e10.yaml` with presets that have no `blackLevel: 4096`, no `exposureTarget`,
and CCMs measured on stock statistics. install.sh still prints "Use ./tune-ccm.sh
to interactively find the best color preset" after installing the 0.7.2 file
(L889). tune-ccm backs up and restores, so this is recoverable. Either skip that
hint on the 0.7.2 branch or note it. A follow-up is fine.

**N5. The 4c gate also passes on master.** If the tag clone fails and the script
falls back to master (L781–785), `meson.build` there still reads `0.7.2`. Step 4c
runs, fails, and restores, so behaviour is correct (verified) but prints a
misleading warning. Optional: also require `LIBCAMERA_GIT_TAG != master`.

**N6. Untested distros.** The PR body says Ubuntu 26.04 and Arch are still to be
tested. Both are full-install paths that would apply the patches (Ubuntu via the
0.7.0 → v0.7.2 floor). Worth waiting for those two results or noting them in the
release. Fedora 45 SRPM (applied) and Fedora 44 0.7.1 (skipped) are covered by
the author.

**N7 (nit).** install.sh greps every candidate IPA path. A stale patched IPA left
under `/usr/local/…` would select the 0.7.2 yaml even when the active libcamera is
`/usr`. This is very unlikely, so leave it.

## GitHub review (posted 2026-10-09, review id 5468715276, unchanged from the draft)

> Thanks David, this is a really clean port, and the PR description made it easy
> to check.
>
> I checked what I could without Book5 hardware. On libcamera clones, the PR's
> steps 4/4b/4c apply all four patches on v0.7.2. As a set they fail on v0.7.0,
> v0.7.1 and current master, and the snapshot restores the tree exactly when they
> fail. (Master's `meson.build` still says `0.7.2`, so that restore path really
> does get exercised.) The moved install-strategy block has identical conditions.
> No stock IPA I could find contains `exposureTarget`. The IPA path list covers
> every libdir the full install can produce. The new yaml goes in under the
> existing `ov02e10.yaml` name, so `uninstall.sh` cleans it up. shellcheck finds
> nothing new.
>
> **One blocker:** the commit changes `build-patched-libcamera.sh` from 100755 to
> 100644. `install.sh`, `uninstall.sh` and the README all run it directly
> (`sudo "$BAYER_FIX_SCRIPT"`), so it would fail with "command not found" and
> every OV02E10 install would be left purple. A quick
> `git update-index --chmod=+x webcam-fix-book5/libcamera-bayer-fix/build-patched-libcamera.sh`
> fixes it.
>
> Small things, none of them blocking:
> - `ov02e10-0.7.2.yaml` lines 6 and 81 say **1.8**, but the value is 1.7.
>   I'm happy with 1.7 for the shell file: it's a smaller step down from the
>   stock 2.5 that shell users have today.
> - A short README note would help. Existing 0.7.2 users won't get the patches
>   from re-running `./install.sh`, because the version still matches the backup.
>   They need `build-patched-libcamera.sh --uninstall` and then `./install.sh`.
>   It's also worth noting that after a standalone `--uninstall` the patched yaml
>   stays until `install.sh` or `uninstall.sh` is run.
> - Optional: `install.sh` still suggests `tune-ccm.sh` after installing the
>   0.7.2 yaml, but its presets drop `exposureTarget` and the 4096 black level.
>   This could be a follow-up.
>
> Looking forward to the Ubuntu 26.04 and Arch results. Once the mode is fixed,
> I'm happy to merge.

## Re-check at 586c849

RE-CHECK VERDICT: READY TO MERGE

Re-checked 2026-10-09. The author force-pushed a single commit `586c849` (parent
`e9a3738`, the same base as before). The previously reviewed head was `c7e48f5`.
GitHub: `MERGEABLE` / `CLEAN`. `git merge-tree` against current `main` (`d405992`,
docs only since the base) is clean. There is no CI. `reviewDecision` is still
`CHANGES_REQUESTED` from my 10:14Z review, so **Andy has to approve before
merging** to clear it.

Inputs: David's comments at 10:28Z ("fixing now, then Ubuntu/Arch") and 14:40Z
(everything addressed, plus Ubuntu 26.04.1 / CachyOS / Fedora 45 results), and the
rewritten PR description.

**Since the last review, the PR is larger.** `c7e48f5 → 586c849` changes 4
files, +124/−14. Most of that is not the requested fixes. It is a **rework of
`--uninstall`**, prompted by David's Ubuntu test. On Ubuntu 26.04 (distro 0.7.0,
built as v0.7.2 per #71), `uninstall.sh` on `main` leaves libcamera broken: no
soft ISP, RAW only. I reviewed the rework in full (below). It is correct, it
fixes a real bug on `main`, and it is limited to package-managed installs.

### Requested changes

| Item | Status | Evidence |
|---|---|---|
| **B1** file mode | **Fixed** | `git ls-tree pr-107 …/build-patched-libcamera.sh` → `100755`. `git diff main...pr-107` contains no `old mode` line (count 0). `install.sh` is still `100755`. |
| N1 yaml comments | **Fixed** | Lines 6 and 81 now say 1.7, and the value at line 83 is `1.7`. No other yaml changes. |
| N2 README | **Fixed, accurate** | A new paragraph after the rebuild block (README ~L160). The upgrade path is `--uninstall` and then `./install.sh`. It does **not** recommend re-running the build script over an existing install. "Re-running `./install.sh` won't add the patches" matches `install.sh` L543–562: the backup version equals the current version, so it prints "already installed". The list of full-install paths matches the install-strategy block. |
| N3 yaml outlives patched IPA | **Fixed (docs)** | README bullet: after a standalone `--uninstall`, re-run `./install.sh` or `./uninstall.sh`. The tuning step in `install.sh` runs on every run, not only when the bayer fix builds, so re-running really does re-select the yaml. |
| N4 tune-ccm | **Fixed** | `install.sh` sets `TUNING_PATCHED=true` only on the 0.7.2 branch and reads it as `${TUNING_PATCHED:-false}` (safe under `set -u`). On that branch it prints "Matched to the SoftISP tuning patches: tune-ccm.sh presets don't apply" instead of the tune-ccm hint. The README bullet tells users to re-run `./install.sh` to put the file back. |
| N5 master gate | **Fixed** | A new first branch in step 4c: `SWISP_SRC_VER == 0.7.2 && USE_SRPM != true && LIBCAMERA_GIT_TAG == master` skips the patches with an info line. `LIBCAMERA_GIT_TAG=master` is set on both master paths: clone fallback (L870) and unparseable version (L294). `USE_SRPM` is initialised at L790, before use. The SRPM guard is correct, because an SRPM build is Fedora's release source even if the version string was unparseable. |
| N6 untested distros | **Covered by author** | On the 940XHA, David tested install and uninstall on Ubuntu 26.04.1 (0.7.0 → v0.7.2: patches applied, 0.7.2 yaml, Kamoso + Firefox work), on CachyOS (Arch repos 0.7.2: applied, camera works, `pacman -Qkk` clean) and on Fedora 45 beta (re-tested with the final code, `rpm -V` clean). |
| N7 | Not changed | As agreed (nit). |

The `.patch` files and the body of step 4c are unchanged
(`git diff c7e48f5 586c849 -- '*.patch'` is empty). The earlier patch-apply runs
on v0.7.0/0.7.1/0.7.2/master therefore still hold, so I did not re-run them.

### New logic: `--uninstall` rework (build-patched-libcamera.sh L48–117, L178–209, L1062–1064, L1114)

What it does:
- A full install now copies meson's `builddir/meson-logs/install-log.txt` into the
  backup. Both copies run from `$BUILD_DIR/libcamera`: the `cd` is at L1054 and
  nothing in between changes directory.
- `libcamera_pkg_managed` checks whether any backed-up `libcamera*.so*` is owned by
  a package (`dpkg-query -S` / `rpm -qf` / `pacman -Qqo`). If none is, as with a
  `/usr/local` source build, the old path runs, now with symlinks restored too.
- `remove_unowned_installed_files` removes a file listed in the install log only
  if it still exists, is not a directory, is **not in the backup** (the backup gets
  restored instead) and is **not owned by any package**. With an older backup
  that has no install log, it falls back to `libcamera*.so*` in the directories
  that hold backed-up libraries. It then runs `rmdir` on directories that are now
  empty, but only while the path contains `libcamera`.
- The restore loop now handles symlinks: `find \( -type f -o -type l \)` and
  `ln -sfn "$(readlink …)"`. Step 7 already backed up symlinks, because
  `[[ -f ]]` follows links and `cp -a` keeps them as links. They were just never
  restored. This is the actual Ubuntu bug: `libcamera.so.0.7` was left pointing
  at the 0.7.2 build.
- `reinstall_distro_libcamera` reinstalls the libcamera packages that are
  **installed**, instead of `apt-get install --reinstall 'libcamera*'`, which
  matches every libcamera package in the archive. It warns, rather than failing,
  if a reinstall doesn't work. The stale-backup path uses the same helpers.

How I verified it:

| Check | Result |
|---|---|
| Sandbox run of the PR's **own** helper and restore code. I extracted them with `sed` from the head and ran them under `set -euo pipefail` in a fake root under the scratchpad. `pkg_owns` was stubbed with an owned-files list, and the setup simulated Ubuntu: distro 0.7.0 → v0.7.2 full install, plus headers, a changed `uncalibrated.yaml` and our `ov02e10.yaml`. | **With install log:** it removed `libcamera.so.0.7.2`, `libcamera-base.so.0.7.2`, the unowned `libcamera.so` dev link and both headers. It kept the owned `uncalibrated.yaml` and the user's `ov02e10.yaml`. It restored `libcamera.so.0.7 → libcamera.so.0.7.0` and `libcamera-base.so.0.7 → …0.7.0`, and the IPA content went back to the 0.7.0 file. The empty `include/libcamera/**` directories were removed and `/usr/include` was kept. **Old backup, no install log:** only the 3 added `libcamera*.so*` were removed (headers left, as documented), and the symlinks and IPA were restored the same way. |
| Version check on Ubuntu 0.7.0 → v0.7.2 | The backup records `LIBCAMERA_VERSION_CLEAN`, which the #71 floor sets to `0.7.2`. After the install, `pkg-config` reads 0.7.2. So uninstall takes the normal path, not the stale one, which matches David's "restored `libcamera.so.0.7 -> 0.7.0`". |
| `dpkg-query -S` on this Ubuntu 26.04.1 box (read-only) | It resolves `/usr/lib/x86_64-linux-gnu/libcamera.so.0.7{,.0}` and `…/ipa/ipa_soft_simple.so` to their packages, so absolute paths in the meson log match the dpkg database. |
| apt package selection (`apt-get install --reinstall -s` with the exact list the new `dpkg-query \| awk` produces here) | The list is `gstreamer1.0-libcamera libcamera-dev libcamera-ipa libcamera0.2 libcamera0.7 libspa-0.2-libcamera`. `libcamera0.2` is an obsolete leftover from an older release and can't be downloaded. apt prints "Reinstallation of libcamera0.2 is not possible" and **exits 0, reinstalling the other 5**, so a stray old package doesn't turn the reinstall into a warning. |
| What meson installs to the tuning directory (libcamera v0.7.2, `src/ipa/simple/data/meson.build`) | Only `uncalibrated.yaml`. Our `ov02e10.yaml` is never in the install log, so uninstall cannot remove or touch it. That is consistent with the README note about the yaml staying behind. |
| `set -e` hazards | `[[ … ]] && continue` / `&& { …; }` lists are exempt. The `grep` inside `mapfile < <(…)` cannot kill the parent. The empty `"${files[@]}"` is fine under `set -u` on bash ≥ 4.4. `reinstall_distro_libcamera` ends with `return 0`. |

### Static checks (re-run)

- `bash -n`: both changed scripts pass.
- shellcheck (`koalaman/shellcheck:stable`):
  - install.sh: main 8 → head 8.
  - build-patched-libcamera.sh: main 8 → head 7.
  - The finding text matches `main`'s set minus the `SCRIPT_DIR` SC2034, which is now used. **No new findings.** The SC2295 on the restore loop's `${backup_file#$BACKUP_DIR}` is pre-existing.

### Non-blocking (follow-ups, not for this PR)

- **R1. Uninstall is slow and silent on Ubuntu.** `pkg_owns` runs one
  `dpkg-query -S` per install-log entry that still exists and isn't backed up.
  That is about 0.33 s each here (50 calls took 16.4 s). With roughly 100
  installed headers plus libs, tools, gst and python, expect up to about a minute
  without output. It's correct, just slow. A follow-up could batch the lookups
  (one `dpkg-query -S` with all paths) or print a "checking package ownership…"
  line.
- **R2. Arch reinstall is `pacman -S` without `-y`.** If the local sync database
  is newer than what's installed, this upgrades only libcamera, which is a partial
  upgrade. This is **pre-existing**: `main` already runs
  `pacman -S libcamera libcamera-ipa`. The PR only widens the package list.
- **R3. The "Found while testing" items in the PR description are worth their own
  issues:**
  - Ubuntu: the MOK key is not checked for enrollment when Secure Boot is turned on later.
  - Fedora: the akmods key is used only when SB is on at install time.
  - Arch: generic `linux-headers` with a CachyOS kernel.
  - Arch: `/usr/lib64` symlink → "Could not verify installation timestamp".

  David also said he'll report the Fedora libraries-only install, where the camera
  didn't work. None of these are caused by this PR.

### Draft merge comment (NOT posted)

> Thanks David, this is great work. Thanks especially for testing on Ubuntu 26.04
> and CachyOS as well as Fedora.
>
> Everything from the review is fixed: the script is executable again, the yaml
> comments say 1.7, `install.sh` no longer points people at `tune-ccm.sh` for the
> patched file, step 4c skips a master clone, and the README now gives the right
> upgrade path for existing 0.7.2 users.
>
> The `--uninstall` fix is a really good catch. Leaving `libcamera.so.0.7`
> pointing at the 0.7.2 build was a real bug on `main` for anyone on Ubuntu's
> 0.7.0. I ran the new helper and restore code in a sandbox with an Ubuntu-style
> layout, with and without the install log, and it removes exactly the added files
> and puts the symlinks back. Your test results cover the hardware side.
>
> Merging now. It'll go out in the next release, v0.3.76. The other installer
> issues you listed at the bottom (Secure Boot key enrollment, CachyOS headers)
> are worth their own issues, and I'll follow up on those separately.

### Draft release notes (NOT published)

**Title:** `v0.3.76 — Book5 OV02E10: SoftISP tuning on libcamera 0.7.2, and the bayer-fix uninstall no longer breaks libcamera`

**Body:**

> If you have a **Galaxy Book5 with the OV02E10 camera** and use the shell
> installer (`webcam-fix-book5`), this release brings the four SoftISP tuning
> patches from the NixOS module to libcamera 0.7.2. It also fixes an uninstall bug
> that could leave libcamera broken on Ubuntu.
>
> Contributed by [@david-bartlett](https://github.com/david-bartlett) in
> [#107](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/107).
>
> ## What's new
>
> - **SoftISP tuning patches on libcamera 0.7.2.** When the bayer-fix build
>   (`libcamera-bayer-fix/build-patched-libcamera.sh`) builds libcamera **0.7.2**
>   as a **full install**, it now applies the same four patches as the NixOS
>   module:
>   - `blc-channel-levels`
>   - `agc-min-gain-step`
>   - `awb-skip-saturated`
>   - `agc-exposure-target`
>
>   Full installs are the Fedora source RPM, Arch, Debian/Ubuntu, and libcamera
>   in `/usr/local`. Ubuntu's 0.7.0 is already built as 0.7.2 (#71), so it is
>   included. `install.sh` then installs a matching tuning file,
>   `ov02e10-0.7.2.yaml`, which has the NixOS CCMs and black level with
>   `exposureTarget: 1.7`.
> - **Other versions are unchanged.** libcamera 0.7.1, 0.6.x and older,
>   libraries-only installs and master builds keep today's behaviour: only the
>   bayer fix and the existing tuning file.
> - **`tune-ccm.sh` isn't suggested for the patched file.** Its presets are
>   measured on stock libcamera.
>
> ## Fixed
>
> - **`./uninstall.sh` / `build-patched-libcamera.sh --uninstall` left libcamera
>   broken when the build was a different version from the distro's.** On Ubuntu
>   26.04 (0.7.0 built as 0.7.2) the camera ended up RAW-only after uninstalling:
>   - the `libcamera.so.0.7` symlink was never restored;
>   - the added 0.7.2 libraries were never removed;
>   - so the 0.7.2 library loaded the stock 0.7.0 IPA, and the soft ISP was
>     disabled.
>
>   When libcamera comes from your package manager, uninstall now:
>   - removes the files the build added that no package owns;
>   - restores the backup, including symlinks;
>   - reinstalls your installed libcamera packages.
>
>   Source builds in `/usr/local` keep the old behaviour, plus the symlink fix.
>
> ## Who is affected
>
> Book5 OV02E10 owners whose sensor needs the bayer fix (flipped sensor), on a
> full-install distro with libcamera 0.7.0 or 0.7.2. Everyone else (OV02C10,
> Book3/Book4, NixOS, libcamera 0.7.1 or older) sees no change.
>
> ## How it was tested
>
> @david-bartlett tested install and uninstall on a Galaxy Book5 Pro (940XHA):
> - **Fedora 45 beta** (0.7.2 source RPM): patches applied, colour correct, and
>   `rpm -V` is clean after uninstall.
> - **Ubuntu 26.04.1** (0.7.0 → 0.7.2): patches applied, and Kamoso and Firefox
>   work. Uninstall restores Ubuntu's 0.7.0.
> - **CachyOS** (Arch repos, 0.7.2): patches applied, and `pacman -Qkk` is clean
>   after uninstall.
> - **Fedora 44** (0.7.1): the patches are skipped as intended.
>
> I also checked off-hardware:
> - the patches apply only to v0.7.2 (they fail on 0.7.0, 0.7.1 and master), and
>   a failure falls back cleanly to the bayer fix alone;
> - the new uninstall code was run in a sandbox;
> - shellcheck finds nothing new.
>
> ## Update
>
> **Already have the bayer fix on libcamera 0.7.2 (or Ubuntu 0.7.0)?** Re-running
> `./install.sh` alone won't pick up the patches, because it sees the fix as
> already installed. Rebuild with:
>
> ```bash
> cd samsung-galaxy-book-linux-fixes && git pull
> cd webcam-fix-book5
> sudo ./libcamera-bayer-fix/build-patched-libcamera.sh --uninstall
> ./install.sh
> ```
>
> Then restart PipeWire: `systemctl --user restart pipewire wireplumber`. Also
> restart `camera-relay.service` if you use the relay.
>
> Nothing else changed. Drivers, the speaker fixes and the NixOS modules are
> untouched.

### Housekeeping

- The head was fetched into the temporary branch `pr-107-586c849` (never checked
  out over `main`), which was deleted after review. The working tree is on `main`.
- Nothing was merged, posted, tagged or released.
