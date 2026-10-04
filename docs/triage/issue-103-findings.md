# Issue #103 — "ipu-bridge-check-upstream.service never runs: ConditionPathExists points to ipu-bridge-fix-1.0, package is 1.4" (@renato-machado-atman)

Hardware: Galaxy Book4 Pro 14" (NP940XGK-KG2BR), Core Ultra 5 125H (Meteor
Lake). Distro: Ubuntu 24.04.5, kernel 7.0.0-34-generic.

Confirmed bug. The reporter's diagnosis is correct and their suggested fix
(drop `ConditionPathExists` from the unit, bail out in the script when `dkms
status` finds no package) was adopted as written. The camera itself was never
affected. The only thing lost was the automatic clean-up that removes the
`ipu-bridge-fix` DKMS workaround once the stock kernel carries the rotation
quirk.

**Status:** fix `62ca875`, release and reply pending.

---

## What they asked

`ipu-bridge-check-upstream.service` is skipped on every boot:

```
ipu-bridge-check-upstream.service - Check if kernel ipu-bridge has Samsung camera rotation fix was skipped because of an unmet condition check (ConditionPathExists=/usr/src/ipu-bridge-fix-1.0/dkms.conf).
```

They traced it to the unit file, proposed a fix, and noted that
`max98390-hda-check-upstream.service` runs fine on the same machine. A bug
report with a patch, not a question.

## Findings

1. **Version mismatch.** `webcam-fix-book5/ipu-bridge-check-upstream.service`
   had `ConditionPathExists=/usr/src/ipu-bridge-fix-1.0/dkms.conf`, but
   `webcam-fix-book5/ipu-bridge-fix/dkms.conf` is `PACKAGE_VERSION="1.4"`, so
   DKMS installs to `/usr/src/ipu-bridge-fix-1.4/`. The condition went stale
   at `c030a39` (2026-03-28, first released in v0.3.19), which bumped the
   package 1.0 → 1.1. The check has not run on any install since.

2. **systemd conditions can't glob.** `ConditionPathExists=` takes a literal
   path, so `/usr/src/ipu-bridge-fix-*/dkms.conf` isn't an option. Every
   version bump would need the unit edited in lockstep, which is how this
   broke.

3. **The script already resolved the version.**
   `ipu-bridge-check-upstream.sh` reads `DKMS_VER` from `dkms status` rather
   than hardcoding it. Only the unit was out of sync, so moving the
   "is it installed?" check into the script removes the duplication.

4. **Both webcam installers were affected.** `webcam-fix-book5/install.sh`
   installs the unit directly, and `webcam-fix-libcamera/install.sh` copies
   it from `../webcam-fix-book5/`.

5. **The speaker-fix unit had the same latent defect.**
   `speaker-fix/max98390-hda-check-upstream.service` hardcodes
   `ConditionPathExists=/usr/src/max98390-hda-1.0/dkms.conf`. It works today
   only because `speaker-fix/dkms.conf` is still `PACKAGE_VERSION="1.0"`, which
   is why the reporter saw it running. The first version bump would have
   broken it the same way.

## What changed (commit `62ca875`)

- `webcam-fix-book5/ipu-bridge-check-upstream.service`: `ConditionPathExists`
  removed.
- `webcam-fix-book5/ipu-bridge-check-upstream.sh`: `log()` moved above the
  version lookup, and the reporter's line added right after `DKMS_VER` is
  computed:
  `[ -n "$DKMS_VER" ] || { log "... not installed via DKMS — nothing to check"; exit 0; }`
- `speaker-fix/max98390-hda-check-upstream.service`: `ConditionPathExists`
  removed.
- `speaker-fix/max98390-hda-check-upstream.sh`: exits 0 with a log line when
  `dkms status max98390-hda/1.0` reports nothing. That script still hardcodes
  `DKMS_VER="1.0"`, but now in one place instead of two.

Neither script sets `pipefail`, so the `| grep -q` in the speaker check can't
turn a match into a false "not installed".

Users pick the fix up by re-running the installer they used. Each one copies
the unit to `/etc/systemd/system/` and runs `systemctl daemon-reload`.

## Verification

- `bash -n` on both scripts, `systemd-analyze verify` on both units: clean.
- Reviewed against the reporter's journal output and `ls /usr/src`.

**Not verified:** a boot on hardware with the new unit. The reporter can
confirm with `journalctl -b -u ipu-bridge-check-upstream`.

---

## Reply posted

_pending_
