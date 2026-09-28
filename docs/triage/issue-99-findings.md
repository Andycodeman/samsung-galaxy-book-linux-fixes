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

**Status:** triage only. Nothing posted to GitHub, no driver code changed, and
no reply drafted. The reply should be written from the
[diagnostic plan](#diagnostic-plan-for-the-reporter), with the write-safety
wording kept intact.

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
