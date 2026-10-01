# Internal Microphone Fix (SOF Firmware Update)

Enables the internal DMIC (digital microphone) on Samsung Galaxy Book4 and Book5 laptops running Linux.

## The Problem

The stock `linux-firmware` package on Ubuntu 24.04 ships SOF (Sound Open Firmware) v2023.12.1, which is too old for reliable DMIC support on Meteor Lake (Book4) and Lunar Lake (Book5) platforms. The internal mic either doesn't appear at all, or shows up but doesn't capture audio.

## What This Fix Does

1. **Downloads** the latest SOF firmware from the upstream [linux-firmware](https://gitlab.com/kernel-firmware/linux-firmware) repository (v2025.12.1+)
2. **Backs up** your existing firmware files (to `*.bak-mic-fix` directories)
3. **Installs** the updated firmware (`sof-ipc4`, `sof-ipc4-lib`, `sof-ace-tplg`, `sof`, `sof-tplg`)
4. **Sets** `dsp_driver=3` in modprobe config to select the SOF driver
5. **Rebuilds** initramfs to include the new firmware

## Supported Hardware

| Platform     | Laptop           | Audio Controller          |
|-------------|------------------|---------------------------|
| Meteor Lake | Galaxy Book4     | `sof-audio-pci-intel-mtl` |
| Lunar Lake  | Galaxy Book5     | `sof-audio-pci-intel-lnl` |

## Install

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book-linux-fixes-main/mic-fix && sudo ./install.sh && sudo reboot
```

## Verify

After reboot:

```bash
# Check that SOF loaded
sudo dmesg | grep -i sof | head -20

# Check for DMIC device
arecord -l
# Should show a "DMIC" or "Digital Mic" device

# Test recording
arecord -D hw:0,6 -f S32_LE -r 48000 -c 2 -d 5 test.wav
aplay test.wav
```

## Uninstall / Revert

```bash
sudo bash uninstall.sh
# Reboot
```

This restores your original firmware from backups and removes the `dsp_driver=3` setting.

## Relationship to Speaker Fix

This mic fix and the [speaker fix](../speaker-fix/) are **independent**:

- **Mic fix** (this) = SOF firmware + `dsp_driver=3` → enables DMIC
- **Speaker fix** = DKMS kernel driver for MAX98390 amplifiers → enables speakers

You likely need **both** for full audio on the Galaxy Book4 Ultra. Install them in either order.

## FAQ

**Q: Do I need this on Fedora?**
A: Fedora ships newer `linux-firmware` and may already have SOF firmware recent enough. Check `sudo dmesg | grep "Booted firmware version"` — if it shows 2.14+ and your mic works, you don't need this.

**Q: Will a future `linux-firmware` update break this?**
A: No — package updates will merge alongside the installed firmware. If a distro update includes SOF firmware new enough, you can safely run `uninstall.sh` to revert to the distro-managed firmware.

**Q: Does this affect my speakers?**
A: It shouldn't — the SOF firmware handles the DSP pipeline, not the amplifiers. However, if speakers stop working after this, revert with `uninstall.sh` and file an issue.
