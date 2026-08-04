# PR #77 review — "docs: the 26 MHz OV02C10 clock is per-board, not Raptor Lake only"

Reviewed: 2026-08-04. Author: **@4nrry**. Base `main`, docs-only, +19/−9 over 3
files (`README.md`, `ov02c10-26mhz-fix/README.md`,
`webcam-fix-libcamera/README.md`). No code changes.
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/77>

## Verdict: 🟢 **Merge — after one precision fix**

The central claim is correct, and this repo's own hardware proves it *more*
strongly than the PR argues. One line overstates in the opposite direction and
should be tightened before or immediately after merge.

## The claim, and why it's right

The docs attributed the `external clock 26000000 is not supported` probe failure
exclusively to Raptor Lake IPU6. @4nrry hit it on a **Meteor Lake** board
(NP960XGL-XG1BR, IPU6 `8086:7d19`) and argues the clock is a per-board property.

**Confirmed here, from the other direction.** Andy's machine is also a Book4
Ultra **960XGL** on **Meteor Lake IPU6 `8086:7d19`** — the same model
designation and the same platform as the reporter's — and it does **not** have
the 26 MHz clock:

```
00:05.0 Multimedia controller [8086:7d19]        # Meteor Lake IPU6
v4l-subdev6: ov02c10 3-0036                      # sensor probed fine
modinfo ov02c10 → /lib/modules/7.0.0-28-generic/ubuntu/ipu6/ov02c10.ko.zst
                                                 # STOCK in-tree driver, not DKMS
dkms status → max98390-hda only                  # no ov02c10 fix installed
journalctl -k -b | grep ov02c10
  → "failed to check hwcfg: -517"  (EPROBE_DEFER, normal) — and nothing else
```

Camera works end to end at 30 fps on the unpatched driver.

So we have **two Book4 Ultra 960XGL boards, both Meteor Lake IPU6 `8086:7d19`,
that disagree** — one needs the fix, one doesn't. The clock is not merely
platform-independent, it is not even *model*-determined. That is a stronger
version of the PR's thesis and worth saying outright in the docs.

## Supporting claims — all verified

- **"The installer was already correct."** True.
  `webcam-fix-libcamera/install.sh:300-306` greps dmesg / `sudo dmesg` /
  `journalctl -k` for the clock rejection string and never inspects the
  platform. This PR genuinely only aligns prose with existing behaviour.
- **Kernel ceiling 6.17 → 7.0.** Reasonable — Andy's box runs 7.0.0-28-generic
  with the in-tree `ov02c10` loaded and working.
- **"Kernel 7.0 selects SOF and exposes the DMIC, no `mic-fix` needed."**
  Independently confirmed on the same kernel here: `snd_sof_pci_intel_mtl`
  loaded, `card 0 … device 6: DMIC Raw` present, and no mic/SOF entries in
  `/etc/modprobe.d/`.

## The one fix needed

`ov02c10-26mhz-fix/README.md` lists as a confirmed affected model:

> - Galaxy Book4 Ultra **NP960XGL** — Meteor Lake IPU6 `8086:7d19`

and `README.md`'s "Tested On" entry says the same board "still needed the 26 MHz
clock fix".

Listing the bare model `NP960XGL` as affected tells every 960XGL owner they need
a DKMS patch — including Andy's, which demonstrably does not. That is the exact
failure mode this PR exists to fix, just inverted: instead of Meteor Lake owners
wrongly *skipping* the fix, 960XGL owners would wrongly *install* it.

The reporter's machine is **NP960XGL-XG1BR**; the `-XG1BR` suffix is the SKU. So:

- carry the **full SKU** in the affected list, not the bare model, and
- state explicitly that **the same model can differ board to board**, citing the
  960XGL that does not need it.

That change makes the document's own argument stronger, not weaker.

## Not verified

- The reporter's dmesg evidence (their board's 26 MHz rejection and the
  post-fix informational message) is taken on their report — no 26 MHz board
  available here to reproduce it.
- The Secure Boot / MOK-signing claim in the "Tested On" entry.
