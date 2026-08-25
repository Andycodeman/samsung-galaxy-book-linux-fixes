# Issue #37 — Firefox PipeWire camera permission fix (Fedora 44), @david-bartlett

**Status:** the original report is **done** — documented, credited, shipped in
[v0.3.52](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/releases/tag/v0.3.52).
The reporter's 2026-08-22 reply is not a new symptom; it **contradicts advice we
added on top of his fix**, and that advice is now corrected in this branch.

**Recommendation: fix the docs (done here), post the reply below, close #37, and
move the one open question to [#70](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/70).**

Reply below is **drafted, not posted** — needs maintainer sign-off.

---

## What the reply actually says

He was asked (comment 4956222028, 2026-07-13) whether he really needed
`media.webrtc.camera.allow-pipewire = true`, on the theory that with the relay
running Firefox works over plain V4L2 with no flag — which would make the stale
portal denial unreachable in the first place. Measured on Fedora 44, Book5,
OV02E10, 2026-08-22:

| `media.webrtc.camera.allow-pipewire` | Result |
| --- | --- |
| `true` | both **Camera Relay** and **Built-in Front Camera** work |
| `false` | **no camera works** — `NotReadableError: Starting videoinput failed` |

Plus: Chrome behaves the same way — camera only via `#enable-webrtc-pipewire-camera`.

So the premise of the follow-up question was wrong, and the paragraph written on
that premise was wrong with it.

## Why this matters more than the thread does

The "just turn the flag off" line was **ours, not his**. It went into two READMEs
and one install summary in v0.3.52:

| Where | Claim |
| --- | --- |
| `webcam-fix-libcamera/README.md` (compat table + #37 section) | "No flags needed"; setting the pref false "avoids this entirely" |
| `webcam-fix-book5/README.md` (compat table + #37 section) | same |
| `webcam-fix-libcamera/install.sh` summary | "Firefox: Works out of the box (no flags needed)" |

On Fedora that is not a workaround, it is a second way to break the camera — and
it is the *first* thing a reader hits, because it is offered as the easier
option. Left alone it would keep generating this exact thread.

The Chrome half of his reply, by contrast, is not news: it is the documented
Chromium V4L2 capability filter (PR #83), already handled by
`chromium-pipewire-camera`. Nothing to change there.

## Why `NotReadableError` and not `NotFoundError`

Worth being precise, because the two point at different layers.
`NotFoundError` = nothing enumerated. `NotReadableError` = **a node was found and
would not start**. So with the pref off, Firefox is finding *something* and
failing on it — and the same loopback is demonstrably producing frames, since
with the pref on the `Camera Relay` PipeWire node (which is WirePlumber's view of
that same `/dev/videoN`) works.

Leading suspect, and it is our bug rather than Firefox's:

> `webcam-fix-book5/install.sh:1121` — "Installed plain 755 here, NOT setgid. The
> setgid treatment in webcam-fix-libcamera exists to reach raw MC nodes that its
> udev rule moves into the memberless camera-relay group; **this installer ships
> neither that group nor that rule, so the nodes stay in 'video'** and the desktop
> user already has them. […] Porting the full setgid + udev hardening across is
> issue #70 and wants a Book5 tester."

On Book4 the raw IO_MC ISYS nodes are hidden by
`74-camera-relay-mc-nodes.rules`; a Book5 install has no equivalent (only the
superseded `90-hide-ipu7-v4l2.rules`, which the libcamera installer's own comments
record as never having hidden anything — `TAG-="uaccess"` alone cannot beat
`70-uaccess.rules`). Those nodes open fine and can never stream. A V4L2 consumer
that walks `/dev/video*` and picks one gets exactly `NotReadableError`.

**This is unconfirmed** — the alternative is that Firefox's direct open of the
dual-caps loopback fails on Fedora for an unrelated reason. Two commands
separate them, and they are in the reply. And @david-bartlett is already the
Book5 tester #70 is waiting on, so the question belongs there, not here.

## Disposition

1. Correct the docs — **done in this branch** (see below). Not optional: the bad
   advice is live in the released READMEs.
2. Post the reply, then **close #37**. Its subject — the stale PermissionStore
   denial — is fixed, documented and credited. Reopening its scope to cover
   "why does the V4L2 path fail on Fedora" would bury a good, findable writeup.
3. Carry the open question to **#70**, where the Book5 udev hardening already
   lives and where the same person is already the tester.

## Changes made in this branch

| File | Change |
| --- | --- |
| `webcam-fix-libcamera/README.md` | compat table row + #37 section: flag-off is no longer presented as a workaround; his measurement quoted as a table |
| `webcam-fix-book5/README.md` | same, plus the `NotReadableError` / #70 note above |
| `webcam-fix-libcamera/install.sh` | summary no longer claims Firefox needs no flags; also gives the following "the flag above enables" line a referent it did not have |
| `camera-relay/camera-relay` | new `firefox_pipewire_pref_state()`; `doctor` now reports the Firefox pref per profile (native, snap, flatpak) |
| `camera-relay/tests/test-firefox-pipewire-pref.sh` | new, 15 assertions |

`doctor` reporting Firefox is a gap, not a feature request: both install summaries
already say *"Run 'camera-relay doctor' to see the flag state per browser"*, and
the entire browser block was gated behind `chromium_family` — so a Firefox-only
machine, which is precisely this reporter's, got no browser diagnostic at all.

Deliberately **not** done: making an installer set the Firefox pref. It is right
on Fedora and unnecessary elsewhere, one data point is not enough to justify
writing into someone's `prefs.js`, and `doctor` now surfaces it either way.

### Verification

- New suite: 15 assertions, passing. Mutation-tested twice — reporting an absent
  pref as `DISABLED` fails 5 assertions; reading the first assignment instead of
  the last fails 2. It is not a suite that passes against the bug it guards.
- Full `camera-relay/tests` suite: **10 suites, 212 assertions, 0 failures.**
- `camera-relay doctor` run live on the maintainer's Book4: found both snap
  Firefox profiles, reported `not set (build default)`, skipped the profile
  directories with no `prefs.js`, printed outside the Chromium block.
- **No Fedora and no Book5 hardware here.** The doc correction rests entirely on
  the reporter's measurement, and the #70 hypothesis is unverified. The reply
  says so.

---

## Drafted reply (NOT posted — needs sign-off)

> That's a much more useful answer than the one I was fishing for — thanks for
> going back and measuring it.
>
> You've disproved the thing I suggested. I'd written into both READMEs that if
> you don't need the PipeWire path you can just set
> `media.webrtc.camera.allow-pipewire = false` and Firefox will read the V4L2
> relay node directly, which would sidestep the stale portal denial entirely.
> That holds on Book4 under Ubuntu. On your Fedora 44 box it clearly doesn't: the
> pref off gives you `NotReadableError` on everything. That was my suggestion
> layered on top of your fix, not anything you claimed, and offering it as the
> easier of the two options was the worst place to put it. Fixed — the READMEs
> now carry your table and tell Fedora users to delete the stale
> PermissionStore entry and leave the pref **on**.
>
> `camera-relay doctor` also now reports the Firefox pref per profile (native,
> snap and flatpak), the way it already did for the Chromium flag. Both install
> summaries have been promising "the flag state per browser" while the whole
> browser section was skipped unless a Chromium-family browser was present — so
> on a Firefox-only machine it said nothing at all.
>
> Chrome needing `#enable-webrtc-pipewire-camera` is expected and already
> handled: Chromium only accepts a V4L2 node that reports capture *without*
> output, and the relay reports both, so it filters the node out before any
> prompt. `chromium-pipewire-camera` (installed to `/usr/local/bin`) sets that
> flag for you.
>
> So yes — **happy to close this one.** The stale-denial fix is documented and
> credited and the write-up stays findable.
>
> One loose end I'd rather chase in #70 than here, if you're up for it. The error
> you get with the pref off is `NotReadableError`, not `NotFoundError` — Firefox
> *found* a node and couldn't start it. And the relay itself is plainly fine,
> because with the pref on the `Camera Relay` source works, and that's
> WirePlumber's view of the very same `/dev/videoN`. My suspicion is it's picking
> a raw IPU7 media-controller node: those open fine and can never stream, and the
> Book4 installer hides them with a udev rule that has never been ported to
> `webcam-fix-book5` — which is exactly #70, and you're already the Book5 tester
> it's waiting on. Two commands would settle it, whenever you have a moment:
>
> ```bash
> # 1. What Firefox is choosing between. "Camera Relay" is the loopback;
> #    anything ipu7/isys-shaped is a raw node that can never produce frames.
> v4l2-ctl --list-devices
>
> # 2. With the pref back to false, point a plain V4L2 consumer at the relay
> #    node from (1) — substitute the right N:
> mpv av://v4l2:/dev/videoN
> ```
>
> If mpv shows a picture while Firefox still errors, it's node *selection* and
> #70's udev rule is the fix. If mpv fails too, it's the direct open of the
> dual-caps loopback on Fedora and I'm wrong — either way that's a real answer
> and I'd rather have it than guess.
>
> I've got no Fedora or Book5 hardware here, so everything above rests on your
> measurements. Thanks again for coming back to it.
