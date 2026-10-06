Thanks for this. It's one of the clearest reports we've had on these machines.
Isolating it to a single amp by muting each one in turn during playback,
checking Windows on the same machine, and ruling out the obvious host-side
suspects first saved a lot of back-and-forth.

## You're not the first: this is #61 on a second model

Issue #61 has the same signature on a **Galaxy Book3 Ultra** (`144d:c1cc`):
same `ALC298_FIXUP_SAMSUNG_AMP_V2_4_AMPS` fixup, same SOF path, the right side
misbehaves, it goes away when **`0x3d`** is muted, and Windows is clean. That
was one machine, so "a marginal tweeter on one unit" was a fair explanation.
Yours is a different model with the same position failing in the same way,
which makes a one-off hardware fault much less likely. The two reports
together point at something systematic.

For reference, your `0xc886` is in the kernel's table (labelled `NP964XFG`; your
`NP960XFG-KC2IT` is a regional variant), so the V2_4 fixup is picked correctly.
The per-amp init table is unchanged in 7.2.8, and none of this repo's packages
apply to your machine.

## What's different between Linux and Windows

Two things in the kernel's V2 code, both checked against the upstream
MAX98390 register definitions. (The four amps behind COEF `0x22` are MAX98390s,
and the pack sub-addresses are their register addresses.)

1. **The amps' speaker-protection DSP is switched off on Linux.** The first
   thing the init writes to every amp is `0x23e1 = 0x0000`, and `0x23e1` is
   `DSP_GLOBAL_EN`. Nothing ever sets it back to 1. Both the upstream ASoC
   MAX98390 driver and our own Book4/Book5 package load a tuning and then set
   it to 1. So on Linux all four amps run with no excursion limiting, no thermal
   protection and no crossover. Windows almost certainly runs that DSP with a
   proper tuning. The tweeters on Linux get the full band, bass included.
2. **The `0x3c` and `0x3d` init is otherwise identical.** Same gain, same
   volume, same everything except which channel each listens to. And `0x3d`
   gets exactly the same signal as `0x39`, which you've shown plays cleanly.

My working theory: the two tweeters don't have the same mechanical headroom.
Laptop speaker chambers are rarely mirror images. With the DSP protecting them
(Windows) both are fine. Unprotected (Linux), the right one runs out of
headroom first. That fits #61, where the rattle was only below ~1.6 kHz and
clean above.

One thing in your report doesn't fit it, though, and I don't want to skate
past it. You say it crackles at **any volume, including low**, and that a
high-pass in EasyEffects made no difference. Excursion problems get better at
low volume and go away under a high enough high-pass. **What cutoff did you set
the high-pass to?** Something around 100–200 Hz would leave the whole range
that rattled on #61 in place, so it wouldn't contradict the theory. A cutoff
above 2 kHz would.

## Is there a fix now?

Not yet, and I'd rather say so than guess. The real fix if the theory holds is
to turn that protection on with a tuning that matches these speakers. We don't
have a Book3 tuning, and the Book4/5 one is for different drivers in a
different chassis. Running the DSP with the wrong speaker model could remove
protection rather than add it. A crossover in PipeWire can't do it either:
`0x39` and `0x3d` get the same channel, so filtering the right channel would
filter the right woofer too.

**Your 2-amp workaround is safe to keep using in the meantime.** It's the
kernel's own code path, the one the Galaxy Book2 Pro models use upstream. The
tweeters are simply never enabled, and the woofers carry the full range. You
lose some treble, as you noticed, but you're not hurting anything. (Your
`snd_hda_intel power_save=0` line does nothing on this machine, by the way:
you're on the SOF driver, and `snd_hda_intel` isn't the one bound to your
card. Harmless to leave in.)

Also, good find: `hda_model=` on `snd_sof_intel_hda_generic` works. I told the
#61 reporter that switching models needed the legacy HDA driver; you've just
shown it doesn't.

On the `0x239e` write from our 940XFG script doing nothing: the upstream header
names `0x239e` as the amp's **coil-temperature read-back** register. Looking
again at the Windows capture that value came from, it was most likely Windows
*reading* the coil temperature, not writing anything. So "no change" is what
I'd now expect. That's something I need to chase on the 14" fix; it isn't
something you got wrong.

## Tests: listening only, no register writes

Everything below is listening, rebooting and reading logs. I'm deliberately not
asking for any `hda-verb` writes this round. On #61 I called a register write
"safe" and it froze the reporter's codec, so writes come later and only with
the risk spelled out.

**Setup: go back to stock for the tests.** Comment out your
`hda_model=` line in `/etc/modprobe.d/` (if you ran `sudo dracut -f` after
adding it, run it again), then turn on the driver's debug messages:

```bash
sudo grubby --update-kernel=ALL --args="snd_hda_codec_alc269.dyndbg=+p"
```

**Shut down fully** (power off, not restart), then power on into Fedora.
Check it took:

```bash
sudo dmesg | grep -E 'picked fixup|alc298_samsung_v2: Initialized'
```

You want the fixup line to end in `for PCI SSID 144d:c886` (**not**
`(model specified)`), and four `Initialized speaker amp` lines for `0x38`,
`0x39`, `0x3c`, `0x3d`.

### Step 0, before every test: turn the volume down first

This isn't optional. If my theory is right, your tweeters are running with
**no speaker protection** on Linux, and a full-level 120 Hz tone through
`plughw` is exactly the kind of stress that could damage the right one for
real. Your alsa-info has `Master` at 100%, so lower it to −20 dB (about 37%) before any tone:

```bash
amixer -c sofhdadsp -- sset Master -20dB
amixer -c sofhdadsp get Master        # must show [-20.00dB]
```

Repeat both lines at the start of **every** test below, including after the
suspend in Test 2 and the restart in Test 3: PipeWire can put `Master` back
up when it resumes the speakers. Don't play anything else between setting it
and running the tones.

Three rules for all the tones:

- The first tone should be **clearly quieter** than normal. If it isn't, stop
  and tell me rather than carrying on.
- **If the right side rattles loudly, press Ctrl+C immediately.** You don't
  need to hold it. A second of rattle tells me everything I need.
- Each tone plays once per side (`-l 1`), short. Don't loop or repeat them.

### Test 1: cold boot, where does it crackle?

No headphones plugged in, close anything playing audio, wait ~10 s, do step 0.
Then:

```bash
D=plughw:sofhdadsp,0
for f in 120 400 1000 2000 4000 8000; do
  echo "== $f Hz"; speaker-test -D $D -c 2 -t sine -f $f -l 1
done
```

`plughw` goes straight to the hardware, so neither PipeWire nor EasyEffects is
involved. Each run plays left, then right. Ctrl+C stops the current tone; press
it again to stop the loop. If it reports "device busy", wait a few more
seconds; failing that, use `D=default` with EasyEffects switched off, and
re-check step 0 afterwards.

Then two controls:

```bash
aplay -D $D -f S16_LE -r 48000 -c 2 -d 10 /dev/zero   # 10 s of silence, amps on
speaker-test -D $D -c 2 -t sine -f 400 -s 1           # left channel only
```

What I'd like to know:

- At which frequencies does the right side crackle? Is there a point above
  which it's clean? (#61's was ~1600 Hz.)
- During the **silence**, ear close to the right speaker: any crackle, pops or
  hiss?
- During the **left-only** tone: does anything come out of the right side?

Crackle only on the low tones means it's mechanical (tweeter excursion).
Crackle on 8 kHz, on silence, or on the right while only the left plays means
it's electrical, and that's a very different investigation.

### Test 2: does a suspend change anything?

`systemctl suspend`, wake it, **redo step 0**, then play just the 120 Hz and
4000 Hz tones once each, with the same Ctrl+C rule:

```bash
D=plughw:sofhdadsp,0
speaker-test -D $D -c 2 -t sine -f 120  -l 1
speaker-test -D $D -c 2 -t sine -f 4000 -l 1
sudo dmesg | grep alc298_samsung_v2 | tail -40
```

Background: the kernel tunes the amps once at boot and, as far as I can tell
from the code, never again after a resume. If it's clean on a cold boot and
crackles after a resume, that's a different, very fixable bug. The log should
show whether `Initialized speaker amp` reappears after the resume. I expect it
won't.

### Test 3: does coming from Windows change anything?

In Windows, play some audio, then **Restart** (not shut down) straight into
Fedora. **Redo step 0**, then the same two tones as Test 2, once each. Same as
the cold boot, or different?

The kernel's V2 init doesn't reset the amps, so anything it doesn't write
stays as the last owner left it. Caveat: I'm not certain the amps keep power
across a restart on this board at all. If the answer is "no difference", that's
still useful.

### Test 4 (optional): RtHDDump from Windows

Thank you for offering. One thing to know first: on #44 (Book3 Pro 14"),
Windows 11 blocked RtHDDump's `rtport.sys` driver no matter what the reporter
tried, so it could only produce a snapshot of the codec's registers, not a log
of what Windows sends. A snapshot shows only the last value written, which
isn't enough. **A trace** (the sequence of verbs Windows sends to `0x3c`
and `0x3d` at boot and when playback starts) would be the most valuable thing
anyone could give us for this, because it's exactly the tuning we're missing.
If you get a trace, please attach it. If you only get the snapshot, don't
spend time on it.

### Afterwards

Put your `hda_model=` line back and remove the debug flag:

```bash
sudo grubby --update-kernel=ALL --remove-args="snd_hda_codec_alc269.dyndbg=+p"
amixer -c sofhdadsp sset Master 100%   # back to where your alsa-info had it
```

then reboot.

Post Tests 1–3 when you have them, along with the high-pass cutoff, and I'll
take it from there. If you only have time for one, make it Test 1.
