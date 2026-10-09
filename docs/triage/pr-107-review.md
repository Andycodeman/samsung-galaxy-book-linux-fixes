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
