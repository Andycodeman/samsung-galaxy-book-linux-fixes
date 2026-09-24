# Issue #98 — "Hibernation disables the fix (7.2.6-arch2-1)" (@AhmadAli2024)

Hardware: MAX98390 board covered by `speaker-fix/` (4x MAX98390 on I2C behind
the ALC298). Distro: Arch, kernel 7.2.6-arch2-1.

**Status:** fix `4bae1c2` released as **v0.3.71** —
https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/releases/tag/v0.3.71. Reply posted — [comment-5810736173](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/98#issuecomment-5810736173), 2026-09-24.
Issue left **open** until the reporter confirms after a real hibernate cycle.

---

## What they asked

The speakers go silent after resuming from hibernation. Their workaround
reloads the I2C module:

```bash
sudo modprobe -r snd-hda-scodec-max98390-i2c
sudo modprobe snd-hda-scodec-max98390-i2c
```

They automated it with a systemd `system-sleep` hook
(`/usr/lib/systemd/system-sleep/max98390-hibernate-fix`) that does the same
reload on `post/hibernate`, `post/hybrid-sleep` and
`post/suspend-then-hibernate`. It's a report plus a workaround, not a
question. Their diagnosis ("they lose all state on power-off") is correct.

## Findings

1. **The driver had no system-sleep callback at all.** Before `4bae1c2`,
   `max98390_hda_pm_ops` in `speaker-fix/src/max98390_hda.c` contained only
   `RUNTIME_PM_OPS(max98390_hda_runtime_suspend, max98390_hda_runtime_resume, NULL)`.
   Nothing ran on system suspend, hibernate or restore.

2. **The runtime PM ops were inert anyway,** for two independent reasons:
   - Nothing in `speaker-fix/src/` calls `pm_runtime_enable()`, so the PM core
     never invokes the runtime callbacks.
   - The regmap is `REGCACHE_NONE` (`speaker-fix/src/max98390_regs.h`), so
     `regcache_sync()` in `max98390_hda_runtime_resume()` has no cache to
     replay and does nothing. Even if runtime PM were on, the "resume" would
     not restore a single register.

3. **Hibernation powers the amps off, which wipes every register probe
   wrote.** That includes the PCM/I2S format config, the 913-byte DSM tuning
   blob per amp (`0x2050`–`0x23E0`, woofer or tweeter variant), `DSM_VOL_CTRL`,
   and the three enable bits (`DSP_GLOBAL_EN`, `SPK_EN`, `GLOBAL_EN`). The
   amps come back at power-on defaults: disabled and untuned. Hence silence.

4. **Why the reporter's workaround works:** `modprobe -r` + `modprobe` unbinds
   and rebinds the I2C driver, which re-runs `max98390_hda_probe()` →
   `max98390_hda_init()` — the full init sequence. That is also exactly the
   right fix, just done from userspace.

5. **Plain suspend was affected too, to a degree we can't measure here.**
   Whether the amps lose power in s2idle/S3 is board- and firmware-dependent.
   The reporter only hit hibernate, but the driver had no hook for either.

## What was changed (commit `4bae1c2`)

`speaker-fix/src/max98390_hda.c` — new `max98390_hda_resume()` wired in with
`SYSTEM_SLEEP_PM_OPS(NULL, max98390_hda_resume)`. It calls the same
`max98390_hda_init()` probe uses: software reset → basic + PCM config →
`max98390_configure_filters()`, which reloads the DSM blob and sets the enable
bits again. Checked that init itself ends with the amps enabled: the
enable writes live at the end of `max98390_configure_high_pass_filter()` in
`max98390_hda_filters.c`, not in probe, so calling init alone is enough.

`SYSTEM_SLEEP_PM_OPS` sets `.resume`, `.thaw` and `.restore`, so it covers:

| Transition | Callback that runs |
| --- | --- |
| suspend (s2idle / S3) → resume | `.resume` |
| hibernate → restore from image | `.restore` |
| hybrid-sleep (resumed from RAM or from disk) | `.resume` or `.restore` |
| suspend-then-hibernate | `.resume` or `.restore` |
| hibernate snapshot written → `.thaw` | `.thaw` (amps were never off; harmless re-init) |

The runtime PM ops were left as they were. They are dead code, but removing
them is out of scope for this fix.

`speaker-fix/README.md` — a "Suspend / hibernate" paragraph under Power
Management.

**Trade-off:** every resume now does a software reset and ~930 I2C writes per
amp. That's a small fixed resume cost, and it's the same work probe already
does at boot.

**Note for anyone reloading by hand:** the resume callback lives in the
library module `snd-hda-scodec-max98390`, not in `-i2c`. The reporter's
reload only cycles `-i2c`, which would leave the *old* library module (no
resume callback) loaded. After updating: reboot, or unload both.

## Verification

- Compile-tested against kernel **7.0.0-31-generic** headers on the
  maintainer's machine: both `snd-hda-scodec-max98390.ko` and
  `snd-hda-scodec-max98390-i2c.ko` build. The only warnings are the
  toolchain-mismatch notes (compiler/pahole version), none in the code.
  `nm` shows `max98390_hda_resume` in the library module.
- `SYSTEM_SLEEP_PM_OPS` has been in mainline since 5.17 and the string-form
  `EXPORT_SYMBOL_NS_GPL` since 6.13, so the reporter's 7.2.6 is fine.

**Not verified:** an actual hibernate cycle on hardware. No hibernate test was
possible here. Confirmation has to come from @AhmadAli2024.

---

## Reply

Thanks for the report @AhmadAli2024, and for posting the workaround so others can use it in the meantime.

Your diagnosis is right. The driver set the amps up once, when it loaded, and never again. Hibernation cuts power to the four MAX98390 chips, so they lose their configuration and speaker tuning and come back silent. Reloading the module works because it re-runs that whole startup sequence.

The driver now re-runs that sequence itself on every resume: suspend, hibernate, hybrid-sleep and suspend-then-hibernate. It's in **[v0.3.71](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/releases/tag/v0.3.71)**. To update on Arch:

```bash
cd samsung-galaxy-book-linux-fixes   # wherever you cloned it
git pull
cd speaker-fix && sudo ./install.sh
sudo reboot
```

(If you installed from the tarball rather than a clone, just re-run the Quick Install one-liner from `speaker-fix/README.md`.) Please reboot rather than reload only `snd-hda-scodec-max98390-i2c`. The fix is in the `snd-hda-scodec-max98390` library module, and that one needs reloading too.

Your `system-sleep` hook is harmless to keep, but it's no longer needed. You can remove it with `sudo rm /usr/lib/systemd/system-sleep/max98390-hibernate-fix`.

One honest caveat: this was compile-tested, but I couldn't do a hibernate test on hardware here. Could you confirm the speakers survive a hibernate cycle after updating (with the hook removed)? If they don't, please post the output of `journalctl -b -k | grep -i max98390`. After a resume you should see `MAX98390 amp re-initialised on resume` once per amp.
