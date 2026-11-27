# Issue #68 — Galaxy Book6 Ultra webcam (Panther Lake IPU7)

Status (2026-11-27): reply below POSTED 2026-11-27 as comment 7228762369. Covers @jpnayak (the
reporter, Book6 Ultra), @OlleHall (three unanswered posts from 2026-08-09) and
@z4ziggy (new comment 7228055613). Companion to `issue-57-findings.md`.

## The thread so far

| When | Who | What |
|---|---|---|
| 2026-07-12 | jpnayak | Book6 Ultra (`Galaxy Book6 Ultra - PAMC`), `8086:b05d` IPU, RTX 5070, Ubuntu 7.0 kernel. Asks for webcam support. No sensor info. |
| 2026-07-13 | us (4956163551) | Same claims as our July #57 reply: "ov08f40 driver does not exist anywhere", "in-tree ov08x40 is a different sensor". Asked for `dmesg`/`ls /sys/bus/i2c/devices`/`cam -l`. **jpnayak never answered.** |
| 2026-08-09 | OlleHall ×3 | Book6 Pro 14": fingerprint, keyboard backlight and camera working on Ubuntu 26.04 as DKMS debs. Chrome needs the PipeWire camera flag. Page: http://olle.bz.nu/galaxybook6pro/. **We never replied.** |
| 2026-11-27 | z4ziggy (7228055613) | Book6 Ultra probably has the same SC200PC (`SSLC2000`) as the Book6 Pro. Points to his driver in #57. |

## What Olle's page says (read 2026-11-27)

- Tested on Galaxy Book6 Pro **NP944XJG-KG4SE**, BIOS PRHK.1.4.56.576,
  kernel 7.0.0-2x. Camera, backlight + power, fingerprint all confirmed.
- **Camera:** SmartSens SC200PC (`SSLC2000`) on IPU7. Same finding as
  z4ziggy, three and a half months earlier. Driver is based on
  **github.com/Jabbslad/sc200pc-linux**, plus one `IPU_SENSOR_CONFIG("SSLC2000", 0)`
  line in `ipu-bridge`, a softISP tuning file and a WirePlumber rule hiding the
  raw IPU7 nodes. No relay or v4l2loopback. Their write-up also says the
  sensor was first mis-identified as OV08X40.
  Download: `galaxybook6pro-camera-dkms_1.5_all.deb`.
- **Keyboard backlight / profiles / charge limit:** Book6 Pro's SCAI device is
  `SAMB430`, missing from `samsung-galaxybook`. Package:
  `samsung-galaxybook-dkms_1.0-samb430_all.deb`.
- **Fingerprint:** Goodix `27c6:6984` (goodixmoc), patched libfprint rebuilt
  from Ubuntu source + `apt-mark hold`.
- Binary debs only, served over plain HTTP. The page describes a `build.sh` +
  `src/` but publishes no source repo.

## Checked upstream (2026-11-27)

- `SAMB430` **is in mainline**: commit 31e1acf15df9 "platform/x86:
  samsung-galaxybook: Add SAMB430 device ID" (Riccardo Squarcialupi, tested on
  NP944XJG-KG4IT). `compare` says v7.3-rc5 and v7.3 contain it; v7.2 does not.
- `27c6:6984` **is in upstream libfprint**: present in tag v1.94.100
  (2026-07-26), absent in v1.94.10. Whether a given distro's package has it
  depends on which branch it builds from (Olle's base was
  `1.95.1+tod1-0ubuntu1`, which evidently lacked it), so the reply only says
  "upstream already has it".

## Three community SC200PC drivers now

| Project | Since | Form | Tested on |
|---|---|---|---|
| Jabbslad/sc200pc-linux | 2026-04-18 | Source, Arch/AUR packaging. Packages: `ipu-bridge-sslc2000-dkms`, `sc200pc-dkms`, `galaxybook6pro-camera` | Book6 Pro NP940XJG-KGDUK |
| OlleHall (based on Jabbslad) | 2026-08-09 | Binary .debs, Ubuntu 26.04 | Book6 Pro NP944XJG-KG4SE |
| z4ziggy/galaxybook6-camera | 2026-11-27 | Source, `make install` + DKMS, Debian/Ubuntu deps | Book6 Pro, Ubuntu 26.04, XanMod 7.2.15 |

**This answers the question we asked Marc in #57.** His DKMS list had an
`ipu-bridge-sslc2000` module: that is Jabbslad's package name. So Marc had
very likely already tried Jabbslad's driver before he posted. Worth a short
follow-up in #57 (not drafted here).

Bridge entries differ: Olle's/Jabbslad's line is `("SSLC2000", 0)` (no link
frequency), z4ziggy's is `("SSLC2000", 1, 390000000)`. Not something for us to
rule on; left out of the reply.

## The Book6 Ultra is still unconfirmed

All three drivers were tested on Book6 **Pro** units. z4ziggy's "probably the
same sensor" is a reasonable guess, not a check. jpnayak never sent the sensor
info we asked for in July. The z4ziggy/Olle `SSLC2000` status check settles it
in one line, so the reply asks for that instead of re-asking the July list.

The Ultra has an RTX 5070. Every one of these drivers delivers the picture
through PipeWire's libcamera source with the softISP. On hybrid-NVIDIA
machines that is exactly our README's "Known gap" (GPU debayer inside
`pipewire.service` picking the NVIDIA EGL vendor → black image), so the reply
points at that section. Our July note about "the CPU-debayer path (see #66)"
was about our relay, which a Book6 owner won't be running.

## Reply (posted 2026-11-27, comment 7228762369)

> Hi @jpnayak, @OlleHall, and thanks @z4ziggy.
>
> First, an apology and a correction.
>
> **@OlleHall, sorry for the silence.** You posted three times in August that you had the camera, keyboard backlight and fingerprint reader working on your Book6 Pro, and nobody here replied. That was a miss on my side. You had also already found the real sensor back then.
>
> **@jpnayak, my July reply to you was wrong**, the same way my July reply in #57 was (corrected there today). I wrote that the OV08F40 driver "does not exist anywhere" and that the in-tree `ov08x40` was a different sensor. In fact mainline `ov08x40` already matches the ACPI ID `OVTI08F4`. That ID was never the problem: on the Book6 units people have checked, the `OVTI08F4` entries are disabled in firmware. The camera that's actually wired up is a **SmartSens SC200PC** (ACPI ID `SSLC2000`). Mainline has no driver for it, and stock `ipu-bridge` doesn't know it either. That's why you get `no subdev found in graph`.
>
> **There are now three community drivers for it**, all tested on Book6 **Pro** units:
>
> - [Jabbslad/sc200pc-linux](https://github.com/Jabbslad/sc200pc-linux): the original, from April, with Arch/AUR packaging.
> - @OlleHall's Ubuntu 26.04 `.deb` packages, based on Jabbslad's driver: http://olle.bz.nu/galaxybook6pro/
> - @z4ziggy's [galaxybook6-camera](https://github.com/z4ziggy/galaxybook6-camera): source + DKMS via `make install`, Debian/Ubuntu dependencies handled for you.
>
> **@jpnayak, nobody has checked a Book6 Ultra yet.** z4ziggy's guess that it uses the same sensor is likely right, but please confirm before installing anything:
>
> ```
> cat /sys/bus/acpi/devices/SSLC2000:00/status   # 15 = SC200PC present
> cat /sys/bus/acpi/devices/OVTI08F4:00/status   # 0 = disabled placeholder
> ```
>
> If `SSLC2000` reads 15, try one of the drivers above. Two notes for your machine:
>
> 1. If you ever ran our `webcam-fix-book5/install.sh --force`, run `./webcam-fix-book5/uninstall.sh` and reboot first. Our package installs its own `ipu-bridge.ko` without the `SSLC2000` entry, and you don't want two of them fighting over which one loads.
> 2. Your RTX 5070 matters here. These drivers send the picture through PipeWire's libcamera source, and on hybrid-NVIDIA laptops that path can pick the NVIDIA GPU for debayering and give a black image. If that happens, the fix is in our README under [LED on but black image, on laptops with a dedicated GPU](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/blob/main/webcam-fix-libcamera/README.md#led-on-but-black-image-on-laptops-with-a-dedicated-gpu) (the `pipewire.service` drop-in under "Known gap"). My July note about the CPU-debayer path in #66 was about our relay, which you won't be running, so you can ignore it.
>
> Whatever the result, please post it here or in the driver's repo, together with `cat /sys/class/dmi/id/product_name`. It would be the first Ultra report for any of them.
>
> **@OlleHall, two things you can probably drop now:**
>
> - The `SAMB430` ID for `samsung-galaxybook` is in mainline since **7.3** (commit 31e1acf15df9).
> - Upstream libfprint already lists the Goodix `27c6:6984` too. So once your distro's kernel and libfprint catch up, the backlight package and the held libfprint packages won't be needed.
>
> If you could put the camera package's `build.sh` + `src/` on GitHub (or anywhere public), that would help people who'd rather build from source than install a binary `.deb`. Comparing notes with Jabbslad and z4ziggy would probably help too: there are now three copies of an SC200PC driver, and one of them will need to go upstream eventually.
>
> On our side, the Book6 stays out of this repo's installers, as I said in #57. Different sensor and bridge, I don't have the hardware, and you all do. I'll add a README pointer to these projects, and have the Book5 installer send `8086:b05d` machines there instead of installing a bridge that can't see their sensor.

## Follow-ups done 2026-11-27 (uncommitted)

- #57 note to Marc about Jabbslad posted (7228790732).
- README: new "Webcam — Galaxy Book6 (Panther Lake)" section listing the three
  drivers; `webcam-fix-book5/README.md` points there next to `--force`.
- `webcam-fix-book5/install.sh` step 3 refuses `8086:b05d` even with
  `--force` and prints the three links + the uninstall hint. Nothing is
  installed before step 3. Tested by sourcing the step-3 block with a stub
  `lspci`: b05d exits 1 with and without `--force`; 645d continues; no IPU
  exits 1 without `--force` and continues with it. Not changed: the NixOS
  `webcam-fix-book5.nix` module (no PCI gate there).

## Round 2 — z4ziggy 7229550737 (2026-11-27 22:42)

Points to **MarcoGlauser/galaxybook6-ultra-camera** (GPL-2.0, created
2026-08-11, last push 2026-09-29). Read its README:

- Built and tested on a Book6 **Ultra**, model `PAMC-960UJH-PTLH-0`.
  jpnayak's DMI is `Galaxy Book6 Ultra - PAMC`, so it's the same family. Ubuntu 26.04,
  stock `7.0.0-34-generic`.
- Same SC200PC driver (forked from Jabbslad), plus an `ipu-bridge-sslc2000`
  DKMS override (bundled 7.0 `ipu-bridge.c`). The picture goes through the
  **IPU7 hardware ISP**: Intel ipu7-camera-hal at e5172cc + icamerasrc,
  built from Intel's GitHub. The graph settings and `.aiqb` are converted from
  Samsung's Windows driver, which the installer downloads from Samsung's
  download center. Output goes through `v4l2-relayd` → v4l2loopback "Virtual Camera",
  720p30 (24 fps in dim light). No libcamera, so the NVIDIA GPU-debayer
  black-image gap in our previous reply doesn't apply to it.
- Caveats from its README: no uninstall script, Ubuntu 7.0 only for now
  (z4ziggy has PRs #1–#3 open there: s_ctrl deadlock, other kernels, 1080p
  NV12), and it needs a MOK for Secure Boot.

Also learned:

- **Jabbslad/sc200pc-linux issue #1** (dcippolito, Book6 Ultra NP960UJH,
  Fedora 44, kernel 7.1.3): the original driver advertises a **195 MHz** link
  frequency. On 7.1.x IPU7 ISYS programs D-PHY from it → probe OK, stream
  starts, no frames, nothing logged. The fix is 416 MHz, and analogue gain was also
  mis-encoded. Marco's fork has both fixes. z4ziggy's driver uses 390 MHz.
  So "try any of the drivers" in our previous reply was too loose for an Ultra:
  Marco's is the only one confirmed on Ultra hardware.
- z4ziggy's repo since our replies: 4327aa8 makes `make install` install
  deps with **dnf on Fedora** and **refuse if another DKMS package ships
  `ipu-bridge`/`sc200pc`** (`FORCE=1` overrides). Its regex matches our
  `ipu-bridge-fix/dkms.conf` (`BUILT_MODULE_NAME[0]="ipu-bridge"`), so it
  catches a leftover Book5 install. e68722e adds a "which project" box
  recommending Marco's for best picture. **Our #57 reply's "on Fedora, install
  the dependencies yourself" is now out of date** (correct when posted
  21:13, fixed by z4ziggy at 21:17).
- Marc's `ipu-bridge-sslc2000` (#57, posted 2026-06-06) predates Marco's
  repo (2026-08-11), so "it came from Jabbslad's" still stands, even though
  both projects use that package name.

Repo changes (released v0.3.113): README Book6 list now has Marco's first, says "pick
one", adds per-project tested-on, and notes Fedora deps for z4ziggy's. The
`install.sh` refusal message adds Marco's link. Stub-`lspci` retest: b05d still
exits 1 with `--force`, 645d continues.

### Reply (posted 2026-11-27, comment 7229703430)

> Thanks @z4ziggy, that's the one to lead with.
>
> **@jpnayak, start with [MarcoGlauser/galaxybook6-ultra-camera](https://github.com/MarcoGlauser/galaxybook6-ultra-camera).** It's built and tested on a Book6 Ultra `PAMC-960UJH`, and your machine reports `Galaxy Book6 Ultra - PAMC`, so it's the closest match. Same Ubuntu kernel series too (7.0). Same `SSLC2000` check first. Things to know before you run it: it downloads Intel's camera software and Samsung's Windows camera driver during install, it needs a MOK enrolled if Secure Boot is on, and there's no uninstall script yet. Because it doesn't use libcamera, ignore my NVIDIA black-image note from my last comment. That only applies to the software-ISP drivers.
>
> I should also narrow what I said about the other drivers. On a Book6 Ultra, the original Jabbslad driver needed two fixes (link frequency and gain) before it delivered frames. Those are in [Jabbslad/sc200pc-linux#1](https://github.com/Jabbslad/sc200pc-linux/issues/1), and Marco's fork carries both. So for an Ultra, treat the software-ISP drivers as untested.
>
> Whichever you pick, install only one. They ship the same kernel modules.
>
> I've updated our README's Book6 section with Marco's project and which model each one was tested on.

### #57 follow-up (posted 2026-11-27, comment 7229704740)

> @MarcM6909, a quick update to my Fedora note above: z4ziggy's `make install` now installs the dependencies with `dnf` on Fedora too ([4327aa8](https://github.com/z4ziggy/galaxybook6-camera/commit/4327aa8)), so you don't need to install them yourself.
