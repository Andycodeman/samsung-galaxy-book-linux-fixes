# Samsung Galaxy Book3 Pro 14" Speaker Fix (NP940XFG / 940XFG)

Restores internal speaker output on the **Samsung Galaxy Book3 Pro 14"**
(NP940XFG-KC1*, ALC298, subsystem ID `0x144dc882`).

## Quick Install

Download and install in one step — no git required, no reboot needed:

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book-linux-fixes-main/speaker-fix-940xfg && sudo ./install.sh
```

**Already cloned?** `sudo ./install.sh`

To uninstall: `sudo ./uninstall.sh`

> **Wrong board?** This fix is specifically for the **14" Book3 Pro (NP940XFG, DMI `940XFG`, ALC298 SSID `0x144dc882`)**. The installer DMI-checks before running and refuses on anything else. If you have a Book4 Pro/Ultra or Book5 Pro (MAX98390 amps), use [`../speaker-fix/`](../speaker-fix/) instead. The 16" Book3 Pro (NP964XFG) already works upstream via `V2_4_AMPS` and needs no fix.

---

## What this fixes

Out of the box on Linux, the internal speakers on this laptop are silent.
Headphones work, audio is otherwise functional — only the built-in speakers
have no sound.

The cause is a missing `SND_PCI_QUIRK` entry for subsystem ID `0x144dc882`
in the kernel's ALC298 fixup table (`sound/hda/codecs/realtek/alc269.c`).
Without that entry, the kernel never initializes the codec's four internal
class-D amplifiers (NIDs 0x38, 0x39, 0x3C, 0x3D), so the speakers never get
a usable signal.

The 16" sibling (NP964XFG, SSID `0xc886`) has working upstream support via
`ALC298_FIXUP_SAMSUNG_AMP_V2_4_AMPS`. The 14" needs the same V2_4 init
sequence **plus a SKU-specific `{0x239e, 0x0004}` enable write** that
mainline does not perform — that single missing write is what makes the
existing V2_4 fixup silent on this board even when forced via `model=`.

## What this does *not* do

This is **not** a kernel module. It does not patch `snd-hda-codec-realtek`.
It is a userspace fix:

- One bash script that talks to the codec via `hda-verb` (from `alsa-tools`)
- One systemd unit, activated by udev when the sound card registers (not enabled at boot)
- One `system-sleep` hook that re-runs it after resume from suspend

That keeps the fix entirely outside the kernel module hierarchy: it survives
kernel updates, kernel-source reorganizations (e.g. the 6.17 move of
`patch_realtek.c`), and DKMS rebuild failures with zero impact.

## Hardware support

| Board                        | SSID         | Status                                       |
|------------------------------|--------------|----------------------------------------------|
| **Galaxy Book3 Pro 14" (NP940XFG-KC1*)** | `0x144dc882` | Fixed by this installer                      |
| Galaxy Book3 Pro 16" (NP964XFG)        | `0xc886`     | Already works upstream (`V2_4_AMPS`)         |
| Galaxy Book2 Pro (NP950XED/EE)         | `0xc870/c872`| Already works upstream (`V2_2_AMPS`)         |
| Galaxy Book4 Pro/Ultra, Book5 Pro      | (MAX98390)   | Use `../speaker-fix/` (DKMS, different chip) |

The installer checks DMI `product_name` (`940XFG`) **and** ALSA codec
subsystem ID (`0x144dc882`). It refuses to run on anything else unless
`--force` is passed.

## Install

```bash
sudo bash install.sh
```

The installer will:

1. Verify the DMI product is `940XFG` and a codec with SSID `0x144dc882` is present.
2. Install `alsa-tools` if `hda-verb` is missing.
3. Copy `alc298-amp-init.sh` to `/usr/local/sbin/`.
4. Install `alc298-amp-init.service` and the udev rule that starts it as soon as the sound card registers (`controlC*` node appears) — not enabled at boot.
5. Install `/lib/systemd/system-sleep/alc298-amp-init` (re-runs after suspend/resume).
6. Fire the script once so speakers work immediately, no reboot required.

Test after install:

```bash
speaker-test -D plughw:0,0 -c 2 -t pink -l 1
```

You should hear pink noise out of both internal speakers.

## Uninstall

```bash
sudo bash uninstall.sh
```

Disables the systemd service, removes the resume hook, removes the script.
A reboot returns the codec to its default (silent) state. `alsa-tools` is
left installed; remove it manually if you want.

## How it works (technical)

The init script writes a Realtek COEF init sequence to four codec-internal
amp NIDs via the `hda-verb` userspace tool. The sequence matches what the
Realtek Windows driver does on the same hardware, derived from `RtHDDump`
codec-state snapshots captured during issue #44 diagnosis.

Per amp:

```
COEF[0x22] = <amp_nid>            # select internal amp (0x38, 0x39, 0x3C, 0x3D)
write_pack(0x23e1, 0x0000)         # 18-pair init for main amps,
write_pack(0x2012, 0x006f)         # 15-pair init for secondary amps,
... (V2_4-style coefficient table)
COEF[0x89] = 0x0000                # finalize

# Then enable:
write_pack(0x203a, 0x0081)         # V2 enable
write_pack(0x23ff, 0x0001)         # V2 enable
write_pack(0x239e, 0x0004)         # SKU-specific delta (the missing piece)
```

`write_pack(idx, val)` writes `COEF[0x23]=idx, COEF[0x25]=val,
COEF[0x26]=0xb011` to perform an indirect 16-bit write to the selected
amp's internal coefficient register.

## Tradeoffs vs. a full kernel fixup

The upstream V2 fixups install a `pcm_playback_hook` that toggles amps on
PCM open/close, saving a small amount of power when no audio is playing.
This script enables the amps once at boot and leaves them on. Power impact
is roughly 40–100 mW continuous — measurable but small (a few percent of
battery per day at idle).

If/when the upstream patch lands in mainline (planned submission to
alsa-devel), users running the patched kernel can remove this workaround
and get proper on-demand power management.

## See also

- Issue #44 in this repo — original report and full diagnostic trail
- `joshuagrisham/samsung-galaxybook-extras#97` — parallel report from another
  user with the same SSID; this fix should apply identically
