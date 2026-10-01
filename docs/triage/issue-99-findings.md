# Issue #99 — "Internal speakers: only left channel plays (right-side MAX98390 amps probe successfully but produce no audio)" (@Bruzado1975)

**Classification: undiagnosed, one-sided fault below the host mixer. Not yet
attributable to this driver, and no code change is justified yet.**
The driver configures the left and right amps identically apart from one
register, so a *driver* explanation needs evidence we don't have yet. The plan
below is built to get that evidence in one round.

Hardware (as reported): Galaxy Book4 360 Pro (see [identity](#identity-is-not-yet-pinned-down)),
Fedora Workstation (fresh install), kernel `7.2.6-200.fc44.x86_64`, Secure Boot
**off**, card `sof-hda-dsp` with Realtek ALC298, 4x MAX98390 at
`0x38`/`0x39`/`0x3c`/`0x3d` on **I2C bus 2**.

**Status:** round-1 reply posted 2026-09-27 as
[comment-5863742135](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/99#issuecomment-5863742135)
(see [Reply posted](#reply-posted)). Round-2 reply posted 2026-09-28 as
[comment-5874275777](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/99#issuecomment-5874275777)
(see [Round 2 reply posted](#round-2-reply-posted)). Round-3 reply posted
2026-09-30 as
[comment-5920907688](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/99#issuecomment-5920907688)
(see [Round 3](#round-3): Windows plays both sides, so H3 is ruled out). No
driver code changed. Issue stays **open**; the reporter is back on Windows and
will redo the tests on a Fedora dual-boot over the school holidays.

---

## What the report establishes, and what it doesn't

| Claim in the report | Holds? | Why |
| --- | --- | --- |
| All four amps probe | **Yes** | Four `MAX98390 HDA I2C probe` lines. No `probe with driver max98390-hda failed` line, which a failing `max98390_hda_probe()` would log and which their `grep -i max98390` would have caught. So on all four, the `REV_ID` read and the `SOFTWARE_RESET` write (the only checked accesses, `max98390_hda.c:94-101`) succeeded. |
| Modules load cleanly | **Yes** | Secure Boot is off, so the #48 failure mode (key rejected at load) can't apply. See [#48](#issue-48-is-not-a-precedent). |
| Host mixer is balanced | **Yes, for ALSA** | `Master 100<>100`, `Speaker 35<>35`, unmuted. |
| `speaker-test -c2` on `default` bypasses PipeWire | **No** | On stock Fedora Workstation, `pipewire-alsa`'s `99-pipewire-default.conf` makes ALSA `default` the PipeWire plugin. That test still went through PipeWire. The card's "confirmed below PipeWire" isn't established yet. It's cheap to fix: step 2 of the plan. |
| Headphones in full stereo prove the codec sends correct stereo to the amps | **No** | They prove the HDA stream reaching the ALC298 carries both channels, and that the codec's analog headphone path plays both. The amps are fed from the codec's amp-facing digital output (the link from the codec to the amps), which the headphone path doesn't use. Stereo headphones can't rule out a missing right channel on that link. |

### Timing in their dmesg says the right amps' init ran to completion

`max98390-hda-i2c-setup.sh` creates each device through sysfs `new_device`. Probe
runs synchronously inside that write, so the "Instantiated" line comes after
probe (and so after the whole `max98390_hda_init()`) has returned:

| Amp | probe line | "Instantiated" line | init took |
| --- | --- | --- | --- |
| `0x39` (right woofer, silent) | 6.092518 | 6.348573 | **256 ms** |
| `0x3c` (left tweeter, works) | 6.348700 | 6.593281 | **245 ms** |
| `0x3d` (right tweeter, silent) | 6.593456 | 6.836576 | **243 ms** |

Init is two `msleep()`s (70 ms) plus about 930 single-byte register writes
(14 setup writes, `0x2021`, the 913-byte DSM blob, `DSM_VOL_CTRL`, three
enables). A device that NAKed would fail each write within one address byte,
and init would finish close to the 70 ms of sleeps. The silent `0x39`/`0x3d`
took as long as the working `0x3c`. That is **consistent with every write being
ACKed**, but it isn't proof that each write took effect. The read-back in step 3
is the proof.

`0x3c` also shows the **manual instantiation path is fine**. It was created by
the same script, in the same loop, between `0x39` and `0x3d`, and it plays.

## What differs between left and right in the software

Verified against the source, not re-derived:

- `max98390_hda_init()` (`speaker-fix/src/max98390_hda.c:88-137`) is identical
  for all four amps: `PCM_RX_EN_A=0x03`, `PCM_MODE_CFG=0xc0`,
  `PCM_MASTER_MODE=0x1c`, `PCM_CLK_SETUP=0x44`, `PCM_SR_SETUP=0x08`,
  `CLK_MON=0x6f`, `DAT_MON=0x00`, and the rest.
- `max98390_configure_filters()` (`max98390_hda_filters.c:15-51`): the
  **only** per-side write is `0x2021 PCM_CH_SRC_1` (`:47`): `0x00` for
  `0x38`/`0x3c`, `0x01` for `0x39`/`0x3d`. Blob choice and `DSM_VOL_CTRL`
  (`0x23BA`) are per *type* (woofer/tweeter), not per side.

Upstream `sound/soc/codecs/max98390.{c,h}` (torvalds master `72d3fcf8`) adds
three facts the repo didn't record:

1. **`0x2021` is the amp's "DAI Sel" mux, not a raw slot number.**
   `dai_sel_enum = SOC_ENUM_SINGLE(MAX98390_PCM_CH_SRC_1, MAX98390_PCM_RX_CH_SRC_SHIFT /* 0 */, 3, max98390_switch_text)`,
   with `max98390_switch_text[] = {"Left", "Right", "LeftRight"}`. So `0x00` =
   left, `0x01` = right, `0x02` = (L+R) mix. This is what makes the
   [swap test](#step-4--the-swap-tests-writes--only-with-nothing-playing)
   meaningful: writing `0x00` to a right amp tells it to play the left channel.
2. **The driver's "CRITICAL" PCM writes are the chip's reset defaults.**
   Upstream `max98390_reg_defaults[]` has `PCM_MODE_CFG 0xc0`, `PCM_MASTER_MODE 0x1c`,
   `PCM_CLK_SETUP 0x44`, `PCM_SR_SETUP 0x08`, which are exactly what
   `max98390_hda.c:116-119` writes straight after a software reset. So no
   part of this stack actively matches link framing: the amps sit at their
   reset default (I2S, 32-bit), and the codec side is whatever BIOS/firmware
   left it. That's also true upstream. PR #5616's `alc269.c` hunk
   (`bfa17b7`) adds only `max98390_fixup_i2c_four()` →
   `comp_generic_fixup()` (component binding), with no codec verbs or COEFs.
   PR #5616 maps the Book4 Pro 360 (NP960QGK) to SSID `0x144dc892`.
3. **The init block is upstream's `max98390_init_regs()`.** `CLK_MON 0x6f`,
   `DAT_MON 0x00`, `PWR_GATE_CTL 0x00`, `PCM_RX_EN_A 0x03`, `0x2076 0x0e`,
   `0x207c 0x46`, `0x2081 0x03` are upstream's first seven writes, verbatim.
   Enabling both RX slots on every amp and picking one with the mux is how
   upstream does it too. Not a defect.

For comparison, the kernel's own path to the same amp family on Book3 boards
(`alc298_samsung_v2_amp_desc_tbl[]`, `linux-6.17/.../alc269.c:1709`, via COEF
indirection) enables **one** RX slot per side instead (`0x201b` = `0x01` left /
`0x02` right). It is still left/right symmetric, and it doesn't write
`PCM_MODE_CFG`…`PCM_SR_SETUP` either. It also relies on reset-default framing.

**Consequence.** As in #61: identical configuration, identical input,
different behaviour = physical. Here the input is *not* shown to be identical.
`0x39` and `0x3d` share exactly one thing that `0x38`/`0x3c` don't: they
listen to channel 1 of the link. Both right amps are silent together. So the
most economical explanation is a shared cause, either the channel-1 data or a
shared right-side physical path, rather than two independent per-amp faults.

## Ruled out by symmetry, or by the report itself

- **Woofer/tweeter map inverted (the #93 hypothesis).** The blob is per type,
  so an inverted map affects both sides equally. It can't silence one side.
- **Left/right address map inverted.** Every amp still gets a channel. The
  result would be swapped stereo, not silence.
- **Manual instantiation.** `0x3c` is manually instantiated and works.
- **DSM blob corruption.** Fixed in `1194a83`, `static_assert`ed at build
  time, and per type anyway.
- **Resume/hibernate state loss (#98).** The report is from a normal boot, and
  the resume callback only re-runs the same symmetric init.

## Issue #48 is not a precedent

#48 ("fix broke on latest BIOS P10ALX", Book4 Ultra) was **not** a BIOS change
to the audio path. The BIOS update wiped the enrolled MOK, and the kernel
rejected the DKMS modules (`Loading of module with unavailable key is
rejected`). v0.3.41 fixed MOK handling, and the reporter confirmed it. It can't
apply here: Secure Boot is off, and the modules load and probe. The same
conclusion appears in `issue-61-findings.md`.

The BIOS version **is** still a plausible differential, just not via #48. It
is the one thing that can make a same-model unit's codec-side output differ,
and the repo has precedent for same-model, different-board behaviour (PR #77,
`docs/triage/pr-77-review.md`: two 960XGL boards, only one needing the 26 MHz
clock; #61: same SSID, opposite enumeration).

## Issue #98 is weaker evidence than it looks

@AhmadAli2024 has the same model on the same upstream kernel (7.2.6), and
confirmed "all your fixes work". Nobody asked them about left vs right, though,
and they didn't say. It is good evidence the driver drives a Book4 Pro 360, and
weaker evidence that every NP960QGK gets stereo. Two differentials between the
units are worth recording:

- **BIOS version.** Unknown for both.
- **Audio driver path.** #99 is on SOF (`sof-hda-dsp`). #98 is on Arch, which
  doesn't install `sof-firmware` by default (repo README), so it may be on
  legacy `snd_hda_intel`. The prior for that causing a *one-sided* fault is low
  (both paths drive the same codec with the same codec driver, and headphone
  stereo works on #99's SOF path), but it is free to record.

## Identity is not yet pinned down

"Galaxy Book4 360 Pro" is most likely the **Book4 Pro 360 (NP960QGK)**. Four
MAX98390s fit that model. The plain Book4 360 is a different machine. The
`dmidecode`, codec `Subsystem Id` and `/proc/asound/cards` output in step 1
settle it, and give SKU and BIOS in one line. PR #5616 expects SSID
`0x144dc892` for NP960QGK. A different SSID is a lead in itself.

---

## Hypotheses, ranked

Ranked by likelihood. The plan **tests** them by cost, so H5, the least
likely, is excluded first because it costs nothing.

### H1 — The codec isn't putting right-channel audio on the amp link (BIOS/codec side)

- **For:** it explains both right amps going silent together through their
  one shared input. Nothing in this package or upstream PR #5616 configures the
  ALC298's amp-facing output, so it's whatever this unit's firmware set, and
  same-model units can differ (PR #77, #61).
- **Against:** #98's same-model unit apparently has stereo. That needs a
  per-unit difference such as BIOS version. Headphone stereo doesn't count
  against it (different path).
- **Test:** swap test S2 (left amps told to play channel 1 go silent), with S1
  as corroboration.

### H2 — Link framing mismatch, so the amps find channel 1 empty

The amps sit on reset-default framing (I2S, 32-bit). If this unit's codec
frames the link differently (TDM-style short frame sync, or a different bit-clock
ratio), an amp in I2S mode can still decode the first slot while the right half
of the frame comes out empty or garbage. The symptom is the same one-sided
silence.

- **For:** neither end actively configures framing (upstream fact 2 above),
  and the symptom is exactly left works, right doesn't.
- **Against:** it needs the same per-unit codec difference as H1. A badly wrong
  bit-clock ratio might trip the enabled clock monitor (`CLK_MON=0x6f`) and
  mute **all four** amps, which isn't what's happening. That's unverified,
  since the bit meanings aren't in the upstream header.
- **Test:** the swap tests give the **same result as H1**. Telling H1 from H2
  is round 2, using the codec dump and BIOS comparison from step 1. Don't
  propose framing writes to the reporter before then.

### H3 — Physical fault on the right side (speaker assembly, cable or connector)

- **For:** nothing in software distinguishes the sides, and both right drivers
  silent at once fits one shared right-side cable or connector. Whether the
  Book4 Pro 360 has one is unknown.
- **Against:** it needs a common physical element, since two separate drivers
  failing independently at the same time is unlikely.
- **Test:** S1. The right amps, told to play the left channel, stay silent
  while step 3 shows them enabled with no fault flags that differ from their
  left partners. Windows (step 5) corroborates. Also ask: has the bottom cover
  been off, for example for an SSD swap before the "fresh install"?

### H4 — The right amps aren't in the state the driver wrote (partial init, latched protection)

- **For:** every write after the software reset ignores its return value (see
  [source gap](#source-level-gap-found-not-the-cause)). A failed write would
  leave no trace in dmesg.
- **Against:** it needs `0x39` **and** `0x3d` to fail while `0x3c`, initialised
  between them over the same path, succeeded. Init timing is identical for all
  three, and there are no probe errors.
- **Test:** step 3 read-back (pair-wise mismatch), and S0 (re-enable only).

### H5 — Host-side channel volume (PipeWire), not the hardware

- **For:** the reporter's "raw ALSA" test actually ran through PipeWire (see
  table above). PipeWire keeps per-route volume, so the Speaker route and the
  Headphones route can differ.
- **Against:** the ALSA hardware mixer is balanced, and it's a fresh install.
- **Test:** step 2, `speaker-test` on `plughw` with PipeWire idle.

---

## Diagnostic plan for the reporter

Everything before step 4 is **read-only**. Step 4 writes amp registers and has
its own safety rules. Don't hand over step 4 without them.

### Step 0 — confirm the bus (read-only)

Their dmesg already shows bus 2 (`i2c i2c-2: new_device`, and the `2-0039`
prefix). Confirm without scanning the bus:

```bash
ls /sys/bus/i2c/devices/ | grep -E '^[0-9]+-003[89cd]$|MAX98390'
# expect 2-0039 2-003c 2-003d and i2c-MAX98390:00; the number before the dash is the bus
i2cdetect -l | grep -E '^i2c-2\b'
```

Deliberately **not** `i2cdetect -y 2`, which #93 used. It probes every unbound
address on the bus, and the sysfs listing gives the same answer without that
traffic.

### Step 1 — identity and codec state (read-only)

```bash
cat /proc/asound/cards                     # longname = vendor-product-BIOS-SKU in one line
sudo dmidecode -s system-product-name
sudo dmidecode -s system-sku-number
sudo dmidecode -s bios-version
sudo dmidecode -s bios-release-date
grep -m1 'Subsystem Id' /proc/asound/card*/codec#0     # NP960QGK expected 0x144dc892
sudo dmesg | grep -iE 'picked fixup|max98390|component bound'
ls /etc/modprobe.d/ | grep -iE 'dsp|sof'   # was mic-fix (dsp_driver=3) installed?
```

Full codec state, attached as a file:

```bash
alsa-info.sh --no-upload       # prints the path of the file it writes
# if alsa-info.sh isn't available:
cat /proc/asound/card*/codec#0 > codec0.txt
```

If `dmesg` shows `MAX98390 HDA component bound`, the playback hook is live on
this machine (`max98390_hda.c:62`), which the README says never happens. Note
it, because the hook also writes `0x203A`/`0x23FF` on stream open/close.

### Step 2 — rule out PipeWire (no register access)

Close anything that plays audio and wait ~10 s for PipeWire to release the
device, then:

```bash
aplay -l                                            # find the sof-hda-dsp card, device 0 (HDA Analog)
speaker-test -D plughw:sofhdadsp,0 -c 2 -t wav -l 1   # says "Front Left", then "Front Right"
```

`sofhdadsp` is the card ID `aplay -l` shows in brackets for `sof-hda-dsp`. If
it differs on their machine, substitute it in every `speaker-test` line below.

If `plughw` reports the device busy, something is still holding it. Wait and
retry rather than falling back to `default`, which is the point of this test.
If "Front Right" comes out of the right speakers here, it's H5: stop and look
at `pactl list sinks` for the Speaker route's channel volumes.

### Step 3 — register read-back (read-only)

Helpers, pasted once per terminal (`sudo -v` first, so the password prompt
doesn't land mid-table). `-f` is needed because the driver owns the devices.
It's safe here because after probe the driver does no I2C traffic at all: the
playback hook never fires (README "Power Management"), there's no runtime PM,
and only resume or remove touch the amps.

```bash
BUS=2        # from step 0
rd(){ sudo i2ctransfer -y -f "$BUS" w2@"$1" $(printf '0x%02x 0x%02x' $(( $2 >> 8 )) $(( $2 & 0xff ))) r1; }
wr(){ sudo i2ctransfer -y -f "$BUS" w3@"$1" $(printf '0x%02x 0x%02x' $(( $2 >> 8 )) $(( $2 & 0xff ))) "$3"; }
table(){ printf '%-8s %-6s %-6s %-6s %-6s\n' reg 0x38 0x39 0x3c 0x3d
         for r in "$@"; do printf '%-8s' "$r"
           for a in 0x38 0x39 0x3c 0x3d; do printf ' %-6s' "$(rd $a $r)"; done; echo; done; }
idle(){ s=$(cat /proc/asound/card*/pcm*p/sub*/status 2>/dev/null)
        if [ -z "$s" ] || grep -qv '^closed$' <<<"$s"; then
          echo 'NOT IDLE - audio is still open. Stop it, wait 10 s, retry.'; return 1; fi
        echo 'idle - OK'; }
chan(){ wr $1 0x23ff 0x00 && wr $1 0x203a 0x80 &&
        wr $1 0x2021 $2 &&
        wr $1 0x203a 0x81 && wr $1 0x23ff 0x01 &&
        echo "$1 0x2021 now $(rd $1 0x2021)"; }
```

**3a. Configuration, with nothing playing:**

```bash
table 0x2021 0x201b 0x2024 0x2025 0x2026 0x2027 0x2012 0x2014 \
      0x203a 0x23e1 0x23ff 0x23ba 0x23e0 0x2039 0x203c 0x203d 0x24ff
```

Expected, from source:

| reg | name | `0x38` | `0x39` | `0x3c` | `0x3d` | source |
| --- | --- | --- | --- | --- | --- | --- |
| `0x2021` | PCM_CH_SRC_1 (DAI Sel) | `0x00` | `0x01` | `0x00` | `0x01` | `max98390_hda_filters.c:47` |
| `0x201b` | PCM_RX_EN_A | `0x03` | `0x03` | `0x03` | `0x03` | `max98390_hda.c:109` |
| `0x2024`–`0x2027` | PCM mode/master/clk/sr | `c0 1c 44 08` | `c0 1c 44 08` | `c0 1c 44 08` | `c0 1c 44 08` | `max98390_hda.c:116-119` (= reset defaults) |
| `0x2012` | CLK_MON | `0x6f` | `0x6f` | `0x6f` | `0x6f` | `max98390_hda.c:106` |
| `0x2014` | DAT_MON | `0x00` | `0x00` | `0x00` | `0x00` | `max98390_hda.c:107` |
| `0x203a` | AMP_EN | `0x81` | `0x81` | `0x81` | `0x81` | `max98390_hda_filters.c:222` |
| `0x23e1` | DSP_GLOBAL_EN | `0x01` | `0x01` | `0x01` | `0x01` | `max98390_hda_filters.c:219` |
| `0x23ff` | GLOBAL_EN | `0x01` | `0x01` | `0x01` | `0x01` | `max98390_hda_filters.c:225` |
| `0x23ba` | DSM_VOL_CTRL | `0xa0` | `0xa0` | `0x8d` | `0x8d` | `max98390_hda_filters.c:213-216` |
| `0x23e0` | DSMIG_EN (blob's last byte) | `0x21` | `0x21` | `0x20` | `0x20` | blob `:116` / `:185` |
| `0x2039`, `0x203c`, `0x203d` | AMP_DSP_CFG, SPK_SRC_SEL, SPK_GAIN | default | default | default | default | never written; must match **within each pair** |
| `0x24ff` | REV_ID | same | same | same | same | read-only chip revision |

None of these are in upstream's volatile ranges, so a read-back should equal
what was written. Some bits may still read differently from what was written,
so **the decisive comparison is pair-wise**: `0x38` vs `0x39` (woofers) and
`0x3c` vs `0x3d` (tweeters). The only allowed difference inside a pair is
`0x2021`.

**3b. Status: once idle, and once with audio playing (reads only, safe while
playing):**

```bash
table 0x2002 0x2003 0x2004 0x2005 0x2006 0x2007 0x2008 0x2009 0x200a 0x2051 0x2054 0x207b
# then, in a second terminal:  speaker-test -D plughw:sofhdadsp,0 -c 2 -t sine -f 440
# and repeat the same `table ...` line while the tone plays; Ctrl-C the tone afterwards
```

These are `INT_RAW1-3`, `INT_STATE1-3`, `INT_FLAG1-3`, `PWR_GATE_STATUS`,
`BROWNOUT_STATUS` and `ENV_TRACK_BOOST_VOUT_READ` (upstream `max98390.h`). The
upstream header gives **no bit definitions** for these, so read them
comparatively only. A right amp that differs from its left partner is the
finding, especially one whose values stay the same between idle and playing
while its partner's change.

### Step 4 — the swap tests (writes — only with nothing playing)

> **Safety rule, and any reply must carry it: never write an amp register
> while audio is playing.** In #61 a channel-select
> write on a live stream froze the reporter's codec
> (`issue-61-findings.md`, round 3). That wedge came from writes going through
> the ALC298's COEF indirection, and these writes go straight to the amp over
> host I2C and never touch the codec. So the exact mechanism can't recur, but
> we don't know how the amp's DSP reacts to its source changing mid-stream,
> and we aren't going to find out on a user's machine.

How the helpers enforce it:

- `idle` refuses unless **every** ALSA playback substream reads `closed`. It
  also refuses if it can't read any, so it fails safe. Every write line below is
  `idle && …`, so nothing is written while a stream is open.
- `chan` wraps the one real change in an amp-off / amp-on pair:
  `GLOBAL_EN=0`, `AMP_EN=0x80`, **`0x2021=<ch>`**, `AMP_EN=0x81`,
  `GLOBAL_EN=1`. That's the same order and values the driver's own init
  uses around this register every boot (`max98390_hda.c:122,128`, then
  `max98390_hda_filters.c:47,222,225`), and the same EN toggle upstream
  performs on every stream start/stop (`max98390.c:480-494`, DAPM
  `POST_PMU`/`POST_PMD`). An EN cycle preserves the configuration by design.
- Before each write: close media apps and browser tabs, and don't touch the
  volume keys (GNOME plays a feedback sound, which opens a stream).
- **Everything here is temporary.** A reboot, a module reload, or (v0.3.71+)
  suspend/resume re-runs `max98390_hda_init()` and restores the driver's
  values. The explicit revert lines are given anyway.

Dry-run verified here against a stub `i2ctransfer`: `chan 0x39 0x00` emits
`w3@0x39 0x23 0xff 0x00`, `0x20 0x3a 0x80`, `0x20 0x21 0x00`, `0x20 0x3a 0x81`,
`0x23 0xff 0x01`, then reads back `0x2021`. `idle` blocked the write when a
fake substream read `state: RUNNING`, and when the status glob matched nothing.

**S0 — control: re-enable the right amps, channel unchanged.**

```bash
idle && chan 0x39 0x01 && chan 0x3d 0x01
speaker-test -D plughw:sofhdadsp,0 -c 2 -t wav -l 1
```

If the right side now works, it was latched state that an enable cycle
clears. That's H4, and it's the result that points hardest at code (see
[below](#is-a-code-fix-justified)). Stop here and report.

**S1 — right amps play the LEFT channel.**

```bash
idle && chan 0x39 0x00 && chan 0x3d 0x00
speaker-test -D plughw:sofhdadsp,0 -c 2 -t wav -l 1     # listen: which side says "Front Left"?
idle && chan 0x39 0x01 && chan 0x3d 0x01                # revert (wait for speaker-test to finish first)
```

**S2 — left amps play the RIGHT channel.**

```bash
idle && chan 0x38 0x01 && chan 0x3c 0x01
speaker-test -D plughw:sofhdadsp,0 -c 2 -t wav -l 1     # listen: does "Front Right" come out on the left?
idle && chan 0x38 0x00 && chan 0x3c 0x00                # revert
```

S2 is the sharper of the two, because it uses the side we **know** works as
the probe. If known-good amps and speakers go silent when pointed at channel 1,
channel 1 is empty, whatever the right-side hardware is doing.

| S1: right amps on ch0 | S2: left amps on ch1 | Reading |
| --- | --- | --- |
| right side says "Front Left" | left side silent throughout | **Channel 1 is empty on the link (H1/H2).** Right amps and speakers are fine. |
| right side still silent | left side says "Front Right" | **The link carries channel 1, and the fault is on the right side (H3/H4).** Step 3 decides between amp state and the speaker/cable. |
| right side still silent | left side silent throughout | Both at once, or the writes didn't land. Check the `0x2021 now …` echoes first. |
| right side says "Front Left" | left side says "Front Right" | Both work when swapped, which contradicts the symptom. The S0 result, or the pre-test read-back of `0x2021` on `0x39`/`0x3d`, should explain it. |

### Step 5 — Windows

If Windows was ever on this machine (factory image included): did the right
speakers play there? That separates "Linux/firmware state" from "hardware" in
one answer, as it did in #61. Also ask whether the bottom cover has ever been
off.

---

## Is a code fix justified?

**No, not yet.** Nothing in the source explains a one-sided fault. The only
per-side write (`0x2021`) matches upstream's own semantics and the kernel's
Book3 table. The same model reports working, and the right amps' init ran for
the same length of time as a working amp's.

What would justify one:

| Result | Justified change |
| --- | --- |
| Step 3 shows a right amp's registers not matching its left partner, or S0 restores sound | **Driver fix:** check every write in `max98390_hda_init()` / `max98390_configure_filters()`, verify the enable registers after writing, retry or fail probe loudly. See the gap below. |
| S1 + S2 say channel 1 is empty (H1/H2) | **No amp-driver fix.** The real fix is on the codec side: find what programs the ALC298's amp-facing output. That needs step 1's codec dump and BIOS version compared against a same-model unit that has stereo. A **stopgap** is possible: an opt-in module parameter setting the right amps' `0x2021` to `0x00` (left) or all four to `0x02` (upstream's "LeftRight" mix). It must **never be the default**, because it would downmix every working stereo machine to mono, and it should only be built after S2 proves channel 1 empty. |
| S1 silent, step 3 clean, and Windows also silent on the right | **Hardware.** No code change. A repair or warranty conversation. |

## Source-level gap found (not the cause)

`max98390_hda_init()` checks only the `REV_ID` read and the `SOFTWARE_RESET`
write (`max98390_hda.c:94-101`). Every later write discards its return value:
the setup block (`:106-131`), the channel select (`max98390_hda_filters.c:47`),
the 913-byte blob loop (`:202-203`), `DSM_VOL_CTRL` and the three enables
(`:213-225`). `max98390_hda_resume()` reuses the same init. A NAK or bus error
mid-init therefore leaves an amp partly configured, possibly not enabled, and
probe (or resume) still reports success with nothing in dmesg.

This is provable from the source alone, and it's why "all four probed" can't
count as evidence that all four are configured. It isn't shown to be #99's
cause: it's symmetric, and the timing evidence argues against it here. **Not
changed in this card.** If step 3 or S0 implicates H4, a separate card should
implement write checking with a per-amp error count in the log.

## Not asked, deliberately

- **Reading ALC298 COEFs with `hda-verb`.** That would show the codec-side
  output configuration directly (H1 vs H2), but reading a COEF means *writing*
  the codec's shared COEF index register, and that's the same interface that
  wedged #61's codec. Only worth considering once S2 says channel 1 is empty,
  and then with the same idle-only discipline.
- **Framing experiments on the amps** (`PCM_MODE_CFG` to TDM, etc.). They're
  round 2 at the earliest, and only once the codec dump says what the link
  actually is.
- **Suspend/resume as a test.** It re-runs the same symmetric init, so it
  can't separate any of H1–H4.

---

## Reply posted

Posted verbatim to @Bruzado1975 on 2026-09-27 as
[comment-5863742135](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/99#issuecomment-5863742135).
Issue left **open**, with no labels and no driver change.

How it differs from the plan above:

- **Step 0 dropped.** Their dmesg already shows bus 2, so `BUS=2` is set
  directly.
- **Added `sudo dnf install i2c-tools && sudo modprobe i2c-dev`.** `i2ctransfer`
  needs `/dev/i2c-2`, and Fedora doesn't necessarily autoload `i2c-dev`.
- **Step 1 trimmed** to `dmidecode`, the codec `Subsystem Id`, the dmesg grep and
  `alsa-info.sh`.
- **#98 isn't called a stereo confirmation.** The reply says another NP960QGK
  owner on 7.2.6 has the driver working "with no left/right complaint", not
  that it plays both sides, because nobody asked #98 about left vs right (see
  [above](#issue-98-is-weaker-evidence-than-it-looks)).
- **Suspend/resume isn't given as a revert path.** Only a reboot is, because
  resume re-init needs v0.3.71+ and their install version is unknown.
- The helpers `rd`/`wr`/`table`/`idle`/`chan`, the S0/S1/S2 commands and the
  outcome table are verbatim from steps 3 and 4. `chan 0x39 0x00` was re-checked
  against a stub `i2ctransfer` before posting and emits the same five writes
  plus read-back.

> Thanks for such a thorough report. Your triage was good: you checked the mixer balance, you tested headphones and the external speakers, and you narrowed it to the right-side amps (`0x39` woofer, `0x3d` tweeter). That saved a whole round.
>
> ## What the driver does per side
>
> All four amps get the same setup. The only per-side difference is one register, `0x2021`, the amp's channel select. The left amps (`0x38`/`0x3c`) are set to PCM channel 0, and the right amps (`0x39`/`0x3d`) to channel 1. Another Book4 Pro 360 (NP960QGK) owner on the same 7.2.6 kernel has this driver working, with no left/right complaint. Both of your right amps share exactly one thing: they listen to channel 1. So the likely causes are either the codec not putting right-channel data on the link to the amps on this unit, or something physical on the right side (amps, speakers or cable). The tests below should tell us which.
>
> One small correction first. On Fedora, ALSA's `default` device *is* PipeWire (that's what `pipewire-alsa` sets up), so your `speaker-test` still went through it. The `plughw` form below really does bypass it.
>
> Everything up to step 3 only reads. Step 4 writes amp registers, so please read its note first.
>
> ## 1. Model, BIOS and codec state (read-only)
>
> ```bash
> sudo dmidecode -s system-product-name
> sudo dmidecode -s system-sku-number
> sudo dmidecode -s bios-version
> sudo dmidecode -s bios-release-date
> grep -m1 'Subsystem Id' /proc/asound/card*/codec#0
> sudo dmesg | grep -iE 'picked fixup|max98390|component bound'
> alsa-info.sh --no-upload        # attach the file it writes
> # if alsa-info.sh isn't installed:  cat /proc/asound/card*/codec#0 > codec0.txt
> ```
>
> This gives the exact model/SKU and BIOS version. A Book4 Pro 360 is expected to show `Subsystem Id: 0x144dc892`. A different value would be a lead in itself.
>
> ## 2. Speaker test that really bypasses PipeWire
>
> Close everything that plays audio, wait about 10 seconds, then:
>
> ```bash
> aplay -l                                              # sof-hda-dsp should show as [sofhdadsp]
> speaker-test -D plughw:sofhdadsp,0 -c 2 -t wav -l 1   # says "Front Left", then "Front Right"
> ```
>
> If `aplay -l` shows a different ID in brackets, use that everywhere below. If it says "device busy", wait and retry rather than falling back to `default`.
>
> - **Right speakers play "Front Right" here:** it's a PipeWire volume/route setting, not hardware. Stop and send `pactl list sinks`.
> - **Still silent on the right:** carry on.
>
> ## 3. Amp register read-back (read-only)
>
> You'll need `i2c-tools` and the `i2c-dev` module. Then paste these helpers into one terminal (run `sudo -v` first so the password prompt doesn't land mid-table):
>
> ```bash
> sudo dnf install i2c-tools && sudo modprobe i2c-dev
> sudo -v
>
> BUS=2
> rd(){ sudo i2ctransfer -y -f "$BUS" w2@"$1" $(printf '0x%02x 0x%02x' $(( $2 >> 8 )) $(( $2 & 0xff ))) r1; }
> wr(){ sudo i2ctransfer -y -f "$BUS" w3@"$1" $(printf '0x%02x 0x%02x' $(( $2 >> 8 )) $(( $2 & 0xff ))) "$3"; }
> table(){ printf '%-8s %-6s %-6s %-6s %-6s\n' reg 0x38 0x39 0x3c 0x3d
>          for r in "$@"; do printf '%-8s' "$r"
>            for a in 0x38 0x39 0x3c 0x3d; do printf ' %-6s' "$(rd $a $r)"; done; echo; done; }
> idle(){ s=$(cat /proc/asound/card*/pcm*p/sub*/status 2>/dev/null)
>         if [ -z "$s" ] || grep -qv '^closed$' <<<"$s"; then
>           echo 'NOT IDLE - audio is still open. Stop it, wait 10 s, retry.'; return 1; fi
>         echo 'idle - OK'; }
> chan(){ wr $1 0x23ff 0x00 && wr $1 0x203a 0x80 &&
>         wr $1 0x2021 $2 &&
>         wr $1 0x203a 0x81 && wr $1 0x23ff 0x01 &&
>         echo "$1 0x2021 now $(rd $1 0x2021)"; }
> ```
>
> `-f` is needed because the driver owns these devices. It's safe for reads because the driver doesn't talk to the amps after boot.
>
> **3a. Configuration**, with nothing playing:
>
> ```bash
> table 0x2021 0x201b 0x2024 0x2025 0x2026 0x2027 0x2012 0x2014 \
>       0x203a 0x23e1 0x23ff 0x23ba 0x23e0 0x2039 0x203c 0x203d 0x24ff
> ```
>
> The woofers (`0x38` vs `0x39`) should match each other, and so should the tweeters (`0x3c` vs `0x3d`). The only expected difference within a pair is `0x2021` (`0x00` left, `0x01` right). A right amp that differs from its left partner anywhere else points at the driver.
>
> **3b. Status**, once idle and once while a tone plays in a second terminal (reads are safe during playback):
>
> ```bash
> table 0x2002 0x2003 0x2004 0x2005 0x2006 0x2007 0x2008 0x2009 0x200a 0x2051 0x2054 0x207b
> # second terminal:  speaker-test -D plughw:sofhdadsp,0 -c 2 -t sine -f 440   (Ctrl-C afterwards)
> ```
>
> Please paste both tables. I can only read these comparatively, so a right amp that doesn't change between idle and playing while its left partner does would be the interesting part.
>
> ## 4. Channel-swap tests (these write registers)
>
> > ⚠️ **Only do this with nothing playing.** Close media apps and browser tabs, and don't press the volume keys (the feedback sound opens a stream). **Never write amp registers while audio is playing.** In issue #61 a similar channel-select write on a live stream froze another reporter's codec. These writes go straight to the amp rather than through the codec like that one did, but I don't know how the amp reacts to a mid-stream change, and I'd rather not find out on your machine.
> >
> > The `idle` helper refuses unless every playback stream is closed, and each write line starts with `idle &&`, so it stops rather than writes if anything is open. Every change here is **temporary**: a reboot restores the driver's settings. Revert lines are included anyway. Let each `speaker-test` finish before running the next line.
>
> **S0: re-enable the right amps, channel unchanged.**
>
> ```bash
> idle && chan 0x39 0x01 && chan 0x3d 0x01
> speaker-test -D plughw:sofhdadsp,0 -c 2 -t wav -l 1
> ```
>
> If the right side now works, stop here and tell me. That would point at the driver.
>
> **S1: right amps play the LEFT channel.**
>
> ```bash
> idle && chan 0x39 0x00 && chan 0x3d 0x00
> speaker-test -D plughw:sofhdadsp,0 -c 2 -t wav -l 1     # which side says "Front Left"?
> idle && chan 0x39 0x01 && chan 0x3d 0x01                # revert
> ```
>
> **S2: left amps play the RIGHT channel.**
>
> ```bash
> idle && chan 0x38 0x01 && chan 0x3c 0x01
> speaker-test -D plughw:sofhdadsp,0 -c 2 -t wav -l 1     # does "Front Right" come out on the left?
> idle && chan 0x38 0x00 && chan 0x3c 0x00                # revert
> ```
>
> | S1: right amps on ch 0 | S2: left amps on ch 1 | What it means |
> | --- | --- | --- |
> | right side says "Front Left" | left side silent throughout | **Channel 1 is empty on the codec→amp link.** Your right amps and speakers are fine. |
> | right side still silent | left side says "Front Right" | **Channel 1 is there. The fault is on the right side** (amp state, or speaker/cable). Step 3 decides which. |
> | right side still silent | left side silent throughout | Check the `0x2021 now …` lines first. The writes may not have landed. |
> | right side says "Front Left" | left side says "Front Right" | Contradicts the symptom. S0 or the step 3 table should explain it. |
>
> Please paste the full terminal output, including the `0x2021 now …` lines, along with what you heard.
>
> ## 5. A few questions
>
> - Exact model number/SKU and BIOS version (step 1 covers it, but a sticker or box label helps too).
> - If Windows was ever on this machine, factory image included: did the right speakers play there?
> - Has the bottom cover ever been off, for example for an SSD swap?
>
> ## Where this stands
>
> To be upfront: there's no code fix yet, because nothing in the driver treats the two sides differently apart from that channel select. What happens next depends on the results:
>
> - **Step 3 shows a right amp that doesn't match its partner, or S0 fixes it:** that's a driver bug, and I'll fix it (the init currently doesn't check most of its writes).
> - **S1 and S2 say channel 1 is empty:** the real problem is on the codec side, and your BIOS version and codec dump are what I'd compare against a working unit. An opt-in workaround (e.g. feeding the right amps the left channel) is possible, but I'd only build it after S2 proves this.
> - **S1 silent, registers clean, and Windows silent on the right too:** that's hardware, and a repair/warranty route rather than code.
>
> I'll leave the issue open until you've had a chance to run these. Thanks again!

---

## Round 2

Reporter's reply:
[comment-5873965095](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/99#issuecomment-5873965095)
(2026-09-28). Answered the same day, see [Round 2 reply posted](#round-2-reply-posted).
No driver code changed.

### What they sent

| Item | Result |
| --- | --- |
| Identity | `960QGK`, SKU `SCAI-PROT-A5A5-MTLH-PRHB`, BIOS `P15RHB.470.260103.04` (2026-01-03), codec `Subsystem Id: 0x144dc892`. That's the NP960QGK that PR #5616 expects, so [identity](#identity-is-not-yet-pinned-down) is settled. |
| dmesg | `sudo dmesg` failed (`Operation not permitted`), so only the probe/`new_device` lines came through. No `picked fixup` or `component bound` lines. Probe timing matches round 1 (about 245–265 ms per amp). |
| `alsa-info.txt` | They say it's attached, but the comment has **no attachment URL**. We don't have it. It was written to `/tmp`, which is tmpfs on Fedora, so it'll be gone after a reboot and needs regenerating. |
| Step 2 (`plughw`) | **Silent on both sides.** `plughw` was busy, so they stopped PipeWire/WirePlumber to free it. |
| Step 3a | Fully symmetric within each pair. Every value matches the expected table in step 3. Details below. |
| Step 3b | Only one table, taken **during the silent `plughw` sine test**. No idle table to compare it with. |
| Step 4 (S0/S1/S2) | Silent on both sides, every time. |
| Windows | Both sides worked. |
| History | **Both sides also worked on Fedora before.** They opened the bottom cover to clean the fans, both sides still worked after closing it, and the right side stopped "later on". |
| Their question | Could a kernel or package update be the cause, or should they open the case? |

**This contradicts round 1.** The original report said "Fedora Workstation
(fresh install)". Round 2 says the right side worked on Fedora and failed
later. The two fit together if they reinstalled Fedora *after* the fault
appeared, perhaps to try to fix it, or if "fresh install" was loose wording.
Which one matters (see [timeline](#timeline-questions)): a fault that survived
a clean reinstall can't be accumulated user config.

### Why the `plughw` test was silent on both sides

**The card's leading explanation doesn't hold up in the source.** The theory
was that stopping WirePlumber runs the UCM `DisableSequence` for the Speaker
device, which turns the codec's `Speaker Playback Switch` off, so any `plughw`
test afterwards is silent. The config half is true. The teardown half isn't.

- **The sequence exists.** This machine's alsa-ucm-conf (Ubuntu 1.2.10,
  `/usr/share/alsa/ucm2/HDA/HiFi-analog.conf:151-163`) and upstream master
  (`ucm2/HDA/HiFi-spk.conf:17-29`, where the Speaker device now lives) both
  give the Speaker device `DisableSequence [ cset "name='Speaker Playback Switch' off" ]`.
  `sof-hda-dsp` includes it via `Intel/sof-hda-dsp/HiFi.conf`.
- **Nothing runs it when PipeWire or WirePlumber stops.** In PipeWire's ACP
  (the ALSA card code WirePlumber loads for each card), `acp_card_destroy()`
  (`spa/plugins/alsa/acp/acp.c:2196-2216`, master) frees the profiles and ports,
  then calls `pa_alsa_ucm_free()` (`alsa-ucm.c:2734-2752`), which calls
  `snd_use_case_mgr_close()`. In alsa-lib that's `uc_mgr_card_close()` plus
  `uc_mgr_free()` (`src/ucm/main.c:1899-1905`), which unlink the manager from
  a list and **free** the sequences (`src/ucm/utils.c:608-620`, `829-835`)
  without executing them.
- **What does run a Speaker `DisableSequence`:** a verb change, including to
  `_verb Inactive` (profile "Off"), via `pa_alsa_ucm_set_profile()`
  (`alsa-ucm.c:1715-1774`); `_disdev` when a profile drops a mapping; and the
  verb's own `EnableSequence [ disdevall "" ]`
  (`Intel/sof-hda-dsp/HiFi.conf:5`) whenever the verb is (re)activated, at
  PipeWire startup for example, before the selected port's device is enabled
  again. None of these is a plain `systemctl --user stop`.

Confidence: **high** for PipeWire and alsa-lib master as read today. I haven't
checked Fedora 44's exact package versions, and a Fedora patch that changes
teardown can't be ruled out. It isn't likely, though. The mechanism also doesn't
fit what they saw: if stopping PipeWire leaves the mixer as PipeWire last set
it, the Speaker switch was **on** (the left side had been playing).

**So we don't know why `plughw` was silent.** Candidates, none of them tested:

1. Mixer state at test time: the Speaker or Master switch off, or a volume at
   zero. We can't check it, because no `amixer` output was captured in that
   state and the alsa-info attachment is missing.
2. PipeWire restarting between "stop" and the test (socket activation) and
   re-running `disdevall` on startup. That would normally leave `plughw` busy,
   not silent, so it's weaker.
3. Something specific to opening the PCM directly, as opposed to through PipeWire.
   Round 2's redo separates this from (1) (see step R2-2).

**Consequence for the results.** Whatever the cause, **step 2, S0, S1 and S2
are void.** A swap test uses the known-good left side as its control. When the
left side is also silent, "right silent" and "left on channel 1 silent" carry
no information. They can't be read as "channel 1 is empty" (H1) or as "right
side dead" (H3).

**Busy device matters too.** Step 2 said to wait about 10 s for PipeWire to
release the device. That they still had to stop PipeWire means PipeWire
**hadn't suspended** the sink. Either a stream was still open (a paused browser
tab, a media app, an event sound), or suspend is disabled in their config
(`session.suspend-timeout-seconds = 0` is a common anti-pop tweak). The redo
has to find out which, rather than stopping PipeWire again.

#### The redo keeps PipeWire running

The `idle` helper (step 3) reads the kernel's view directly:
`/proc/asound/card*/pcm*p/sub*/status` for every playback substream on every
card. It passes only if all of them read `closed`. It doesn't ask PipeWire
anything, so it's correct regardless of which process owned the device.

When a sink goes idle, WirePlumber sends its node a `Suspend` command after
`session.suspend-timeout-seconds`, default **5 s**, and `0` disables it.
Verified on this machine's WirePlumber 0.4.17 (`scripts/suspend-node.lua`,
`main.lua.d/50-alsa-config.lua:154`). Fedora 44 ships WirePlumber 0.5, which
keeps the same 5 s default and logic, but I only have that from memory, not
from source. The ALSA sink closes its PCM on suspend, which is the state `idle` reads.
If it didn't, `idle` would simply refuse, so the helper fails safe either way. So with PipeWire running:

- all sinks suspended → every substream `closed` → `idle` passes → `chan`
  writes are safe, and `plughw` can open the device, because nobody holds it;
- anything still open → `idle` refuses, and `plughw` would say busy. Then
  `wpctl status` (the Streams section) shows what's holding it.

Two new timing rules for the reply. After any `speaker-test` that goes
**through** PipeWire, wait 10 s or more before the next `idle && chan …` line,
because PipeWire keeps the device open for the suspend timeout after playback
ends. And the `idle` check and the writes are separate commands, so a sound
that starts in the few milliseconds between them isn't caught. The
"close everything, don't touch the volume keys" rule is what covers that gap.

### Step 3a: symmetric, so H4 is out

| reg | `0x38` | `0x39` | `0x3c` | `0x3d` | expected (step 3) |
| --- | --- | --- | --- | --- | --- |
| `0x2021` | `00` | `01` | `00` | `01` | ✓ |
| `0x201b` | `03` | `03` | `03` | `03` | ✓ |
| `0x2024`–`0x2027` | `c0 1c 44 08` | same | same | same | ✓ (reset defaults) |
| `0x2012` CLK_MON | `6f` | `6f` | `6f` | `6f` | ✓ |
| `0x2014` DAT_MON | `00` | `00` | `00` | `00` | ✓ |
| `0x203a` AMP_EN | `81` | `81` | `81` | `81` | ✓ |
| `0x23e1` / `0x23ff` | `01`/`01` | `01`/`01` | `01`/`01` | `01`/`01` | ✓ |
| `0x23ba` DSM_VOL | `a0` | `a0` | `8d` | `8d` | ✓ per type |
| `0x23e0` DSMIG_EN | `21` | `21` | `20` | `20` | ✓ per type (blob fix `1194a83` present) |
| `0x2039` / `0x203c` / `0x203d` | `0f 00 05` | same | same | same | never written, match within pairs |
| `0x24ff` REV_ID | `42` | `42` | `42` | `42` | same silicon revision |

**This rules out H4 and any driver-side asymmetry.** Both right amps hold
exactly the configuration the driver wrote, identical to their left partners
apart from the intended `0x2021`, and they're enabled (`AMP_EN`, `GLOBAL_EN`,
`DSP_GLOBAL_EN` all set). No write was lost, so the unchecked-write
[gap](#source-level-gap-found-not-the-cause) didn't bite here. A reinstall
couldn't have introduced an asymmetry either: `speaker-fix/src` has changed
twice since the initial release (`1194a83` blob fix, per type; `4bae1c2`
resume, re-runs the same init). Neither has a per-side branch, and the table
shows the resulting state is symmetric anyway.

The "latched state that an enable cycle would clear" variant of H4 was meant
to be tested by S0, which is void. It's still very unlikely: the latched
`INT_FLAG1-3` registers read zero on all four (next section), and a latch
wouldn't hit exactly the two amps that share channel 1.

### Step 3b: what `0x2006`/`0x2007` and `0x2014` can and can't say

From upstream `sound/soc/codecs/max98390.h` (torvalds master, fetched
2026-09-28): `0x2002`–`0x2004` = `INT_RAW1-3`, `0x2005`–`0x2007` =
`INT_STATE1-3`, `0x2008`–`0x200a` = `INT_FLAG1-3` (each with its own
`INT_FLAG_CLR1-3` at `0x200e`–`0x2010`), `0x2051` = `PWR_GATE_STATUS`,
`0x2054` = `BROWNOUT_STATUS`, `0x207b` = `ENV_TRACK_BOOST_VOUT_READ`. The repo
header (`speaker-fix/src/max98390_regs.h`) names none of these.

- **`0x2006` = `INT_STATE2` = `0x18` (bits 3 and 4), `0x2007` = `INT_STATE3`
  = `0x0f` (bits 0–3). I can't decode these bits.** Neither the upstream
  header nor the upstream driver defines bit fields for any `INT_*` register
  (the driver never reads them). The Analog/Maxim datasheet wasn't reachable
  from here. Any decoding would be a guess, and it would go into a reply as
  fact, so there's none here.
- **What they do say: they're identical on all four amps, including the two
  known-good left amps.** Whatever they encode, it doesn't separate the silent
  side from the working side.
- **They can't show whether the amps see clocks or data.** The table was taken
  during a test in which all four amps were silent. The idle table asked for
  in 3b wasn't sent, so there's no idle-vs-playing delta, which was the only
  way we'd planned to read these registers. And the four amps share the same
  link clocks, so no clock-derived bit could differ by side anyway.
- **`INT_FLAG1-3` = `0x00` on all four.** Going by the naming (flag registers
  with separate clear registers, the latched-flag pattern), there are no
  latched fault events on any amp. `PWR_GATE_STATUS`, `BROWNOUT_STATUS` and
  the boost VOUT read-back are also zero on all four.
- **`0x2014` DAT_MON = `0x00` at idle** is a **configuration** register, not
  a status one. Upstream's reset default is `0x03`
  (`max98390.c` `max98390_reg_defaults[]`), and both upstream's
  `max98390_init_regs()` (`max98390.c:853`) and ours (`max98390_hda.c:107`)
  write `0x00`. Reading `0x00` only confirms that write landed. It says
  nothing about data arriving. The bit meanings aren't in the header. By name
  and default it's the data monitor, and writing `0x00` most likely **disables**
  it (inference, not verified). If so, it has a consequence: an amp whose slot
  carries silence, or nothing at all, raises no flag and just plays silence.
  So **clean status registers on the right amps are expected under H1** and
  can't count against it.

### Hypotheses, re-ranked

| | Round 1 | Round 2 | Why |
| --- | --- | --- | --- |
| **H4** partial init / driver state | 4th | **Ruled out** | 3a table (above). |
| **H3** right-side physical (cable, connector, speaker) | 3rd | **Joint lead** | Worked in Windows, worked on Fedora, cover opened for fan cleaning, failed *later*. A connector or flex cable that's disturbed but not fully out can keep contact for a while and then drop with heat cycles or with the chassis flexing (it's a 360 convertible, so hinge and lid movement flexes it). Both right drivers going silent together needs one shared right-side element. Whether this chassis has one isn't known. |
| **H1** channel 1 empty on the codec→amp link | 1st | **Joint lead** | Still the only software mechanism that silences both right amps at once. Any *software regression* has to act through H1 (or H5), because the amps are provably configured correctly. |
| **H5** PipeWire per-channel volume / route state | 5th | **Moved up, still cheap to exclude** | The main argument against it was "fresh install", and round 2 contradicts that. A per-route balance or channel volume stored in `~/.local/state/wireplumber/` is exactly the kind of change that happens "later" and survives reboots and kernel updates. The balanced ALSA mixer in round 1 (`Speaker 35<>35`) argues against it, but not conclusively: when PipeWire's hardware volume hits its floor it applies the rest in software, and that part isn't visible in `amixer`. |
| **H2** framing mismatch | 2nd | **Folded into H1** | It needs a per-unit codec difference to exist, and it did stereo on this same unit before. Only worth separating if S2 says channel 1 is empty. |

#### Software regression vs. physical (H1-by-update vs. H3)

The reporter leans towards a kernel or package update. What's actually known:

- **It can't be the amp driver.** See the 3a table, and the source hasn't
  changed per side.
- **The upstream kernel has no quirk for this machine.** torvalds master
  `sound/hda/codecs/realtek/alc269.c` (fetched 2026-09-28) has no
  `SND_PCI_QUIRK(0x144d, 0xc892, …)`, so no SSID-specific codec fixup was
  added or changed for NP960QGK in a kernel update. A regression would have to
  be a generic ALC298/HDA change, or a Fedora-only patch. That's possible, but
  a generic change that drops only the amp link's right slot, on one unit,
  while headphones keep stereo, is a narrow target.
- **SOF firmware/topology** feeds headphones and speakers through the same PCM.
  Headphone stereo still works, so an SOF regression is unlikely.
- **BIOS** is the one thing we know programs the ALC298's amp-facing output
  (round 1, fact 2). Their BIOS is dated 2026-01-03. Whether it was updated
  near when the fault started is an open question.

What would separate them:

| Evidence | Points to |
| --- | --- |
| Started right after a specific update or reboot, and is **constant** since | Software regression (H1 via codec config, or H5). **Booting the previous kernel from GRUB** (Fedora keeps 3) is the cheap test, if `dkms status` shows `max98390-hda` built for it. If the right side comes back there, it's the kernel. |
| **Intermittent**: comes and goes, changes with lid/hinge position, warmth, or a tap near the right speaker | H3 (marginal connector). A software regression doesn't care about hinge angle. |
| Constant, survives the older kernel, survived a clean reinstall | H3 or BIOS. The redone S2 decides which. |
| Redone S2: left amps on channel 1 **play "Front Right"** | Channel 1 is on the link. The fault is on the right side, **after** the amps' input: H3. |
| Redone S2: left amps on channel 1 **silent** | Channel 1 is empty: H1 (or H5, which is why `pactl` comes first). Physical checks won't help. |

None of this is decided yet, and the reply shouldn't lean either way. Their
own reasoning ("it worked after I closed it") is fair, but it's only weak
evidence against H3: marginal contacts often fail later, not straight away.

### Host-side codec check we haven't done yet

Every HDA widget (DAC, mixer, pin) can have its own output and input
amplifier, with a separate **mute bit and gain per channel**. A right-only
mute or zero gain on the speaker pin, its mixer or its DAC would cut the right
channel below PipeWire. It wouldn't show in `alsamixer` if it sits on a node
that no ALSA control maps to. `alsamixer`'s `Speaker 35<>35` only covers the
node that control is attached to.

How to read `/proc/asound/card*/codec#0`:

- Each node lists `Amp-Out vals: [0xLL 0xRR]` (and `Amp-In vals:` per input).
  The first value is left, the second right. **Bit 7 (`0x80`) = mute**, and
  bits 0–6 = gain step.
- Find the speaker pin: the node whose `Pin Default` reads
  `[Fixed] Speaker at Int …`. Follow its `Connection:` list (the `*` marks the
  selected input) back through any mixer or selector to the `Audio Output` (DAC).
- **The finding is any node on that chain whose right value differs from its
  left**, e.g. `[0x57 0xd7]` (right muted) or `[0x57 0x00]` (right at zero).
  Also check `Pin-ctls` has `OUT` set, and that `Control: name=…` lines show
  which nodes the `Speaker`/`Master` controls actually drive.
- **A clean chain doesn't exonerate the codec.** The per-slot setup of the
  amp link on Realtek parts is in vendor COEFs, which the dump doesn't show,
  and we don't know which node this board taps for the amp link. A right-only
  mute is a strong lead if present. Its absence proves little.

Commands (read-only, no `sudo` needed):

```bash
cat /proc/asound/card*/codec#0 > codec0.txt          # attach it (see note below)
amixer -c sofhdadsp contents | grep -i -A3 -E 'speaker|master'
pactl list sinks                                      # H5: "Channel Map" + per-channel "Volume:" on the Speaker port
wpctl status                                          # default sink, and any stream holding it open
grep -rs suspend-timeout ~/.config/wireplumber /etc/wireplumber   # suspend disabled?
```

Attachment note for the reply: drag the file into the GitHub comment box
**and wait for the upload link to appear** before posting (the last one didn't
make it), or paste its contents into a
`<details><summary>codec0.txt</summary>…</details>` block.

### Timeline questions

- **When exactly did the right side stop?** Roughly a date. Then what changed
  around it:
  `sudo dnf history list --reverse | tail -n 20`, and
  `rpm -q --last kernel-core alsa-sof-firmware alsa-ucm pipewire wireplumber`
  (or `rpm -qa --last | head -n 40` to catch everything).
- **Constant or intermittent?** Has it ever come back, even briefly? Does lid
  angle or tent/tablet mode change anything?
- **Does a reboot or a suspend/resume ever change it?**
- **The "fresh install":** did they reinstall Fedora after the right side
  stopped? If so, did it come back straight after reinstalling, even briefly?
- **The speaker fix:** when was it installed or reinstalled, and which release
  (tag, or the date they cloned)? The driver hasn't changed per side
  in any release, but a date lined up against the dnf history helps.
- **BIOS:** was it updated recently? `P15RHB.470.260103.04` is dated
  2026-01-03. Was that already installed when both sides worked?

### Is a code change justified now?

**No.** Round 2 removes the only driver-side hypothesis (H4) and adds nothing
that points at this package. The 3a table shows the driver's state is exactly
what it intends on all four amps.

What would justify one now:

| Result | Change |
| --- | --- |
| Redone S2 shows channel 1 empty (with `pactl` showing balanced volumes) | Still **no amp-driver fix** for the cause. The opt-in module parameter stopgap from round 1 (right amps `0x2021=0x00`, or all four `0x02`), **never** default, becomes justifiable. The real fix is codec-side and needs the codec dump plus a same-model comparison. |
| Older kernel restores the right side | A kernel regression. Bisect by kernel, and report upstream (alsa-devel / Fedora bugzilla). Not a change to this driver, since its source is identical across kernels. |
| Redone S2 plays "Front Right" on the left, and physical reseat fixes it | Hardware. No change. |

The unchecked-write gap is still worth a separate hardening card on its own
merits. It isn't #99's cause.

### Round-2 diagnostic plan (cheapest first)

The order is by **cost and risk**, and each step can end the investigation:

**R2-1. Read-only state: no writes, no stopping anything.** The `pactl`,
`wpctl` and suspend-timeout commands and the codec dump above, plus
`sudo dmesg | grep -iE 'picked fixup|max98390|component bound|alc298'`
(or `journalctl -k -b | grep …` if `sudo dmesg` is refused), and the timeline
answers. This alone can close H5 (a right-channel volume of 0 in
`pactl list sinks`) or open a codec lead (a right-only mute bit). It costs
nothing and can't make anything worse.

**R2-2. Baselines, with PipeWire running. No register writes.**

```bash
# close all audio apps and tabs, don't touch the volume keys, wait 10+ s
idle                                               # must print "idle - OK"; if not: send `wpctl status`, don't stop PipeWire
speaker-test -D plughw:sofhdadsp,0 -c 2 -t wav -l 1   # A: bypasses PipeWire
# wait 10+ s
speaker-test -c 2 -t wav -l 1                      # B: through PipeWire (ALSA default)
```

- **A plays "Front Left" on the left:** the round-2 silence came from stopping
  PipeWire. Use `plughw` for the swap tests. It also removes H5 from the S2
  reading.
- **A silent, B plays left:** direct PCM access is the difference (candidate 3
  above). Run the swap tests through B, and only after `pactl list sinks`
  shows equal left/right volumes, or S2 can't be read.
- **Both silent:** stop. The left side, which worked in round 1, is now silent
  too. That's a new fault, and swap tests are pointless until it's explained.

**R2-3. Swap tests redone**, same helpers and outcome table as step 4. The only
changes: PipeWire is never stopped; every write line stays `idle && …`; and
there's a 10 s wait after each through-PipeWire test before the next write.
S0 can be skipped (H4 is out). S2 is the one that matters.

**R2-4. Physical, last.** Only if S2 says channel 1 **is** on the link (left
amps play "Front Right"), or if the timeline says it's intermittent or
position-dependent:

1. With `speaker-test -c 2 -t sine -f 440` running through PipeWire (it
   alternates left and right every few seconds until Ctrl-C; `-s 2` is
   single-shot and too short for this), apply **gentle** pressure to the
   chassis near the right speaker during the right-channel turns, and slowly
   move the lid and hinge through their range. Any crackle or return of sound
   points at a marginal connection.
2. Reseat the right speaker connector: power off, bottom cover off,
   **disconnect the battery connector first**, then reseat. The reporter has
   already had the cover off, so this is within their comfort zone, but the
   reply must say battery first, and that it's at their own risk and warranty
   discretion.

Why this order: R2-1 and R2-2 are free and can't change the machine's state.
R2-3 writes registers, but it's temporary and has the idle guard. R2-4 opens
the machine, and that's only worth doing once the redone S2 says the link
carries channel 1. If S2 says channel 1 is empty, a screwdriver can't help,
and asking for it first would waste their time. Their "worked after I closed
it" also means a reseat isn't a sure fix, so it shouldn't be the first ask.

Nothing in this section has been tested on hardware. There's no NP960QGK
here, so every expected result above comes from reading source and the
reporter's own tables.

### Round 2 reply posted

Posted verbatim to @Bruzado1975 on 2026-09-28 as
[comment-5874275777](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/99#issuecomment-5874275777).
Issue left **open**, with no labels and no driver change.

How it differs from the round-2 plan above:

- **The `plughw` silence is called unexplained.** The reply says the "stopping
  WirePlumber mutes the speaker" guess doesn't hold up in the source, hedged
  "as far as I can tell", because Fedora 44's package versions weren't checked.
  It doesn't offer any of the three untested candidates as an explanation.
- **The status registers aren't decoded.** `0x2006`/`0x2007` are described
  only as "interrupt-state registers whose bits aren't publicly documented".
  The reply says they're identical on all four amps, and that `INT_FLAG1-3`,
  power-gate and brownout read zero. `DAT_MON` isn't mentioned.
- **The suspend timeout is "normally about 5 s"**, because the 5 s default for
  Fedora's WirePlumber 0.5 is from memory, not source.
- **The swap commands use B (PipeWire, ALSA `default`)**, with the rule
  "redo the swaps using whichever of A/B played the left side". B also needs
  `pactl list sinks` to show equal left and right volumes first. The card asked for the
  `default` form. The plan's preference for `plughw` when A works is kept as
  "use that same `speaker-test` line".
- **S0 dropped, S2 listed before S1**, per R2-3 (H4 is out, S2 is decisive).
  The outcome table is cut to three rows.
- **The helpers are in a collapsed `<details>` block.** `rd`/`wr`/`idle`/`chan`
  are byte-identical to round 1 (diffed). `table` is dropped because the redo
  doesn't use it, and `i2c-tools` install is dropped because they already have it
  (`sudo modprobe i2c-dev` kept). Re-checked against a stub `i2ctransfer`
  before posting: `chan 0x38 0x01` emits the same five writes plus read-back,
  and `idle` refused with a fake `state: RUNNING` substream and with no status
  files, and passed only when every substream read `closed`.
- **Older-kernel boot added** to the timeline section, from the "what would
  separate them" table, since it tests their "kernel update" suspicion
  directly. It carries the `dkms status` caveat.
- **`journalctl -k -b`** replaces the refused `sudo dmesg`.
- **Physical checks are last**, and gated on S2 showing channel 1 reaching the
  amps, or on the timeline showing the fault comes and goes. The reply says
  "keep the case closed" until then. The reseat step says battery first, at
  their own risk, may affect warranty.
- **Shorter than round 1**: 1450 words vs 1544.

> Thanks for running all of that. The register tables settle one question for good.
>
> ## Short answer: software or hardware?
>
> I can't tell yet, and your results don't favour either side. Here's what they do and don't show:
>
> - **It isn't the speaker-fix driver.** Your 3a table matches what the driver writes on all four amps. The right amps are switched on and identical to their left partners, apart from the intended channel select (`0x2021`). That rules out a bug in how the driver sets them up.
> - **A software regression is still possible**, but it would have to be upstream of the amps: the codec (ALC298) not putting the right channel on the link that feeds them, or a PipeWire channel setting. For what it's worth, the upstream kernel has no model-specific audio quirk for the NP960QGK, so no kernel update has added or changed one. It would have to be a generic change, or a Fedora-specific patch.
> - **Hardware is still possible too.** A connector that isn't fully home can work for a while and then lose contact, so "worked after I closed it" doesn't rule it out.
>
> The redone swap test (step 3) separates the two. Until then, please keep the case closed.
>
> ## What the status registers say
>
> `0x2006 = 0x18` and `0x2007 = 0x0f` are interrupt-state registers whose bits aren't publicly documented, so I won't guess. They're **identical on all four amps, including the two that work**, so they don't separate the sides. The latched fault flags (`0x2008`–`0x200a`), power-gate and brownout status are zero on all four: no amp has logged a fault. That table was taken during silence, though, so it can't show whether audio reaches the amps.
>
> ## Why the swap tests need redoing
>
> Your `plughw` test was silent on **both** sides, including the left, which normally works. **I don't know why yet.** My first guess, that stopping PipeWire/WirePlumber mutes the speaker path, doesn't hold up when I read the PipeWire and ALSA source: as far as I can tell, stopping them doesn't run the step that switches the speaker off.
>
> Either way, the swap tests use the working left side as the reference, so with the left silent too they tell us nothing. This time **PipeWire stays running throughout**. `idle` checks the kernel directly, and passes once PipeWire lets go of the device, normally about 5 s after the last sound stops.
>
> ## 1. Read-only information (nothing changes)
>
> The alsa-info attachment didn't come through. It was written to `/tmp`, which Fedora clears on reboot, so please regenerate it (`alsa-info.sh --no-upload`), or just save the codec dump:
>
> ```bash
> cat /proc/asound/card*/codec#0 > codec0.txt
> ```
>
> To attach it, drag the file into the comment box **and wait for the upload link to appear** before posting. Or paste it inside `<details><summary>codec0.txt</summary>` … `</details>`.
>
> Please also paste the output of these:
>
> ```bash
> pactl list sinks                     # per-channel volume on the speaker: a low/zero right channel is a PipeWire setting
> wpctl status                         # which app, if any, was holding the audio device open
> grep -rs suspend-timeout ~/.config/wireplumber /etc/wireplumber    # whether PipeWire's idle release is turned off
> amixer -c sofhdadsp contents | grep -i -A3 -E 'speaker|master'    # the codec's own speaker/master switches and volumes
> journalctl -k -b | grep -iE 'picked fixup|max98390|component bound|alc298'   # replaces the dmesg that was refused
> ```
>
> The codec dump can show a right-only mute inside the codec that no mixer control exposes.
>
> ## 2. Timeline questions
>
> - **When did the right side stop**, roughly? And what changed around then:
>   `sudo dnf history list --reverse | tail -n 20` and `rpm -q --last kernel-core alsa-sof-firmware alsa-ucm pipewire wireplumber`
> - **Constant or intermittent?** Has it ever come back, even briefly? Does lid angle, or tent/tablet mode, change anything?
> - **Does a reboot or a suspend/resume ever change it?**
> - **Your first report said "fresh install".** Did you reinstall Fedora *after* the right side stopped? If so, did it work straight after the reinstall, even briefly?
> - **When did you install (or reinstall) the speaker fix**, and which release or clone date?
> - **Was the BIOS updated recently?** Was `P15RHB.470.260103.04` already installed when both sides worked?
>
> If it started right after an update, booting the previous kernel from GRUB is a cheap test (check `dkms status` lists `max98390-hda` for it first). If the right side comes back there, it's a kernel regression.
>
> ## 3. Baselines, then the swap tests (PipeWire running)
>
> First, paste the helpers into one terminal (collapsed below). Then close all audio apps and browser tabs, don't touch the volume keys, and wait 10+ s:
>
> ```bash
> idle                                                   # must print "idle - OK"
> speaker-test -D plughw:sofhdadsp,0 -c 2 -t wav -l 1    # A: bypasses PipeWire
> # wait 10+ s
> speaker-test -c 2 -t wav -l 1                          # B: through PipeWire
> ```
>
> If `idle` keeps saying NOT IDLE, **don't stop PipeWire**; send `wpctl status` instead. Tell me what A and B each did. If **both** are silent on both sides, stop there: the swaps can't help until the left side plays again.
>
> If at least one of them plays "Front Left" on the left, redo the swaps using that same `speaker-test` line. The commands below show B, which needs `pactl list sinks` to show equal left and right volumes first. After any test through PipeWire, **wait 10+ s before the next `idle && …` line**.
>
> > ⚠️ **Never write amp registers while audio is playing.** In issue #61 a similar write on a live stream froze another reporter's codec. Every write line starts with `idle &&`, so it refuses if anything is open. The check and the write are separate commands, though, so also keep everything closed and leave the volume keys alone. All changes are temporary, and a reboot restores the driver's settings.
>
> **S2: left amps play the RIGHT channel.** This is the one that matters.
>
> ```bash
> idle && chan 0x38 0x01 && chan 0x3c 0x01
> speaker-test -c 2 -t wav -l 1        # does "Front Right" now come out of the LEFT side?
> # wait 10+ s
> idle && chan 0x38 0x00 && chan 0x3c 0x00               # revert
> ```
>
> **S1: right amps play the LEFT channel.**
>
> ```bash
> idle && chan 0x39 0x00 && chan 0x3d 0x00
> speaker-test -c 2 -t wav -l 1        # does "Front Left" now come out of the RIGHT side?
> # wait 10+ s
> idle && chan 0x39 0x01 && chan 0x3d 0x01               # revert
> ```
>
> | Result | Meaning |
> | --- | --- |
> | S2: left side stays silent on "Front Right" | **Channel 1 never reaches the amps.** Codec/BIOS/software side, and opening the case won't help. |
> | S2: left side says "Front Right", and S1: right side still silent | **The signal reaches the amps and is lost after them.** That's the right speaker, cable or connector: go to step 4. |
> | S1: right side says "Front Left" | The right amps and speakers work. It's the channel-1 feed, not the hardware. |
>
> Please paste the full terminal output, including the `0x2021 now …` lines, along with what you heard.
>
> <details>
> <summary>Helpers (paste once per terminal)</summary>
>
> ```bash
> sudo modprobe i2c-dev
> sudo -v
> BUS=2
> rd(){ sudo i2ctransfer -y -f "$BUS" w2@"$1" $(printf '0x%02x 0x%02x' $(( $2 >> 8 )) $(( $2 & 0xff ))) r1; }
> wr(){ sudo i2ctransfer -y -f "$BUS" w3@"$1" $(printf '0x%02x 0x%02x' $(( $2 >> 8 )) $(( $2 & 0xff ))) "$3"; }
> idle(){ s=$(cat /proc/asound/card*/pcm*p/sub*/status 2>/dev/null)
>         if [ -z "$s" ] || grep -qv '^closed$' <<<"$s"; then
>           echo 'NOT IDLE - audio is still open. Stop it, wait 10 s, retry.'; return 1; fi
>         echo 'idle - OK'; }
> chan(){ wr $1 0x23ff 0x00 && wr $1 0x203a 0x80 &&
>         wr $1 0x2021 $2 &&
>         wr $1 0x203a 0x81 && wr $1 0x23ff 0x01 &&
>         echo "$1 0x2021 now $(rd $1 0x2021)"; }
> ```
>
> </details>
>
> ## 4. Physical checks, last
>
> **Only if** step 3 says the signal reaches the amps (S2 left side says "Front Right") but the right side stays silent, or if the timeline says it comes and goes:
>
> 1. **Before opening anything:** run `speaker-test -c 2 -t sine -f 440` (it alternates left and right every few seconds until Ctrl-C). During the right-channel turns, press **gently** on the chassis near the right speaker, and slowly move the lid through its range. If any crackle or sound comes back, that's a marginal connection.
> 2. **Reseat the right speaker connector:** power off, remove the bottom cover, and **disconnect the battery connector first**, then reseat the speaker connector. This is at your own risk, and may affect your warranty.
>
> I'll keep the issue open until you've had a chance to run these. Thanks again for your patience!

---

## Round 3

[@Bruzado1975's round 3 comment](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/99#issuecomment-5920687618)
(2026-09-30). No data this round. What they said:

- They're a music teacher and need working speakers, so they **reinstalled
  Windows**. In Windows **both internal speakers work perfectly**: both
  channels, full volume.
- They ran the round-2 baselines (A/B) and S1/S2, but didn't save the output
  and no longer have that Fedora install. **The results are lost.**
- They plan to dual-boot Fedora over the school holidays and redo everything,
  saving every log.

### What Windows settles

**H3 (right-side speaker, cable or connector) is ruled out** by the reporter's
own evidence. Windows drives both right drivers at full volume through the same
amps, the same speakers and the same right-side cabling. A marginal contact
would have to keep working through their normal Windows use while failing
consistently under Fedora. That isn't credible. The #61 caveat about Windows
(it may high-pass the tweeters, so a weak driver is never stressed) doesn't
apply here: #99 is **both** right drivers completely silent, not a distorting
tweeter.

It also backs up the round-2 3a table, which already cleared the amp driver
(H4). Both right amps hold exactly what the driver wrote.

### What's left

| | Round 2 | Round 3 | Why |
| --- | --- | --- | --- |
| **H1** channel 1 not on the codec→amp link under Linux | Joint lead | **Favoured** | The only software mechanism that silences both right amps at once, and the hardware is now known to be good. Nothing in this package or upstream PR #5616 programs the ALC298's amp-facing output, so under Linux it's whatever state the codec is left in. Weak evidence against: #100 (Lunar Lake, different SSID) shows right amps on channel 1 do get audio on that board (`issue-100-findings.md`). Different platform, so it doesn't settle #99. |
| **H5** PipeWire per-route volume | Moved up | **Open, cheaper to check** | Untouched by the Windows result. The dual-boot install will start with **fresh WirePlumber state** (`~/.local/state/wireplumber/`). If the right side works straight after that install and fails later, H5 (or some other stored per-user state) becomes the lead. `pactl list sinks` still closes it. |
| **H3** right-side physical | Joint lead | **Ruled out** | Windows plays both sides. |
| **H4** amp driver state | Ruled out | Ruled out | Round-2 3a table. |
| **H2** framing mismatch | Folded into H1 | Folded into H1 | Unchanged. |

The S2 swap results are lost, so **S2 is still the decisive pending test**
between H1 and H5. It needs a working left side as its control.

### Is a code change justified?

**No.** Nothing new points at this package. The round-2 table ("Is a code
change justified now?") still applies unchanged: only a redone S2 showing
channel 1 empty would justify the opt-in stopgap, and the real fix would still
be codec-side.

### Firmware-inherited state: what #100 does and doesn't support

`docs/triage/issue-100-findings.md` (Book5 Pro 940XHA, Lunar Lake, stock
7.2.8 kernel) found all four MAX98390s already configured when Linux starts:
`GLOBAL_EN=1`, `0x2021` set per side, `AMP_EN` on only `0x38`. No Linux code
touches those amps on a stock kernel, so that state was **written before Linux
and inherited by it**. The reporter has no Windows, so it came from UEFI/BIOS.

That genuinely supports one point: **on these Samsung boards, audio state set
before Linux starts can persist into Linux.** It does **not** show that
Windows' state survives a warm reboot. #100's "Windows warm-reboot residue"
hypothesis was dropped untested because there was no Windows to test it with.
It's also amp state, not codec state, and on #99 our driver software-resets
every amp at probe (`max98390_hda.c`, the checked `SOFTWARE_RESET` write), so
any amp-side state Windows leaves is wiped. **Only codec-side (ALC298) state
could carry over.**

### New test for when they return: cold boot vs warm reboot from Windows

Two boots, listening only:

1. **Cold boot:** full shutdown, then power on straight into Fedora.
2. **Warm reboot from Windows:** in Windows, with sound playing, choose
   Restart and pick Fedora in the boot menu.

Optional, after each boot: `journalctl -k -b | grep -iE 'picked fixup|alc298'`.
That shows which Realtek fixup the kernel picked and when. It should be
identical across both boots, and a difference would be a finding in itself.

| Result | Meaning |
| --- | --- |
| Right side plays after the **warm** reboot, silent after the **cold** boot | Windows' codec programming survived the reboot, and Linux doesn't do it. **Direct evidence for H1**, and it says what to look for: the ALC298's amp-link configuration, set by Windows' driver, missing under Linux. Next step would be a codec dump from each boot, compared. |
| Same result after both | That mechanism isn't shown. H1 stays open. Either Windows' codec state doesn't survive the reboot (Linux's HDA probe may reset it), or it isn't the missing piece. The test can't tell which. |
| Right side plays after **both** | Fresh install works: points at H5 or other stored state building up later, not H1. |

Why it matters: it's the one H1 test that needs no register writes and no
helpers, so it's safe to ask first, and a positive result goes straight to the
cause.

**How sure I am of the premise: not very.** It's inferred, not verified on this
board. What the repo actually has:

- #61 (Book3 Ultra, ALC298): amp state set through the codec's COEFs **does
  not survive suspend** (`issue-61-findings.md`, round 3; the shipped 940XFG
  resume hook only exists for that reason). That's evidence state is **lost**
  on power-down, not that it's **kept** across a reboot.
- #100: state from **before** Linux persists into Linux (above). Firmware,
  not Windows.
- No note in the repo shows ALC298 vendor COEF state surviving a warm reboot.
  Whether Linux's HDA controller reset at probe clears it is unknown. So the
  warm-reboot half of the test could come back negative for reasons unrelated
  to H1, which is why the "same result" row doesn't exclude H1.

Nothing in this section has been tested on hardware.

### Round 3 reply posted

Posted verbatim to @Bruzado1975 on 2026-09-30 as
[comment-5920907688](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/99#issuecomment-5920907688).
Issue left **open**, with no labels and no driver change.

How it differs from the round-3 notes above: it names H1 as the main suspect
in plain words but doesn't mention H5, and it doesn't include the result table
for the cold/warm test. It calls the test "an educated guess" from other
Samsung models, not a confirmed mechanism. The only command is the optional
`journalctl` line.

> Hi @Bruzado1975, thank you so much for the update. Your teaching comes first, and Windows was the right call.
>
> You're right that Windows settles the hardware question. If both sides play at full volume there, the amps, speakers and right-side cabling are fine. That leaves the software between the codec and the amps under Linux, as you said. Your last register dump showed the amps set up identically on both sides, so my main suspect is the codec not sending the right channel to the amps under Linux.
>
> And no need to apologise about the lost output. We'll redo it.
>
> When you have the dual-boot, one test is worth doing first, and it's only listening. Boot into Fedora twice: once from cold (full shutdown, then power on), and once by restarting straight from Windows while sound is playing there, then picking Fedora. If the right side works after the restart from Windows but not after the cold boot, Windows is setting up something in the codec that Linux misses, and that tells us exactly where to look. It's an educated guess from what we've seen on other Samsung models, not confirmed on yours. As a bonus, paste the output of this after each boot:
>
> ```bash
> journalctl -k -b | grep -iE 'picked fixup|alc298'
> ```
>
> The S2 swap test and codec dump from [my earlier comment](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/99#issuecomment-5874275777) will still be there when you have time.
>
> I'll keep the issue open, and there's no rush at all. Good luck with the term!
