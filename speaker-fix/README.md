# Samsung Galaxy Book4 — Speaker Fix (MAX98390 HDA Driver)

> **Wrong board?** This fix is for Samsung Galaxy Book4 Pro/Ultra and Book5 Pro models with **MAX98390 I2C smart amps**. If you have a **Galaxy Book3 Pro 14" (NP940XFG-KC1\*, DMI `940XFG`, ALC298 SSID `0x144dc882`)**, your hardware uses ALC298 codec-internal class-D amps with **no MAX98390 chip at all** — this DKMS package will refuse to install on it. Use [`../speaker-fix-940xfg/`](../speaker-fix-940xfg/) instead. Other Book3/Book4/Book5 models continue here.

## Quick Install

Download and install in one step — no git required:

```bash
curl -sL https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/archive/refs/heads/main.tar.gz | tar xz && cd samsung-galaxy-book-linux-fixes-main/speaker-fix && sudo ./install.sh && sudo reboot
```

**Already cloned?** `sudo ./install.sh && sudo reboot`

To uninstall: `sudo ./uninstall.sh && sudo reboot`

---

> **Battery Impact:** The amps are enabled when the driver probes and stay on — they are **not** powered down when idle. The driver implements an HDA playback hook for on-demand power, but it never fires, because the in-kernel alc269 quirk that would create the HDA component master doesn't exist for these boards (see [Power Management](#power-management)). Enabling at probe is what makes the speakers work at all. If you want the amps genuinely off when idle, unload the modules — e.g. via [@MatiDegli's helper scripts](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/discussions/4). When native kernel support eventually lands (no confirmed timeline yet — see below), this package will auto-remove itself.

> **Secure Boot Users:** If you have Secure Boot enabled (most laptops do by default), you **must** enroll a Machine Owner Key (MOK) before the driver modules will load. If you've never installed a DKMS or out-of-tree kernel module before, you will need to complete a **one-time MOK enrollment** that involves a reboot and typing a password in a blue setup screen. See the [Secure Boot Setup](#secure-boot-setup) section below — **do this before running the install script**.

## The Problem

Samsung Galaxy Book4 laptops using **MAX98390 speaker amplifiers** have no audio output from the built-in speakers on Linux. The headphone jack works fine, but the laptop speakers are completely silent.

**Tested on:**

- Samsung Galaxy Book4 Ultra — Ubuntu 24.04 LTS, Kernel 6.17.0-14-generic (HWE)
- Samsung Galaxy Book4 Ultra — Fedora 43, Kernel 6.18.9 (community-confirmed)
- Samsung Galaxy Book5 Pro — Speaker fix works, mic continues to work (community-confirmed)
- Samsung Galaxy Book4 Pro (NP940XGK, subsystem 0x144dca07) — Zorin OS 18.1, Kernel 6.17.0-23-generic (community-confirmed, [#53](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/53))

The upstream PR was also reported working on Galaxy Book4 Pro, Pro 360, and Pro 16-inch by other users — this fix should work on those models too.

> **Book5 owners:** The speaker fix works on Galaxy Book5 Pro models and the built-in microphone continues to work after installation (confirmed on Ubuntu and Fedora). The install script auto-detects the number of amplifiers present on your model.

> **Arch-based distros (CachyOS, Manjaro, etc.):** The built-in mic on Book5 models requires SOF firmware, which Arch does not install by default. If your mic doesn't work, install it: `sudo pacman -S sof-firmware` and reboot.

> **Fedora users:** The install script auto-detects Fedora (DNF) and configures DKMS module signing using the akmods MOK key. If no key exists, it generates one and prompts for enrollment.

This affects systems with:

- **HDA Codec**: Realtek ALC298 (subsystem ID `0x144dc1d8` or similar Samsung variants)
- **Speaker Amps**: 4x Maxim MAX98390 connected via I2C (addresses `0x38`, `0x39`, `0x3c`, `0x3d`)
- **Kernel**: 6.x series (tested on 6.17.0-14-generic, Ubuntu 24.04)

### Root Cause

The stock kernel is missing three things needed to drive these amps:

1. **`serial-multi-instantiate`** doesn't know about the `MAX98390` ACPI device ID, so it doesn't enumerate all 4 amplifiers
2. **`snd_hda_codec_alc269`** has no quirk entry for Samsung's MAX98390 subsystem IDs, so it never sets up the HDA side-codec component master
3. **`snd-hda-scodec-max98390`** (the actual amp driver) doesn't exist in the kernel tree yet

An upstream fix is being developed at [thesofproject/linux PR #5616](https://github.com/thesofproject/linux/pull/5616), but has not yet been submitted to mainline Linux via the ALSA mailing list. There is no confirmed timeline for when native support will land — it could still be a ways out.

## What This Fix Does

This is a **DKMS out-of-tree driver package** that provides the missing `snd-hda-scodec-max98390` driver. It works around the other two missing pieces (serial-multi-instantiate and alc269 quirk) by:

- **Manually creating I2C devices** for the 3 amps that ACPI doesn't enumerate (the first amp at `0x38` is created by ACPI automatically)
- **Enabling the amps during driver probe** rather than relying on HDA playback hooks (which require the missing alc269 quirk)
- **Loading DSM (Dynamic Speaker Management) firmware** with separate woofer/tweeter configurations

### Speaker Layout

| I2C Address | Component Index | Type | Channel |
|---|---|---|---|
| `0x38` | 0 | Woofer | Left |
| `0x39` | 1 | Woofer | Right |
| `0x3c` | 2 | Tweeter | Left |
| `0x3d` | 3 | Tweeter | Right |

### What Gets Installed

| File | Purpose |
|---|---|
| `snd-hda-scodec-max98390.ko` | Core HDA side-codec driver (init, DSM, component binding) |
| `snd-hda-scodec-max98390-i2c.ko` | I2C transport driver (probe, regmap, ACPI matching) |
| `/usr/local/sbin/max98390-hda-i2c-setup.sh` | Creates I2C devices for amps 2-4 on boot |
| `/usr/local/sbin/max98390-hda-check-upstream.sh` | Checks for native kernel support; auto-removes this package when found |
| `/etc/systemd/system/max98390-hda-i2c-setup.service` | Systemd service: runs I2C setup on boot |
| `/etc/systemd/system/max98390-hda-check-upstream.service` | Systemd service: upstream detection on boot |
| `/etc/modules-load.d/max98390-hda.conf` | Ensures modules load on every boot |
| `/usr/src/max98390-hda-1.0/` | DKMS source tree (auto-rebuilds on kernel updates) |

## Installation

### Prerequisites

```bash
# Ubuntu / Debian
sudo apt install dkms linux-headers-$(uname -r)

# Fedora
sudo dnf install dkms kernel-devel

# Arch / CachyOS / Manjaro
sudo pacman -S dkms linux-headers i2c-tools
```

> **Arch-based distros:** The install script auto-detects `pacman` and will auto-install `i2c-tools` if missing. However, `dkms` and `linux-headers` must be installed manually before running the script (the correct headers package depends on your kernel — e.g., `linux-headers` for the default kernel, `linux-lts-headers` for LTS, `linux-zen-headers` for Zen).

### Install

```bash
git clone <this-repo>
cd speaker-fix
sudo ./install.sh
sudo reboot
```

The install script will:

1. Verify MAX98390 hardware is present (refuses to install on unsupported systems)
2. Build the kernel modules via DKMS (auto-signs for Secure Boot if MOK keys are configured)
3. Install systemd services and module autoload config
4. DKMS will auto-rebuild the modules on every kernel update

### Test Without Reboot

```bash
sudo ./install.sh
sudo systemctl start max98390-hda-i2c-setup.service
# Speakers should work immediately
```

### Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

## Automatic Upstream Detection

A systemd service runs on every boot to check if the running kernel has gained native MAX98390 support. It checks three conditions:

1. `serial-multi-instantiate` has a `MAX98390` alias
2. `snd_hda_codec_alc269` contains the `alc298-samsung-max98390` quirk string
3. `snd-hda-scodec-max98390` exists in the kernel module tree (not just DKMS)

**When all three pass**, the service automatically removes the entire DKMS workaround — modules, services, scripts, everything. Speakers continue working that session (modules are already loaded in memory), and on the next reboot the native kernel driver takes over. No user interaction needed.

## How It Works (Technical Details)

### The Workaround

The upstream PR (#5616) touches 5 areas of the kernel:

1. `drivers/acpi/scan.c` — built-in, can't be changed without recompiling the kernel
2. `drivers/platform/x86/serial-multi-instantiate.c` — adds MAX98390 enumeration
3. `sound/pci/hda/patch_realtek.c` — adds Samsung quirk entries to alc269
4. `sound/soc/codecs/max98390.c` — exports regmap config
5. `sound/hda/codecs/side-codecs/` — new MAX98390 HDA driver (this package)

This DKMS package only implements #5 (the new driver) and works around #1-#4:

- **Instead of scan.c + serial-multi-instantiate**: A systemd service dynamically finds the I2C bus via ACPI and creates the missing I2C devices via sysfs `new_device`
- **Instead of the alc269 quirk**: The driver enables the amps during probe (see Power Management below)
- **Instead of the exported regmap**: A local `regmap_config` with `REGCACHE_NONE` is defined in the driver headers

### Power Management

**The amps are enabled at probe and stay on. They are not powered down when idle.**

The driver *does* implement an HDA playback hook (`max98390_hda_playback_hook()`), and registers
itself as an HDA component via `component_add()`. But `component_add()` is only the *client* half
of the contract — the *master* lives in the kernel's `comp_generic_fixup()` and is only created by
an in-kernel alc269 quirk for the machine. That quirk doesn't exist for these Samsung boards (it's
missing piece #2 above), so no master ever binds, the component never completes, and the playback
hook is **never called**.

That's exactly why the driver enables the amps in `max98390_configure_high_pass_filter()` at probe
time (`DSP_GLOBAL_EN`, `SPK_EN`, `EN` → 1) instead: if it waited for the playback hook, there would
be no sound at all. The trade-off is deliberate — working speakers, at the cost of idle power
management.

**Battery impact:** the MAX98390 draws ~10μA per chip only in its *disabled* state, which this
package never reaches. The real idle draw is that of four enabled class-D amps. If you want them
genuinely powered down when you're not playing audio, use [@MatiDegli's speaker-on/off helper
scripts](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/discussions/4) to unload
the modules.

This will resolve itself if/when the alc269 quirk lands upstream: the master would then bind, the
playback hook would start firing, and on-demand power management would work as designed.

*(Thanks to [@HCIMECHA](https://github.com/HCIMECHA), whose investigation in
[#63](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/63) surfaced that no
component master exists.)*

### I2C Bus Detection

The I2C setup script doesn't hardcode a bus number. It dynamically finds the correct bus by:

1. Searching `/sys/bus/i2c/devices/` for any device matching `MAX98390`
2. Following symlinks to find the parent I2C adapter
3. Falling back to ACPI device path resolution

This makes it portable across Galaxy Book4 Pro, Pro 360, Ultra, and Book5 models.

### Secure Boot

DKMS handles module signing automatically if MOK (Machine Owner Key) keys are configured. See the full [Secure Boot Setup](#secure-boot-setup) section below if you haven't set this up before.

## File Structure

```
speaker-fix/
├── README.md                           # This file
├── install.sh                          # Installer (run with sudo)
├── uninstall.sh                        # Uninstaller (run with sudo)
├── dkms.conf                           # DKMS build configuration
├── max98390-hda-i2c-setup.sh           # I2C device creation script
├── max98390-hda-i2c-setup.service      # Systemd service for I2C setup
├── max98390-hda-check-upstream.sh      # Upstream detection + auto-removal
├── max98390-hda-check-upstream.service # Systemd service for upstream check
└── src/
    ├── Makefile                        # Kernel module build rules
    ├── max98390_hda.c                  # Core driver (init, component, PM)
    ├── max98390_hda.h                  # Driver private structures
    ├── max98390_hda_i2c.c              # I2C transport + probe logic
    ├── max98390_hda_filters.c          # DSM firmware blobs + filter config
    ├── max98390_hda_filters.h          # Filter function declarations
    ├── max98390_regs.h                 # Register definitions + local regmap
    ├── hda_scodec_component.h          # HDA side-codec component framework
    └── hda_generic.h                   # PCM action enum shim
```

## Credits

- **[Andycodeman](https://github.com/Andycodeman)** — DKMS packaging, out-of-tree build workarounds (local headers, regmap shim), I2C probe fix (address-based index derivation), dynamic I2C bus detection, automatic upstream detection and self-removal, install/uninstall scripts, systemd services, and documentation
- **[Kevin Cuperus](https://github.com/thesofproject/linux/pull/5616)** — Original MAX98390 HDA side-codec driver code, DSM filter configuration, and HDA component integration (upstream PR #5616)
- **DSM firmware blobs** — Extracted from Google Redrix (Chromebook with same MAX98390 amps)

## Sound Quality & EQ

The speakers will sound noticeably **thinner and quieter** compared to Windows. This is expected — it's not a bug in the driver.

> **Not the same as "the woofers are silent".** Expected-thin still has audible bass, and boosting the low end in an EQ still changes what you hear. If the woofers produce *no* bass at all and EQ has **zero** effect, that's a different problem — see **"Woofers produce no bass at all"** under [Troubleshooting](#troubleshooting).

### Why it sounds different from Windows

On Windows, Samsung's audio stack applies multiple layers of DSP (Digital Signal Processing) before audio reaches the speakers:

- **Dolby Atmos / Samsung Audio Wizard** — EQ curves, spatial audio, and loudness normalization tuned specifically for the laptop's speaker enclosure
- **Psychoacoustic bass enhancement** — DSP tricks that make your brain perceive bass frequencies that the small laptop speakers physically cannot produce
- **Dynamic range compression** — Makes quiet sounds louder and prevents distortion at high volumes
- **Speaker protection DSP** — Allows higher output levels without damaging the drivers

This fix provides the **raw hardware driver only** — it gets the speakers working, but none of the Windows audio processing exists on Linux. Additionally, the DSM (Dynamic Speaker Management) firmware in this package was extracted from a **Google Redrix Chromebook** (which uses the same MAX98390 amps), not from Samsung's Windows driver, so the tuning parameters are optimized for a different speaker enclosure.

### Improving sound quality with EasyEffects

You can significantly improve the sound using **[EasyEffects](https://github.com/wwmm/easyeffects)**, a PipeWire-based audio effects application that provides EQ, bass enhancement, compression, and more:

```bash
# Ubuntu / Debian
sudo apt install easyeffects

# Fedora
sudo dnf install easyeffects

# Arch / CachyOS / Manjaro
sudo pacman -S easyeffects
```

The Bass Enhancer effect requires Calf Studio Gear — install it if EasyEffects shows "Bass Enhancer Not Available":

```bash
# Ubuntu / Debian
sudo apt install calf-plugins

# Fedora
sudo dnf install calf-plugins

# Arch / CachyOS / Manjaro
sudo pacman -S calf
```

#### Recommended: JackHack96 presets

The [JackHack96 EasyEffects Presets](https://github.com/JackHack96/EasyEffects-Presets) collection includes several presets tuned for different use cases. Install them all:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/JackHack96/EasyEffects-Presets/master/install.sh)"
```

After installing, open EasyEffects and select a preset from the **Presets** dropdown (top-left). Personal preference varies, but the **"Advanced Auto Gain"** preset does a good job toning down the highs and allowing the bass to come through more, resulting in a more evenly distributed sound on these laptop speakers. Other presets to try:

- **Laptop** — Tuned specifically for laptop speakers
- **Loudness + Autogain Laptop** — Compensates for lower perceived volume
- **Bass Enhancing + Perfect EQ** — More aggressive bass boost

EasyEffects runs in the background and applies effects to all audio output. It won't perfectly match Windows' Dolby Atmos processing, but it makes a noticeable difference.

### When will it improve?

The [upstream kernel fix (PR #5616)](https://github.com/thesofproject/linux/pull/5616) includes proper Realtek ALC298 codec configuration through the `alc298-samsung-max98390` quirk, which will improve baseline audio quality with correct mixer levels and output routing. However, the PR is on GitHub for development only — it still needs to be submitted as patches via the [ALSA mailing list](https://mailman.alsa-project.org/mailman/listinfo/alsa-devel) to reach mainline Linux. There is **no confirmed timeline** and it could still be a ways out. Even with the upstream fix, matching Windows' full DSP stack would require Samsung to release Linux audio software, which is unlikely in the near term.

## Troubleshooting

**Speakers not working after install + reboot?**

```bash
# Check if modules loaded
lsmod | grep max98390

# Check if I2C devices were created
ls /sys/bus/i2c/devices/ | grep -i max

# Check service status
systemctl status max98390-hda-i2c-setup.service

# Check kernel log for driver messages
dmesg | grep -i max98390
```

**Woofers produce no bass at all (tweeters work, EQ has no effect)?**

All four amps probe fine, the tweeters play, but there is no low end — and boosting bass in EasyEffects or any other PipeWire-side EQ changes nothing. That last part is the tell: an EQ that does nothing means the attenuation is happening inside the amp, downstream of everything the host controls.

**Under investigation — see [#93](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/93).** One contributing bug has been fixed: the DSM firmware blobs shipped by this package were transcribed from upstream PR #5616 with two rows wrong, so every DSM parameter past register `0x2380` (woofer) / `0x2330` (tweeter) landed in the wrong register, and the short tweeter blob made the driver read past the end of its array. Both blobs now match upstream byte for byte, with a build-time size check.

That fix did **not** resolve the silent woofers on the machine that reported it (Book5 Pro 360, Lunar Lake), so the root cause is still open. If you hit this, please reinstall first — you want the corrected blobs before anything else is worth measuring:

```bash
sudo ./install.sh && sudo reboot
```

If the woofers are still silent afterwards, please say so on [#93](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/93) with your exact model and whether muting each amp individually changes what you hear — that's the measurement that will narrow it down.

**Modules not loading with Secure Boot? ("required key not loaded")**

This means the DKMS modules were built but not signed with your MOK key. Verify the signing config:

```bash
# Check if DKMS knows where your signing keys are
cat /etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf 2>/dev/null | grep mok_

# You should see lines like:
# mok_signing_key=/etc/pki/akmods/private/private_key.priv    (Fedora)
# mok_signing_key=/var/lib/shim-signed/mok/MOK.priv           (Ubuntu)
```

If no `mok_signing_key` / `mok_certificate` lines appear, create a drop-in config:

```bash
# Fedora
sudo mkdir -p /etc/dkms/framework.conf.d
sudo tee /etc/dkms/framework.conf.d/akmods-keys.conf > /dev/null << 'EOF'
mok_signing_key=/etc/pki/akmods/private/private_key.priv
mok_certificate=/etc/pki/akmods/certs/public_key.der
EOF

# Then rebuild the modules
sudo dkms remove max98390-hda/1.0 --all
sudo dkms install max98390-hda/1.0
sudo reboot
```

> **Note:** The exact key paths vary by distro. Ubuntu typically uses `/var/lib/shim-signed/mok/MOK.priv` and `MOK.der`. Fedora uses `/etc/pki/akmods/private/private_key.priv` and `public_key.der`. Check which files exist on your system.

**DKMS build fails on kernel update?**

```bash
# Check if headers are installed for the new kernel
sudo apt install linux-headers-$(uname -r)   # Ubuntu/Debian
sudo dnf install kernel-devel                 # Fedora

# Rebuild manually
sudo dkms build max98390-hda/1.0
sudo dkms install max98390-hda/1.0
```

**Audio worked, then a Samsung BIOS update broke it? ("Loading of module with unavailable key is rejected")**

A Samsung BIOS update can wipe EFI NVRAM, including your enrolled MOK key. The DKMS modules are still built and signed on disk, but the firmware no longer trusts the signing key, so the kernel rejects them at load time. Confirm with:

```bash
# Look for the rejection message in dmesg
sudo dmesg | grep "Loading of module with unavailable key"

# Confirm Secure Boot is on
mokutil --sb-state

# Check whether your DKMS signing key is enrolled
# (try each path that exists on your system)
mokutil --test-key /var/lib/dkms/mok.pub             # Debian
mokutil --test-key /var/lib/shim-signed/mok/MOK.der  # Ubuntu
mokutil --test-key /etc/pki/akmods/certs/public_key.der  # Fedora
```

If `mokutil --test-key` says **"is not enrolled"**, re-enroll the key and reboot:

```bash
# Use the SAME path that --test-key flagged as not enrolled
sudo mokutil --import /var/lib/dkms/mok.pub
sudo reboot
# On the blue MOK Manager screen, choose "Enroll MOK" → "Continue" → "Yes" → enter password
```

The `install.sh` script auto-detects this state on Fedora, Debian, and Ubuntu and queues the enrollment for you — re-running it is the lowest-friction recovery path:

```bash
sudo ./install.sh
sudo reboot
```

## Secure Boot Setup

**If Secure Boot is disabled on your system, skip this section entirely.** Check with:

```bash
mokutil --sb-state
# "SecureBoot enabled" = you need to do this
# "SecureBoot disabled" = skip this section
```

Secure Boot prevents unsigned kernel modules from loading. DKMS on Ubuntu can auto-sign modules using a Machine Owner Key (MOK), but the key must be **enrolled in your firmware** first. This is a one-time process.

### Step 1: Check if MOK keys already exist

```bash
ls /var/lib/shim-signed/mok/MOK.der /var/lib/shim-signed/mok/MOK.priv 2>/dev/null
```

If both files exist, skip to Step 2. If not, Ubuntu's `shim-signed` package usually generates them automatically. If they're missing:

```bash
sudo apt install shim-signed
# Keys should now exist at /var/lib/shim-signed/mok/
```

### Step 2: Check if the MOK is already enrolled

```bash
mokutil --list-enrolled
```

If you see a key listed, you're already set — skip to the install. If it says "MokListRT is empty" or shows no keys, continue to Step 3.

### Step 3: Enroll the MOK key

```bash
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
```

You'll be prompted to create a **one-time password**. Remember it — you'll need to type it on the next screen.

### Step 4: Reboot into MOK Manager

```bash
sudo reboot
```

On reboot, instead of booting normally, you'll see a **blue screen** (MOK Manager). This is expected:

1. Select **"Enroll MOK"**
2. Select **"Continue"**
3. Select **"Yes"**
4. **Type the password** you created in Step 3
5. Select **"Reboot"**

After this, your MOK is permanently enrolled. You never need to do this again — all future DKMS module builds (including kernel updates) will be auto-signed and load without issues.

### Step 5: Verify

After rebooting:

```bash
mokutil --list-enrolled | head -5
# Should show [key 1] with a SHA1 fingerprint
```

**Now you can run the install script.** If you already ran it before enrolling the MOK, just reboot — DKMS already signed the modules during install, they just couldn't load until the key was enrolled.

## See Also

- **[Webcam Fix — Book3/Book4](../webcam-fix-libcamera/)** — Fix for the built-in webcam (Intel IPU6 / OV02C10) using libcamera
- **[Webcam Fix — Book5](../webcam-fix-book5/)** — Fix for the built-in webcam (Intel IPU7 / Lunar Lake) using libcamera
