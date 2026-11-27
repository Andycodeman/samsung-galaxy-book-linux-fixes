# Issue #160 — Book4 Pro 16" (NP960XGK, SSID 144d:c890): MAX98390 + Windows tables

Reporter: @szvince62, Ubuntu 26.10, kernel 7.3.0-11, Secure Boot on, tested at 7764e44.
Has NOT installed speaker-fix yet (worried about "wrong tuning").

## What we already do (no change needed for basic sound)

- `speaker-fix/` is not SSID-gated. `install.sh:65` only requires an ACPI `MAX98390:*`
  device, which this board has. The i2c-setup service finds the amps per board.
- `c890` is in upstream PR #5616's alc269 SSID list (`docs/triage/issue-100-findings.md:236`),
  and the README already says the upstream PR was reported working on the Pro 16".
- Default path = built-in Redrix DSM (`max98390_hda_filters.c`). Same tuning every Book4
  Pro/Ultra/Book5 user without the optional firmware runs today.

So answer to Q3: yes, the driver suits this hardware. Installing it is not a gamble.

## Optional Windows tables (#133) are C1D8-only, on purpose

`extract_adi_tables.py`:
- `TARGET_SUBSYS = "0x144dc1d8"`, refuses other codecs unless `--force`.
- One `KNOWN` hash, `b24fa092…`, mapped to the reporter's **group C**
  (amps `0x9B10/0x9BF0/0x9BA0/0x9C80`, DSM `0x9CD0`/`0x9FD0`).
- Reporter's file: same version 1.0.0.44, different hash `95b7e636…`, but group C at
  our offsets passes all the script's structural + L/R slot checks.

The C1D8 → group C mapping came from @4nrry's hardware validation (regmap dump on a
960XGL), not from decoding the driver's selection logic. Nobody knows which group the
driver picks for C890. The binary says "Project id based on registry_info", so the
choice is made from a registry value the INF sets per SUBSYS.

The loader (`max98390_hda_windows.c`) is table-driven and model-agnostic. Supporting
C890 = one more `KNOWN` entry + accept `0x144dc890` as a target. Small code, but only
once the offsets are known. Guessing a group could put woofer tuning on tweeters.

## Unknowns to settle before adding C890

1. **Why the hash differs.** Likely the per-model package is re-signed (Authenticode
   blob differs, data identical), but unproven. Test: hash of the table region in both
   files, e.g. `0x8F10..0xB100`, from the reporter and from @4nrry's Ultra copy.
2. **Which group is C890's.** Get the INF's per-SUBSYS `AddReg` lines (plain text, next
   to the .sys in the DriverStore folder) and/or the offline registry value. If the
   project IDs are 0..5 and C1D8 → 2 = group C, the mapping is likely by index.
3. **Amp count.** Pro 16" is likely 4 amps (2 woofers + 2 tweeters, like the Ultra).
   Group F looks like a woofer-only layout (no tweeter DSM found), so a 2-amp model
   would point there instead.

## Q4 "strict Windows mode"

Not recommended as a default. The fallback is the Redrix path every other user runs.
The real safety net is the offset/hash check in the extractor, which already refuses
unknown files. A module param that keeps amps off when the firmware fails is easy
(`windows_tuning` is a bool today) but would trade "sounds generic" for "silent",
with no protection gained. Would take it as an opt-in PR if someone wants it.

## Draft reply (NOT posted)

> Thanks for the careful report, and for not loading anything blind.
>
> **Short version: you can install `speaker-fix/` as it is today.** It doesn't depend on
> your subsystem ID. It binds to the ACPI `MAX98390` device your laptop has. The tuning it
> uses by default (the Chromebook DSM tables) is what every Book4 Pro/Ultra and Book5 user
> runs unless they've added the optional Windows file. `c890` is also in the upstream
> kernel PR's list, and the Pro 16" was reported working with it. With Secure Boot on,
> Ubuntu's DKMS signs the modules with its MOK key. If you haven't enrolled that key
> before, you'll be asked to at the next boot.
>
> On your questions:
>
> 1. **No, nobody has identified C890's group yet.** The C1D8 mapping to your group C came
>    from a hardware check on a Book4 Ultra, not from decoding how the driver picks.
> 2. **Yes, once we know the offsets.** The kernel side already reads any 4-amp table set,
>    so adding C890 is one table entry in the script. I don't want to guess a group, though.
> 3. **Yes**, see above.
> 4. I'd rather not make that the default. If the Windows file fails to load, the driver
>    falls back to the same tuning everyone else uses, so a strict mode would trade
>    "generic sound" for "no sound". The safety check that matters is the script refusing
>    unknown files and offsets, and it already does that. A PR adding it as an opt-in is
>    welcome.
>
> A few things would let us add your model properly (all read-only from your mounted
> Windows partition):
>
> - The `adiampdriver.inf` next to your `ADIAmpDriver.sys` in the same `FileRepository`
>   folder. It's plain text, so you can paste or attach it. We mostly need the sections
>   that mention `C890` / `C1D8` and their `AddReg` / project-ID values.
> - A hash of just the table region, so we can tell whether your file differs from the
>   Ultra's only in its signature:
>   ```bash
>   python3 -c 'import hashlib,sys; b=open(sys.argv[1],"rb").read(); print(hashlib.sha256(b[0x8F10:0xB100]).hexdigest())' /path/to/ADIAmpDriver.sys
>   ```
> - After installing `speaker-fix`: `sudo dmesg | grep -i max98390` and
>   `ls /sys/bus/i2c/devices/`, so we can see how many amps you have (we expect four).
>
> @4nrry, could you run the same region hash on your Ultra copy (`b24fa092…`)? If they
> match, we only need the group mapping.
