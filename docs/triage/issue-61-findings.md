# Issue #61 — new comment from @GiulioMicheletti (Book3 Ultra, right channel unusable)

**Classification: NOT the Book3 audio problem we just fixed, and not the same
problem as the issue he posted under. Two unrelated faults are now sharing one
thread.**

Andy's question was "does the recent Book3 speaker work solve this guy's problem
or is it unrelated". Short answer: **unrelated as a fix, but his data is the most
useful thing to land on #61 so far** — it settles what was open for the original
reporter.

**Status:** both replies **POSTED** 2026-09-17 with maintainer sign-off —
[comment-5707102987](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/61#issuecomment-5707102987)
(to @GiulioMicheletti) and
[comment-5707103265](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/61#issuecomment-5707103265)
(to @flasheyy-26). Issue stays **open** pending both sets of test results. One
code change went with it, unrelated to the diagnosis but surfaced by it — see
[Changed](#changed-disable-before-init-in-the-940xfg-script). No new diagnostic
script was needed: the tests are read-only or reuse sequences the kernel already
runs, so they go inline in the reply, as in #93.

---

## Who is in this thread now

| | @flasheyy-26 (opener, 2026-06-24) | @GiulioMicheletti (2026-09-17) |
| --- | --- | --- |
| Model | NP960XFH Book3 Ultra | same, SKU `NP964XFH_XA4IT`, BIOS `P07ALQ` |
| SSID | `144d:c1cc` | `144d:c1cc` |
| Kernel | 7.0.0-22-generic (Ubuntu 26.04) | 7.0.0-22-generic (Zorin, Ubuntu-based) |
| ALC298 on HDA bus | **absent** — no `hwC0D0`, no `pcm0` | **present** — `codec#0`, `pcm0p`/`pcm0c` |
| Symptom | total silence from internal speakers | plays, but **right channel has no bass and badly distorted highs** |

Same model, same SSID, same kernel, opposite enumeration outcome. That is the
whole value of the new comment (see "What this does for the original reporter").

## Why neither existing speaker fix applies

**`speaker-fix-940xfg/` (the issue #44 work) does not apply.** That fix exists
because `0x144dc882` has *no* entry in the kernel's ALC298 fixup table, so the
amps are never initialised. Giulio's `0x144dc1cc` **is** in the table:

```
linux-6.17/sound/hda/codecs/realtek/alc269.c:6871
SND_PCI_QUIRK(0x144d, 0xc1cc, "Samsung Galaxy Book3 Ultra (NT960XFH)",
              ALC298_FIXUP_SAMSUNG_AMP_V2_4_AMPS),
```

and his own dmesg confirms it fired:

```
snd_hda_codec_alc269 ehdaudio0D0: ALC298: picked fixup  for PCI SSID 144d:c1cc
```

The blank fixup name is not a sign of a partial match. `snd_hda_pick_fixup()`
(`sound/hda/common/auto_parser.c:1089`) `return`s without logging when nothing
matches; the message at `:1096` is only reached after a match, and the name is
only filled in under `CONFIG_SND_DEBUG_VERBOSE`, which
Ubuntu does not set (`# CONFIG_SND_DEBUG is not set` in `/boot/config-7.0.0-*`).
So: quirk matched, `V2_4_AMPS` applied, all four amps initialised — on paper.

The same `CONFIG_SND_DEBUG` being off is why his dmesg has **no**
`alc298_samsung_v2: Initialized speaker amp 0x..` lines. Those are `codec_dbg`.
Their absence proves nothing; getting them printed is test 3 below.

**`speaker-fix/` (MAX98390 DKMS) does not apply either**, and the reason is
worth writing down because it also explains flasheyy-26's "no MAX98390 I2C
devices" finding — see next section.

## Finding: the Book3 ALC298 "V2 amps" *are* MAX98390s, reached through the codec

This has not been written down in the repo before and it links #61 directly to
the issue #93 work.

The COEF pack sub-addresses in `alc298_samsung_v2_amp_desc_tbl[]`
(`alc269.c:1709`) are not Realtek coefficients. They are MAX98390 register
addresses, one for one with `speaker-fix/src/max98390_regs.h`:

| Pack sub-address | `max98390_regs.h` |
| --- | --- |
| `0x2012` | `MAX98390_CLK_MON` |
| `0x2014` | `MAX98390_DAT_MON` |
| `0x201b` | `MAX98390_PCM_RX_EN_A` |
| `0x2021` | `MAX98390_PCM_CH_SRC_1` |
| `0x203a` | `MAX98390_R203A_AMP_EN` |
| `0x2050` | `MAX98390_PWR_GATE_CTL` (also `MAX98390_DSM_START_ADDR`, `max98390_hda_filters.c:54`) |
| `0x2076` | `MAX98390_ENV_TRACK_VOUT_HEADROOM` |
| `0x207c` | `MAX98390_BOOST_BYPASS1` |
| `0x2081` | `MAX98390_FET_SCALING3` |
| `0x23e1` | `MAX98390_R23E1_DSP_GLOBAL_EN` |
| `0x23ff` | `MAX98390_R23FF_GLOBAL_EN` |

`alc298_samsung_v2_enable_amps()` writes `{0x203a, 0x81}` then `{0x23ff, 0x01}` —
that is `AMP_EN` then `GLOBAL_EN`, exactly the sequence `speaker-fix/` issues over
host I2C. And the values selected into COEF `0x22` — `0x38`, `0x39`, `0x3c`,
`0x3d` — are the amps' **I2C addresses**, the same four addresses
`docs/triage/issue-93-findings.md` mutes with `i2ctransfer`.

Consequences:

1. **Book3 and Book4/Book5 drive the same amplifier** — a MAX98390 or a
   register-compatible sibling — two different ways: Book3 through the codec's
   own I2C master via COEF `0x22/0x23/0x25/0x26` indirection, Book4/5 over a
   host I2C bus that the SoC exposes. That is why
   flasheyy-26 correctly found "no MAX98390 I2C devices, no ACPI entries" and
   why `speaker-fix/` reported no amplifier — on Book3 the amps are invisible to
   the host. His diagnostic was right; the conclusion drawn from it ("wrong
   chip") was half right.
2. **The address map transfers.** `speaker-fix/src/max98390_hda_filters.c:23-44`
   assigns `0x38` woofer/left, `0x39` woofer/right, `0x3c` tweeter/left, `0x3d`
   tweeter/right. The V2 table corroborates the split independently: the
   `0x38`/`0x39` pair get an 18-write init including the extra DSM params
   `0x2399`/`0x23a4`/`0x23a5` and `0x23ba = 0x94`, while `0x3c`/`0x3d` get 15
   writes and `0x23ba = 0x8d` — and `0x23ba` is `DSM_VOL_CTRL`, where
   `max98390_hda_filters.c:213` writes exactly `0x8d` for a tweeter and `0xA0`
   for a woofer.
   *Caveat, stated plainly:* issue #93 round 2 suspects this very map is
   inverted on Lunar Lake. The init-size difference only proves `0x38`/`0x39`
   and `0x3c`/`0x3d` are two different *classes* of driver; which class is the
   woofer is inherited from the map #93 questions. Test 4 in the draft reply
   does not depend on the labels being right — it isolates by ear.
3. **`0x2021 PCM_CH_SRC_1` gives left/right.** `0x38`/`0x3c` = `0x00`,
   `0x39`/`0x3d` = `0x01`, matching `max98390_hda_filters.c:47` one for one. So
   Giulio's bad right channel is amps **`0x39` and `0x3d`**.

## What the symptom rules out

"No bass, distorted highs, right side only" is, in amp terms, *the woofer is not
reproducing and the tweeter is being asked to carry the whole band* — the same
shape as issue #93.

But #93 is **bilateral** and this is **unilateral**, and that difference does the
work. `alc298_samsung_v2_amp_desc_tbl[]` is left/right symmetric apart from the
channel-select fields (`0x201b`, `0x201d`, `0x201f`, `0x2021`); every gain,
volume and DSM value is identical between `0x38`/`0x39` and between
`0x3c`/`0x3d`. **A symmetric table cannot produce an asymmetric fault.** So the
issue #93 hypothesis — a wrong hardcoded woofer/tweeter map — is not available
here, and neither is "the V2_4 tuning is wrong for this enclosure": both would
break both sides.

What is left, in the order worth testing:

1. **Host-side clipping or channel imbalance** — cheapest, must be excluded first.
2. **The right woofer's init or enable did not land**, leaving `0x39` at
   power-on defaults (no DSM tuning loaded, possibly not enabled at all) while `0x3d` runs
   full range. Fixable in software if true.
3. **`0x39` latched a MAX98390 fault** (over-current / over-temp / DSM excursion).
4. **Physical damage to the right woofer or its wiring.** Note the issue title he
   posted under is "even after replacing my speakers" — unrelated person, but a
   reminder that these units do lose drivers.

His report that `dsp_driver=1` (legacy HDA) behaves identically is good
supporting evidence: the fault survives a complete change of playback driver, so
it sits at or below the amps, not in SOF topology.

## Aside: SKU string

`/proc/asound/cards` longname reads
`SAMSUNGELECTRONICSCO.LTD.-960XFH-P07ALQ-NP964XFH_XA4IT` — DMI product `960XFH`
but SKU `NP964XFH`, where the kernel labels `0xc1cc` as `NT960XFH`. Regional
variant. Recorded for completeness; it changes nothing, because the SSID is what
selects the fixup and the fixup fired.

## What this does for the original reporter (@flasheyy-26)

This is the part worth telling him. Giulio is the same model, same SSID, same
kernel — and his ALC298 enumerates. So flasheyy-26's missing codec is **not** a
model-wide Linux gap, and no kernel quirk, COEF sequence or DKMS module was ever
going to bring it back. It is specific to his unit: firmware/BIOS state, or the
speaker replacement he mentions in the title (an unseated or damaged connector on
reassembly would look exactly like this).

Two concrete follow-ups that are now worth asking him for, neither of which was
askable before:

- **BIOS version.** Giulio is on `P07ALQ` and enumerates. If flasheyy-26 is on a
  different version, that is the one variable we can now compare directly
  between two otherwise identical machines. (Checked issue #48 as a possible
  precedent for "BIOS update killed the audio" — it is *not* one. That turned
  out to be Secure Boot rejecting the DKMS signing key after the update, which
  cannot apply here: nothing in flasheyy-26's path is an out-of-tree module.)
- **Whether the speakers were replaced before or after the audio stopped**, and
  whether the analog codec works in Windows / the BIOS beep works.

## Recommended next step on the issue itself

**Split it.** #61 is "ALC298 does not enumerate on NP960XFH". Giulio's report is
"ALC298 enumerates, right-side amps misbehave on NP960XFH". Different layer,
different fix, and they will tangle if they share a thread. Suggest he open his
own issue; keep a cross-link both ways because his enumeration data is the
evidence #61 needed.

## Changed: disable-before-init in the 940XFG script

Found while reading the V2_4 path for this triage, unrelated to either reporter's
fault. `speaker-fix-940xfg/alc298-amp-init.sh` went straight to writing init
sequences into live amps. Upstream `alc298_samsung_v2_init_amps()`
(`alc269.c:1798-1799`) mutes all of them first, with the comment "Disable
speaker amps before init to prevent any physical damage" — because the init
writes retune the DSM excursion, boost and limiter parameters, which must not
land on an amp whose output stage is running.

On a cold boot that gap is harmless: with no quirk entry for `0xc882`, the amps
are at power-on defaults and not enabled. It is **not** harmless on the two
paths where the script runs against already-enabled amps: the
`/lib/systemd/system-sleep/` resume hook, and any manual or udev-triggered
re-run while audio is playing.

Fixed by adding `disable_amp()` — the exact inverse of the existing
`enable_amp()`, `{0x23ff, 0x0000}` then `{0x203a, 0x0080}`, matching upstream's
`disable_seq` in both content and order — and a four-amp mute pass ahead of the
init calls. README's "How it works (technical)" updated to match.

End state is unchanged: all four amps still finish enabled, the SKU-specific
`{0x239e, 0x0004}` write is untouched, and the pin/unmute writes still close the
script. Verified by running the whole script against a stub that records every
`hda-verb` invocation: 550 verbs, the first 56 being the mute pass (4 amps ×
select + 2 packs) and ending exactly where the `0x38` init begins; 4 × `0x203a`
= `0x80` (disable) and 4 × `0x203a` = `0x81` (enable); `0x239e` still written 4
times. `bash -n` clean.

Not fixed, and still open: the service's `RemainAfterExit=yes`, which lets the
unit fire early and no-op if another card's `controlC*` registers first. Known
gap from v0.3.60, separate from this.

## Not addressed here

- There is no read-back path for the indirect amp registers. The kernel only
  ever writes them (`0x26 = 0xb011` trigger); no read counterpart is documented,
  and guessing one is not worth the risk. This is why the tests below isolate by
  muting rather than by reading `INT_RAW`, which is what #93 could do over I2C.

---

## Reply to @GiulioMicheletti — POSTED

Posted verbatim as
[comment-5707102987](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/61#issuecomment-5707102987).

> Thanks — this is a genuinely useful report, and I want to answer two things:
> what your data does for the original poster, and what I think is going on with
> your right channel.
>
> **First, the good news for @flasheyy-26.** You are the same model, the same
> subsystem ID `144d:c1cc`, the same kernel — and your ALC298 enumerates. That
> tells us his missing codec isn't a Linux gap on the Book3 Ultra, because on
> your identical machine Linux finds it fine. It's specific to his unit. That is
> the first hard evidence we've had on that question, so thank you.
>
> **Second, your problem is a different one, and the recent Book3 fix won't help
> you.** Worth being explicit about why, since it's the obvious thing to try:
>
> - `speaker-fix-940xfg/` exists because the 14" Book3 Pro's SSID `0x144dc882`
>   is *missing* from the kernel's ALC298 fixup table, so its amps never get
>   initialised. Yours is not missing — `0x144dc1cc` is in the table and maps to
>   `ALC298_FIXUP_SAMSUNG_AMP_V2_4_AMPS`, and your dmesg line
>   `ALC298: picked fixup  for PCI SSID 144d:c1cc` is the kernel confirming it
>   fired. (The name is blank only because Ubuntu builds without
>   `CONFIG_SND_DEBUG_VERBOSE`; it isn't a partial match.)
> - `speaker-fix/` is the MAX98390 DKMS module and it targets amps on a *host*
>   I2C bus, which your machine doesn't have.
>
> On the `sof-hda-generic-2ch.tplg` / `speaker_outs=0` line you flagged: good
> catch, but it isn't the fault. Those three autoconfig lines are identical on
> the 940XFG in #44, and they're what ALC298 always prints on these machines —
> pin `0x17` gets classified as a line-out of type speaker. It doesn't matter
> here, because the internal amps aren't driven through a `speaker_out` pin at
> all; the fixup talks to them directly over the codec's COEF registers,
> independently of what autoconfig decided about the pins.
>
> **What I think is actually happening.** Your Book3 Ultra has four amplifiers
> the codec talks to indirectly: `0x38`/`0x39` are the woofers, `0x3c`/`0x3d`
> the tweeters, with `0x38`/`0x3c` on the left and `0x39`/`0x3d` on the right.
> "No bass, distorted highs" on one side is what it sounds like when a woofer
> stops reproducing and the tweeter next to it is left carrying the whole band.
> So the suspect is `0x39`, your right woofer.
>
> The important detail is that your fault is **one-sided**. The kernel writes an
> identical sequence to left and right — same gain, same volume, same DSM
> settings, the only difference being which channel each amp listens to. A
> symmetric sequence can't produce a one-sided fault, so this is not the kernel
> tuning being wrong for your model. It's either a host-side setting, an init
> that didn't land on that one amp, or the driver itself.
>
> Four tests, cheapest first. 1 and 2 need no tools at all.
>
> **1. Rule out clipping.** Distortion on one side can just be the signal
> clipping. Turn off any EasyEffects/PulseEffects profile, set the volume to
> about 40%, check the balance isn't skewed (`wpctl get-volume
> @DEFAULT_AUDIO_SINK@`, and `alsamixer` → F6 → the sof-hda-dsp card), then
> listen again. If it cleans up, that's your answer.
>
> **2. Isolate the woofer band.** With nothing plugged into the headphone jack:
>
> ```bash
> speaker-test -D plughw:0,0 -c 2 -t sine -f 120  -l 2   # woofer band
> speaker-test -D plughw:0,0 -c 2 -t sine -f 4000 -l 2   # tweeter band
> ```
>
> Each alternates left then right. The question is whether the 120 Hz tone is
> present and clean on the left but absent, weak or buzzing on the right. If so,
> the right woofer is the whole story and tests 3 and 4 tell us whether it's
> software.
>
> **3. Confirm the kernel really initialised all four amps.** It logs this, but
> only with debug output on. Add to `/etc/default/grub`:
>
> ```
> GRUB_CMDLINE_LINUX_DEFAULT="... snd_hda_codec_alc269.dyndbg=+p"
> ```
>
> then `sudo update-grub && sudo reboot`, and:
>
> ```bash
> sudo dmesg | grep alc298_samsung_v2
> ```
>
> You should see `Initialized speaker amp` for `0x38`, `0x39`, `0x3c` and `0x3d`.
> If `0x39` is missing or the list is short, we have a concrete bug to chase.
>
> **4. Mute one amp at a time.** This tells us which physical driver is making
> the noise. Install `alsa-tools` (`sudo apt install alsa-tools`), then
> `sudo -i` and paste:
>
> ```bash
> DEV=/dev/snd/hwC0D0
> hv(){ hda-verb $DEV 0x20 "$@" >/dev/null; }
> coef(){ hv 0x500 $1
>         hv $(printf '0x%x' $((0x400|(($2>>8)&0xff)))) $(printf '0x%x' $(($2&0xff))); }
> pack(){ coef 0x23 $1; coef 0x25 $2; coef 0x26 0xb011; }
> sel(){ coef 0x22 $1; }
> ampoff(){ sel $1; pack 0x23ff 0x0000; pack 0x203a 0x0080; }
> ampon(){  sel $1; pack 0x203a 0x0081; pack 0x23ff 0x0001; }
> ```
>
> These are the exact enable/disable sequences the kernel itself runs every time
> a stream opens and closes, so nothing here is more dangerous than pressing
> play. **Keep audio playing the whole time** — the kernel re-enables all four
> amps on stream open, so start the tone first:
>
> ```bash
> speaker-test -D plughw:0,0 -c 2 -t sine -f 300 &
> sleep 2
> ampoff 0x3d      # right tweeter — listen for a few L/R cycles
> ampon  0x3d
> ampoff 0x39      # right woofer  — listen again
> ampon  0x39
> kill %1
> ```
>
> What we learn:
>
> | Result | Meaning |
> | --- | --- |
> | muting `0x3d` makes the right channel go silent | the tweeter is the only right-side driver producing anything — `0x39` is dead |
> | muting `0x39` audibly thins the right channel | the woofer *is* being driven, so it's a tuning/DSM problem, not a dead amp |
> | muting `0x3d` kills the distortion but bass returns | the tweeter is the faulty part, not the woofer |
>
> And if you can boot Windows on this machine even once: does the right channel
> sound correct there? That single answer separates "Linux isn't initialising
> this amp" from "the driver or its wiring has failed", and it would save us both
> a lot of guessing.
>
> Post whatever you get from 2, 3 and 4 and I'll take it from there. One
> housekeeping note: your problem is genuinely different from the one this issue
> was opened for — his codec doesn't appear at all, yours works and one amp
> misbehaves — so it's worth opening a separate issue for yours so the two
> don't tangle. Link it here and I'll cross-reference.

## Reply to @flasheyy-26 — POSTED

Posted verbatim as
[comment-5707103265](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/61#issuecomment-5707103265).

> @flasheyy-26 — the comment above is worth your attention. Giulio has the same
> NP960XFH, the same `144d:c1cc`, the same 7.0.0-22 kernel, and his ALC298 shows
> up on the HDA bus normally. That rules out the possibility I raised earlier
> that this is a model-wide enumeration problem: on identical hardware, Linux
> finds the codec.
>
> Which points the investigation back at your specific unit. Two things would
> help:
>
> 1. **Your BIOS version** — `sudo dmidecode -s bios-version`. Giulio is on
>   `P07ALQ`. Firmware is now the one variable we can compare directly between
>   two otherwise identical machines, so a mismatch there is worth knowing.
> 2. **The speaker replacement.** Did the audio stop before or after that work?
>   On these chassis the analog audio path runs through connectors that are easy
>   to leave unseated, and a codec that doesn't respond at all is more consistent
>   with that than with anything in software. If you can get into Windows or even
>   just the BIOS setup screen, do you get any sound there?

---

# Round 2 — it is the right *tweeter*, and round 1's suspect was wrong

[@GiulioMicheletti ran all four tests](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/61#issuecomment-5716787172)
and the result inverts round 1. Round 1 named `0x39` (right woofer) as the
suspect on the reasoning that "no bass + distorted highs" means a dead woofer
with the tweeter carrying the band. Wrong. His isolation test has `0x39` playing
the right channel **cleanly on its own**, and the buzzing disappearing the moment
`0x3d` is muted. The right woofer is fine; **the right tweeter is the fault.**

What he measured:

| Test | Result |
| --- | --- |
| dyndbg amp init | all four — `0x38`, `0x39`, `0x3c`, `0x3d` — `Initialized speaker amp` |
| mute `0x3d`, music playing | distortion gone; `0x39` alone plays the right channel clean |
| mute `0x39`, keep `0x3d` | low/mid through `0x3d` → heavy scratching/buzzing |
| 120 Hz sine | left clean; right heavy buzzing/rattling |
| 4000 Hz sine | **both sides clean** |
| 500→2000 Hz sweep | severe rattle below ~1600 Hz; stops at ~1620–1630 Hz; above that clean but `0x3d` noticeably quieter than `0x3c` |

## The software is symmetric — verified register by register

Re-reading `alc298_samsung_v2_amp_desc_tbl[]` (`alc269.c:1709`) for the two
tweeters: the configuration written to `0x3c` and `0x3d` is **byte-identical**
across all fifteen writes except the channel-select group. Specifically
`0x203d SPK_GAIN = 0x05` and `0x23ba DSM_VOL_CTRL = 0x8d` on both (register
names confirmed against upstream `sound/soc/codecs/max98390.h`:
`MAX98390_R203D_SPK_GAIN`, `DSM_VOL_CTRL`).

And no DSM filter blob is loaded on **either** tweeter. This path writes 15
individual registers; nothing in the `0x2101`–`0x228F` coefficient range that
`docs/triage/issue-93-findings.md` identified as the actual crossover. `0x2050`
is written once as `MAX98390_PWR_GATE_CTL` (upstream `max98390.h:79`), not as a
913-byte blob start — `speaker-fix/`'s `MAX98390_DSM_START_ADDR 0x2050` is the
same address used as a bulk-write origin, which is a separate thing.

The decisive comparison is not left-vs-right, though. **`0x39` and `0x3d` both
carry `0x2021 PCM_CH_SRC_1 = 1`** — they receive the same signal. One reproduces
it cleanly, the other rattles. Identical configuration, identical input,
different behaviour: the difference is physical.

## The ~1620 Hz number is the tweeter's resonance

Below resonance a driver sits at maximum excursion for a given drive voltage;
above it, excursion falls off steeply. A defect that only shows where excursion
peaks — a rubbing voice coil, a torn or partly detached diaphragm — buzzes below
Fs and goes quiet above it. That is exactly the shape of his sweep, and ~1620 Hz
is a plausible Fs for a laptop micro-tweeter.

Two details corroborate:

- The ~0.5 s transient buzz at the threshold is the tone's onset still exciting
  the resonance before it decays.
- **`0x3d` is quieter than `0x3c` above 1630 Hz at identical `SPK_GAIN` and
  `DSM_VOL_CTRL`.** It cannot be a gain difference — the register values are the
  same. Reduced output at identical drive is what partial voice-coil damage
  looks like.

## The counter-hypothesis that is still live

Linux loads no crossover on this path, so both tweeters run full-range on the
amp's power-on defaults. Windows very likely high-passes them in its DSP. If so,
on Linux both tweeters are fed bass, the left tolerates it and the right does
not — making `0x3d` *marginal* rather than broken, and making a Linux-side
crossover a real fix rather than a non-issue.

This matters beyond one machine: if it holds, every V2_4 Samsung on Linux is
feeding its tweeters full-range, which is a slow-damage mechanism, not just a
fidelity gap. Unproven — do not act on it before the tests below come back.

Two tests discriminate, and they went out in the round 2 reply:

**A. Channel swap** (Linux-only, safe, two writes). `chan(){ sel $1; pack 0x2021 $2; }`,
then mute the woofers, set `0x3c` to channel 1 and `0x3d` to channel 0. With
`speaker-test` alternating, the *left* burst now drives `0x3d` and the *right*
burst drives `0x3c`. Buzz follows `0x3d` → the fault is that amp/driver. Buzz
stays on the right burst → something upstream feeds the right side differently.
Helper dry-run verified against a recording stub: emits select-amp then
`pack {0x2021, val}`, matching the init path's own write.

**B. Windows.** Rattles there too → hardware, repair not patch. Clean there →
Windows filters where we do not, and it becomes ours to fix.

## Practical note that saves the reporter a wasted afternoon

Muting `0x3d` does not persist. `alc298_samsung_v2_init_amps()` registers
`spec->gen.pcm_playback_hook = alc298_samsung_v2_playback_hook`, and that hook
calls `alc298_samsung_v2_enable_amps()` on every `HDA_GEN_PCM_ACT_OPEN`, which
loops all four amps. So a hand mute survives only until the next application
opens a stream. There is no simple boot-time way to hold one amp down.

The one persistent lever is the 2-amp fixup: `num_speaker_amps = 2` means the
enable loop never reaches `0x3c`/`0x3d`, so neither tweeter is ever enabled.
Clean, but dull on both sides. Needs the legacy HDA path because `model=` is a
`snd-hda-intel` parameter and he is on SOF — and he has already confirmed
`dsp_driver=1` behaves identically on his machine. Offered as an untested
experiment, labelled as such:

```
options snd-intel-dspcfg dsp_driver=1
options snd-hda-intel model=alc298-samsung-amp-v2-2-amps
```

Model string verified against `alc269.c:7365`.

## If the counter-hypothesis wins

The avenue would be pushing a real high-pass tuning into the tweeter amps
through the same COEF pack path — `speaker-fix/src/max98390_hda_filters.c`
already carries a 913-byte tweeter blob. 913 packs is ~5,500 `hda-verb`
invocations, and per [[issue-93]] the blob-to-speaker assignment is itself under
suspicion, so this is speculative and needs care. Not to be attempted before
test B says Windows is clean.

## Aside, noted not acted on

Upstream names `0x239e` as `THERMAL_COILTEMP_RD_BACK_BYTE1` (`max98390.h:564`).
That is the address `speaker-fix-940xfg/alc298-amp-init.sh` writes `0x0004` to as
its "SKU-specific enable delta". It is confirmed working on #44 so nothing should
change on that basis alone, but the naming is worth understanding before that
sequence is reused anywhere else.

## Round 2 reply — POSTED

Posted verbatim as
[comment-5717005002](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/61#issuecomment-5717005002).

> Thanks — this is the kind of testing that actually settles things, and it turns my last answer on its head.
>
> I said the suspect was `0x39`, your right woofer. That was wrong. Your isolation test has `0x39` playing the right channel cleanly on its own, and the buzzing vanishing the moment you mute `0x3d`. The right woofer is fine. **It's the right tweeter.**
>
> ## What your data proves
>
> I went back through the V2_4 table the kernel applies. The configuration written to `0x3c` and `0x3d` is **byte-identical** — the same fifteen register writes, the same `0x203d SPK_GAIN = 0x05`, the same `0x23ba DSM_VOL_CTRL = 0x8d`. No DSM filter blob is loaded on either one; this path writes a handful of individual registers, not the 913-byte tuning blob the Book4/Book5 package pushes over I2C. The only thing that differs between the two tweeters is `0x2021 PCM_CH_SRC_1`, which picks the channel.
>
> And here's the part that does the real work: **`0x39` and `0x3d` both have `0x2021 = 1`.** They receive the same signal. One reproduces it cleanly, the other rattles.
>
> Identical configuration, identical input, different behaviour. That difference has to be physical.
>
> Your sweep then says what kind of physical:
>
> - **Rattle below ~1620 Hz, clean above.** Below its resonance a driver sits at maximum excursion for a given drive voltage; above resonance, excursion falls off steeply. ~1620 Hz is very likely that tweeter's resonant frequency — and a defect that only shows where excursion peaks is the classic signature of a rubbing voice coil or a torn/partly detached diaphragm.
> - **The ~0.5 s transient buzz right at the threshold** — the onset of the tone still excites the resonance, then it decays. Fits.
> - **Quieter than `0x3c` above 1630 Hz.** This is the one I find most telling. `SPK_GAIN` and `DSM_VOL_CTRL` are the *same register values* on both tweeters, so it cannot be a gain difference. Reduced output at identical drive is what partial voice-coil damage looks like.
>
> ## The honest counter-argument
>
> Linux loads no crossover here — both tweeters run full-range on the amplifier's power-on defaults. Windows almost certainly high-passes them in its DSP. If that's the case, then on Linux both your tweeters are being fed bass, your left one tolerates it and your right one doesn't — which would make the right tweeter *marginal* rather than broken, and would mean a Linux-side crossover could rescue it.
>
> That's the difference between "your hardware needs repair" and "our software has a gap", so it's worth two more tests.
>
> ## Test A — swap the channels
>
> Safe, two extra writes, and it separates "the signal reaching the right side is different" from "the hardware on the right side is different". Add one helper to the set you already have:
>
> ```bash
> chan(){ sel $1; pack 0x2021 $2; }   # 0x0000 = left channel, 0x0001 = right
> ```
>
> Start the audio *first* — the kernel re-enables all four amps whenever a stream opens, so anything you mute beforehand gets undone:
>
> ```bash
> speaker-test -D plughw:0,0 -c 2 -t sine -f 120 &
> sleep 2
> ampoff 0x38; ampoff 0x39        # woofers out of the way, tweeters only
> chan 0x3c 0x0001                # left tweeter now plays the RIGHT channel
> chan 0x3d 0x0000                # right tweeter now plays the LEFT channel
> ```
>
> `speaker-test` alternates left burst, then right burst. With the swap in place the **left** burst drives `0x3d` and the **right** burst drives `0x3c`. So:
>
> - buzz now on the **left** burst → it followed `0x3d`, and the fault is that amp/driver
> - buzz still on the **right** burst → it stayed with the channel, and something upstream is feeding the right side differently
>
> If `plughw:0,0` reports the device busy, `-D default` is fine — we're only comparing within one run. To undo: `chan 0x3c 0x0000; chan 0x3d 0x0001`, or just reboot.
>
> ## Test B — Windows, if you still have it
>
> Does the right side rattle on bass-heavy material there? Rattles too → hardware, and it's a repair/warranty conversation rather than a patch. Clean in Windows → Windows is filtering where we aren't, and it becomes our problem to fix.
>
> ## One thing that will save you an afternoon
>
> Muting `0x3d` by hand won't stick. The kernel registers a playback hook that re-enables **all four** amps every time a PCM stream opens, so your mute survives only until the next app starts audio. There's no simple boot-time way to hold one amp down.
>
> The one persistent lever is to have the kernel bring up only two amps instead of four, which leaves both tweeters out of the picture entirely — no buzz, but duller on both sides, since you'd lose all treble rather than just the right. It needs the legacy HDA path, because `model=` is a `snd-hda-intel` parameter and you're on SOF:
>
> ```
> # /etc/modprobe.d/alc298-2amp.conf
> options snd-intel-dspcfg dsp_driver=1
> options snd-hda-intel model=alc298-samsung-amp-v2-2-amps
> ```
>
> I haven't tested that combination, so treat it as an experiment — but you've already confirmed `dsp_driver=1` behaves the same on your machine, and if it works it's a usable stopgap. Worth knowing either way.
>
> ## Where this goes
>
> If test A says the fault follows `0x3d` and Windows rattles too, I'd call it a damaged tweeter and stop there — that's a repair, not something we can patch around.
>
> If Windows is clean, that's a lot more interesting. It would mean we're feeding the tweeters full-range where Windows doesn't, and the next thing to try would be pushing a proper high-pass tuning into the tweeter amps through the same COEF path you've been using. That's new ground and I'd want to be careful with it, but your testing has got us close enough that it's a real option.
>
> Either way — thank you for the sweep. The frequency threshold is what made this diagnosable at all.

**Recommendation: keep #61 open.** Still no release cut — nothing here changes
shipped code, and the 940XFG mute fix (`3b966ef`) is already on `main`, which is
what the installers pull.
