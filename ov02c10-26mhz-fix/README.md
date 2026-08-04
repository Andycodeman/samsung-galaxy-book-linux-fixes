# OV02C10 26 MHz Clock Fix (DKMS)

**Test fix** for Samsung Galaxy Book 3/4 models where the OV02C10 camera sensor
fails to probe with:

```
ov02c10 i2c-OVTI02C1:00: error -EINVAL: external clock 26000000 is not supported
```

## What this fixes

The upstream kernel's `ov02c10` driver only accepts a 19.2 MHz external clock.
Some IPU6 boards provide 26 MHz instead. This DKMS module patches the driver to
accept both frequencies.

Based on the patch from:
https://lore.kernel.org/linux-media/CAKP_te-WT+HTEyhSvQ3snEOaTp5B1OUL18JjuzO238=_fTOuXQ@mail.gmail.com/

The 26 MHz clock is a **per-board property, not a platform property** — it shows
up on both Raptor Lake and Meteor Lake IPU6. Confirmed affected models:

- Galaxy Book4 Pro **940XGK** — Raptor Lake, subsystem ID `0x144dca07`
- Galaxy Book4 Ultra **NP960XGL** — Meteor Lake IPU6 `8086:7d19`
- Book3/Book4 Ultra Raptor Lake variants

So don't decide by platform: check `dmesg` for the error above. That is exactly
what `webcam-fix-libcamera/install.sh` does — it greps for the clock rejection
and offers this fix, regardless of which IPU6 generation the board uses.

## Requirements

- Linux kernel with in-tree `ov02c10` driver (kernel 6.8+, tested up to 7.0)
- `dkms` and kernel headers (the install script will try to install these)
- Samsung Galaxy Book with IPU6 + OV02C10 sensor rejecting the 26 MHz clock
  (Raptor Lake or Meteor Lake — confirm in `dmesg`, see above)

## Secure Boot

If Secure Boot is **enabled** (common on Ubuntu/Zorin out of the box), an
unsigned DKMS module is silently rejected by the kernel, which then loads the
distro-signed *in-tree* driver — and that one still rejects the 26 MHz clock.
The result looks like "I ran the fix and rebooted but the camera still doesn't
work". `install.sh` now detects this: it configures DKMS to sign the module
with a MOK key and queues the key for enrollment. **You must complete the blue
MOK Manager enrollment screen on the next reboot** (enter the one-time password
you set), otherwise the patched driver will never load. Alternatively, disable
Secure Boot in the BIOS.

## A note on `clk_freq`

If you see `ov02c10: unknown parameter 'clk_freq' ignored` in `dmesg`, that is
**not** the cause of the failure — this driver (and the upstream one) has no
`clk_freq` module parameter. It comes from a stale
`/etc/modprobe.d/*.conf` left over from an older community workaround.
`install.sh` automatically comments it out (with a `.bak` backup).

## Install

```bash
sudo bash install.sh
```

## Verify

After installing, check that the driver loaded without the clock error:

```bash
dmesg | grep -i ov02c10
```

You should no longer see `external clock 26000000 is not supported`.

## Uninstall

```bash
sudo bash uninstall.sh
```

This removes the DKMS module and restores the stock kernel driver.

## How it works

The only change from the stock driver is in the `ov02c10_probe()` function:

```c
// Stock driver:
if (freq != OV02C10_MCLK)  // OV02C10_MCLK = 19200000

// Patched driver:
if (freq != OV02C10_MCLK_19_2MHZ && freq != OV02C10_MCLK_26MHZ)
```

This is the exact same fix proposed in the upstream kernel mailing list patch.
