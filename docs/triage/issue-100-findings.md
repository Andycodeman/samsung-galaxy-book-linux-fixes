# Issue #100 — "On Fedora 45 Beta" (@noopduck): one speaker side only, stock kernel, no DKMS

**Classification: expected behaviour of a stock kernel on this board, NOT a bug in
this repo, and NOT native support partly landing.** Mainline has no MAX98390 HDA
support (7.2.8 or 7.3-rc5), so nothing in Linux touches these amps. The one-amp-on
state is what the platform firmware leaves behind, and the reporter's workaround
completes it by hand. `speaker-fix/` covers exactly this case and has no conflict on
7.2.8. **No repo code change is needed for #100.**

Hardware (as reported): Galaxy Book5 Pro **940XHA** (Lunar Lake), ALC298 subsystem
**`0x144dca08`**, Fedora 45 Beta, stock kernel **7.2.8**, no DKMS driver installed.
Four MAX98390 at `0x38`/`0x39`/`0x3c`/`0x3d` on **i2c-2**. The reporter is the
same tester as in #49 (Book5 OV02E10 webcam).

**Status:** reply posted 2026-09-28 as
[comment-5881260449](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/100#issuecomment-5881260449)
(see [Reply posted](#reply-posted)). Round 2: reporter confirmed "left" and no
Windows; short follow-up posted as
[comment-5881394333](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/100#issuecomment-5881394333)
(see [Round 2](#round-2)). No code changed. Issue stays **open**, awaiting the
pre-install listen test and register dump.

---

## What the report establishes

| Observation (reporter's own reads) | `0x38` | `0x39` | `0x3c` | `0x3d` |
| --- | --- | --- | --- | --- |
| Answers on i2c-2 | yes | yes | yes | yes |
| `0x23FF` GLOBAL_EN | `0x01` | `0x01` | `0x01` | `0x01` |
| `0x203A` AMP_EN (bit 0 = SPK_EN) | **`0x81`** | `0x80` | `0x80` | `0x80` |
| `0x2021` channel select | left | right | left | right |

Writing `0x203A = 0x81` to the other three (his `galaxybook-amps-on`) restores
stereo. He made no other register writes, and he says the result sounds "very
good".

**The report contradicts itself on which side plays.** The first paragraph says
"speaker output on the **right** side during installation (livecd)… **left** side
doesn't activate". The summary says "Only the **left** speaker worked". The register
data fits the summary: the only enabled amp is `0x38`, and it listens to the left
channel. That's worth one clarifying question, because *which physical speaker*
`0x38` drives is exactly what #93 is unsure of (see [Q3](#q3--what-0x2021-adds-to-93-and-99)).

The live ISO shows the same one-sided behaviour, so this isn't something the
Fedora install configured.

## Q1 — Who enabled amp `0x38`? Firmware, not Linux

### (a) Native kernel support: absent in 7.2.8 and in mainline

Checked against the actual trees, not the changelog. Kernel line numbers in this
doc are from `v7.2.8`.

- **`v7.2.8`** (stable, `9a66fdc0`) and **torvalds master `72d3fcf8` (7.3-rc5,
  2026-09-27)**: `grep -ri max98390` over `sound/hda/` and
  `drivers/platform/x86/serial-multi-instantiate.c` returns **nothing**. No
  `snd-hda-scodec-max98390` in `sound/hda/codecs/side-codecs/Makefile`, no
  `MAX98390` in `smi_acpi_ids[]` (`serial-multi-instantiate.c:407`), and no
  `MAX98390` in `drivers/acpi/scan.c`'s `ignore_serial_bus_ids[]` (`:1750`).
- **thesofproject/linux PR #5616** is still **open**, head `bfa17b7`, last
  updated 2026-05-20. It hasn't been merged anywhere.
- **The ASoC driver can't bind either.** `sound/soc/codecs/max98390.c` (7.2.8)
  matches ACPI `"MX98390"` only (`:1114-1117`) and I2C id `"max98390"`
  (`:1098-1101`). This board's HID is `MAX98390` (`i2c-MAX98390:00`), so
  `i2c-MAX98390:00` stays unbound on a stock kernel.

Because `scan.c` doesn't list `MAX98390`, ACPI enumerates only the first
I2cSerialBus resource: one client, `i2c-MAX98390:00` at `0x38`. That matches our
README and `max98390-hda-i2c-setup.sh:57-58`. The brief asked whether a native
driver that probes only the ACPI-enumerated `0x38` would produce this exact
pattern. It would, but **no such driver exists in 7.2.8**. The "only `0x38`"
coincidence comes from firmware (below), not a partial Linux probe.

### (b) The in-tree ALC298 "Samsung V2 amps" quirk: doesn't match, and the wrong shape anyway

- **No `0x144dca08` entry.** 7.2.8's `alc269_fixup_tbl` has no `ca08` entry. The
  nearest are `ca03` (Book2 Pro 360, `SAMSUNG_AMP`) and `ca06` (Book3 360,
  headphone-only fixup). The V2 quirk
  (`ALC298_FIXUP_SAMSUNG_AMP_V2_{2,4}_AMPS`) is keyed on SSIDs `c870`/`c872`/`c1ac`
  (2 amps) and `c886`/`c1ca`/`c1cb`/`c1cc` (4 amps), plus one LG gram.
- **It can't produce this register state.** `alc298_samsung_v2_enable_amps()`
  (`alc269.c:1842`) writes `0x203A=0x81` and `0x23FF=0x01` **together**, to every
  configured amp, on stream open. `…_disable_amps()` (`:1859`) writes `0x23FF=0x00`
  and `0x203A=0x80` together on close. So its idle state is GLOBAL_EN=0 on all amps.
  Its playing state is all configured amps at 0x81. The observed state is
  GLOBAL_EN=1 on all four with AMP_EN=0x81 on one, and no V2 code path reaches it.
  In the 2-amp variant the V2 code configures `0x38` **and** `0x39`, never `0x38`
  alone.

### (c) Firmware: the only candidate the evidence supports

Upstream's regmap defaults for the chip (`sound/soc/codecs/max98390.c` 7.2.8,
`max98390_reg_defaults[]`) give **`0x203A AMP_EN = 0x81`** (`:64`) and
**`0x23FF GLOBAL_EN = 0x00`** (`:160`). These are the driver's declared power-on
values, not checked against the datasheet here. Taken at face value:

- `GLOBAL_EN = 0x01` on **all four** is non-default. Something wrote it to all four.
- `AMP_EN = 0x80` on `0x39`/`0x3c`/`0x3d` is non-default. Something wrote it to
  three amps.
- `0x2021` is set per side (`0x39`/`0x3d` right). Something set up all four
  channel selects.

Nothing in a 7.2.8 kernel writes to these amps ((a) and (b)). SOF firmware runs on
the audio DSP and has no path to the host LPSS I2C bus. So the writer ran **before
Linux**: UEFI/BIOS, or state left over from Windows across a warm reboot if the
machine dual-boots. What we know: the firmware configures all four amps, switches
their outputs off, and leaves `0x38` (or only `0x38`) enabled. The data can't
tell us why. A pre-OS boot-sound path is a guess, not a finding.

**Open question for the reporter:** does the pattern survive a full power-off
(shut down, wait, power on) as well as a reboot? Does the machine dual-boot
Windows? Same after a cold boot → UEFI. Only after a reboot from Windows →
Windows' state.

**Caveat:** Fedora kernels can carry patches that aren't in stable. The
`lsmod`/`journalctl` asks in the draft reply confirm that no MAX98390 module is
loaded on his kernel.

## Q2 — Does `speaker-fix/` work on Fedora 45 / 7.2.8? Yes, and it doesn't misfire

### The check-upstream script does NOT misfire on 7.2.8

`max98390-hda-check-upstream.sh` requires **all three** checks to pass before it
removes anything. Any failure sets `UPSTREAM_READY=false` and exits at `:50`
before the `dkms remove` at `:68`. On 7.2.8 every check fails:

| Check | Line | What it tests | 7.2.8 result |
| --- | --- | --- | --- |
| 1 | `:18-20` | `modinfo serial-multi-instantiate` has an `alias.*MAX98390` | **fail**: no `MAX98390` in `smi_acpi_ids[]` |
| 2 | `:30-32` | alc269 module contains string `alc298-samsung-max98390` | **fail**: 7.2.8's model list stops at `alc298-samsung-amp-v2-4-amps` |
| 3 | `:42` | `snd-hda-scodec-max98390*` under `kernel/sound` (not `updates/dkms`) | **fail**: not in the side-codecs Makefile |

So on 7.2.8 it logs "DKMS workaround still needed" and exits. A *partial*
landing, such as the driver merged without the SMI entry, also keeps the DKMS
package, because the checks are ANDed. The script fails closed.

Two details, neither a misfire:

- **Check 2 will match PR #5616 as written.** The PR's model string is
  `alc298-samsung-max98390-4-amps`, and the grep is a substring match.
- **Check 2 is fragile on Fedora, but it fails safe.** It runs
  `zstdcat | strings`. Fedora ships modules as `.ko.xz`, so this needs a zstd
  build with xz support and binutils' `strings` installed. Ubuntu's zstd 1.5.5
  reports `xz` support. Fedora's wasn't checked here. If either is missing, check
  2 always fails and the package is never auto-removed, so it outlives native
  support rather than removing itself too early. Low priority.

### No conflict with anything already bound

- `i2c-MAX98390:00` (`0x38`) has **no driver** on stock 7.2.8 ([Q1a](#a-native-kernel-support-absent-in-728-and-in-mainline)).
  Our `max98390_hda_i2c.c:60-65` claims it through its ACPI table (`"MAX98390"`).
- `max98390-hda-i2c-setup.sh` skips `0x38` (`:57-58`), and skips any address
  whose `${bus}-00NN` device already exists (`:60`). It then creates the others
  with `new_device` (`:90`), so it can't double-instantiate.
- Our init **software-resets** each amp (`max98390_hda.c:99`) and ends with
  `0x2021`, the DSM blob, `0x23E1=1`, **`0x203A=0x81`**, **`0x23FF=1`** on every amp
  (`max98390_hda_filters.c:47,219-225`). Whatever the firmware left is overwritten,
  and all four amps come up enabled. That fixes #100's symptom directly.
- **His own service stops working once our driver is bound.** `i2ctransfer`
  refuses an address "already under the control of a kernel driver" without `-f`
  (i2ctransfer(8)). His script has no `set -e` and ends on `echo`, so it logs errors
  and still exits 0. That isn't dangerous, but it's two owners for one register
  and confusing noise on every boot and resume. The reply tells him to disable
  it first. **He must not add `-f`.**

### The real caveat is sound quality, not function

His firmware-state amps sound "very good" to him. Our driver replaces that state
with the Google Redrix DSM blobs. The only other Lunar Lake Book5 report on this
driver, #93 (Book5 Pro 360), has **silent or bass-less woofers** after the blob
fix, root cause still open. So installing speaker-fix will fix the one-sided
problem. It **may** also sound worse than his workaround. We can't promise
otherwise, and the reply says so and gives him the way back.

On the build itself: #99 built and probed this DKMS source on Fedora
`7.2.6-200.fc44`. 7.2.8 is a point release, so we expect it to build, but that
hasn't been verified. `install.sh:22` picks `dnf` first, so the #91-style distro
misdetection doesn't hit Fedora.

## Q3 — What `0x2021` adds to #93 and #99

- **README Speaker Layout, channel column: confirmed, independently.** The firmware
  set `0x38`/`0x3c` → left and `0x39`/`0x3d` → right. That is the same split our
  driver writes (`max98390_hda_filters.c:24-37,47`) and the in-tree V2 table uses
  (`alc269.c:1813,1821`). It's a second, unrelated source agreeing with ours.
  `0x2021` is a channel select, though, not a physical position. It says which
  audio channel an amp plays, not where the speaker sits.
- **#93 (woofer/tweeter map inverted on Lunar Lake?): not addressed.** `0x2021` is
  per side, not per type. But this machine can answer #93 cheaply. On a fresh
  boot without his service, **only `0x38` plays**. Whether that one speaker
  sounds bassy or thin/tinny tells us directly whether `0x38` is a woofer (README)
  or a tweeter (#93's hypothesis), on Lunar Lake, with no driver involved. His
  firmware-state `0x23BA` per amp is a second read-only tell (the V2 table uses
  `0x94` for woofers and `0x8d` for tweeters). So is a dump of the DSM range
  before our driver resets it. That's also the first chance to see what Samsung's
  own firmware loads, next to the Redrix blobs. All three asks are in the draft.
- **#99 (Book4 Pro 360, right side silent WITH our driver): different mechanism.**
  #99's read-back already shows `AMP_EN=0x81` and `GLOBAL_EN=0x01` on all four amps
  (`issue-99-findings.md:776-777`). #100's cause, amps left disabled, isn't
  present there. #100 is "not enabled". #99 is "enabled and silent". The one fact
  #100 adds: on this Lunar Lake board, right amps listening to channel 1 do get
  audio from the codec link. It's a different platform and SSID (Meteor Lake
  `0x144dc892`), so this is weak evidence against #99's H1 and doesn't settle it.

## Hypotheses, ranked

1. **Firmware leaves 3 of 4 amps disabled; no OS driver completes the job.**
   Supported by every datapoint, and fully explains the report.
2. **Fedora-specific kernel patch partly driving the amps.** Unlikely: no
   upstream code exists to carry, and a partial driver would software-reset
   rather than leave firmware's per-side `0x2021`. The `lsmod`/`journalctl` asks
   rule it out cheaply.
3. **Warm-reboot residue from Windows** rather than UEFI. A sub-case of 1. The
   cold-boot question separates them. It doesn't change the recommendation.

## Q4 — Recommendation: (A) no repo change; the reporter should install speaker-fix

Why (A):

- This board is exactly `speaker-fix/`'s target (Book5 Pro, 4x MAX98390, ACPI
  `MAX98390`). The package enables all four amps from a software reset, so it
  doesn't depend on what the firmware left.
- On 7.2.8 there's no native driver to collide with, and check-upstream won't
  remove the package ([Q2](#q2--does-speaker-fix-work-on-fedora-45--728-yes-and-it-doesnt-misfire)).
- Neither (B) nor (C) is justified. No script misbehaves on this kernel. The
  upstream fix is PR #5616, which already covers this board through the
  SSID-independent SMI path (below). Pointing him upstream would leave him on a
  hand-rolled workaround with no timeline.

With one honest caveat in the reply: sound quality may differ from his firmware
state (#93). He can revert with `uninstall.sh` and re-enable his own service.

**Non-blocking follow-ups for the orchestrator** (none needed to close #100):

1. **PR #5616 omits `0x144dca08`.** Its alc269 hunk adds `ca07`, `c890`, `c892`,
   `c1d8`, `c1da`, but not the 940XHA. The SMI entry is keyed on the ACPI HID, not
   the SSID, and the PR's driver enables amps at probe too
   (`max98390_hda_filters.c:224-231` @ `bfa17b7`). So a 940XHA would still get
   sound if the PR lands as-is. It would only miss the component master, and
   with it idle power management. Worth a comment on the PR once the reporter
   confirms speaker-fix works. The data isn't solid enough yet to ask for an
   SSID to be added.
2. **README "The Problem"** says the speakers are "completely silent". On the
   940XHA a stock kernel gives **one side**, because of the firmware state above.
   A one-line note would help others who find a workaround like his. Also add
   940XHA / `0x144dca08` to the tested list once he confirms. Docs only.
3. **check-upstream check 2 on Fedora** (`zstdcat`/`strings`). It fails closed, so
   the only cost is the package outliving native support. Could use `modinfo` or
   `xzcat`/`zstdcat` by extension. Lowest priority.

If his answers show `0x38` is a *tweeter*, or that Samsung's firmware loads a
different DSM than Redrix, that's new #93 evidence and belongs in #93. #100
doesn't need to stay open for it.

---

## Draft reply

Posted unchanged; see [Reply posted](#reply-posted). Follows repo conventions: no claim of personal testing, `journalctl -k -b`
rather than `dmesg`, files attached rather than written to `/tmp` (Fedora clears it on
reboot).

````markdown
Thanks — this is a really clean report, and the register reads made it quick to pin down.

**What's going on:** there's no MAX98390 support in the stock kernel yet — not in 7.2.8, and not in current mainline (7.3-rc5) either. The upstream driver is still an open PR ([thesofproject/linux#5616](https://github.com/thesofproject/linux/pull/5616)). So on a stock kernel nothing in Linux touches the amps at all. The state you found — `GLOBAL_EN=1` on all four, the channel selects already set per side, but `AMP_EN` on only `0x38` — is what the laptop's firmware leaves behind before Linux starts. Your script finishes the job the firmware didn't. (It also explains why the live ISO behaved the same way.)

**The fix in this repo covers exactly this.** [`speaker-fix/`](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/tree/main/speaker-fix) binds to the `MAX98390` ACPI device at `0x38`, creates `0x39`/`0x3c`/`0x3d` itself, resets each amp, and enables all four. It doesn't depend on what the firmware left. Nothing else in 7.2.8 claims these amps, so there's no conflict.

One honest caveat before you switch: your amps currently run on whatever tuning the firmware loaded, and you say that sounds very good. speaker-fix replaces it with the DSM tuning from PR #5616 (originally from a Google Chromebook). On another Lunar Lake Book5 ([#93](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/93)) the woofers are still weak with it, and we haven't found out why. So you'll definitely get both sides, but it might sound thinner than your workaround. If it does, reverting is one command (below), and we'd really like to hear about it.

Before installing, a few things would help a lot, both for this issue and for #93. Everything below only **reads** — no register writes.

**1. Quick clarification.** Your first paragraph says the *right* side played and the left didn't. Your summary says only the *left* worked. Which one was it, physically? Also: does it happen after a full shutdown and power-on as well as after a reboot, and does this machine dual-boot Windows?

**2. One boot without your service, then listen.** Please disable your service and reboot:

```bash
sudo systemctl disable galaxybook-amps.service
sudo reboot
```

Play some music. Only `0x38` should be on. Which physical side is it on, and does it sound **bassy** (woofer) or **thin/tinny** (tweeter)? That answers the open question in #93 with no driver involved.

**3. Logs and the firmware's register state** (same boot, still without your service). Please attach the files rather than pasting:

```bash
journalctl -k -b | grep -iE 'max98390|scodec|smi|serial-multi' > kernel-max98390.txt
ls -l /sys/bus/i2c/devices/ > i2c-devices.txt
lsmod | grep -i max98390 > lsmod-max98390.txt   # empty is the expected answer
cat /proc/asound/card*/codec#0 > codec0.txt
```

And a read-only dump of each amp's registers as the firmware left them. Run as root (`sudo -s` first), with nothing playing:

```bash
modprobe i2c-dev
for a in 0x38 0x39 0x3c 0x3d; do
  for r in $(seq $((0x2010)) $((0x23ff))); do
    printf '0x%04x %s\n' "$r" "$(i2ctransfer -y 2 w2@$a $((r >> 8)) $((r & 0xff)) r1)"
  done > "amp-$a.txt"
done
```

That gives four `amp-0x3?.txt` files. They let us compare Samsung's own firmware tuning against what speaker-fix loads.

**4. Then install speaker-fix.** Leave your service disabled; otherwise two things drive the same registers, and your `i2ctransfer` calls will fail with "busy" once the driver owns the amps. (Please don't add `-f` to get around that.)

```bash
sudo dnf install dkms kernel-devel-$(uname -r) i2c-tools
curl -sL https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book-linux-fixes-main/speaker-fix && sudo ./install.sh && sudo reboot
```

After the reboot, `journalctl -k -b | grep -i max98390` should show four `MAX98390 HDA I2C probe` lines. Then let us know: both sides playing? And how does it compare to your workaround, especially the bass?

**To go back** if you prefer your workaround:

```bash
cd samsung-galaxy-book-linux-fixes-main/speaker-fix && sudo ./uninstall.sh
sudo systemctl enable galaxybook-amps.service
sudo reboot
```

On #99: that one looks different. There, the right amps are already enabled (`AMP_EN=0x81` on all four) and still silent, whereas here they were never switched on. Your finding that the firmware sets up the same left/right channel split we use is still a useful cross-check, so thank you for including it.
````

## Reply posted

Posted verbatim to @noopduck on 2026-09-28 as
[comment-5881260449](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/100#issuecomment-5881260449).
Issue left **open**, with no labels and no code change.

It is the [draft above](#draft-reply) unchanged: no fix card landed after
triage (a79c345), so recommendation (A) still stands and the reply points at
`speaker-fix/` on `main` rather than a release tag. Before posting, the reply's
`bash` blocks passed `bash -n`, and the paths and log line it cites were
checked against the repo: `speaker-fix/install.sh`, `speaker-fix/uninstall.sh`,
and the `MAX98390 HDA I2C probe` message (`max98390_hda_i2c.c:41`). The service
name `galaxybook-amps.service` and bus `2` come from the reporter's own report.

> Thanks — this is a really clean report, and the register reads made it quick to pin down.
>
> **What's going on:** there's no MAX98390 support in the stock kernel yet — not in 7.2.8, and not in current mainline (7.3-rc5) either. The upstream driver is still an open PR ([thesofproject/linux#5616](https://github.com/thesofproject/linux/pull/5616)). So on a stock kernel nothing in Linux touches the amps at all. The state you found — `GLOBAL_EN=1` on all four, the channel selects already set per side, but `AMP_EN` on only `0x38` — is what the laptop's firmware leaves behind before Linux starts. Your script finishes the job the firmware didn't. (It also explains why the live ISO behaved the same way.)
>
> **The fix in this repo covers exactly this.** [`speaker-fix/`](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/tree/main/speaker-fix) binds to the `MAX98390` ACPI device at `0x38`, creates `0x39`/`0x3c`/`0x3d` itself, resets each amp, and enables all four. It doesn't depend on what the firmware left. Nothing else in 7.2.8 claims these amps, so there's no conflict.
>
> One honest caveat before you switch: your amps currently run on whatever tuning the firmware loaded, and you say that sounds very good. speaker-fix replaces it with the DSM tuning from PR #5616 (originally from a Google Chromebook). On another Lunar Lake Book5 ([#93](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/93)) the woofers are still weak with it, and we haven't found out why. So you'll definitely get both sides, but it might sound thinner than your workaround. If it does, reverting is one command (below), and we'd really like to hear about it.
>
> Before installing, a few things would help a lot, both for this issue and for #93. Everything below only **reads** — no register writes.
>
> **1. Quick clarification.** Your first paragraph says the *right* side played and the left didn't. Your summary says only the *left* worked. Which one was it, physically? Also: does it happen after a full shutdown and power-on as well as after a reboot, and does this machine dual-boot Windows?
>
> **2. One boot without your service, then listen.** Please disable your service and reboot:
>
> ```bash
> sudo systemctl disable galaxybook-amps.service
> sudo reboot
> ```
>
> Play some music. Only `0x38` should be on. Which physical side is it on, and does it sound **bassy** (woofer) or **thin/tinny** (tweeter)? That answers the open question in #93 with no driver involved.
>
> **3. Logs and the firmware's register state** (same boot, still without your service). Please attach the files rather than pasting:
>
> ```bash
> journalctl -k -b | grep -iE 'max98390|scodec|smi|serial-multi' > kernel-max98390.txt
> ls -l /sys/bus/i2c/devices/ > i2c-devices.txt
> lsmod | grep -i max98390 > lsmod-max98390.txt   # empty is the expected answer
> cat /proc/asound/card*/codec#0 > codec0.txt
> ```
>
> And a read-only dump of each amp's registers as the firmware left them. Run as root (`sudo -s` first), with nothing playing:
>
> ```bash
> modprobe i2c-dev
> for a in 0x38 0x39 0x3c 0x3d; do
>   for r in $(seq $((0x2010)) $((0x23ff))); do
>     printf '0x%04x %s\n' "$r" "$(i2ctransfer -y 2 w2@$a $((r >> 8)) $((r & 0xff)) r1)"
>   done > "amp-$a.txt"
> done
> ```
>
> That gives four `amp-0x3?.txt` files. They let us compare Samsung's own firmware tuning against what speaker-fix loads.
>
> **4. Then install speaker-fix.** Leave your service disabled; otherwise two things drive the same registers, and your `i2ctransfer` calls will fail with "busy" once the driver owns the amps. (Please don't add `-f` to get around that.)
>
> ```bash
> sudo dnf install dkms kernel-devel-$(uname -r) i2c-tools
> curl -sL https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book-linux-fixes-main/speaker-fix && sudo ./install.sh && sudo reboot
> ```
>
> After the reboot, `journalctl -k -b | grep -i max98390` should show four `MAX98390 HDA I2C probe` lines. Then let us know: both sides playing? And how does it compare to your workaround, especially the bass?
>
> **To go back** if you prefer your workaround:
>
> ```bash
> cd samsung-galaxy-book-linux-fixes-main/speaker-fix && sudo ./uninstall.sh
> sudo systemctl enable galaxybook-amps.service
> sudo reboot
> ```
>
> On #99: that one looks different. There, the right amps are already enabled (`AMP_EN=0x81` on all four) and still silent, whereas here they were never switched on. Your finding that the firmware sets up the same left/right channel split we use is still a useful cross-check, so thank you for including it.

## Round 2

@noopduck answered two of the round-1 questions on 2026-09-28
([comment-5881315622](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/100#issuecomment-5881315622)):
"the left speaker was the one working without any changes on F45" and "I dont
dual boot with Windows on the system". A second comment
([comment-5881362199](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/100#issuecomment-5881362199))
says he'll follow up on the rest later because he's busy.

What the answers settle:

- **(a) Left is right; the report's first paragraph was the typo.** "Left"
  matches the register data: `0x38` is the only amp with `AMP_EN=0x81`, and its
  `0x2021` selects the left channel. That also means `0x38` physically sits on the
  **left**, the side the README puts it on. It says nothing about woofer vs
  tweeter, so #93's question is still open.
- **(b) No Windows, so the one-amp-on state comes from UEFI/BIOS.** Nothing that
  runs before Linux on this machine can have left the state except the laptop's
  own firmware. **Hypothesis 3 (Windows warm-reboot residue) is dropped.
  Hypothesis 1 is confirmed as far as the data goes.** The cold-boot vs reboot
  question went unanswered, but without Windows it no longer separates anything.
  It only mattered for telling UEFI apart from Windows.
- **(c) Outstanding asks are unchanged.** Steps 2 and 3 of the round-1 reply
  (listen test, logs, firmware register dump) and step 4 (install speaker-fix and
  report) are all still pending. For #93 the most valuable one is **step 2**: one
  boot without his service, is the single playing speaker bassy or thin? Next is
  the **step 3 register dump**. **Both have to happen before he installs
  speaker-fix.** Our driver software-resets every amp at probe
  (`max98390_hda.c:99`) and loads the Redrix DSM, so while it's installed the
  firmware's own tuning is overwritten on every boot. After that, the only way
  back to the firmware state is `uninstall.sh`.

No code change. Recommendation (A) stands. Issue stays **open**, no labels.

## Round 2 reply posted

Posted verbatim to @noopduck on 2026-09-28 as
[comment-5881394333](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/100#issuecomment-5881394333).
It's deliberately short and low-pressure. It links the round-1 comment rather
than repeating its command blocks, and it asks for just one thing (steps 2 + 3
before installing speaker-fix). Issue left **open**, no labels, no code change.

> Thanks, and no rush at all. "Left" lines up with the register data: `0x38` is the only amp the firmware switched on, and it's set to the left channel, so that clears up the contradiction. No Windows on the machine means the one-side state comes from the laptop's own firmware, which is the tidiest explanation.
>
> When you do have time, one thing matters most: steps 2 and 3 from [my earlier comment](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/100#issuecomment-5881260449). That's one boot without your service, a listen to whether that single left speaker sounds bassy or thin, and the `amp-0x3?.txt` register dump. Please do those *before* installing speaker-fix. The driver resets the amps on every boot, so the firmware's own tuning can't be read once it's installed. Everything else can wait, and if you'd rather just have both sides working, you're welcome to install speaker-fix whenever you like and tell us how it sounds.
