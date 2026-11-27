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

## Reply (posted 2026-11-27, comment 7227786164)

Expanded from the first draft: thanks, plus step-by-step asks to identify C890's group
(.inf AddReg, offline SYSTEM hive via hivexregedit, per-group sha256 of A–F, amp count).
Asks @4nrry for the same per-group hashes from the Ultra copy.

> Thank you for this report. Pulling the driver off a read-only mount, working out the six table groups and running the structural checks yourself saves a lot of back-and-forth. Holding off until you knew what the tuning would do was the right call too.
>
> ## Short version: you can install `speaker-fix/` today
>
> The speaker fix doesn't depend on your subsystem ID. It binds to the ACPI `MAX98390` device your laptop has, and the setup service finds however many amps are on the I2C bus.
>
> What it loads by default is the generic DSM tuning taken from a Google Redrix Chromebook (same MAX98390 amps). Every Book4 Pro, Book4 Ultra and Book5 user runs that same tuning unless they've added the optional Windows file. `c890` is also in the subsystem list of the upstream kernel PR ([thesofproject/linux#5616](https://github.com/thesofproject/linux/pull/5616)), and the Pro 16" was reported working with it. It will sound thinner than Windows (see the README), but it won't be wrong for your hardware.
>
> With Secure Boot on, Ubuntu's DKMS signs the modules with its MOK key. If you've never enrolled that key, you'll be asked to at the next boot.
>
> ## Your questions
>
> 1. **C890's group: not identified yet.** The Ultra (`c1d8`) gets your **group C** (`0x9B10` amps, `0x9CD0` woofer DSM, `0x9FD0` tweeter DSM). That came from @4nrry testing on a Book4 Ultra and matching the live amp registers ([#133](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/133)). Nobody decoded how the driver chooses a group. So group C passing your structural checks tells us the layout is the same, not that it's your model's group.
> 2. **Extending `extract_adi_tables.py`: yes, once we know the offsets.** The kernel side (`max98390_hda_windows.c`) already loads any per-amp table set from `max98390-galaxybook.bin`. Adding C890 is one new entry in the script's `KNOWN` table plus accepting `0x144dc890`. I don't want to guess a group, though: a wrong guess could put woofer tuning on the tweeters.
> 3. **The current MAX98390 driver suits your hardware: yes**, see above.
> 4. **Strict mode: I'd rather not make it the default.** If the Windows file is missing or fails to parse, the driver falls back to the same Redrix tuning everyone else runs. So a strict mode would trade "generic sound" for "no sound" without protecting anything. The safety check that matters is the extractor refusing unknown files and offsets, and it already does that. If you'd like it as an opt-in module parameter, a PR is welcome.
>
> ## How to find the right table group for your Book4 Pro 16"
>
> The driver says it picks its configuration from a *"Project id based on registry_info"*. So we need two things: what project ID your model gets, and whether your `.sys` matches the Ultra's apart from its signature. Everything below is read-only from your mounted Windows partition. You don't need to boot Windows, and you don't need to load our modules first.
>
> I'll write `/mnt/windows` for your mount point. Change it if yours is different.
>
> ### Step 1: the driver's `.inf`
>
> This file is what sets the project ID for each subsystem. It sits next to `ADIAmpDriver.sys` and is plain text:
>
> ```bash
> ls -d /mnt/windows/Windows/System32/DriverStore/FileRepository/adiampdriver.inf_amd64_*
> grep -n -i -E 'c890|c1d8|project|addreg|hkr' /mnt/windows/Windows/System32/DriverStore/FileRepository/adiampdriver.inf_amd64_*/*.inf
> ```
>
> Please attach the whole `.inf` (or each one, if `ls` shows more than one folder). The `grep` output alone helps too. We're after the install section that matches `SUBSYS_C890144D` and the `AddReg` lines it pulls in.
>
> ### Step 2: the value Windows actually stored
>
> The `.inf` says what *should* be written. The registry shows what your install *did* write. You can read the offline SYSTEM hive with `hivexregedit` (Ubuntu package `libwin-hivex-perl`):
>
> ```bash
> sudo apt install libwin-hivex-perl
> hivexregedit --export --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' \
>   /mnt/windows/Windows/System32/config/SYSTEM '\ControlSet001' > ~/system-cs001.reg
> grep -n -i -a -B3 -A25 'max98390\|adiamp' ~/system-cs001.reg > ~/adi-registry.txt
> ```
>
> Please attach `~/adi-registry.txt`, not the full export, which is large and holds unrelated machine details. If `grep` finds nothing, say so and we'll try another key.
>
> ### Step 3: per-group fingerprints of your `.sys`
>
> This tells us whether your file differs from the Ultra's (`b24fa092…`) only in its Authenticode signature, or whether the tables differ too:
>
> ```bash
> python3 - /mnt/windows/Windows/System32/DriverStore/FileRepository/adiampdriver.inf_amd64_*/ADIAmpDriver.sys <<'EOF'
> import hashlib, sys
> for path in sys.argv[1:]:
>     b = open(path, "rb").read()
>     print(path)
>     print("size", len(b), "sha256", hashlib.sha256(b).hexdigest()[:16])
>     for g, o in zip("ABCDEF", range(0x8F10, 0xB311, 0x600)):
>         print(g, hex(o), hashlib.sha256(b[o:o + 0x600]).hexdigest()[:16])
> EOF
> ```
>
> @4nrry, could you run the same on your Ultra copy and post the output? If groups A–F match between the two files, the drivers carry identical tables, and the only question left is which group each project ID selects.
>
> ### Step 4: after installing `speaker-fix`
>
> ```bash
> sudo dmesg | grep -i max98390
> ls /sys/bus/i2c/devices/
> ```
>
> This shows how many amps your board has and at which addresses. We expect four (`0x38`/`0x39` woofers, `0x3c`/`0x3d` tweeters), like the Ultra. If you only see two, that changes which groups are even candidates.
>
> Once we have steps 1–3, I'll add the C890 entry to `extract_adi_tables.py` and the README. Then you can build `max98390-galaxybook.bin` from your own driver the same way Ultra owners do.
>
> Thanks again for the careful work and the offer to test. It's what makes adding a new model possible.

## Status

OPEN, awaiting reporter steps 1–4 and @4nrry's group hashes. No code change yet.
