# Issue #106 — Book3 Pro 16" (NP960XFG, `144d:c886`): right tweeter `0x3d` crackles on V2_4

**Reporter:** @DeveloperMatt02 · opened 2026-10-06 · state: open · no comments yet

**Classification: same signature as issue #61, now on a second model.** No
fix to ship yet; testing comes first. The reporter's 2-amp workaround is the
kernel's own code path and is safe to keep using.

**Status:** reply posted 2026-10-06, comment
[6020627289](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/106#issuecomment-6020627289),
verbatim from `docs/triage/issue-106-reply.md` (no reporter comments had arrived
since the draft). No code changed. No separate #61 cross-post made; the reply's
`#61` mentions auto-link it on #61's timeline (see "Repo changes this suggests").

### Review notes for Andy before posting

- The reply's `0x239e` paragraph says the 940XFG "enable delta" is probably a
  misread Windows *read* (see "A probable read-back path" below). It stays in
  because it explains his "no change" result, and it is hedged. Nothing else in
  the reply depends on it.
- The per-amp register read-back idea is deliberately **left out** of this
  round, because its command word is a guess.
- **Volume safety (added after review):** if H1 is right, the tweeters run
  with no DSM protection, so a full-level 120 Hz `plughw` tone at his alsa-info
  `Master` 100% is a real damage risk. The reply makes a −20 dB `Master` step
  (≈37%, 47/127 at 0.25 dB/step) mandatory before every test, with a read-back
  check. It also uses `-l 1` single bursts and tells him to Ctrl+C at the first
  loud rattle. `amixer … sset Master -20dB` without `--` fails ("invalid option
  -- '2'"; checked locally), so the reply uses `amixer -c sofhdadsp -- sset
  Master -20dB`. One thing isn't verified: that `Master` attenuates the
  codec→amp path on this board. The reply's backstop is "the first tone must
  be clearly quieter; if not, stop".

---

## What they reported

| | |
| --- | --- |
| Model | Galaxy Book3 Pro 16", DMI `960XFG`, board `NP960XFG-KC2IT` (Italy) |
| BIOS | `P07RGU.330.240529.ZQ` (2024-05-29) |
| Codec | ALC298, SSID `0x144dc886`, rev `0x100103` |
| OS | Fedora 44, kernel `7.2.8-200.fc44` |
| Driver path | **SOF** (`sof-audio-pci-intel-tgl`, `skl_hda_dsp_generic`, `sof-hda-generic-2ch.tplg`), Raptor Lake-P `8086:51ca` |
| Symptom | right speaker crackles/distorts with **any** sound at **any** volume, including low. Left is clean. **Windows (dual boot, same machine) is clean.** |

Their own isolation work, all done during playback with the kernel's own
disable sequence (`{0x23ff,0}` then `{0x203a,0x80}`):

| Muted | Result |
| --- | --- |
| `0x38`, `0x39` or `0x3c` | still crackles |
| **`0x3d`** | **crackle gone** |
| `write_pack(0x239e, 0x0004)` on all four (the 940XFG "SKU delta") | no change |
| `power_save=0` + EasyEffects high-pass + limiter | no change |

Workaround in use: `options snd_sof_intel_hda_generic hda_model=alc298-samsung-amp-v2-2-amps`
→ only `0x38`/`0x39` brought up, no crackle, "slightly less full sound".

They offer an RtHDDump capture from Windows and any `hda-verb` tests.

## What the alsa-info shows

Downloaded to `/tmp/issue-106/alsa-info.txt` (untrusted data, read in full).
**Captured with the workaround active**, so it shows the V2_2 state, not the
crackling V2_4 one:

- `snd_hda_codec_alc269 ehdaudio0D0: ALC298: picked fixup alc298-samsung-amp-v2-2-amps (model specified)`
- Modprobe options: `snd_hda_intel: power_save=0` and
  `snd_sof_intel_hda_generic: hda_model=alc298-samsung-amp-v2-2-amps`.
- Autoconfig as on every ALC298 Samsung: `line_outs=1 (0x17) type:speaker`,
  `hp_outs=1 (0x21)`, `Mic=0x18`. Pin `0x17` `0x90170110`, fed from DAC
  `0x03` via mixer `0x0d`. Nothing unusual.
- Mixer: `Master` 127/127, `Speaker` 127/127 both on, no balance skew.
- Modules: no `snd_hda_scodec_max98390*`, nothing out-of-tree. **None of our
  packages are installed.** `speaker-fix-940xfg/install.sh` would refuse anyway
  (DMI must be `940XFG`, SSID must be `0x144dc882`).
- ACPI lists two Realtek SoundWire IDs, but the card is HDA-only at runtime
  (same as #44's 940XFG).
- No kernel command line section in this alsa-info version.

Two small things worth telling them:

- `snd_hda_intel power_save=0` does nothing here. `snd_hda_intel` is loaded
  but not bound to the card on the SOF path (also seen on Andy's Book4, see
  #61 round 3). Harmless, but not a test result.
- **Their workaround corrects something we told #61.** Our #61 round 2 reply
  said the 2-amp model "needs the legacy HDA path because `model=` is a
  `snd-hda-intel` parameter". Wrong. SOF has had its own `hda_model` parameter
  for years (`sound/soc/sof/intel/hda.c:473`, module
  `snd-sof-intel-hda-generic` per `sound/soc/sof/intel/Makefile:11`), and
  their dmesg proves it works. @GiulioMicheletti on #61 can drop
  `dsp_driver=1` and use it the same way.

## Kernel code, v7.2.8 (fetched from stable, `/tmp/issue-106/k72/`)

- `alc269.c:7731`: `SND_PCI_QUIRK(0x144d, 0xc886, "Samsung Galaxy Book3 Pro (NP964XFG)", ALC298_FIXUP_SAMSUNG_AMP_V2_4_AMPS)`.
  The reporter's `NP960XFG-KC2IT` is a regional variant of the same board.
  SSID selects the fixup, and it fires automatically. This is the same kind of
  label mismatch #61 saw (`NP964XFH` vs `NT960XFH`).
- `alc298_samsung_v2_amp_desc_tbl[]` (`:1808`) is **byte-identical** to the
  6.17 tree we analysed for #61 (diffed). So everything #61 established
  carries over unchanged.
- `alc298_fixup_samsung_amp_v2_4_amps()` (`:2080`) still runs init on
  `HDA_FIXUP_ACT_PROBE` only. `alc_resume()` → `snd_hda_codec_init()` →
  `alc_init()` → `snd_hda_apply_fixup(codec, HDA_FIXUP_ACT_INIT)`
  (`realtek.c:782`, `:824`) is still a no-op for this fixup.
- `0x3c` and `0x3d` get the same 15 writes. They differ only in the
  channel-select group: `0x201b PCM_RX_EN_A`, `0x201d PCM_TX_EN_A`,
  `0x201f PCM_TX_HIZ_CTRL_A`, `0x2021 PCM_CH_SRC_1`. `0x39` and `0x3d` share
  `0x2021 = 1`, so they get the same input.

### New in this round, verified against upstream `max98390.h` / `max98390.c` (v7.2.8)

1. **The V2 path turns the Maxim DSM off on all four amps and never turns it
   back on.** The first write of every amp's init is
   `{0x23e1, 0x0000}`, and `0x23e1` is `MAX98390_R23E1_DSP_GLOBAL_EN`
   (`max98390.h:573`). The ASoC driver loads its DSM parameters and then writes
   `DSP_GLOBAL_EN = 0x01` (`max98390.c:843`). Our own Book4/5 `speaker-fix/`
   does the same (`max98390_hda_filters.c:218`). The ALC298 V2 path never
   writes `0x01`. So on Linux these amps run as plain class-D stages, with no
   excursion limiting, no thermal protection and no crossover. Windows runs the
   DSM. #61 round 2 called this "no crossover loaded". It is stronger than that:
   **the DSP that would run a crossover is disabled.**
2. **The Samsung V2 path never software-resets the amps.** The LG gram Style 14
   fixup in the same file (`alc269.c:1947`, `alc298_lg_gram_style_preinit_seq`)
   writes `{0x2000, 0x01}` before the same per-amp table, and `0x2000` is
   `MAX98390_SOFTWARE_RESET`. The ASoC driver resets at probe too
   (`max98390.c:912`). Samsung V2 does not. So every register V2 doesn't write
   (PCM framing `0x2024`–`0x2027`, the whole DSM coefficient block, thermal
   setup) keeps whatever the previous owner left. That is POR on a cold boot.
   After a restart from Windows it *may* be Windows' values. That second part
   is unverified: nobody has shown amp power survives a warm reboot on these
   boards.

### Why only `0x3d`, on two different models?

#61 round 3 left this as "unexplained — unit variation is hand-waving". A
second machine changes the picture. Two units of two different models (Book3
Ultra 16", Book3 Pro 16") fail at the **same position**, the right tweeter, and
both are clean on Windows. Random unit damage hitting the same spot twice is
unlikely. Fact 1 gives a mechanism that doesn't need asymmetric software: the
software is symmetric, but the two tweeters may sit in **different acoustic
chambers** (laptop layouts are rarely mirror images: fan, hinge and port
placement differ). With the DSM's excursion protection on, both survive the
same full-band signal. With it off, the one with less headroom rattles. That
is a hypothesis; nothing here proves the chambers differ.

One detail in this report argues *against* it: "crackles at any volume,
including low volume" and "EasyEffects high-pass: no change". Excursion
distortion scales with level and goes away under a high enough high-pass.
#61's sweep was clean above ~1620 Hz. We don't know the cutoff they used. A
100–200 Hz high-pass would leave the 200–1600 Hz band that rattled #61 intact,
so this needs one question and one sweep, not a conclusion.

## Hypotheses, ranked

| | Hypothesis | For | Against | Test |
| --- | --- | --- | --- | --- |
| **H1** | Tweeter over-excursion: DSM off, full-band signal, right tweeter has less mechanical headroom | Same position on two models; Windows (DSM on) clean on both; #61 sweep: rattle below ~1.6 kHz only | "Any volume incl. low", high-pass "no change" (cutoff unknown) | T1 sweep: clean at 4/8 kHz and on silence? |
| **H2** | Init lost after resume (ACT_PROBE only) | Code fact; can't explain one amp alone | Reporter says "any sound", probably right after boot | T2: cold boot vs after suspend |
| **H3** | Leftover state: V2 doesn't reset amps, so non-V2 registers depend on who ran before | Code fact (fact 2); dual-boot machine | Doesn't explain why only `0x3d` | T3: cold boot vs restart from Windows |
| **H4** | Electrical/digital fault on `0x3d` (link framing, clocking, a latched fault) | "Any volume, incl. low" fits better than excursion | Windows is clean on the same wiring | T1: crackle on 8 kHz, on digital silence, or on a left-only tone |
| H5 | Physical damage | — | Windows clean; same position on two models | only if all else is clean |

## Can we ship a fix now?

**No.** Each candidate depends on a result we don't have:

- **Turn on the DSM / load a tweeter tuning through the COEF pack.** This is
  the real fix if H1 holds, but we have no Book3 tuning. The Book4/5 blob in
  `speaker-fix/` is for different drivers in a different chassis, and #93 shows
  blob-to-speaker assignment is itself uncertain. A DSM running a wrong tuning
  (wrong `Rdc`, wrong excursion model) can also *remove* protection, which is
  worse than having it off. It is also ~5,500 `hda-verb` calls per amp. **Needs
  the Windows-side data first.**
- **Host-side crossover.** Not possible on this architecture: `0x39` and `0x3d`
  share PCM channel 1 (`0x2021 = 1`), so anything PipeWire does to the right
  channel hits the right woofer too. (`0x2021` has a `BASS` field at bit 4,
  `MAX98390_PCM_RX_CH_SRC_BASS_SHIFT`, but nothing tells us the codec puts
  separate content on another slot.)
- **`ACT_INIT` kernel patch** (from #61). Right in principle, but only fixes the
  resume case. It ships only if T2 shows a cold-boot/resume difference.
- **"3-amp" mode** (`num_speaker_amps = 3` brings up `0x38/0x39/0x3c` and never
  `0x3d`). Rejected: treble on the left only.
- **Lower `0x203d SPK_GAIN` on `0x3d` alone.** Config registers persist across
  the playback hook (it only touches `0x203a`/`0x23ff`), so it would stick until
  reboot or resume. But it treats a symptom, unbalances the stereo image, and
  per #93 config writes need the amp disabled first. Not before T1.

**The 2-amp workaround is safe.** `alc298-samsung-amp-v2-2-amps` is the
upstream path for the Book2 Pro (`0xc870`, `0xc872`, `0xc1ac`). The kernel
never enables `0x3c`/`0x3d`, and the playback hook's loop stops at 2. The
woofers carry the full band, which is what they do on every 2-amp Samsung
upstream. One caveat, for the record only: the kernel never explicitly
*disables* the tweeters either, so they stay in whatever state firmware left
them. The reporter hears no crackle, so `0x3d` is evidently not being driven.

## Test plan (goes in the reply)

All steps run on stock V2_4 (workaround commented out), with
`snd_hda_codec_alc269.dyndbg=+p` set via `grubby`. **No register writes in
this round.** Every step is listening, rebooting, or reading `dmesg`.
**Step 0 before every test is mandatory:** `Master` to −20 dB with a
read-back check, single `-l 1` bursts, and Ctrl+C at the first loud rattle.
See the review notes at the top for why.

- **T1: cold boot, tone sweep plus two controls.** `speaker-test -D
  plughw:sofhdadsp,0` at 120/400/1000/2000/4000/8000 Hz, then 10 s of digital
  silence (`aplay … /dev/zero`, which keeps the amps enabled), then a left-only
  tone (`-s 1`). `plughw` bypasses PipeWire/EasyEffects (#99: on Fedora
  `default` *is* PipeWire). Discriminates H1 from H4.
- **T2: suspend/resume, repeat 120 + 4000 Hz, then `dmesg | grep
  alc298_samsung_v2`.** Prediction from the code: no new `Initialized speaker
  amp` lines after resume. Discriminates H2.
- **T3: restart from Windows (with audio played there) straight into Fedora,
  repeat 120 + 4000 Hz.** Discriminates H3. Its premise (amp state surviving a
  warm reboot) is stated as unverified in the reply.
- **T4 (optional, Windows): RtHDDump during playback.** Expectations set: on
  #44, Win11 build 26200 blocked `rtport.sys`, so it produced register
  snapshots, not a verb trace. Only a trace is worth their time (see next
  section).
- Plus one question: **what cutoff did the EasyEffects high-pass use?**

| Result | Reading | Next |
| --- | --- | --- |
| crackle only at low tones, clean ≥ 2–4 kHz, nothing on silence or left-only | H1, the same as #61 | tweeter protection/crossover work, needs Windows data. Keep 2-amp meanwhile |
| crackle on 8 kHz, or on silence, or on the right while only the left plays | H4 | per-amp register read-back becomes the priority (below) |
| clean on cold boot, crackle after resume | H2 | resume hook (shippable, same shape as `speaker-fix-940xfg`) + upstream `ACT_INIT` patch |
| clean after a Windows restart, crackle on cold boot | H3 | a Windows verb trace becomes decisive |

## A probable read-back path, found in #44's Windows snapshots (NOT in this reply)

The card asked for "COEF readback of all registers per amp, 0x3c vs 0x3d". #61
said no read path is known, and that guessing one isn't worth the risk. Still
true for this round. But re-reading #44's RtHDDump snapshots (re-downloaded to
`/tmp/issue-106/i44/`) turns up something:

| Snapshot | `0x22` amp | `0x23` reg | `0x24` | `0x25` data | `0x26` cmd |
| --- | --- | --- | --- | --- | --- |
| boot | `0x3D` | `0x203A` | `0x0000` | `0x0080` | `0xB001` |
| playback stop | `0x3D` | `0x23FF` | `0x0000` | `0x0001` | `0xB001` |
| **playback start** | `0x39` | **`0x239E`** | `0x0000` | **`0x0004`** | **`0xB00B`** |

- Both *writes* (the two disable/enable values match the kernel's own
  sequences) read back as `0x26 = 0xB001`. Linux writes `0xB011`, so bit 4
  looks like a self-clearing "go" bit.
- The `0x239E` row carries a **different command, `0xB00B`**. And `0x239E` is
  `THERMAL_COILTEMP_RD_BACK_BYTE1` (`max98390.h:564`), a read-back register.
  The likely reading: **Windows was *reading* the coil temperature of `0x39`**
  (DSM thermal monitoring), and `0x25 = 0x0004` is the result, not a value
  written.

Two consequences:

1. **A read path probably exists**: `0x23 = reg`, `0x26 = 0xB01B`-ish, result
   in `0x25`. Not tested. A safe first probe would target a read-only register
   (`0x24FF MAX98390_R24FF_REV_ID`) with the amps idle. If the guessed command
   turned out to be a write, it would land on a read-only register. That would
   unlock a real per-amp `0x3c` vs `0x3d` register diff, cold vs warm-from-
   Windows, which is exactly what this issue needs if T1 says H4. **Proposed
   for round 2, not this reply.** It is still a guessed command word, and #61
   taught us what a confident "safe" costs.
2. **The `{0x239e, 0x0004}` "SKU-specific enable delta" in
   `speaker-fix-940xfg/alc298-amp-init.sh` was probably a misreading** of a
   Windows read as a write. #61 round 2 already flagged the register name. The
   `0xB00B` command makes it concrete. That would also explain why it did
   nothing on this machine. The 940XFG fix is confirmed working on hardware
   (#44), so *something* in that script makes the difference against
   `model=…v2-4-amps`, but it is probably not this write. **Separate follow-up;
   don't touch the shipped script on this basis alone.**

## Repo changes this suggests (described, not made)

- `speaker-fix-940xfg/README.md:23,39,63` says the 16" `0xc886` "already works
  upstream… and needs no fix". It works, but with the right tweeter crackling
  on at least one unit. Suggest: "works upstream (`V2_4_AMPS`); if one side
  crackles, see #106/#61".
- Once T1–T3 come back: a short README note for `0xc886`/`0xc1cc` users
  documenting `snd_sof_intel_hda_generic hda_model=alc298-samsung-amp-v2-2-amps`
  as the supported stopgap.
- Cross-post to #61: @GiulioMicheletti can use `hda_model=` on SOF instead of
  `dsp_driver=1` + `model=`, and his machine is no longer a single data point.

## Not addressed

- #61 has had no reply since round 3 (2026-09-18). The cold-boot vs resume test
  there is still outstanding, and #106's T2 asks the same question on a second
  machine.
- No upstream (alsa-devel) report yet. A report with two models needs at least
  T1 back first.
