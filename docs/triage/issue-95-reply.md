# Issue #95 — NixOS support for the Galaxy Book3 Pro 14"

**Reporter:** @hayden-xyz · opened 2026-09-13 · state: open · no comments yet

## What they asked

> I've checked the nixos directory and it seems only devices with MAX98390 are
> supported.
>
> Small question: Im relatively new to nixos, how would I go about importing
> the modules?

## Findings

1. **Their read is correct.** `nixos/` contained only `samsung-speaker-fix.nix`
   + `max98390-hda-module.nix` (Book4/Book5, MAX98390 amps) and
   `webcam-fix-book5.nix`. The Book3 Pro 14" is **NP940XFG** — no MAX98390 amps
   at all. Its speaker fix is `speaker-fix-940xfg/` (ALC298 SSID `0x144dc882`,
   userspace `hda-verb` COEF init, issue #44), and that fix had **no Nix
   module**. So this is a real gap, not a misunderstanding.

2. **The main README pointed at a file that does not exist.** The NixOS section
   told people to import `nixos/webcam-fix-libcamera.nix`. There has never been
   such a file — only the three above. Fixed.

3. **There were no import instructions anywhere**, which is the other half of
   their question.

## What was changed (commit `cc2e173`)

- `nixos/speaker-fix-940xfg.nix` — new module. Packages the shipped
  `speaker-fix-940xfg/alc298-amp-init.sh` verbatim (so the bash installer and
  the Nix module cannot drift), wraps it with `alsa-tools` on PATH, installs the
  `controlC?` udev rule + the `alc298-amp-init.service` oneshot with **no**
  `wantedBy` (same reason as PR #75: a boot-transaction start races the codec,
  no-ops, and `RemainAfterExit` then swallows udev's later trigger), and re-runs
  the init on resume via `powerManagement.resumeCommands`.
- `nixos/README.md` — new. Which-module table, a board-identification snippet,
  and import instructions for both `configuration.nix` and flakes.
- `README.md` — NixOS section rewritten: removed the phantom
  `webcam-fix-libcamera.nix`, added the 940XFG module, stated plainly that the
  IPU6 webcam fix and the mic fix have no Nix module yet.
- `speaker-fix-940xfg/README.md` — one "on NixOS, use the module instead" note.

## Verification

No NixOS hardware here, so this was verified by evaluation and build rather
than by hearing speakers:

- Full `nixos/lib/eval-config.nix` system evaluation against nixpkgs
  `nixos-25.05` with the module imported and enabled — evaluates clean to a
  `nixos-system` derivation (confirms every option name and type).
- Generated unit inspected: `wantedBy = []`, `Type=oneshot`,
  `RemainAfterExit=true`, `ExecStart` → the wrapped script. Udev rule and
  resume hook both present in the built config.
- The `alc298-amp-init` derivation builds; `patchShebangs` rewrites
  `#!/bin/bash`, `wrapProgram` puts `alsa-tools` (which ships `hda-verb`) on
  PATH, and running it on non-matching hardware prints the "no ALC298 codec"
  message and exits 0 as designed.

**Not verified:** that the speakers actually come on. That needs @hayden-xyz.

## Posting

Posted 2026-09-13 after the change landed on `main` as `cc2e173`:
https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/95#issuecomment-5654745834

Latest release at time of writing: v0.3.68. No release cut for this change —
the reply points at `main`.

---

## Draft reply

Good catch — you're right, and it was a gap rather than an oversight on your
part.

The `nixos/` directory only had modules for the MAX98390 boards (Book4
Pro/Ultra, Book5 Pro). Your Book3 Pro 14" doesn't have MAX98390 amps at all —
it's an **NP940XFG with a Realtek ALC298** whose four internal class-D amps are
never initialised because mainline has no `SND_PCI_QUIRK` for subsystem ID
`0x144dc882`. That fix lives in
[`speaker-fix-940xfg/`](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/tree/main/speaker-fix-940xfg)
and it's userspace-only (no kernel module, no DKMS) — but it had no Nix module,
so there was nothing for you to import.

There is one now: **`nixos/speaker-fix-940xfg.nix`**. I've also added
[`nixos/README.md`](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/blob/main/nixos/README.md)
with import instructions, since that was the other half of your question.

### First, confirm it's the right board

```bash
cat /sys/class/dmi/id/product_name                 # expect: 940XFG
cat /sys/class/sound/hwC0D0/vendor_id              # expect: 0x10ec0298
cat /sys/class/sound/hwC0D0/subsystem_id           # expect: 0x144dc882
```

If those match, this is your fix. (If instead
`ls -d /sys/bus/acpi/devices/MAX98390:*` prints something, you want
`samsung-speaker-fix.nix` and not this one.)

### Importing it — classic `configuration.nix`

The module reads files from its sibling directories in the repo, so clone the
**whole repo** somewhere permanent — it has to still be there at rebuild time:

```bash
sudo git clone https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes.git \
  /etc/nixos/samsung-galaxy-book-linux-fixes
```

Then in `/etc/nixos/configuration.nix`:

```nix
{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./samsung-galaxy-book-linux-fixes/nixos/speaker-fix-940xfg.nix
  ];

  hardware.samsungGalaxyBook.speakerFix940xfg.enable = true;
}
```

```bash
sudo nixos-rebuild switch
```

### Importing it — flake

This repo isn't a flake, so add it as a plain source input with `flake = false`
and reference the module by path:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    samsung-fixes = {
      url = "github:Andycodeman/samsung-galaxy-book-linux-fixes";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, samsung-fixes, ... }: {
    nixosConfigurations.my-book = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        "${samsung-fixes}/nixos/speaker-fix-940xfg.nix"
        { hardware.samsungGalaxyBook.speakerFix940xfg.enable = true; }
      ];
    };
  };
}
```

```bash
sudo nixos-rebuild switch --flake .#my-book
```

`nix flake update samsung-fixes` pulls later fixes.

### Checking it worked

The unit is started by udev when the sound card registers, not at boot (starting
it from the boot transaction races the codec), so don't be alarmed that nothing
is `wantedBy` anything:

```bash
systemctl status alc298-amp-init.service
sudo alc298-amp-init          # re-run by hand, it's idempotent
```

It also re-runs on resume, because suspend power-cycles the codec and the COEF
writes are lost across S3.

### One caveat

I don't have a 940XFG to test on. The module evaluates and builds cleanly in a
full NixOS system evaluation, and the generated unit, udev rule and resume hook
are all what I intended — but whether the speakers actually come on is something
only you can confirm. If it doesn't work, please paste:

```bash
systemctl status alc298-amp-init.service
journalctl -u alc298-amp-init.service -b
cat /sys/class/sound/hwC0D0/vendor_id /sys/class/sound/hwC0D0/subsystem_id
amixer -c0 scontents | grep -iA3 speaker
```

Separately, note there's still no Nix module for the Book3/Book4 IPU6 webcam fix
(`webcam-fix-libcamera/`) or the mic fix — those are install-script only for
now. The old README wrongly claimed a `nixos/webcam-fix-libcamera.nix` existed;
that's been corrected too, thanks for prompting the look.
