# Issue #95 round 3 — root cause found: OV02C10 26 MHz clock rejection

@hayden-xyz volunteered to test and posted diagnostics (2026-09-13). The dmesg
is decisive.

## Root cause

```
ov02c10 i2c-OVTI02C1:00: error -EINVAL: external clock 26000000 is not supported
ov02c10 i2c-OVTI02C1:00: probe with driver ov02c10 failed with error -22
```

That is the exact string `webcam-fix-libcamera/install.sh:347` greps for. His
board needs `ov02c10-26mhz-fix/` (#77). The sensor never probes, so **no camera
stack of any kind can work** — this sits upstream of libcamera, icamerasrc and
`hardware.ipu6` alike.

It also fully explains his symptom: "a bunch of ipu6 named camera devices that
dont output anything" are the raw IPU6 ISYS media-controller nodes with no
sensor behind them. **Draw no conclusion about the icamerasrc route from this**
— it was never given a sensor to work with.

## New data point for #77

Third independently confirmed board, and the first **940XFG**:

| Board | Platform | Source |
|---|---|---|
| Book4 Pro 940XGK | Raptor Lake, SSID `0x144dca07` | earlier |
| Book4 Ultra NP960XGL-XG1BR | Meteor Lake `8086:7d19` | @4nrry |
| **Book3 Pro 14" 940XFG** | **Raptor Lake `8086:a75d`** | **#95, NixOS, kernel 7.2.4-cachyos** |

Added to `ov02c10-26mhz-fix/README.md`. Reinforces the per-board thesis —
this is the same board we just shipped the speaker fix for.

## Module placement — a hypothesis I had to retract

Installs to `lib/modules/<ver>/updates/`, where DKMS puts it.

I initially believed NixOS had a precedence problem here: its module aggregator
(`pkgs/os-specific/linux/kmod/aggregator.nix`) runs
`depmod -b $out -C $out/etc/depmod.d`, and nothing normally provides that
directory, so I reasoned depmod ran with no search-priority config and an
out-of-tree module would not reliably beat its in-tree namesake. I shipped a
`depmod.d` override to force it, wrote it into the module, the README and #96,
and told Andy it probably explained the Book5 `ipu-bridge` wart too.

**It was wrong.** Test: build an aggregate containing both a synthetic
`kernel/drivers/media/i2c/ov02c10.ko` and an out-of-tree copy, then read what
`modules.dep` resolves to.

| out-of-tree location | depmod.d override | modules.dep resolves to |
|---|---|---|
| `updates/` | yes | `updates/ov02c10.ko` |
| `updates/` | **no** | `updates/ov02c10.ko` |
| `extra/` | no | `extra/ov02c10.ko` |

Both files confirmed present in the tree in every case (the first version of
this test was vacuous — nixpkgs' 6.12 kernel ships no in-tree `ov02c10` at all,
so there was no conflict to resolve; caught it before drawing a conclusion).

kmod's compiled-in default already ranks `updates/` and `extra/` above the
in-tree `kernel/` tree. The override was dead weight built on a wrong premise
and has been removed. Issue #96 corrected in place.

Consequence: **this does not explain the Book5 `ipu-bridge` note.** That cause
is still unknown; depmod precedence is now ruled out.

Caveat: the synthetic in-tree module was uncompressed `.ko` while a real
in-tree module is `.ko.xz`. Precedence is directory-based so this should not
matter, but it is not a from-scratch proof.

## Sequencing change

Originally the plan was to write the libcamera module first. That would have
failed on his machine for a reason having nothing to do with it. Re-split:

1. **#96** — `nixos/ov02c10-26mhz-fix.nix`. Small, one rebuild, binary result
   (does the dmesg line go away).
2. **#97** — `nixos/webcam-fix-libcamera.nix`. Blocked on #96.

## Open risks

- **Kernel 7.2.4-cachyos vs "tested up to 7.0"** in the README. The vendored
  `ov02c10.c` carries a `LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)` guard so
  it has been maintained forward, but 7.2 is unverified. Fallback is
  `boot.kernelPatches` — robust, but a full kernel rebuild, painful on a custom
  cachyos kernel.
- **IVSC may be a second wall.** His dmesg has no `mei-vsc` / `ivsc-*` lines at
  all and `ls /run/current-system/firmware/ | grep -i vsc` was empty. Could be a
  reverted config; could be a real second blocker. Asked.

## Verification done here

- Evaluates clean in a full `eval-config.nix` NixOS system evaluation.
- **The kernel module compiles** — built against nixpkgs' 6.12.63, producing
  `lib/modules/6.12.63/updates/ov02c10.ko`. That is *a* kernel, not *his*
  kernel: 7.2.4-cachyos is still unverified, and the vendored source is
  documented as tested only to 7.0.
- Module-search precedence verified as above.

## Status

Posted 2026-09-13 as comment 5656056173. Module shipped on `main`.
Issues #96 (this) and #97 (libcamera module, blocked on #96) opened.
No release cut yet — awaiting @hayden-xyz's test result, since the fix is
unverified on affected hardware.
