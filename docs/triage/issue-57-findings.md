# Issue #57 — Galaxy Book6 Pro webcam (Panther Lake IPU7)

Status (2026-11-27): new comment from @z4ziggy (7228055353) with a working
community driver. Reply below POSTED 2026-11-27 as comment 7228254743
(paragraphs unwrapped for GitHub); awaiting Marc's SSLC2000/OVTI08F4 status.

## What the new comment says

- On z4ziggy's Book6 Pro the enabled sensor is `SSLC2000` = **SmartSens SC200PC**
  (module KAFC917). The five `OVTI08F4` ACPI entries are disabled placeholders
  (`_STA` = 0).
- Driver repo: https://github.com/z4ziggy/galaxybook6-camera (GPL-2.0, created
  2026-11-27, 2 commits, 0.1.0). Contents: `sc200pc.c` V4L2 sensor driver
  (671 lines, chip id 0x0b71, ACPI match `SSLC2000`), an `ipu-bridge.ko` built
  from kernel.org's `ipu-bridge.c` for the running kernel plus one
  `IPU_SENSOR_CONFIG("SSLC2000", 1, 390000000)` line, DKMS packaging, and a
  libcamera simple-pipeline tuning file. Tested on Ubuntu 26.04 + XanMod 7.2.15
  + libcamera 0.7.0.
- Skimmed the Makefile, dkms.conf, Kbuild and the driver: an ordinary sensor
  driver and DKMS setup. Nothing unusual (no firmware loading, no file access,
  no usermode helpers).

## What our July reply got wrong

1. **"ov08f40 exists nowhere / in-tree ov08x40 is close in name only".** Wrong.
   Mainline `drivers/media/i2c/ov08x40.c` matches ACPI ID `OVTI08F4`
   (`ov08x40_acpi_ids[] = { {"OVTI08F4"}, ... }`). The `ipu-bridge` entry Marc
   found is the stock upstream one, not ours (our `ipu-bridge-fix` copy only
   carries it because it is a full copy of upstream). So the driver for that ID
   is already in Marc's kernel.
2. **"The only missing piece is the sensor driver."** Wrong. `no subdev found
   in graph` comes from the OVTI08F4 devices being disabled in firmware, so
   ov08x40 never probes. The real sensor is SSLC2000, which no mainline driver
   and no stock `ipu-bridge` knows about.

Per the correct-visibly rule, the reply says this outright rather than editing
the July comment.

Marc's original report lists a DKMS module called `ipu-bridge-sslc2000`, which
is not ours, so he may have found SSLC2000 already from another source. Worth
asking.

## Conflict with our Book5 installer

Marc ran `webcam-fix-book5/install.sh --force`. That installs:

- `ipu-bridge-fix` DKMS → `ipu-bridge.ko` in `/updates/`
- `vision-driver` DKMS, WirePlumber hide rules, camera relay, libcamera bits

z4ziggy's package installs another `ipu-bridge.ko` in `/updates/dkms/`. Two
out-of-tree modules with the same name both beat the in-tree one, and which of
the two depmod picks isn't something we should rely on. Ours lacks SSLC2000.
Anyone who ran our Book5 installer on a Book6 should run
`webcam-fix-book5/uninstall.sh` first.

Also for Fedora: `make install` only installs dependencies through `apt-get`.
On Fedora it skips that step, so DKMS, kernel headers, libcamera tools/IPA and
PipeWire's libcamera plugin have to be installed by hand. The DKMS build
downloads `ipu-bridge.c` from kernel.org, so a kernel update installed offline
will fail to rebuild the bridge.

## Recommendation

- **Don't absorb it into this repo.** Different SoC (Panther Lake), different
  sensor, nobody here has the hardware, and the author has it and maintains it.
  Point to it.
- **Keep `8086:b05d` out of our installer's supported list** (same reasoning as
  July: ours would install a bridge without SSLC2000).
- After Marc (or a second Book6 owner) confirms it works: add a README line
  "Galaxy Book6 (Panther Lake) → community driver z4ziggy/galaxybook6-camera".
  Also consider having `webcam-fix-book5/install.sh` detect `8086:b05d` and print
  that pointer, refusing even with `--force`, so Book6 owners don't install a
  conflicting `ipu-bridge`.

## Reply (posted 2026-11-27, comment 7228254743)

> Thanks a lot @z4ziggy, this is a great find, and it corrects my July reply
> here, so let me fix that properly:
>
> - I wrote that the OV08F40 driver "exists nowhere" and that the in-tree
>   `ov08x40` was "close in name only". That was wrong. Mainline `ov08x40`
>   already matches ACPI ID `OVTI08F4`, and the `ipu-bridge` entry Marc found is
>   the stock upstream one.
> - So a missing OV08F40 driver was never the problem. If those `OVTI08F4`
>   entries are disabled in firmware, as z4ziggy found, `ov08x40` never probes,
>   and that is exactly what `no subdev found in graph` looks like. The sensor
>   that is actually wired up is `SSLC2000` (SmartSens SC200PC), and nothing in
>   mainline knows about it.
>
> @MarcM6909, could you check which sensor your unit has?
>
> ```
> cat /sys/bus/acpi/devices/SSLC2000:00/status   # 15 = present
> cat /sys/bus/acpi/devices/OVTI08F4:00/status   # 0 = disabled
> ```
>
> (Your DKMS list also shows an `ipu-bridge-sslc2000` module. That one isn't
> from this repo. Where did it come from?)
>
> If `SSLC2000` reads 15, z4ziggy's driver is the one to try. Two things first:
>
> 1. **Remove our Book5 fix first** if you ran it with `--force`:
>    `./webcam-fix-book5/uninstall.sh`, then reboot. Both packages install their
>    own `ipu-bridge.ko` through DKMS, ours doesn't have the SSLC2000 entry, and
>    you don't want both fighting over which one loads. Our `vision-driver`
>    isn't needed on the Book6 either.
> 2. **On Fedora, install the dependencies yourself.** `make install` only does
>    that through `apt-get`, so you'll need DKMS, `kernel-devel` for your
>    kernel, the libcamera tools/IPA packages and PipeWire's libcamera plugin
>    before you run it. It also downloads `ipu-bridge.c` from kernel.org at
>    build time, so it needs network access when a new kernel gets built.
>
> A report from a second unit on a different distro and kernel (Fedora 44,
> 7.0.x) would be really useful to z4ziggy. Please post the results in
> their repo.
>
> On our side: the Book6 stays out of this repo's installers. It's a different
> sensor and bridge entry, I don't have the hardware, and z4ziggy does and
> maintains the driver. Once a second Book6 owner confirms it works, I'll add
> a pointer to the README and have the Book5 installer send Book6 owners
> (`8086:b05d`) there instead of installing a bridge that can't see their sensor.
