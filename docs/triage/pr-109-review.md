# PR #109 review — "Fedora: build libcamera only from the source RPM, never fall back to a git clone"

VERDICT: READY TO MERGE — approved, merged and released as v0.3.77

Reviewed: 2026-10-10. Author: **@david-bartlett** (David Bartlett, also #107).
Head `f868ded` (1 commit), base `main` at `e201572` (current tip, so no
merge-tree check needed), `MERGEABLE` / `CLEAN`, no CI, no prior comments or
reviews. Fixes #108 (his own report, found while testing #107).
1 file: `webcam-fix-book5/libcamera-bayer-fix/build-patched-libcamera.sh`
+102/−62, all in step 3.
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/109>

## The bug (#108)

On Fedora, step 3 fell back to a `git clone` of upstream libcamera whenever the
source RPM couldn't be downloaded, unpacked, prepped or located. Fedora's
libcamera is in `/usr/lib64`, so a clone build takes the **libraries-only**
install in step 8 (`USE_FULL_INSTALL=false`; only the SRPM, `/usr/local`, Arch
and Debian/Ubuntu branches are full installs). That copies `libcamera.so` out of
the build tree with its build runpath still set (`$ORIGIN/base:/`). libcamera
then thinks it isn't installed, looks for the IPA proxy worker under
`//src/libcamera/proxy/worker`, and the distro IPA (signed with a different key,
so it must run through the proxy) can't start: soft ISP disabled, RAW only, no
picture in PipeWire apps. Worse than the purple tint the fix exists to remove.

Separately, `dnf download --source libcamera` fetched whatever SRPM the mirrors
carried, not the installed one, so a full install could put a different version
over `/usr` than the RPM database and `libcamera-ipa`.

## What the PR does

Step 3's Fedora block becomes `prepare_srpm_source()`, called as
`if ! prepare_srpm_source; then rm -rf "$BUILD_DIR"; die "…Nothing was changed…"; fi`.

1. Reads `NAME-VERSION-RELEASE`, `SOURCERPM`, `VERSION`, `RELEASE` of the
   installed `libcamera` via `rpm -q --qf`. Not installed / not from an RPM →
   `return 1`.
2. `dnf download --srpm <nvr>` (dnf5) then `--source <nvr>` (dnf4).
3. If `$SRPM_DIR/$srpm_name` still isn't there: `curl -fL --retry 3` from
   `https://kojipkgs.fedoraproject.org/packages/libcamera/$ver/$rel/src/$srpm_name`.
4. Accepts only that exact filename; `rpm -i`, spec lookup,
   `rpmbuild -bp --nodeps` with output to `$BUILD_DIR/rpmbuild-prep.log` (tail 20
   on failure), each checked with `return 1`.
5. Accepts the prepared tree only via a `meson.build` matching
   `project.*libcamera` (maxdepth 3). The old "Strategy 2: grab the first
   directory in BUILD" fallback is removed.
6. Non-Fedora: the clone block is unchanged apart from its comment.

## What I verified

| # | Check | Result |
|---|---|---|
| 1 | File mode | `git ls-tree` on the head and on `main`: both `100755`. The diff header is `index 3808ffe..51a1b1c 100755`, no `old mode`/`new mode` (the #107 B1 regression did not recur). |
| 2 | **Real run of the PR's step-3 code in a `fedora:latest` container** (Fedora 44, dnf5 5.4.3, `libcamera-0.7.1-1.fc44`, `rpm-build` installed). Harness = the script's own colour/`info/ok/warn/error/die` helpers + PR lines 800–897 verbatim, under `set -euo pipefail`, `BUILD_DIR=/work/build`. Failures forced with PATH shims (`dnf download` → exit 1; `curl` → exit 22). | **A, normal:** dnf5 auto-enabled the source repos and downloaded exactly `libcamera-0.7.1-1.fc44.src.rpm`; prep OK; tree found at `BUILD/libcamera-0.7.1-build/libcamera-v0.7.1` (the rpm ≥ 4.20 nested layout the comment mentions) and moved to `$BUILD_DIR/libcamera`, whose `meson.build` starts `project('libcamera', …`; `USE_SRPM=true`, exit 0. **B, dnf fails:** "dnf could not download…", then Koji, same file, same prep, exit 0 (the unsigned Koji SRPM unpacks fine with F44's rpm). **C, dnf + curl fail:** "Koji download failed" → "Could not download the libcamera source RPM" → the "Nothing was changed" `die`, exit 1, `/work` empty (build dir removed). **D, `rpm -e --nodeps libcamera`:** "The libcamera package is not installed from an RPM." → `die`, exit 1. |
| 3 | Koji path format | `packages/<name>/<version>/<release>/src/<srpm>` returns HTTP 200 for `libcamera-0.7.2-3.fc45.src.rpm` (the author's build) and `0.7.1-1.fc44` (case B downloaded it). Hardcoding `libcamera` as the Koji package name is correct: the binary package's source package is `libcamera`, and Fedora binary VERSION/RELEASE always equal the SRPM's. |
| 4 | `set -e` / `pipefail` | The four `rpm -q … \| head -1 \|\| true` captures are safe: an uninstalled package makes `rpm` exit 1 (stdout "package libcamera is not installed"), `pipefail` propagates it and `\|\| true` absorbs it; the `*"not installed"*` / `*.src.rpm` test then catches it (case D). Output is a few bytes, so `head -1` can't SIGPIPE `rpm`. `grep -q` reads a file, not a pipe — the SIGPIPE-141 gotcha can't fire. `local x; x=$(…)` is split, so `local` doesn't mask statuses. Note: the function is called from `if !`, so **errexit is off inside it**; every step that matters has an explicit `return 1`, except the final `mv` (nit N2). |
| 5 | Failure leaves stock untouched | The `die` is in step 3. Step 7 (backup, L1058) and step 8 (install) come later, and steps 1–2 only detect and install build deps. So exit 1 happens with no backup dir and no files replaced (case C). `install.sh` L567/L552 then takes its existing "Bayer fix build FAILED — the camera will work but … purple/magenta tint" / "rebuild failed" branch. In the rebuild branch `install.sh` has already removed the stale backup before calling the script; that's pre-existing and harmless, since the next run takes the no-backup branch and builds. |
| 6 | `install.sh` always provides the RPM | `install.sh` L210–220 installs `libcamera` via dnf on Fedora if missing, so case D is reachable only by running the build script directly. |
| 7 | Non-Fedora paths | The diff has one hunk, inside step 3. The clone block (`if [[ "$USE_SRPM" != "true" ]]`, tag then master) is byte-identical apart from the comment line. `USE_SRPM` is still initialised to `false` before the Fedora block. Fedora derivatives with another `os-release` `ID` (Nobara etc.) were `unknown` before and still are. |
| 8 | `bash -n` | Passes on the head and on `main` after the merge. |
| 8 | shellcheck (`koalaman/shellcheck:stable`) | `main` 7 → head 6. The set difference is one `SC2012` (the removed Strategy-2 `ls … \| head -1`). The remaining step-3 finding (L851 `SC2012`, `ls SPECS/*.spec`) existed before. **No new findings.** |
| — | Tests | No suite covers `webcam-fix-book5`. I didn't compile libcamera; the PR doesn't change anything after step 3, and the author did full builds on Fedora 45. |

## Findings

### Blocking

None.

### Non-blocking (mentioned in the review as optional; no follow-up needed)

**N1. `curl -fL` prints its progress meter into the log.** With stderr merged
(`2>&1`) the meter is noisy. `-sS` or `--progress-bar` would be quieter, and
there's no `--connect-timeout`, so a hung connection can stall the install.

**N2. The final `mv "$prepped_src" "$BUILD_DIR/libcamera"` is unchecked.** Errexit
doesn't apply inside a function called from `if !`. A same-filesystem `mv`
failing is very unlikely, and step 4 would then fail before the backup anyway;
`|| return 1` would just make it consistent.

**N3. The `die` text says "Check your network" for case D too** (libcamera not
installed as an RPM). Only reachable when the script is run directly.

**N4 (note only).** Koji's `packages/…` SRPMs are the unsigned copies (signed ones
live under `data/signed/<key>/`). The trust is HTTPS to Fedora's own
infrastructure, the same as the dnf path and the upstream git clone, and
`rpmbuild -bp` already ran the SRPM's `%prep` as root before this PR. No action.

## GitHub review (posted 2026-10-10 as APPROVE, review id 5480203991)

<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/109#pullrequestreview-5480203991>

> Thanks David, this is a clean, well-scoped fix, and the issue write-up in #108
> made the failure easy to follow.
>
> I checked what I could off-hardware:
>
> - **The PR's own step-3 code in a Fedora 44 container** (dnf5,
>   `libcamera-0.7.1-1.fc44`), extracted from the head and run under
>   `set -euo pipefail`:
>   - normal run: `dnf download --srpm` fetched exactly
>     `libcamera-0.7.1-1.fc44.src.rpm`, `rpmbuild -bp --nodeps` prepared it, and
>     the nested `BUILD/libcamera-0.7.1-build/libcamera-v0.7.1` tree was found
>     and moved into place (`USE_SRPM=true`);
>   - `dnf download` forced to fail: the same SRPM came from Koji, then the same
>     prep;
>   - dnf and curl both forced to fail: exit 1 with your "Nothing was changed"
>     message, and `$BUILD_DIR` removed;
>   - libcamera RPM removed: exit 1 at the "not installed from an RPM" check.
> - **Koji path:** `packages/libcamera/<version>/<release>/src/<srpm>` resolves
>   (HTTP 200) for both `0.7.1-1.fc44` and `0.7.2-3.fc45`.
> - **Failure leaves stock libcamera alone:** the `die` happens in step 3, before
>   the step 7 backup and step 8 install, so `install.sh` takes its existing
>   "Bayer fix build FAILED" branch and a later re-run does the full install.
> - **Other distros:** the diff only touches the Fedora block; the clone block is
>   unchanged apart from its comment.
> - **Static checks:** file mode stays `100755`, `bash -n` passes, and shellcheck
>   goes 7 → 6 findings with nothing new (the old Strategy-2 `ls` is gone). No
>   `grep -q` in a pipeline, and the `rpm -q … | head -1 || true` captures are
>   safe under `pipefail`.
>
> Dropping the old "grab the first directory in BUILD" fallback is a nice extra:
> a tree is now only accepted if its `meson.build` declares `project('libcamera')`.
>
> A few optional nits, none of them blocking, fine as a follow-up or not at all:
> - `curl -fL` prints its progress meter into the log; `-sS` (or
>   `--progress-bar`) would be quieter, and a `--connect-timeout` would stop a
>   hung connection from stalling the install.
> - The final `mv "$prepped_src" "$BUILD_DIR/libcamera"` is unchecked. Because
>   the function is called from `if !`, `set -e` doesn't apply inside it, so
>   `|| return 1` would make it consistent with the other steps.
> - When the libcamera RPM isn't installed at all (only possible when running the
>   script directly, since `install.sh` installs it), the closing message still
>   says "Check your network".
>
> Approving, merging now.

## Merged + released

- **Head re-checked** just before approving: still `f868ded`, `MERGEABLE` /
  `CLEAN`, 0 comments, 0 reviews.
- **Merge:** `gh pr merge 109 --merge --match-head-commit f868ded…` → merge
  commit `68419ab` (2026-10-10T17:57:50Z). `git diff --stat f868ded 68419ab` is
  empty; the script is still `100755` on `main` and `bash -n` passes.
- **#108:** auto-closed by the merge ("Fixes #108"), 2026-10-10T17:57:51Z.
- **Thank-you comment:**
  [#issuecomment-6100514209](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/109#issuecomment-6100514209).
- **Release:** [v0.3.77](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/releases/tag/v0.3.77),
  tagged on the commit that adds this file. Title: `v0.3.77 — Fedora: the
  Book5 bayer-fix build no longer falls back to a git clone that breaks the
  webcam`. Notes cover the git-clone fallback removal, exact-version SRPM, Koji
  fallback, who is affected, the author's hardware tests plus the container run,
  and #108's recovery steps.
- **Housekeeping:** the head was fetched into the temporary branch `pr-109`
  (never checked out over `main`), deleted after the merge. The Fedora container
  was removed; the harness lived only in the session scratchpad.
- **Still open from #107:** R1–R3 in `pr-107-review.md` (slow Ubuntu uninstall,
  Arch partial-upgrade reinstall, the author's "Found while testing" installer
  issues). #108 was the "Fedora libraries-only install" item David said he'd
  report, so that one is now done.
