# PR #90 review — "webcam-fix-libcamera: warn against the intel-ipu6-dkms offer in Additional Drivers"

Reviewed: 2026-08-10. Author: **@4nrry** (Anrry Petrin). Base `main`,
`MERGEABLE` / `CLEAN`, no CI on the repo. 1 commit, 1 file, +75/−0.
Head `78d1ea51`, parent `8f664909` (current `main` tip — no rebase needed).
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/90>

## Verdict: 🟢 **Merge** — as of `9262544a`

Status: **MERGED 2026-08-10** as `c75b3a23`, shipped as
[v0.3.66](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/releases/tag/v0.3.66).

Round 1 verdict was 🟠 changes required, posted as a `CHANGES_REQUESTED`
review. @4nrry pushed `9262544a` the same day; both findings are fixed and one
of my nits was correctly pushed back on. See
[Round 2](#round-2--9262544a-re-review) at the bottom.

The diagnosis is right and I confirmed every load-bearing claim independently
rather than taking the PR's word for it — the modalias false positive against
the actual package metadata, and the `ov02c10` collision against Intel's
upstream `dkms.conf`. Both hold. This is a genuinely useful warning: the repo
had no mention of `intel-ipu6-dkms` anywhere, and the Additional Drivers panel
tells users their working camera is broken.

The problem is the *recovery* half. The runbook's central command,
`sudo dkms install ov02c10/1.0 -k "$(uname -r)"`, exits with an error and
changes nothing in the exact situation the section is written for — so a user
who already accepted the offer follows the runbook, reboots, and is still
broken. That is a blocker for a section whose entire purpose is to unbreak
them.

| | |
|---|---|
| Blocking | 1 |
| Should fix (would land in this PR) | 1 |
| Nits | 2 |
| Docs-only? | **Yes** — 1 file, no code, no installer changes |
| Build artifacts in diff | **None** |
| Subsystems touched | `webcam-fix-libcamera/README.md` only |
| Diagnosis correct? | **Yes** — verified against package metadata + upstream `dkms.conf` |
| Hardware validation | **Real** — 960XGL, Meteor Lake `8086:7d19`, Secure Boot on |

---

## What I verified

### The modalias false positive — confirmed, from the package itself

`apt-cache show intel-ipu6-dkms` on this machine:

```
Modaliases: intel-ipu6-psys(pci:v00008086d0000462Esv*sd*bc*sc*i*,
            pci:v00008086d0000465Dsv*sd*bc*sc*i*,
            pci:v00008086d00004E19sv*sd*bc*sc*i*,
            pci:v00008086d00007D19sv*sd*bc*sc*i*,
            pci:v00008086d00009A19sv*sd*bc*sc*i*,
            pci:v00008086d0000A75Dsv*sd*bc*sc*i*)
```

Exactly one modalias entry, and it is `intel-ipu6-psys` — which the mainline
driver does not expose. `7D19` (Meteor Lake) and `A75D` (Raptor Lake) are both
in the list, so both of our supported platforms get the offer. The PR's
explanation of *why* `ubuntu-drivers` reports "not working" is correct.

The `lspci` line in the PR also works as written:

```
$ lspci -nnk -d 8086:7d19
00:05.0 Multimedia controller [0480]: Intel Corporation Device [8086:7d19] (rev 04)
        Kernel driver in use: intel-ipu6
```

### The `ov02c10` collision — confirmed, against upstream `dkms.conf`

Fetched the raw file from `intel/ipu6-drivers@master`, not a summary of it:

```
BUILT_MODULE_NAME[2]="ov02c10"
BUILT_MODULE_LOCATION[2]="drivers/media/i2c"
DEST_MODULE_LOCATION[2]="/updates"          # unconditional
...
if version_lt ${KERNEL_VERSION} 6.10.0; then
    BUILT_MODULE_NAME[9]="intel-ipu6"       # gated on < 6.10
    BUILT_MODULE_NAME[10]="intel-ipu6-isys" # gated on < 6.10
fi
BUILT_MODULE_NAME[7]="intel-ipu6-psys"      # unconditional
```

Every claim in the PR's table checks out: `ov02c10` unconditional,
`intel-ipu6`/`intel-ipu6-isys` gated on kernels older than 6.10,
`intel-ipu6-psys` unconditional, no `cio2-bridge` entry. And our
`ov02c10-26mhz-fix/dkms.conf` is `PACKAGE_NAME="ov02c10"`,
`BUILT_MODULE_NAME[0]="ov02c10"`, `DEST_MODULE_LOCATION[0]="/updates"` — same
module name, same destination. The collision is real.

### The dmesg strings — both match the driver source

- `external clock 26000000 is not supported` — `ov02c10-26mhz-fix/ov02c10.c:1134`
  (`dev_err_probe`, the rejection path).
- `journalctl -k -b -g '26000000Hz clock'` — matches the *patched* driver's
  `dev_info` at `ov02c10-26mhz-fix/ov02c10.c:709`
  (`"%luHz clock (not %dHz): sensor runs fast; …"`). Correct choice for a
  "did the patched driver actually load" check.

### Links, anchors, structure

- The in-page anchor `#additional-drivers-offers-intel-ipu6-dkms--dont-install-it`
  is **correct**, double hyphen included. I ran the heading through
  github-slugger's rules: the quotes, backticks, apostrophe and em dash are all
  stripped, and the space-emdash-space collapses to two hyphens.
- `../webcam-fix/`, `../ov02c10-26mhz-fix/` and
  `../ov02c10-26mhz-fix/README.md#secure-boot` all resolve — the last against a
  real `## Secure Boot` heading at `ov02c10-26mhz-fix/README.md:45`.
- Both new sections are `###` under `## Troubleshooting`, placed directly after
  the 26 MHz entry. Placement is right: the collision is on `ov02c10`, so a
  reader who lands on the clock error needs this.
- `camera-relay status` is a real subcommand (`camera-relay:1871`).
- PCI IDs match the repo's existing convention (`webcam-fix-libcamera/README.md:9`
  and `:104` already pair `8086:7d19` with `8086:a75d`).
- Commit message is imperative, wrapped, with `Co-Authored-By:` — consistent
  with repo history. No `nixos/`, `docs/`, kernel, speaker, mic or tuning-YAML
  changes, so nothing else needs to stay in sync.

---

## 🔴 Blocking 1 — `dkms install ov02c10/1.0` exits without doing anything

`webcam-fix-libcamera/README.md:340` (in the PR head):

```bash
sudo apt purge intel-ipu6-dkms
sudo dkms install ov02c10/1.0 -k "$(uname -r)"
sudo depmod -a
sudo update-initramfs -u
```

Purging `intel-ipu6-dkms` removes *Intel's* DKMS state. It does not touch
ours — the `ov02c10/1.0` "installed" marker for the running kernel survives.
DKMS 3.0.11 checks that marker first thing in `dkms install`:

```sh
# /usr/sbin/dkms:1244
is_module_installed "$module" "$module_version" "$kernelver" "$arch" && die 5 \
    $"This module/version combo is already installed for kernel $kernelver ($arch)."
```

and `_is_module_installed` (`/usr/sbin/dkms:1432`) is purely a symlink test on
`$dkms_tree/ov02c10/kernel-$KVER-$arch` — nothing the Intel purge clears. So
the command dies with exit 5, `depmod`/`update-initramfs` then run over an
unchanged tree, and the user reboots into the same broken camera.

Two smaller problems in the same block:

- It skips Secure Boot signing entirely. `ov02c10-26mhz-fix/install.sh:95-163`
  is what configures `/etc/dkms/framework.conf.d/ov02c10-mok-keys.conf`,
  verifies the module came out signed, and queues MOK enrollment. A bare
  `dkms install` gets none of that — on the author's own machine, which has
  Secure Boot enabled, a rebuild without it would be rejected at load.
- `depmod -a` and `update-initramfs -u` are a partial reimplementation of
  `install.sh:248-258`, which already does both (plus `dracut`/`mkinitcpio`
  fallbacks for non-Ubuntu).

**Suggested replacement** for "Remove the Intel stack…" and its code block:

> Remove the Intel stack, then re-run the 26 MHz installer to rebuild and
> reinstate the patched driver:
>
> ```bash
> sudo apt purge intel-ipu6-dkms
> cd ov02c10-26mhz-fix && sudo ./install.sh
> ```
>
> Don't reach for `dkms install ov02c10/1.0` directly — purging the Intel
> package does not clear DKMS's own "installed" marker for `ov02c10/1.0`, so
> `dkms install` exits with *"This module/version combo is already installed
> for kernel …"* and changes nothing. `install.sh` does the full
> `dkms remove --all` → `add` → `build` → `install` cycle, re-signs the module
> for Secure Boot, and refreshes `depmod` and the initramfs.

That also matches how this README already tells people to recover from the
other OEM-stack collision ("Just re-run `sudo bash install.sh` and reboot",
line 561) and the invocation form used at line 286.

## 🟠 Should fix 1 — the `modinfo` test can't detect the failure it's used to diagnose

`webcam-fix-libcamera/README.md:353-357`:

> If `modinfo` still points at `kernel/drivers` after the reboot, the DKMS build
> either failed **or was rejected**. With Secure Boot enabled an unsigned module
> is rejected in silence …

`modinfo -n` resolves the path from `modules.dep`, which prefers `updates/dkms`
regardless of whether the module can actually be loaded. Signature rejection
happens at *load* time and never changes what `modinfo` prints. So the
Secure-Boot case — the one the paragraph spends its remaining three lines on —
shows the "good" path, passes the test, and leaves the user with a camera that
still doesn't work and no next step.

Give the two failures separate checks. `install.sh:212` already uses the right
one:

> ```bash
> modinfo -n ov02c10                 # must be under updates/dkms
> modinfo ov02c10 | grep -i '^sig'   # no output = unsigned
> journalctl -k -b -g '26000000Hz clock'
> ```
>
> A path under `kernel/drivers` means the DKMS build or install failed. The
> right path with no `sig*` fields means the module was built but is unsigned,
> so under Secure Boot it is rejected in silence and the 26 MHz error persists.
> See [Secure Boot](../ov02c10-26mhz-fix/README.md#secure-boot) in the 26 MHz
> fix.

## Nits

1. **"There is nothing to gain in exchange" reads as universal but isn't.**
   On 24.04/Zorin with the `oem-solutions-group/intel-ipu6` PPA enabled, the
   HAL packages install fine (verified on Andy's machine: `libcamhal0`,
   `libcamhal-ipu6epmtl` and `gstreamer1.0-icamera` are all *installed*). The
   argument still holds for this README's audience, because the libcamera path
   supersedes the HAL path, but a reader who spots the gap may discount the
   whole warning.

   > **Correction (round 2).** My stated reason — "the PPA is noble-only" —
   > was wrong. I inferred it from the filename of the sources entry on Andy's
   > machine (`…-intel-ipu6-noble.sources`), which only records which series
   > *this box* subscribes to. Launchpad publishes `ipu6-camera-hal` for
   > focal, groovy, hirsute, jammy, noble, oracular **and resolute**, and the
   > 26.04 build is currently `Published`
   > (`0~git202601200757.9899efa~ubuntu26.04.2`). @4nrry caught this and
   > rewrote the paragraph release-independently, which is the better fix.
2. **Package naming.** The repo consistently calls the HAL
   `libcamhal-ipu6epmtl` (`webcam-fix/README.md:229,233`); the PR uses
   `libcamhal0` and `intel-ipu6-camera-hal`. `intel-ipu6-camera-hal` is not a
   package name apt knows about here at all. Worth aligning with the names the
   repo already uses.

---

## Round 2 — `9262544a` re-review

Pushed 2026-08-10, +27/−14, still the one file. PR is now +88/−0 vs `main`,
`MERGEABLE`/`CLEAN`. Both new `###` headings are the only structural change to
the file; the anchor and cross-link at line 580 are untouched and still resolve.

**🔴 Blocking 1 — fixed.** The runbook now purges the Intel package and re-runs
`cd ov02c10-26mhz-fix && sudo ./install.sh`, with a paragraph explaining why
`dkms install ov02c10/1.0` is not the repair command. Keeping that explanation
in the doc rather than just swapping the command was the right call — it is the
part a reader would otherwise rediscover the hard way. New link
`../ov02c10-26mhz-fix/install.sh` resolves; the file is executable. The author
independently reproduced the failure on dkms **3.2.2** (`die` at `:1662`,
`_is_module_installed()` at `:1840`) and showed the surviving marker symlink
`/var/lib/dkms/ov02c10/kernel-7.0.0-29-generic-x86_64 -> 1.0/7.0.0-29-generic/x86_64`
— same behaviour as the 3.0.11 I read, on a second version.

**🟠 Should fix 1 — fixed.** The verify block is now the three-command split,
and the prose names the mechanism (`modinfo -n` reads `modules.dep`; rejection
is at load time) rather than just asserting the check. Better than what I
suggested.

**Nit 2 — fixed.** `libcamhal-ipu6epmtl` + `gstreamer1.0-icamera`, matching
`webcam-fix/README.md` L233–234. Confirmed on this machine that both resolve
only to `ppa.launchpadcontent.net/oem-solutions-group/intel-ipu6` with no
Ubuntu archive entry (`apt-cache madison`), so the new
"not in the Ubuntu archive on any release" phrasing is accurate.

**Nit 1 — pushed back on, correctly.** See the correction inline above. The
rewritten paragraph avoids per-release claims entirely and is stronger for it.

One residual, not worth holding the PR: `modinfo ov02c10 | grep -i '^sig'`
detects *unsigned*, but a module that is signed with a MOK key that was never
enrolled still shows `sig*` fields and is still rejected. The linked Secure
Boot section covers enrollment, and the recommended recovery is now
`install.sh`, which queues enrollment itself and warns when it is pending — so
the reader lands in the right place either way.

## Not flagged, but worth knowing

The claim that the kernel "falls back to the in-tree driver" when a DKMS module
is signature-rejected is inherited from `ov02c10-26mhz-fix/README.md:45-56` and
`install.sh:9-11`, not introduced by this PR. It is worth checking separately:
`depmod`'s search order puts `updates/` ahead of `kernel/` and drops the
duplicate, so `modprobe ov02c10` should resolve only to the DKMS copy and fail
outright rather than falling through to the in-tree one. If that is right, the
observed 26 MHz error after a bad install comes from the DKMS module never
landing in `updates/` at all — a different failure with the same symptom. Out
of scope here; don't hold PR #90 for it.
