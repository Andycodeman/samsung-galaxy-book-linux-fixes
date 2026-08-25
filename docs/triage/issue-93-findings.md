# Issue #93 — "Speaker fix: woofers produce no bass (tweeters work, sound very thin)" (@Elias02345)

**Classification: real bug in this repo — NOT the known "Linux sounds thinner than
Windows" limitation. Do not close as expected behaviour.**

Hardware: Galaxy Book5 Pro 360, NP960QHA-KG2DE (Lunar Lake), Arch/Omarchy,
kernel 7.1.8-arch1-3, ALC298 + 4x MAX98390 (0x38/0x39 woofers, 0x3c/0x3d
tweeters) — squarely inside `speaker-fix/`'s coverage, not `speaker-fix-940xfg/`.

**Status:** fix committed as
[`1194a83`](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/commit/1194a83);
reply **posted** 2026-08-25 with maintainer sign-off —
[comment-5413748371](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/93#issuecomment-5413748371).
Issue deliberately left **open** pending the reporter's confirmation. Release to
be cut once they confirm.

---

## Why this is not a duplicate of the documented limitation

The maintainer's initial read was that this is the recurring "thin sound"
report already answered by
[`speaker-fix/README.md#sound-quality--eq`](../../speaker-fix/README.md#sound-quality--eq).
That section does exist, is complete, and has a working anchor — so the close
would have been *linkable*. It is still the wrong call, for one reason:

> "Boosting bass in EasyEffects (PipeWire-side EQ) has **zero** effect."

EasyEffects *is* the documented workaround. A reporter telling us the workaround
does nothing is not a reporter who needs to be pointed at the workaround. And
"EQ does nothing" is a real diagnostic signal, not a figure of speech: if the
loss were the enclosure's physics or the missing Windows DSP, a low-shelf boost
would still audibly change something. An EQ with *no* effect means the
attenuation happens after the signal leaves the host — inside the amp.

The reporter's own hypothesis (mismatched DSM calibration clamping the woofer
band) pointed at the right file. It was closer to the mark than they knew: the
blobs in this repo are not just mistuned for the enclosure, they are corrupted.

## Root cause: the vendored DSM blobs were transcribed wrong

`speaker-fix/src/max98390_hda_filters.c` writes 913 bytes per amp into registers
`0x2050`–`0x23E0`:

```c
#define MAX98390_DSM_START_ADDR  0x2050
#define MAX98390_DSM_PARAM_SIZE  913

for (i = 0; i < MAX98390_DSM_PARAM_SIZE; i++)
        regmap_write(priv->regmap, MAX98390_DSM_START_ADDR + i, firmware[i]);
```

Upstream ([thesofproject/linux#5616](https://github.com/thesofproject/linux/pull/5616),
`sound/hda/codecs/side-codecs/max98390_hda_filters.c` @ `bfa17b7`) has both
arrays at exactly 913 bytes, one 16-byte row per line, each row carrying a
trailing `// 0xNNNN` address comment.

When they were copied into this repo the address comments were stripped — and
with them, the only thing that made a misaligned row visible. Byte-diffing our
copy against upstream:

| Blob | Ours | Upstream | Defect |
| --- | --- | --- | --- |
| woofer | **929** bytes | 913 | one extra all-zero 16-byte row **inserted** at index 816 (`0x2380`) |
| tweeter | **833** bytes | 913 | five 16-byte rows (80 bytes) **deleted** at index 736 (`0x2330`) |

Verified: `ours_woofer[:816] == upstream[:816]`, `ours_woofer[832:] == upstream[816:]`,
`ours_tweeter[:736] == upstream[:736]`, `ours_tweeter[736:] == upstream[816:]`.

Consequences, both silent — the loop has a fixed trip count and never looked at
the array size:

**Woofer.** Registers `0x2380`–`0x238F` get written as zeros. Everything from
`0x2390` to `0x23E0` receives the value upstream intended for the register 16
*lower*. The real values for `0x23D1`–`0x23E0` — including `0x23E0 DSMIG_EN =
0x21` — are in the array but past index 912, so they are never written at all.
`0x2380`+ is where the DSM excursion/limiter parameters live, which is exactly
the band the reporter says is missing.

**Tweeter.** From `0x2330` on, every register receives the value belonging 80
registers *higher*. Worse, the loop runs 913 iterations over an 833-byte array:
**80 bytes of out-of-bounds read** in kernel space, and whatever `.rodata`
follows gets written into registers `0x2381`–`0x23E0`. That is a KASAN splat
waiting to happen independently of any audio symptom.

The asymmetry matches the report: the woofer's mangled region is the excursion
limiter that gates low-frequency output, while a tweeter reproducing highs is
far less sensitive to a wrong limiter, so it still "works".

## The fix

- Both arrays restored to upstream's exact 913 bytes, byte-for-byte verified
  against `bfa17b7`.
- Per-row `/* 0xNNNN */` address comments restored (kernel comment style to
  match the rest of the file). These are what makes a shifted row visible on
  sight; losing them is how this got in.
- `static_assert(ARRAY_SIZE(blob) == MAX98390_DSM_PARAM_SIZE)` on both arrays,
  so a wrong-length blob is a build failure instead of an OOB read.

Verified by building the DKMS module against kernel 7.0.0-30-generic: clean
build; both upstream blobs appear verbatim in the compiled `.rodata`; deleting a
single byte from a blob fails the build on the new `static_assert`.

No DKMS version bump needed — `speaker-fix/install.sh:120` already does
`dkms remove --all` before re-adding, so an existing 1.0 install picks up the
corrected source on reinstall.

## Still true after the fix

The DSM blobs remain Google Redrix Chromebook tuning on Samsung enclosures, and
the README's "thinner than Windows" framing still applies once the woofers are
actually reproducing bass again. What changed is that "thin" no longer covers
"the woofers are dead". The README now says so, and Troubleshooting has an entry
for the silent-woofer case.

The reporter's Windows-side find (`lnl_dsm_lib.bin` et al. under
`intcoed_oemlibpath.inf_amd64_*`) is genuinely useful but is, as they say
themselves, compiled Intel SST DSP code (`$AE1` / `$CPD` headers), not a
MAX98390 register blob. Not actionable here; worth keeping on file.

## Open, not addressed here

- Whether the corrected blobs fully restore bass on Book5 Lunar Lake, or only
  partly — needs the reporter to confirm. Redrix tuning on a different
  enclosure may still under-drive the woofers even when correctly aligned.
- `max98390_configure_high_pass_filter()` takes a `cutoff_freq` argument
  (`3000`) that the function body never references — the cutoff is whatever the
  blob bakes in. Pre-existing, inherited from upstream, left alone.

---

## Reply as posted

Posted verbatim as
[comment-5413748371](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/93#issuecomment-5413748371),
expanded from the draft below with the reinstall commands, the
`grep '/* 0x2380 */' /usr/src/max98390-hda-1.0/src/max98390_hda_filters.c`
check that tells the reporter whether they actually picked up the corrected
source, and a three-way ask (bass back / better but weak / no change) so the
answer distinguishes "corruption was the whole story" from "Redrix tuning is
also a poor match for the enclosure".

> Thanks for this — the detail here is what made it findable, and you were
> closer than you thought.
>
> Normally "thin sound" is our known limitation: the DSM blobs in this package
> come from a Google Redrix Chromebook rather than Samsung's Windows driver, and
> there's a [README section](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/blob/main/speaker-fix/README.md#sound-quality--eq)
> about closing the gap with EasyEffects. But you said EQ has *zero* effect, and
> that ruled the usual answer out — if it were just tuning or enclosure physics,
> a low-shelf boost would still change something.
>
> So we went and diffed our blobs against upstream PR #5616. They don't match.
> They were transcribed into this repo with the per-row address comments
> stripped, and two rows went wrong in the process:
>
> - **woofer blob: 929 bytes instead of 913** — an extra all-zero 16-byte row
>   inserted at register `0x2380`
> - **tweeter blob: 833 bytes instead of 913** — 80 bytes dropped at `0x2330`
>
> The loader writes a fixed 913 bytes, so nothing complained. On the woofers,
> `0x2380`–`0x238F` were written as zeros and every parameter above that landed
> 16 registers too high — which is precisely the DSM excursion-limiter block
> that decides how much low end the amp will pass. Your read was right: the
> limiter was clamping the woofer band, and no host-side EQ could reach it. (The
> tweeter blob being *short* also meant the driver was reading 80 bytes past the
> end of the array and writing the garbage to the amp — a separate bug your
> report flushed out.)
>
> Both blobs are now restored byte-for-byte from upstream, the address comments
> are back, and there's a build-time size check so this can't silently happen
> again.
>
> Please reinstall and reboot:
>
> ```bash
> cd speaker-fix && sudo ./install.sh && sudo reboot
> ```
>
> Then let us know how the woofers sound. Two outcomes are possible and it's
> useful to know which: bass genuinely back, or better but still weak. The
> second would mean the Redrix tuning is a poor match for the Book5 enclosure on
> top of the corruption — which is the point where your Windows-side find
> becomes the interesting thread again.
>
> On that: agreed that `lnl_dsm_lib.bin` is an Intel SST DSP module (`$AE1` /
> `$CPD`), not a MAX98390 register blob, so it isn't something we can drop in.
> Documenting where it lives is still worth having on record. Let's see where
> the reinstall lands first.

**Recommendation: keep #93 open** until the reporter confirms. It found a real
bug; closing it as expected behaviour would have buried both the misalignment
and the out-of-bounds read.
