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


## Round 2 (2026-11-28) — reporter results

szvince62 comments 7236239012 + 7236280176:
- INF generic (`ACPI\MAX98390` only, empty CoInstaller AddReg); no project ID in Enum\ACPI\MAX98390, Services\ADIAmpDriver or the MEDIA class key.
- DSDT `\_SB.PC00.I2C2.AMPP` _CRS = 4 I2cSerialBus 0x38/0x39/0x3C/0x3D @400 kHz, _STA 0x0F → 4 amps; group F (2-amp) out.
- Full sha 95b7e636… (DriverStore == System32\drivers). Group hashes: A=B f717fd9a3ecd985b (identical), C d9025b2839a27946, D 1a9f91d41f6555e8, E 85edc582868b292e, F d4c270337ad18857.
- Still no 4nrry hashes.

Reading: driver most likely maps the HDA codec SUBSYS (both byte orders in the binary) to a group in code. Next = xrefs to the 0x600-stride table array + SUBSYS strings (adi_xrefs.py), and a per-group register diff (adi_groups.py). Both tested on synthetic PE only. Fallback = Windows warm restart → read-only i2ctransfer reads.

## Round 2 reply (posted 2026-11-28, comment 7236438269)

> Thank you, this is excellent work, and doing all of it from a read-only mount is exactly right.
>
> Your results settle two things and rule out the easy route:
>
> - **Four amps, confirmed.** The DSDT's four I2C descriptors (`0x38`, `0x39`, `0x3C`, `0x3D` on `I2C2`) match the four registry connection resources. So your board has the same 2 woofers + 2 tweeters layout as the Ultra, and I agree group F is out.
> - **There's no project ID in the INF or the device registry keys.** The INF is generic (`ACPI\MAX98390` only), so Windows doesn't hand the driver a project number. Since the binary carries the subsystem IDs in both orders (`SUBSYS_C890144D` and `SUBSYS_144DC890`), the driver most likely reads the Realtek codec's hardware ID itself and maps that to a group in code. You'll probably find `SUBSYS_144DC890` under `ControlSet001\Enum\HDAUDIO` in the same SYSTEM hive. That's likely the "registry_info".
> - **Groups A and B being identical** fits a "default / unknown model" entry next to the per-model ones. That's a guess until we see the code.
>
> So the answer lives in the driver's selection code. Two read-only scripts should get us there quickly. I tested both on synthetic PE files, not on a real `ADIAmpDriver.sys` (I don't have one).
>
> ### 1. Where the code touches the tables and the SUBSYS strings
>
> This lists every pointer and every x64 RIP-relative reference (`lea`/`mov reg,[rip+X]`) into the table region (`0x8E00`–`0xB400`) and to each SUBSYS string (ASCII and UTF-16), with RVAs you can jump to in Ghidra or IDA:
>
> <details><summary><code>adi_xrefs.py</code></summary>
>
> ```python
> #!/usr/bin/env python3
> """List code/data references into ADIAmpDriver.sys's amp-table region and its SUBSYS strings.
>
> Read-only. Prints, for the table region (file 0x8E00-0xB400) and each SUBSYS string:
>   - 8-byte absolute pointers (ImageBase+RVA) anywhere in the file (pointer tables)
>   - x64 RIP-relative disp32 in executable sections (lea/mov reg,[rip+X])
> so the selection code can be opened in Ghidra/IDA at the printed RVAs.
> """
> import struct
> import sys
>
> b = open(sys.argv[1], "rb").read()
> pe = struct.unpack_from("<I", b, 0x3C)[0]
> assert b[pe:pe + 4] == b"PE\0\0", "not a PE file"
> nsec, optsz = struct.unpack_from("<H", b, pe + 6)[0], struct.unpack_from("<H", b, pe + 20)[0]
> opt = pe + 24
> assert struct.unpack_from("<H", b, opt)[0] == 0x20B, "not PE32+"
> base = struct.unpack_from("<Q", b, opt + 24)[0]
> secs = []
> for i in range(nsec):
>     s = opt + optsz + 40 * i
>     name = b[s:s + 8].rstrip(b"\0").decode(errors="replace")
>     vsz, va, rawsz, raw = struct.unpack_from("<IIII", b, s + 8)
>     flags = struct.unpack_from("<I", b, s + 36)[0]
>     secs.append((name, va, vsz, raw, rawsz, bool(flags & 0x20000000)))
>
>
> def rva_of(off):
>     for name, va, vsz, raw, rawsz, x in secs:
>         if raw <= off < raw + rawsz:
>             return va + off - raw, name, x
>     return None, None, False
>
>
> def off_of(rva):
>     for name, va, vsz, raw, rawsz, x in secs:
>         if va <= rva < va + max(vsz, rawsz):
>             return raw + rva - va
>     return None
>
>
> print(f"ImageBase {base:#x}")
> for name, va, vsz, raw, rawsz, x in secs:
>     print(f"  {name:8} rva {va:#07x}-{va + vsz:#07x} file {raw:#07x} {'exec' if x else ''}")
>
> targets = [("table region", 0x8E00, 0xB400)]
> for s in (b"SUBSYS_C890144D", b"SUBSYS_C1D8144D", b"SUBSYS_144DC890", b"SUBSYS_144DC1D8",
>           b"subsys_c890144d", b"subsys_c1d8144d", b"subsys_144dc890", b"subsys_144dc1d8",
>           b"Project id"):
>     for enc, pat in (("ascii", s), ("utf16", s.decode().encode("utf-16-le"))):
>         i = b.find(pat)
>         while i >= 0:
>             targets.append((f"{s.decode()} ({enc})", i, i + len(pat)))
>             i = b.find(pat, i + 1)
>
> for label, lo, hi in targets:
>     rlo, sec, _ = rva_of(lo)
>     if rlo is None:
>         print(f"\n{label}: file {lo:#x} is outside every section")
>         continue
>     rhi = rlo + (hi - lo)
>     print(f"\n{label}: file {lo:#x}-{hi:#x} = rva {rlo:#x}-{rhi:#x} in {sec}")
>     for j in range(0, len(b) - 8):
>         v = struct.unpack_from("<Q", b, j)[0]
>         if base + rlo <= v < base + rhi:
>             r, s2, _ = rva_of(j)
>             print(f"  ptr  at file {j:#x} (rva {r and hex(r)}, {s2}) -> rva {v - base:#x}")
>     for name, va, vsz, raw, rawsz, x in secs:
>         if not x:
>             continue
>         for j in range(raw, raw + rawsz - 4):
>             d = struct.unpack_from("<i", b, j)[0]
>             t = va + (j - raw) + 4 + d
>             if rlo <= t < rhi:
>                 ctx = b[max(raw, j - 3):j].hex()
>                 print(f"  rip  at rva {va + j - raw - 3:#x}..{va + j - raw + 4:#x} "
>                       f"(bytes before disp: {ctx}) -> rva {t:#x}")
> ```
> </details>
>
> ```bash
> python3 adi_xrefs.py /mnt/windows/Windows/System32/drivers/ADIAmpDriver.sys
> ```
>
> What I'd expect: one or a few `lea` hits on group A's start (the base of a 0x600-stride array), with an index multiplied by `0x600` nearby. Then follow that index back to the code that compares the codec ID against the SUBSYS strings. Whatever value C890 sets is your group, and C1D8's should come out as group C. If C1D8 lands anywhere else, my reading is wrong and we stop there.
>
> ### 2. What actually differs between the groups
>
> This parses groups A–F with the same layout `extract_adi_tables.py` uses for group C. It prints only the registers whose values differ between groups, plus a short hash of each group's woofer and tweeter DSM blocks:
>
> <details><summary><code>adi_groups.py</code></summary>
>
> ```python
> #!/usr/bin/env python3
> """Compare the per-amp register tables of ADIAmpDriver.sys groups A-F. Read-only.
>
> Assumes each group uses group C's layout (as extract_adi_tables.py reads it for C1D8):
> amp tables at +0x000 (0x38), +0x0E0 (0x39), +0x090 (0x3C), +0x170 (0x3D), each a
> zero-terminated list of (u16 reg, u16 val). Prints only registers whose value differs
> between groups, plus a short hash of each group's two DSM blocks.
> """
> import hashlib
> import struct
> import sys
>
> b = open(sys.argv[1], "rb").read()
> AMPS = [("0x38", 0x000), ("0x39", 0x0E0), ("0x3C", 0x090), ("0x3D", 0x170)]
> groups = {}
> for gi, g in enumerate("ABCDEF"):
>     base = 0x8F10 + 0x600 * gi
>     amps = {}
>     for amp, rel in AMPS:
>         regs, off = {}, base + rel
>         for _ in range(64):
>             reg, val = struct.unpack_from("<HH", b, off)
>             off += 4
>             if (reg, val) == (0, 0):
>                 break
>             if not (0x2000 <= reg <= 0x24FF and val <= 0xFF):
>                 regs = None
>                 break
>             regs[reg] = val
>         else:
>             regs = None
>         amps[amp] = regs or None
>     dsm = [hashlib.sha256(b[base + o:base + o + n * 8]).hexdigest()[:8] for o, n in ((0x1C0, 95), (0x4C0, 40))]
>     groups[g] = (amps, dsm)
>     bad = [a for a, r in amps.items() if r is None]
>     print(f"group {g} @ {base:#x}: amp tables {'OK' if not bad else 'NOT this layout: ' + ','.join(bad)}"
>           f"  sizes {[len(r) if r else '-' for r in amps.values()]}  dsm woofer {dsm[0]} tweeter {dsm[1]}")
>
> good = [g for g, (a, _) in groups.items() if all(r is not None for r in a.values())]
> if len(good) < 2:
>     sys.exit("\nfewer than two groups use this layout; nothing to compare")
> print("\nregisters that differ between groups " + "/".join(good) + " (-- = not written):")
> for amp, _ in AMPS:
>     regs = sorted({r for g in good for r in groups[g][0][amp]})
>     rows = []
>     for r in regs:
>         vals = [groups[g][0][amp].get(r) for g in good]
>         if len(set(vals)) > 1:
>             rows.append(f"  {amp} {r:#06x}  " + "  ".join(f"{g}={v:02x}" if v is not None else f"{g}=--" for g, v in zip(good, vals)))
>     print("\n".join(rows) if rows else f"  {amp}: identical in all of them")
> ```
> </details>
>
> ```bash
> python3 adi_groups.py /mnt/windows/Windows/System32/drivers/ADIAmpDriver.sys
> ```
>
> It only prints register numbers and values, no DSM coefficients, so it's fine to paste here. If C, D and E differ only in a few speaker values (Rdc, thermal, `0x23BA` volume), they're the same amps with different speaker calibrations. If the slot registers differ, the channel routing is different.
>
> @4nrry, if you can run the fingerprint script from my last comment and `adi_groups.py` on your Ultra copy (`b24fa092…`), that tells us whether the two files carry identical tables. Matching groups C–E would mean your file and @szvince62's differ only in signing.
>
> ### If the code is hard to follow
>
> There's an empirical fallback, but it needs one Windows boot: play a sound in Windows, restart straight into Linux (a warm restart, not a power-off), and read a few amp registers with `i2ctransfer` before anything resets them. Reads don't change anything, and nothing binds the amps until `speaker-fix` is installed. Whether the values survive the restart isn't certain. If you want to try it, I'll post the exact read-only commands.
>
> Once we know C890's group, adding it to `extract_adi_tables.py` is a small change, and you'd be the first to test it.

## Round 3 (2026-11-28) — C890 = project ID 3 = group D (comment 7236652567)

Reporter decoded the selection function (VA 0x1400108D4): `wcsstr` of the codec ID string
from `\Registry\Machine\System\CurrentControlSet\Enum\PCI` against the SUBSYS strings.
The project ID is stored at device context +0xEC and indexes six pointer arrays (6 x u64 each).

| SSID | Project | Group | Model (from our issues) |
|---|---|---|---|
| 144d:f02e | 0 | A | unknown |
| 144d:c892 | 1 | B (= A byte for byte) | Book4 Pro 360 (#99) |
| 144d:c1d8 | 2 | C | Book4 Ultra (#133, current extractor) |
| 144d:c890 | 3 | D | Book4 Pro 16" (this issue) |
| 144d:ca07 | 4 | E (woofer Rdc + 0x23BA differ) | Book4 Pro 14" (#53) |
| 144d:c896 | 5 | F (2 amps; NULL 3rd/4th amp + tweeter DSM) | Book2 Pro SE (#137, 2 amps confirmed by BrunoGee) |

**Independently checked** against his attachments (`adi_xrefs-results.txt`, `project-id-validation.txt`):
- .data rva 0xB000 = file 0x8E00 (file = rva - 0x2200). Pointer arrays at rva 0xD328/0xD358/0xD388/0xD3B8/0xD3E8/0xD418
  (amp 0x38/0x39/0x3C/0x3D, DSM woofer/tweeter). Index 3 → rva 0xC310/0xC3F0/0xC3A0/0xC480/0xC4D0/0xC7D0
  = file **0xA110/0xA1F0/0xA1A0/0xA280/0xA2D0/0xA5D0**. Index 2 → exactly the extractor's current C1D8 offsets.
  Index 5 has no 0x3C/0x3D/tweeter-DSM pointers, so F really is 2 amps.
- My script's string RVAs (C890 variants at 0x11AA0/0x11AC0/0x11AE0/0x11B00, C1D8 at 0x11A20..0x11A80) are exactly
  the `lea rdx` targets in his objdump. C890 hits → `jne 0x140010b13` → `mov edi,3`; C1D8 → `0x140010b1a` → `mov edi,2`.
- Group D amp register tables = group C's. Only DSM differs (25 bytes each in woofer/tweeter). Same counts 35/35/17/17, 95/40,
  so the kernel loader needs no change for C890.
- Hash 95b7e636… applies to his binary only. We still don't know whether the Ultra's b24fa092… has the same arrays (4nrry hashes pending).

**Next (recommendation):** extractor → per-SSID profiles under each known hash. 95b7e636: C890 (D) + C1D8 (C, pointer-verified).
b24fa092: C1D8 only. Codec check picks the profile, refuses SSIDs with no profile. C892/CA07 (4-amp) are trivial to add later
but untested. C896 (2-amp) needs a loader check first. Strict mode = small opt-in module param, Andy's call.

## Status

OPEN. Group D identified + verified. Awaiting Andy's decision: extractor C890 profile (+ optional strict mode), then reporter hardware test.
