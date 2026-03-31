# Samsung Galaxy Book 3/4/5 Linux Fixes

Fixes for hardware that doesn't work out of the box on Linux on Samsung Galaxy Book 3, 4, and 5 laptops. Confirmed working on **Galaxy Book4 Ultra** (Ubuntu, Fedora), **Book4 Pro 360** (Ubuntu), **Book5 Pro 940XHA** (Fedora), **Book5 Pro 960XHA** (Ubuntu), and **Book5 Pro 360 960QHA** (Arch) — should also work on other models with the same hardware.

> **Distro support:** The **speaker fix** works on Ubuntu, Fedora, and Arch-based distros (CachyOS, Manjaro, etc. — `dkms` and `linux-headers` must be installed first, see [speaker-fix README](speaker-fix/)). The **webcam fix** supports **Ubuntu, Fedora, and Arch-based distros** — see [webcam-fix-libcamera](webcam-fix-libcamera/) for Book3/Book4 (Meteor Lake / Raptor Lake) and [webcam-fix-book5](webcam-fix-book5/) for Book5 (Lunar Lake). Both use open-source libcamera + PipeWire with an on-demand camera relay for non-PipeWire apps.

> **Disclaimer:** These fixes involve loading kernel modules and running scripts with root privileges. While they are designed to be safe and reversible (both include uninstall steps), they are provided **as-is with no warranty**. Modifying kernel modules carries inherent risk — in rare cases, incompatible drivers could cause boot issues or system instability. **Use at your own risk.** It is recommended to have a recent backup and know how to access recovery mode before proceeding.

## Quick Install

Each fix can be downloaded and installed in a single command — no git required.

### Speaker Fix (no sound from built-in speakers)

> **Microphone note (Book4 models):** On Galaxy Book4 (Meteor Lake), the built-in DMIC does not work with or without this fix — no mic functionality is lost. On **Galaxy Book5** (Lunar Lake), the speaker fix works and the **built-in mic continues to work** after installation. See [Microphone Status](#microphone-status) for details.

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book-linux-fixes-main/speaker-fix && sudo ./install.sh && sudo reboot
```

To uninstall: `sudo ./uninstall.sh && sudo reboot`

### Mic Fix (internal microphone not working) — Galaxy Book4 / Book5

> Updates SOF (Sound Open Firmware) and sets `dsp_driver=3` to enable the internal DMIC. The stock `linux-firmware` on Ubuntu 24.04 ships SOF v2023.12.1 which is too old for Meteor Lake DMIC support. This pulls v2025.12.1+ from the upstream linux-firmware repo. **Note:** Fedora may already ship new enough firmware — check first with `sudo dmesg | grep "Booted firmware version"`.

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book-linux-fixes-main/mic-fix && sudo ./install.sh && sudo reboot
```

To uninstall: `sudo ./uninstall.sh && sudo reboot`

### Webcam Fix (built-in camera not detected) — Galaxy Book3 / Book4 (Meteor Lake / Raptor Lake)

> **Recommended:** Uses the open-source libcamera stack with PipeWire. Supports **Ubuntu, Fedora, and Arch-based distros**. Includes an on-demand camera relay for apps that don't support PipeWire (Zoom, OBS, VLC) — near-zero CPU when idle, camera activates only when an app opens the device.

> **Galaxy Book5 (Lunar Lake):** Use [webcam-fix-book5](webcam-fix-book5/) instead — the installer will detect Lunar Lake and direct you there.

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book-linux-fixes-main/webcam-fix-libcamera && ./install.sh && sudo reboot
```

To uninstall: `./uninstall.sh && sudo reboot`

The webcam works with **Firefox, Chromium, Zoom, Teams, OBS, mpv, VLC**, and most other apps. For Chromium-based browsers (Brave, Chrome), the installer automatically enables the PipeWire camera flag.

### Webcam Fix (built-in camera not detected) — Lunar Lake / Galaxy Book5 / Arch, Fedora & Ubuntu

> Confirmed working on Samsung Galaxy Book5 Pro 940XHA (Fedora 43), 960XHA (Ubuntu 24.04), Dell XPS 13 9350 (Arch), and Lenovo X1 Carbon Gen13 (Fedora). See the [full README](webcam-fix-book5/) for details, known issues, and tested hardware.

> **Requires kernel 6.18+** and **Arch, Fedora, or Ubuntu** (Ubuntu requires libcamera 0.5.2+ and kernel 6.18+ built from source). Includes an on-demand camera relay for non-PipeWire apps (Zoom, OBS, VLC) with near-zero idle CPU usage. For Chromium-based browsers (Brave, Chrome), the installer automatically enables the PipeWire camera flag.

> **OV02E10 purple tint fix:** Samsung Book5 models with the OV02E10 sensor mounted upside-down get purple/magenta tint due to a bayer pattern mismatch after the rotation flip. A patched libcamera build fixes this — see [OV02E10 bayer fix](webcam-fix-book5/libcamera-bayer-fix/) and the [webcam-fix-book5 README](webcam-fix-book5/) for details.

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book-linux-fixes-main/webcam-fix-book5 && ./install.sh && sudo reboot
```

To uninstall: `./uninstall.sh && sudo reboot`

---

## What's Included

### [Speaker Fix](speaker-fix/) — MAX98390 HDA Driver (DKMS) — Output Only

The internal speakers use 4x Maxim MAX98390 I2C amplifiers that have no kernel driver yet. This DKMS package provides the missing driver, based on [thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616). **Note:** This fix addresses speaker output only — it does not enable the built-in microphones (see [Microphone Status](#microphone-status) below).

- Builds two kernel modules via DKMS (auto-rebuilds on kernel updates)
- Creates I2C devices for the amplifiers on boot
- Loads DSM firmware with separate woofer/tweeter configurations
- Auto-detects and removes itself when native kernel support lands

> **Sound Quality:** Audio will sound thinner and lack bass compared to Windows. This is because Windows uses Samsung's DSP audio processing (Dolby Atmos, bass enhancement, EQ) which Linux doesn't have. See [Sound Quality & EQ](speaker-fix/README.md#sound-quality--eq) for details and a workaround using EasyEffects.

> **Battery Impact:** The speaker amps are only powered on during active audio playback — when idle, they draw ~10μA per chip (effectively zero battery impact). The driver uses HDA playback hooks to enable the amps on demand.

> **Secure Boot:** Most laptops have Secure Boot enabled. If you've never installed a DKMS/out-of-tree kernel module before, you'll need to do a **one-time MOK key enrollment** (reboot + blue screen + password) before the modules will load. See the [full walkthrough](speaker-fix/README.md#secure-boot-setup).

> **Fedora / DNF-based distros:** The install script auto-detects Fedora and configures DKMS module signing using the akmods MOK key (`/etc/pki/akmods/`). If no key exists, it generates one with `kmodgenca` and prompts for enrollment. If modules still won't load after enrollment, check the [Secure Boot signing troubleshooting](speaker-fix/README.md#troubleshooting). Confirmed working on Fedora 43, kernel 6.18.9 (Galaxy Book4 Ultra).

### [Mic Fix](mic-fix/) — SOF Firmware Update (Internal Microphone)

The internal DMIC requires SOF (Sound Open Firmware) with a recent enough firmware version. Ubuntu 24.04's `linux-firmware` package ships SOF v2023.12.1, which doesn't support DMIC on Meteor Lake. This fix updates SOF firmware to v2025.12.1+ from the upstream linux-firmware repository and configures `dsp_driver=3`.

- Downloads latest SOF firmware via sparse git checkout (no full repo clone)
- Backs up existing firmware (reversible with `uninstall.sh`)
- Sets `dsp_driver=3` in modprobe config for SOF driver selection
- Rebuilds initramfs to include updated firmware
- Supports Ubuntu, Fedora, and Arch

> **Independent of speaker fix:** The mic fix (SOF firmware + DSP driver) and the speaker fix (MAX98390 amplifier driver) are separate layers. You likely need **both** for full audio on Galaxy Book4 Ultra.

### [Webcam Fix — Book3 / Book4](webcam-fix-libcamera/) — IPU6 + libcamera (Recommended)

The built-in webcam uses Intel IPU6 (Meteor Lake or Raptor Lake) with an OmniVision OV02C10 sensor. This fix uses the open-source libcamera Simple pipeline handler with Software ISP, accessed through PipeWire. Includes IVSC module loading, initramfs configuration (eliminating the boot race condition), sensor tuning, WirePlumber rules to hide raw IPU6 nodes, and an on-demand camera relay for non-PipeWire apps (Zoom, OBS, VLC). The installer also auto-detects the [26 MHz clock issue](ov02c10-26mhz-fix/) affecting some Raptor Lake models and offers to install the DKMS fix.

- PipeWire-native apps (Firefox, Chromium) access the camera directly — no relay needed
- Non-PipeWire apps use the on-demand V4L2 relay: near-zero CPU when idle, camera activates only when an app opens the device
- Chromium browser PipeWire camera flags are auto-enabled during install

> **Multi-distro:** Supports **Ubuntu, Fedora, and Arch-based distros**. The install script auto-detects your distro. Galaxy Book5 (Lunar Lake / IPU7) is not supported (different driver stack) — see [webcam-fix-book5](webcam-fix-book5/).

### [Webcam Fix — Book5 / Lunar Lake](webcam-fix-book5/) — IPU7 + libcamera

For Galaxy Book5 (Lunar Lake / IPU7) on Arch, Fedora, and Ubuntu (source build). Installs Intel's `intel_cvs` kernel module via DKMS and configures the libcamera + PipeWire pipeline. Requires kernel 6.18+. Confirmed working on Galaxy Book5 Pro 940XHA (Fedora), 960XHA (Ubuntu), Dell XPS 13 9350 (Arch), and Lenovo X1 Carbon Gen13 (Fedora).

- PipeWire-native apps (Firefox, Chromium) access the camera directly
- Non-PipeWire apps (Zoom, OBS, VLC) use the on-demand V4L2 relay: near-zero CPU when idle, camera activates only when an app opens the device
- Chromium browser PipeWire camera flags are auto-enabled during install

For Samsung Book5 models with the OV02E10 sensor, an additional [patched libcamera build](webcam-fix-book5/libcamera-bayer-fix/) is needed to fix the purple/magenta tint caused by bayer pattern mismatch after rotation flip. See the [webcam-fix-book5 README](webcam-fix-book5/) for details.

### [Webcam Fix — Legacy](webcam-fix/) — Intel IPU6 / icamerasrc (Not Recommended)

> **Not recommended.** This is the older proprietary stack using Intel's camera HAL (`icamerasrc`) and `v4l2-relayd`. Use [webcam-fix-libcamera](webcam-fix-libcamera/) instead — it's open-source, supports more distros, and includes on-demand activation. This legacy fix is kept for users who already have it installed or as a fallback if the libcamera stack doesn't work on their hardware.

## Microphone Status

The Galaxy Book4/5 laptops have built-in dual array digital microphones (DMIC). Whether they work on Linux **depends on your model and audio driver**:

| Model | Platform | Default Driver | Mic (default) | Mic (with mic fix) |
|-------|----------|---------------|--------------|-------------------|
| Book4 Ultra | Meteor Lake | Legacy HDA | No | **Yes** (SOF firmware + dsp_driver=3) |
| Book4 Pro / Pro 360 | Meteor Lake | Legacy HDA | No | **Yes** (expected — same hardware) |
| Book5 Pro | Lunar Lake | SOF | **Yes** | **Yes** (already works) |
| Book5 Pro 360 | Lunar Lake | SOF | **Yes** | **Yes** (already works) |

**Good news for Book5 owners:** The speaker fix has been confirmed working on Galaxy Book5 Pro models, and the built-in microphone **continues to work** after installing the speaker fix. On Lunar Lake, the SOF driver coexists with the legacy HDA driver, so both speakers and DMIC work together.

> **Arch-based distros (CachyOS, Manjaro, etc.):** The DMIC on Book5 models requires SOF firmware, which is **not installed by default** on Arch. If your mic doesn't work after installing the speaker fix, install the firmware: `sudo pacman -S sof-firmware` and reboot. This is not caused by the speaker fix — the mic may not have worked before either without this package.

**For Book4 models:** The built-in DMIC does not work on Meteor Lake with the legacy HDA driver (`dsp_driver=1`). The fix is to update SOF firmware and set `dsp_driver=3` — see the **[Mic Fix](mic-fix/)** installer which automates this. After installing, `arecord -l` should show a DMIC device.

**When will this be automatic?** Native support is being developed in [thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616), which will handle both speakers and DMIC together. However, this PR is on GitHub for development only — getting it into mainline Linux requires submitting patches via email to the [ALSA mailing list](https://mailman.alsa-project.org/mailman/listinfo/alsa-devel) for review by the HDA/sound maintainers. This has not happened yet, and there is **no confirmed timeline** for when it will land in a mainline kernel. Once it eventually ships in your distro kernel, the speaker fix in this repo will auto-detect native support and remove itself, and the mic fix can be safely uninstalled.

**Alternative workarounds (if you don't want to change SOF firmware):**
- Use a **USB headset or microphone** — works immediately, no configuration needed
- Use the **3.5mm headphone/mic combo jack** — the external mic input (ALC298 Node 0x18) is functional

## Tested On

- **Samsung Galaxy Book4 Ultra** — Ubuntu 24.04 LTS, kernel 6.17.0-14-generic (HWE)
- **Samsung Galaxy Book4 Ultra** — Fedora 43, kernel 6.18.9 (community-confirmed)
- **Samsung Galaxy Book4 Pro** — Ubuntu 25.10, kernel 6.18.7, speaker fix confirmed (community-confirmed)
- **Samsung Galaxy Book5 Pro** — Speaker fix confirmed working, mic continues to work (community-confirmed)
- **Samsung Galaxy Book5 Pro (940XHA)** — Fedora 43, webcam fix confirmed (correct colors + orientation with bayer fix)
- **Samsung Galaxy Book5 Pro 16" (960XHA)** — Ubuntu 24.04, kernel 6.19.2, webcam fix confirmed (correct colors + orientation with bayer fix)
- **Samsung Galaxy Book4 Pro 360 (960QGK)** — Ubuntu 24.04.2, kernel 6.17.0-19-generic, webcam fix confirmed (community-confirmed, [#18](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/18))
- **Samsung Galaxy Book5 Pro 360 (960QHA)** — Arch Linux, kernel 6.19.9, webcam fix confirmed (community-confirmed, [#22](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/22))
- **Samsung Galaxy Book3 Pro 360 (960QFG)** — Ubuntu 24.04, webcam rotation fix confirmed (community-confirmed, [#17](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/17))

The upstream speaker PR (#5616) was also confirmed working on Galaxy Book4 Pro, Pro 360, and Book4 Pro 16-inch by other users, so this fix should work on those models too. If you try it on another model or distro, please report back.

**Note:** The Book3/Book4 webcam fix ([webcam-fix-libcamera](webcam-fix-libcamera/)) is for **Meteor Lake / Raptor Lake (IPU6)** and supports Ubuntu, Fedora, and Arch. Galaxy Book5 (Lunar Lake / IPU7) has a **[separate webcam fix](webcam-fix-book5/)** for Arch, Fedora, and Ubuntu. Both include an on-demand camera relay for non-PipeWire apps.

## Hardware

**Galaxy Book3 / Book4 (Meteor Lake / Raptor Lake)**

| Component | Details |
|---|---|
| Audio Codec | Realtek ALC298 (subsystem `0x144dc1d8`) |
| Speaker Amps | 4x MAX98390 on I2C (`0x38`, `0x39`, `0x3c`, `0x3d`) |
| Camera ISP | Intel IPU6 Meteor Lake (`8086:7d19`) |
| Camera Sensor | OmniVision OV02C10 (`OVTI02C1`) |
| Microphones | Dual array DMIC (digital — status varies by model, see [Microphone Status](#microphone-status)) |

**Galaxy Book5 (Lunar Lake)**

| Component | Details |
|---|---|
| Audio Codec | Realtek ALC298 (same as Book4) |
| Speaker Amps | 4x MAX98390 on I2C (same as Book4) |
| Camera ISP | Intel IPU7 Lunar Lake (`8086:645d`) |
| Camera Sensor | OmniVision OV02E10 (`OVTI02E1`) |
| Camera Subsystem | Intel CVS (Computer Vision Subsystem) via LJCA |
| Microphones | Dual array DMIC (works out of the box with SOF on Lunar Lake) |

## Community

Thanks to the following users for their contributions and testing:

- **[@jn-simonnet](https://github.com/jn-simonnet)** and **[@david-bartlett](https://github.com/david-bartlett)** — Extensive testing across multiple Galaxy Book models, kernels, and distros that helped identify and resolve numerous issues
- **[@MatiDegli](https://github.com/MatiDegli)** — Created [speaker-on/off/status helper scripts](https://github.com/Andycodeman/samsung-galaxy-book4-linux-fixes/discussions/4) for manually toggling the speaker fix on and off. Note: the driver already powers down the amps when idle, so this isn't needed for battery savings, but may be useful if you want to explicitly unload the modules. Community-contributed and not officially tested — use at your own discretion.

## Credits

- **[Andycodeman](https://github.com/Andycodeman)** — Webcam fix (research, script, documentation), speaker fix DKMS packaging, out-of-tree build workarounds, I2C device setup, automatic upstream detection, install/uninstall scripts, and all documentation in this repo
- **[Kevin Cuperus](https://github.com/thesofproject/linux/pull/5616)** — Original MAX98390 HDA side-codec driver code (upstream PR #5616)
- **DSM firmware blobs** — Extracted from Google Redrix (Chromebook with same MAX98390 amps)

## Related

- [thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616) — Upstream speaker driver (development only — not yet submitted to mainline via ALSA mailing list)
- [Samsung Galaxy Book Extras](https://github.com/joshuagrisham/samsung-galaxybook-extras) — Platform driver for Samsung-specific features
- [Ubuntu Intel MIPI Camera Wiki](https://wiki.ubuntu.com/IntelMIPICamera) — IPU6 camera documentation

## NixOS

NixOS users can use the provided Nix modules in the [`nixos/`](nixos/) directory instead of the DKMS install scripts.

### Speaker Fix

Two files are provided:

- **`max98390-hda-module.nix`** — Nix derivation that builds the out-of-tree MAX98390 HDA kernel modules against your current kernel.
- **`samsung-speaker-fix.nix`** — NixOS module that loads the kernel modules, creates a systemd service to detect and register I2C amplifier devices at boot, and installs `i2c-tools`.

### Usage

Add the speaker fix module to your NixOS configuration:

```nix
# configuration.nix (or your hardware module)
{ ... }:
{
  imports = [
    /path/to/samsung-galaxy-book4-linux-fixes/nixos/samsung-speaker-fix.nix
  ];
}
```

Then rebuild:

```bash
sudo nixos-rebuild switch
```

The module will:
1. Build and install `snd-hda-scodec-max98390` and `snd-hda-scodec-max98390-i2c` kernel modules
2. Load them at boot via `boot.kernelModules`
3. Run a systemd oneshot service that scans the I2C bus for additional MAX98390 amplifiers and registers them

> **Note:** The Nix derivation fetches the driver source directly from this repository. If the hash becomes outdated after an upstream update, you may need to update the `hash` field in `max98390-hda-module.nix`.

## License

[GPL-2.0](LICENSE) — Free to use, modify, and redistribute. Derivative works must use the same license.

## Reporting Issues

If you run into problems, please [open an issue](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues) with your distro, kernel version (`uname -r`), and laptop model. Logs from `dmesg` or `journalctl` are helpful for debugging.

---

*Last updated: 2026-03-30*
