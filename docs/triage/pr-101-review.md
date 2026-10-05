# PR #101 review — "Simplified installation instructions"

Reviewed: 2026-10-04. Author: **@LucasDondo** (Lucas Dondo). Base `main`,
`MERGEABLE`, no CI on the repo. 1 commit (`d20d5869`), 1 file
(`mic-fix/README.md`), +1/−2.
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/101>

## Status: ✅ **MERGED** 2026-10-04 (`3087a74`)

Originally reviewed as 🟡 **Request changes** (below). @LucasDondo applied the
`sudo` fix in `1585a2c` ("Simplified installation instructions", amended in
place of `d20d5869`) and merged `main` into the branch (`c627a7f`, PR head at
merge). Re-checked `gh pr diff 101` before merging: still exactly one line in
`mic-fix/README.md`, `sudo ./install.sh` present, and byte-identical to the
top-level README's mic-fix line. Merged with `gh pr merge 101 --merge
--match-head-commit c627a7f…`, the same merge-commit method as #79–#91. Merge
commit `3087a74c52fd4bbc092f9ae55f177d819dfa02b7` (GitHub `mergedAt`
2026-10-05T05:26:18Z UTC, 2026-10-04 local).

- Thank-you comment:
  <https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/101#issuecomment-5988653187>
- **No release: docs-only.** GitHub renders the README from `main`, so the
  new line is live without a tag.

## Original verdict: 🟡 **Request changes**

The idea is good and the shape is right: it replaces `sudo bash install.sh` +
`# Reboot` with the same download-and-run one-liner every other per-fix README
already uses. But the line drops `sudo`, and `mic-fix/install.sh` refuses to run
as a normal user. Because the line is one `&&` chain, a user who pastes it
downloads and unpacks the repo, gets `ERROR: Run with sudo`, and stops. **The mic
fix never gets applied.** The fix is a single word, so I posted it as a one-click
suggestion.

| | |
|---|---|
| Blocking | 1: missing `sudo` before `./install.sh` |
| Should fix | 0 |
| Nits | 0 |
| Scope creep | **None**: one line, docs only |
| Subsystems touched | `mic-fix/README.md` only, no scripts |
| Release-worthy on its own? | **No**: docs-only. GitHub renders the README from `main`, so a release isn't needed for users to see it |

---

## What I verified

### 1. `install.sh` requires root, so the PR's line fails

`mic-fix/install.sh:36-40`:

```bash
# Must be root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo" >&2
    exit 1
fi
```

Nothing before that check touches the system (only variable assignments and two
`echo`s), so it's safe to run unprivileged. I ran the PR's exact chain, minus the
reboot, in a scratch directory outside the repo:

```
$ curl -sL https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz | tar xz \
    && cd samsung-galaxy-book-linux-fixes-main/mic-fix && ls -l install.sh && ./install.sh; echo "exit=$?"
-rwxrwxr-x 1 andy andy 12438 Oct  4 02:38 install.sh
=== SOF Firmware Installer (Internal Mic Fix) ===
Samsung Galaxy Book4 / Book5

ERROR: Run with sudo
exit=1
```

So the line fails, and in a safe way: `&& sudo reboot` is skipped too, so the user
isn't rebooted into an unfixed system. They are just left with an error and no
fix.

### 2. The other parts of the one-liner are correct

- **URL / tarball directory name**: the archive unpacks to
  `samsung-galaxy-book-linux-fixes-main/`, which matches the `cd` (confirmed by the
  run above).
- **Exec bit**: `git ls-files -s` shows `100755` for `mic-fix/install.sh`, and the
  GitHub tarball keeps it (`-rwxrwxr-x` above), so `./install.sh` doesn't need a
  `chmod` or `bash` prefix.
- **Uninstall section** still says `sudo bash uninstall.sh`. That still works
  after the one-liner because the user is left inside `mic-fix/`. No change needed.

### 3. Consistency with the rest of the repo: audio = `sudo`, webcam = no `sudo`

Every README one-liner uses the same pattern. Whether it has `sudo` depends on
the installer:

| README | `install.sh` invocation |
|---|---|
| `README.md:27` (speaker-fix) | `sudo ./install.sh && sudo reboot` |
| `README.md:35` (speaker-fix-940xfg) | `sudo ./install.sh` |
| `README.md:45` (**mic-fix**) | `sudo ./install.sh && sudo reboot` |
| `speaker-fix/README.md:10` | `sudo ./install.sh && sudo reboot` |
| `speaker-fix-940xfg/README.md:11` | `sudo ./install.sh` |
| `README.md:57,73`, `webcam-fix{,-book5,-libcamera}/README.md` | `./install.sh && sudo reboot` |

The webcam installers run as the user and call `sudo` internally. The audio
installers need root up front. The PR copied the webcam form. The top-level
README's mic-fix line (`README.md:45`) is already correct, and the suggested line
is byte-identical to it (`diff` confirmed).

---

## What was posted

Review: **CHANGES_REQUESTED**, 2026-10-04.
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/101#pullrequestreview-5407407956>

The thank-you is part of the review body, not a separate comment, so the PR gets
one notification instead of two.

### Review body

> Thanks for this, @LucasDondo! A copy-paste one-liner is a real improvement here, and it matches the pattern the top-level README and the other per-fix READMEs already use.
>
> One thing needs changing before I can merge: `install.sh` has to run as root. It checks `id -u` near the top (`mic-fix/install.sh:37`) and exits with `ERROR: Run with sudo` otherwise. Because everything is chained with `&&`, the line as written downloads and unpacks the repo, prints that error and stops, so the mic fix never gets applied (and the reboot never happens either, which is at least harmless).
>
> The webcam installers run without sudo, which is probably where `./install.sh` came from, but the audio ones (`mic-fix`, `speaker-fix`, `speaker-fix-940xfg`) all use `sudo ./install.sh`. The main README's mic-fix line already has it that way.
>
> I've left a one-click suggestion on the line. Once that's in I'll merge it. Thanks again!

### Inline comment on `mic-fix/README.md:27`

<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/101#discussion_r4178683311>

> `install.sh` exits unless it's run as root, so this needs `sudo`, the same as the mic-fix line in the main README:
>
> ```suggestion
> curl -sL https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book-linux-fixes-main/mic-fix && sudo ./install.sh && sudo reboot
> ```

---

## Next step (done — see Status above)

When @LucasDondo applies the suggestion, check that the line matches `README.md:45`,
then merge. Past contributor PRs landed as merge commits (`Merge pull request #91
…`, `#90`, …), so use `gh pr merge 101 --merge`, then `git pull`. No release is
needed for this change on its own.
