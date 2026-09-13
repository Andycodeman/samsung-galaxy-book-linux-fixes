# NixOS modules

Declarative equivalents of the install scripts, for NixOS users.

## Which module do I need?

| Module | Hardware | Fixes |
|---|---|---|
| [`speaker-fix-940xfg.nix`](speaker-fix-940xfg.nix) | Galaxy Book3 Pro 14" (NP940XFG, ALC298, SSID `0x144dc882`) | Silent internal speakers |
| [`samsung-speaker-fix.nix`](samsung-speaker-fix.nix) | Galaxy Book4 Pro/Ultra, Book5 Pro (MAX98390 amps) | Silent internal speakers |
| [`webcam-fix-book5.nix`](webcam-fix-book5.nix) | Galaxy Book5 (IPU7, OV02C10/OV02E10) | Camera not detected, purple tint, upside-down image |

Not sure which speaker fix applies? Run:

```bash
cat /sys/class/dmi/id/product_name          # board, e.g. 940XFG
ls -d /sys/bus/acpi/devices/MAX98390:* 2>/dev/null   # MAX98390 amps present?
```

If `MAX98390:*` ACPI devices exist, use `samsung-speaker-fix.nix`. If
`product_name` is `940XFG` and that second command prints nothing, use
`speaker-fix-940xfg.nix`.

There is no Nix module for the Book3/Book4 IPU6 webcam fix
([`../webcam-fix-libcamera/`](../webcam-fix-libcamera/)) or the mic fix
([`../mic-fix/`](../mic-fix/)) yet — use the install scripts for those.

## Importing the modules

The modules are plain NixOS modules. All of them except
`samsung-speaker-fix.nix` are opt-in and do nothing until you set their
`enable` option, so importing one is always safe.

Each module reads files from its sibling directories in this repo
(`../speaker-fix-940xfg`, `../camera-relay`, ...), so import the module **from a
checkout of the whole repo** — copying a single `.nix` file out on its own will
not evaluate.

### Option A — classic `configuration.nix`

Clone the repo somewhere permanent (it must still exist at rebuild time):

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

### Option B — flake

Add the repo as a flake input and import the module from it:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    samsung-fixes = {
      url = "github:Andycodeman/samsung-galaxy-book-linux-fixes";
      flake = false;          # this repo is not a flake, just a source tree
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

To pick up later fixes from this repo: `nix flake update samsung-fixes`.

## `speaker-fix-940xfg.nix`

Galaxy Book3 Pro 14" only. Mainline has no `SND_PCI_QUIRK` for SSID
`0x144dc882`, so the ALC298's four internal class-D amps (NIDs `0x38`, `0x39`,
`0x3C`, `0x3D`) are never initialized and the speakers stay silent. This module
replays the Windows COEF init sequence with `hda-verb` — no kernel module, no
DKMS, nothing that a kernel update can break.

```nix
hardware.samsungGalaxyBook.speakerFix940xfg.enable = true;
```

What it does:

- Packages [`../speaker-fix-940xfg/alc298-amp-init.sh`](../speaker-fix-940xfg/alc298-amp-init.sh)
  with `alsa-tools` (for `hda-verb`) on its `PATH`.
- Adds a udev rule that starts `alc298-amp-init.service` when the sound card
  registers (`controlC*`). The unit deliberately has no `wantedBy` — starting it
  from the boot transaction races the codec.
- Re-runs the init on resume via `powerManagement.resumeCommands`, because
  suspend power-cycles the codec and the COEF writes are lost.

The script matches the codec's `vendor_id`/`subsystem_id` itself and exits 0 on
anything else, so it is harmless on other hardware — but do **not** enable it on
a MAX98390 machine; use `samsung-speaker-fix.nix` there.

Check it worked:

```bash
systemctl status alc298-amp-init.service
sudo alc298-amp-init          # re-run by hand; it is idempotent
```

## `samsung-speaker-fix.nix`

Book4 Pro/Ultra and Book5 Pro (MAX98390 amps). Builds the out-of-tree
`snd-hda-scodec-max98390` modules, loads them at boot, and creates the I2C
devices for the extra amplifiers via a systemd service.

This module has **no `enable` option** — importing it turns it on:

```nix
imports = [ ./samsung-galaxy-book-linux-fixes/nixos/samsung-speaker-fix.nix ];
```

By default it builds from a pinned GitHub tag. To build from your local
checkout instead:

```nix
hardware.samsungGalaxyBook.speakerFix.source = "local";
```

## `webcam-fix-book5.nix`

Book5 (IPU7, OV02C10/OV02E10):

```nix
hardware.samsungGalaxyBook.webcamFixBook5 = {
  enable = true;
  # Strongly recommended — see the option description. Without it the
  # libcamera overlay cascades through the Nix fixed-point and rebuilds
  # chromium, discord, qemu, webkitgtk, ... from source.
  nixpkgsUnpatched = inputs.nixpkgs.legacyPackages.${pkgs.system};
};
```

Set `videoFlip = true;` if the image is upside-down on a Galaxy Book 360 /
convertible (NP960QHA, NP960QFG, NP960QGK, ...).

## Credits

- [@pagliarinilucas](https://github.com/pagliarinilucas) — `samsung-speaker-fix.nix`
- [@ang3lo-azevedo](https://github.com/ang3lo-azevedo) — `webcam-fix-book5.nix`
