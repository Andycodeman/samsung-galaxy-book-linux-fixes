# PR #75 review — "Fix alc298 amp init service for Book3 Pro 14"

Reviewed: 2026-07-30. Author: **@vaibhavagg101**. Base `main`, `MERGEABLE`,
`mergeStateStatus=CLEAN`, no CI on the repo. 1 file, +3/−3.
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/75>

## Verdict: ❌ **REQUEST CHANGES — do not merge as-is**

**The diagnosis is right; the implementation inverts the outcome.** The PR
replaces a `ConditionPathExists` guard with a `Requires=`/`After=` dependency on
`dev-snd-hwC0D0.device`. That device unit **can never become active**, because
systemd's udev rules never tag `hwC*D*` nodes. Merged as-is, the service goes
from "runs at boot (sometimes too early)" to **"never runs at boot, after a 91-second
hung job."** Speakers would be silent on every boot for the exact users this
bundle exists for.

Status: **POSTED 2026-07-30** as a `CHANGES_REQUESTED` review. The reply as sent
is kept at the bottom as the record of what was said. **Round 2 posted
2026-08-01** — see [Round 2](#round-2--2026-08-01) below. Still open, still
unmerged; the branch has not moved off `62cdaffb`.

| | |
|---|---|
| Blocking | 2 (both measured, not reasoned) |
| Non-blocking / nit | 2 |
| Underlying bug real? | **Yes** — the boot race the author describes is genuine and worth fixing |
| Recommended action | Request changes, point at counter-proposal B (or A), keep the PR open |

---

## What the PR does

`speaker-fix-940xfg/alc298-amp-init.service`:

```diff
-After=systemd-modules-load.service sound.target
-Wants=sound.target
-ConditionPathExists=/dev/snd/hwC0D0
+Requires=dev-snd-hwC0D0.device
+After=systemd-modules-load.service sound.target dev-snd-hwC0D0.device
+Wants=sound.target 
```

Stated rationale: the service was failing on boot because systemd ran the script
before the kernel had finished bringing up the sound card, so it should wait for
`/dev/snd/hwC0D0` to appear first.

Blast radius is narrow and easy to state: **one file, one bundle**
(`speaker-fix-940xfg/`), installed only to `/etc/systemd/system/alc298-amp-init.service`
by `speaker-fix-940xfg/install.sh:~170`. No other bundle ships a `.device`
dependency (`grep -rn '\.device' --include=*.service .` → no other hits), and the
installer gates hard on DMI `product_name == 940XFG` **and** codec SSID
`0x144dc882`, so nothing here can reach a Book4/Book5 or the 16" 964XFG. The
kernel tree under `linux-6.17/`, the libcamera YAMLs, `camera-relay/` and
`nixos/` are all untouched — none of the usual cross-bundle risks apply.

---

## Blocking findings

### B1. `dev-snd-hwC0D0.device` never activates → the service never runs
`speaker-fix-940xfg/alc298-amp-init.service:4` (`Requires=`) and `:5` (`After=`)

systemd only instantiates an **active** `.device` unit for udev devices carrying
the `systemd` tag. The one and only sound-subsystem rule that adds that tag is
`/usr/lib/udev/rules.d/99-systemd.rules:61`:

```
SUBSYSTEM=="sound", KERNEL=="controlC*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="sound.target", ENV{SYSTEMD_USER_WANTS}+="sound.target"
```

It matches `controlC*` and nothing else. `hwC*D*` is **never** tagged. This is
upstream systemd, not a distro quirk — I also checked `/etc/udev/rules.d/` for a
local override and there is none.

Measured here, on a live ALC298 machine where the node plainly exists:

```
$ ls -l /dev/snd/hwC0D0
crw-rw----+ 1 root audio 116, 10 Jul 24 08:24 /dev/snd/hwC0D0

$ udevadm info /dev/snd/hwC0D0 | grep TAGS
E: TAGS=:uaccess:                      <-- no ":systemd:"

$ systemctl show dev-snd-hwC0D0.device  -p ActiveState -p SubState
inactive dead                          <-- the PR's dependency
$ systemctl show dev-snd-controlC0.device -p ActiveState -p SubState
active plugged                         <-- what *is* tagged
```

`systemd-analyze verify` passes on the PR's unit file (exit 0), so this is not
catchable by static checking — it only shows up at runtime.

### B2. 91-second hung job, then a dependency failure, and `ExecStart` never fires
`speaker-fix-940xfg/alc298-amp-init.service:4-5`

I ran a probe unit carrying the PR's exact `[Unit]` block (`ExecStart` replaced
with a `logger` marker), installed to `/run/systemd/system/` so nothing
persisted:

```
$ systemctl list-jobs
206006 pr75-devtest.service   start waiting     <-- our service, blocked
206103 dev-snd-hwC0D0.device  start running     <-- waiting on a device that will never appear

$ time systemctl start pr75-boottime.service
A dependency job for pr75-boottime.service failed. See 'journalctl -xe' for details.
exit=1 after 91s

$ journalctl -t pr75-boottime
-- No entries --                                <-- ExecStart never executed
```

91 s is `DefaultDeviceTimeoutUSec=1min 30s` (systemd 255) plus scheduling. So the
boot transaction carries a 90-second hung job that then fails, and the amp init
does not run. The `system-sleep` hook (`alc298-amp-init-sleep.sh`) is unaffected,
which produces a confusing failure mode for the user: **speakers silent from cold
boot, working after a suspend/resume cycle.**

---

## Non-blocking / nit

### N1. Dropping `ConditionPathExists=` turns a clean skip into a unit failure
`speaker-fix-940xfg/alc298-amp-init.service` (line 6 on `main`, deleted by the PR)

`ConditionPathExists=` made the unit *silently skip* when the codec node was
absent. `Requires=` makes it *fail* instead. Low severity in practice — the
installer's DMI + SSID gate means this only lands on 940XFG hardware, and
`alc298-amp-init.sh:36-40` already exits 0 when no matching codec is found — but
it is the wrong direction, and it should come back in whatever lands instead.

### N2. Trailing whitespace
`speaker-fix-940xfg/alc298-amp-init.service:6` — `Wants=sound.target ` gains a
trailing space. systemd strips it, so it is purely cosmetic, but it is an
unrelated whitespace change inside a 3-line diff and should be dropped.

---

## The underlying bug is real — this shouldn't just be closed

`After=sound.target` genuinely does not guarantee the codec node exists.
`sound.target` is a passive target pulled in by the `controlC*` udev rule above;
if it has already been reached earlier in the boot transaction, the ordering is
satisfied *before* the card registers, and `alc298-amp-init.sh` runs, finds no
codec matching SSID `0x144dc882`, and exits 0. With `RemainAfterExit=yes` the
unit then sits `active (exited)` having done nothing. That matches the reporter's
description exactly, and @vaibhavagg101 is a **second, independent** 940XFG owner
(issue #44 was @derwismtz), so this is a real field report, not a one-off.

Both replacements below were tested on the same machine as B1/B2.

### Counter-proposal B — smallest correct change (recommended)

Depend on the control device, which *is* systemd-tagged, and keep the guard:

```ini
[Unit]
Description=Initialize ALC298 internal speaker amps (Samsung Galaxy Book3 Pro 14" / 940XFG)
Documentation=https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/44
Wants=sound.target dev-snd-controlC0.device
After=systemd-modules-load.service sound.target dev-snd-controlC0.device
ConditionPathExists=/dev/snd/hwC0D0
```

`controlC0` is created by `snd_card_register()`, which runs *after* every codec's
hwdep node is built — so ordering after it is a strictly stronger guarantee than
`After=sound.target`, and it closes the race. `Wants=`, not `Requires=`, so a
renumbered card degrades to today's behaviour instead of hard-failing.

Verified:

```
$ systemctl start pr75-alt-b.service
exit=0 after 1s
ActiveState=active SubState=exited
Jul 30 07:59:41 pr75-alt-b[214853]: RAN-OK      <-- ExecStart ran
```

Caveat: hardcodes card index 0, same assumption `main` already makes.

### Counter-proposal A — robust, also fixes card renumbering

Tag the codec ourselves and let udev start the service the moment it appears.
New file `speaker-fix-940xfg/99-alc298-amp-init.rules` → `/etc/udev/rules.d/`:

```
# /dev/snd/hwC*D* is not systemd-tagged by default (99-systemd.rules only tags
# controlC*), so a .device dependency on it can never activate. Tag the 940XFG's
# ALC298 ourselves and start the amp init exactly when the codec appears.
ACTION=="add", SUBSYSTEM=="sound", KERNEL=="hwC?D?", ATTR{vendor_id}=="0x10ec0298", ATTR{subsystem_id}=="0x144dc882", TAG+="systemd", ENV{SYSTEMD_WANTS}+="alc298-amp-init.service"
```

Verified with `udevadm test` against a rule identical except for the SSID
(matched to this machine's ALC298, `0x144dc1d8`, since no 940XFG is available):

```
$ udevadm test /sys/class/sound/hwC0D0     # matching codec
TAGS=:systemd:uaccess:                     <-- systemd tag acquired
SYSTEMD_WANTS=pr75-udev-probe.service      <-- service would be started

$ udevadm test /sys/class/sound/hwC0D2     # Intel HDMI codec on the same card
(no match)                                 <-- correctly scoped
```

`ATTR{vendor_id}` and `ATTR{subsystem_id}` are both visible to udev on the hwdep
node, confirmed via `udevadm info -a -p /sys/class/sound/hwC0D0`.

**Trap if you take A:** `[Install] WantedBy=multi-user.target` must be *removed*
and the unit left udev-activated only. Otherwise the multi-user job can fire
first, no-op, and — because of `RemainAfterExit=yes` — leave the unit `active`,
so the later udev `SYSTEMD_WANTS` will not start it again. That reproduces
exactly the bug being fixed.

---

## What could not be verified without the hardware

Stated plainly, because most of this repo can only be judged on the bench:

- **No 940XFG was involved.** Every systemd/udev test above ran on Andy's Ubuntu
  machine (systemd 255, ALC298 `vendor_id=0x10ec0298`, `subsystem_id=0x144dc1d8`,
  `skl_hda_dsp_generic`). The `alc298-amp-init.service` unit is not installed
  here and was never touched — all probes were throwaway units under
  `/run/systemd/system/` and a throwaway rule under `/run/udev/rules.d/`, all
  removed afterwards (verified: no `pr75*` units or rules remain).
- **B1/B2 do not depend on the hardware.** They are properties of systemd's udev
  tagging, which is identical on any 940XFG running any systemd-based distro. I
  consider these confirmed, not inferred.
- **The author's original symptom was not reproduced.** That the amp init loses
  the race on *their* boot is taken on their report plus the mechanism above; it
  needs their `journalctl -b -u alc298-amp-init.service` to pin down whether the
  unit was skipped by the condition or ran-and-no-op'd.
- **Neither counter-proposal has been run on a 940XFG.** B was proven to *start
  correctly* here; that it makes the speakers work still needs the reporter to
  confirm on their machine before merge.
- **No COEF/amp behaviour was tested at all.** Nothing in this PR touches
  `alc298-amp-init.sh`, so the verb sequence is out of scope.

---

## Reply posted to @vaibhavagg101 — POSTED 2026-07-30 (`CHANGES_REQUESTED`)

> Thanks for this, and thanks for digging into the ordering rather than just
> working around it — the problem you've identified is real. But I can't take
> this patch as written, because `dev-snd-hwC0D0.device` never actually exists as
> far as systemd is concerned, so it makes the symptom worse rather than better.
>
> systemd only creates an *active* `.device` unit for udev devices tagged
> `systemd`, and the only sound rule that adds that tag is in
> `99-systemd.rules`:
>
> ```
> SUBSYSTEM=="sound", KERNEL=="controlC*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="sound.target"
> ```
>
> That matches `controlC*` only — `hwC*D*` never gets tagged. On a live ALC298
> box here, with the node sitting right there in `/dev/snd`:
>
> ```
> $ udevadm info /dev/snd/hwC0D0 | grep TAGS
> E: TAGS=:uaccess:
> $ systemctl show dev-snd-hwC0D0.device -p ActiveState
> ActiveState=inactive
> ```
>
> I built a throwaway unit with your exact `[Unit]` block to be sure. The job
> sits in `waiting` while the device job spins, and after
> `DefaultDeviceTimeoutSec` it gives up:
>
> ```
> $ time systemctl start pr75-boottime.service
> A dependency job for pr75-boottime.service failed.
> exit=1 after 91s
> $ journalctl -t pr75-boottime
> -- No entries --
> ```
>
> So the amp init would never run at boot at all, and you'd eat ~90s of hung job
> on the way. `systemd-analyze verify` is happy with the file, which is why this
> doesn't show up until you actually boot it.
>
> The race you're describing is real though. `After=sound.target` isn't the
> guarantee it looks like — `sound.target` is passive and can already have been
> reached before the card registers, in which case the script runs, finds no
> codec with SSID `0x144dc882`, exits 0, and `RemainAfterExit=yes` leaves the
> unit sitting `active (exited)` having done nothing. Silent speakers, no failed
> unit.
>
> The one-line version of what you want is to hang the dependency off the
> *control* device, which is tagged, and which ALSA creates only after every
> codec's hwdep node is built:
>
> ```ini
> Wants=sound.target dev-snd-controlC0.device
> After=systemd-modules-load.service sound.target dev-snd-controlC0.device
> ConditionPathExists=/dev/snd/hwC0D0
> ```
>
> `Wants=` rather than `Requires=` so a renumbered card degrades instead of
> hard-failing, and please keep the `ConditionPathExists=` line — it's what makes
> the unit skip cleanly instead of going red.
>
> Tested that shape here: starts in 1s, `ExecStart` runs. Could you try it on
> your 940XFG and confirm the speakers come up from a cold boot? If it works I'll
> merge it.
>
> If you'd rather do it properly, the more robust option is a udev rule that
> matches the codec by ID and starts the service directly — that also survives
> card renumbering, which the hardcoded `hwC0D0` doesn't. Happy to write that up
> if you want to go that route; the one gotcha is you'd need to drop
> `WantedBy=multi-user.target` so the early no-op can't beat udev to it.
>
> Last tiny thing: there's a trailing space on `Wants=sound.target ` — harmless,
> but worth dropping while you're in there.
>
> Also, could you attach `journalctl -b -u alc298-amp-init.service` from a bad
> boot? I'd like to know whether you were seeing the condition skip it or the
> run-and-no-op case, so the fix is aimed at the right one.

---

## Round 2 — 2026-08-01

@vaibhavagg101 replied. Three things came out of it:

1. **They reproduced the 91 s timeout themselves** — independent confirmation of
   B2. Their original failure logs are lost, so we still don't know whether the
   pre-PR symptom was the `ConditionPathExists` skip or the run-and-no-op case.
   They also conceded the patch "worked only once", which is exactly the shape
   of the race.
2. **Counter-proposal B was applied locally and cold-booted several times on a
   real 940XFG — speakers up on every boot.** That is the hardware confirmation
   the original review listed as missing. It was **never pushed**, though: the
   branch is still `62cdaffb` with the unsatisfiable
   `Requires=dev-snd-hwC0D0.device`. **Do not merge this PR in its current
   state.**
3. **They asked for counter-proposal A** (the udev rule) rather than ship a
   workaround they don't fully understand, and asked what was needed to set it
   up.

### Design change vs. counter-proposal A as originally written

The original sketch matched the codec directly:
`KERNEL=="hwC?D?", ATTR{vendor_id}=="0x10ec0298", ATTR{subsystem_id}=="0x144dc882"`.
It works under `udevadm test` — but that reads a fully-populated sysfs long
after boot, so it does **not** prove the attributes exist at the instant the
`add` uevent fires. The pinned tree here is only
`linux-6.17/sound/hda/codecs/realtek/alc269.c` (one file), so the hwdep
attribute-vs-uevent ordering couldn't be settled from source either. Shipping it
risked a rule that silently never fires — the same failure class as the PR.

**Shipped instead:** trigger on `KERNEL=="controlC?"`. `controlC*` is created by
`snd_card_register()`, i.e. after every codec's hwdep node is built, so it is a
guaranteed-late trigger, it carries no card-index assumption, and
`alc298-amp-init.sh` already does the vendor/SSID matching and exits 0 on a
non-match — so firing on a second sound card is harmless.

Verified — our rule and systemd's own `controlC*` rule both use `+=` and
accumulate rather than clobber:

```
$ udevadm test /sys/class/sound/controlC0
SYSTEMD_WANTS=alc298-amp-init.service sound.target
TAGS=:systemd:uaccess:
```

### The `[Install]` trap, now measured

Asserted in round 1, confirmed in round 2 — a oneshot with
`RemainAfterExit=yes`, started twice:

```
$ systemctl start alc298-trap-probe.service   # exit=0
$ systemctl start alc298-trap-probe.service   # exit=0
$ journalctl -t alc298-trap | grep -c RAN
1                                             # ran once, not twice
```

Both starts report success; the second is a no-op. So `WantedBy=multi-user.target`
must be **removed**, not merely reordered — otherwise the boot transaction
no-ops the unit into `active (exited)` and udev's later trigger does nothing.
Also confirmed: `systemctl enable` on a unit with no `[Install]` exits **0**
(so it won't trip `install.sh`'s `set -e`) but prints a "not meant to be
enabled" paragraph, so it should come out of `install.sh` regardless.

### What was handed over

Full implementation posted as a PR comment for the author to push — they stay
the author of the change, so **nothing in `speaker-fix-940xfg/` was modified
locally**: new `99-alc298-amp-init.rules`, the rewritten `.service` with no
`[Install]`, and the `install.sh` / `uninstall.sh` / `README.md` deltas.

**Blocked on:** author pushes, then cold-boots a 940XFG (bonus: a boot with a
USB DAC or dock attached, which is the renumbering case the old `hwC0D0` wiring
got wrong). Merge once that's confirmed. The COEF sequence remains untested from
here and is out of scope — this PR never touched `alc298-amp-init.sh`.
