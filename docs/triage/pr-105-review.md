# PR #105 review — "feat(camera-relay): track v4l2loopback usage events to detect unlisted readers"

Reviewed: 2026-10-05. Author: **@ang3lo-azevedo** (Ângelo Azevedo). Split out
of #102 as asked in the [#102 review](pr-102-review.md). Head `3aab9dc`, based
on `main` `1df6dae`. 1 commit, 1 file (`camera-relay/camera-relay-monitor.c`),
+49/−9. No CI on the repo.
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/105>

## Verdict: 🟠 **CHANGES REQUESTED** (not merged)

Posted 2026-10-05 as a REQUEST_CHANGES review from @Andycodeman:
<https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/pull/105#pullrequestreview-5418552526>

The idea is right and the event handling agrees with upstream v4l2loopback. It
adds no per-frame cost, and on the upstream event path it fixes the bug it
targets: a reader running as another user (root daemon) never started the
camera. Three small changes are needed first, and each was tested here (see §6):

| # | Severity | Finding |
|---|---|---|
| F1 | **Should fix** | Inert on Ubuntu 0.13+. Ubuntu's package queues the same payload under the old `PRIVATE_START` ID, and the monitor subscribes to that ID **first**, so `note_usage_event()` never matches. This includes this machine (Ubuntu 26.04, `v4l2loopback-dkms 0.15.3-1ubuntu2`) |
| F2 | **Should fix** | A reader already streaming when the monitor (re)starts is never picked up: the timeout branch checks only `/proc`. **Reproduced** (Copilot's finding #1) |
| F3 | Minor | A failed event re-subscribe after a pipeline stop leaves `reader_streaming` stale at 1, which would keep the pipeline (and camera) on. Not reproducible, found by reading the code (Copilot's finding #2) |

| | |
|---|---|
| Mergeable vs `main` | **Yes.** `git merge-tree --write-tree origin/main pr-105` is clean (tree `1c6a54b`). `main` gained #104 since the base, which touches only `camera-relay-gst.c` and a test |
| Per-frame cost (PR #60 rule) | **None.** One `poll(…, 0)` per ~30 frames, attached to the existing `/proc` check (strace numbers in §5) |
| `open_writer()` S_FMT check (PR #79) | **Preserved.** The diff doesn't touch `open_writer()` |
| Build | Clean with installer flags (`-O2 -Wall`) and with `-Wall -Wextra -Werror`, gcc 15.2 |
| Tests | 11/11 `camera-relay/tests/test-*.sh` pass on the PR tree and on the merged tree |
| Runtime test | **Yes, on a temporary loopback device** (`/dev/video63`, created and then deleted through `/dev/v4l2loopback`) with Ubuntu's 0.15.3 module, a synthetic frame source, and `v4l2-ctl` readers as andy and as root. No camera hardware involved. Live relay on `/dev/video0` untouched (same PID before and after) |
| Effect on 0.12.x | None. Stock 0.12.7 has no private event at all. Ubuntu's 0.12.7 accepts only the old ID, whose events `note_usage_event()` ignores |
| Blocks | #102 carries a byte-identical copy of this file. See "Knock-on for #102" |

---

## What changed

The monitor decides whether anyone is watching by scanning `/proc/*/fd` for the
loopback's `dev_t`, skipping processes it doesn't own (`count_other_openers()`).
A reader running as another user, such as Ângelo's root `gazed` on NixOS, is
invisible to it. The relay keeps writing idle black frames and never starts the
camera.

The PR records the payload of v4l2loopback 0.13+'s usage event
(`V4L2_EVENT_CLIENT_USAGE_NEW`) in a `reader_streaming` flag and uses it:

- **Idle, event path** (`:552-583`): after the wake-up event, it drains the queue
  and starts the pipeline if `/proc` clients > 0 **or** `reader_streaming`.
- **Relay, periodic check** (`:674-680`): every 30 frames it drains the events
  and adds the flag to the `/proc` count, so the relay keeps running for an
  invisible reader and stops when that reader leaves.
- **After stop** (`:740-787`): it resets the flag on re-subscribe, takes the
  SEND_INITIAL state, and adds it to the "clients still there → restart" count.

## Verification

### 1. Mergeability

```
$ git fetch origin pull/105/head:pr-105
$ git merge-base pr-105 origin/main          → 1df6dae
$ git merge-tree --write-tree origin/main pr-105   → 1c6a54b (rc=0, clean)
$ git diff --stat 1df6dae origin/main -- camera-relay/
 camera-relay/camera-relay-gst.c                |  4 +++-     (#104)
 camera-relay/tests/test-launcher-validation.sh | 30 ++++++     (#104)
```

### 2. Upstream event semantics (cloned `umlaeute/v4l2loopback`, grepped per tag)

| Version | Event ID | Payload `count` | Queued on |
|---|---|---|---|
| 0.12.7 (upstream) | **none.** `vidioc_subscribe_event` accepts only `V4L2_EVENT_CTRL` | | |
| 0.13.0 – 0.13.2 | `PRIVATE_START + 0x08E00000 + 1` | `dev->active_readers` (a second capture STREAMON gets `-EBUSY`, so 0/1) | capture STREAMON, STREAMOFF, close of a reader, subscribe with SEND_INITIAL |
| 0.14.0 – 0.15.4 | same | `!has_capture_token(dev->stream_tokens)` | capture STREAMON/STREAMOFF (`:2079`/`:2124` @0.15.3), close → `REQBUFS(0)` → `vidioc_streamoff`, subscribe with SEND_INITIAL |
| **Ubuntu 0.15.3-1ubuntu2** (`/usr/src/v4l2loopback-0.15.3`) | **both** the upstream ID **and** `V4L2_EVENT_PRIVATE_START` ("backward compatibility for v4l2-relayd", a standing Ubuntu delta) | same payload, queued twice | same |

Other checks:

- `v4l2_event_subscribe(fh, sub, 0, &client_usage_ops)` gives one slot, with
  `replace`/`merge` copying the payload. The queue always holds the **latest**
  state, so the flag can't get stuck from a dropped event.
- A process crash goes through `close` → `REQBUFS(0)` → streamoff → `count=0`.
- `read()`-mode readers are covered too: `start_fileio()` calls
  `vidioc_streamon()`.
- The relay itself doesn't count. The monitor only `write()`s an OUTPUT stream,
  and the pipeline child writes to a pipe, never to the device.
- Known limit on 0.14+: only one capture opener holds the stream token. If a
  second reader STREAMONs while the first holds it, there's no event, and when
  the first stops, `count` drops to 0 even though the second is still
  streaming. For a same-UID second reader, `/proc` still covers it. A
  cross-UID second reader is lost, which is no worse than `main`.

### 3. F1 — Ubuntu 0.13+ never reaches the new code

`try_subscribe_events()` (`:231-254`) tries `_OLD` (= `V4L2_EVENT_PRIVATE_START`)
first. On Ubuntu's 0.13+ packages that succeeds, the monitor logs
"Using v4l2loopback **0.12.x** event API" on a 0.15.3 module, and every event
it receives has type `_OLD`. `note_usage_event()` only acts on `_NEW`, so
`reader_streaming` stays 0 and the PR is a no-op on Ubuntu. This was confirmed at
runtime in §6 (`pr` row). The PR description and our #102 review ("Ubuntu's
0.12.7 is unaffected") both assumed Ubuntu means 0.12.7. That's no longer true:
this machine runs 0.15.3.

**Fix:** subscribe `_NEW` first, then `_OLD`. On vanilla 0.13+ nothing changes,
since `_OLD` fails there anyway. Ubuntu 0.13+ gets the payload. Ubuntu's 0.12.7
can't subscribe `_NEW`, so it falls through to `_OLD` exactly as today. Both IDs
are queued at the same points on Ubuntu, so the wake-up timing doesn't change.

### 4. F2 / F3 — the flag outside the event path

**F2.** The idle loop's poll-timeout branch (`:584-602`) checks only `/proc`.
If the initial or after-stop drain records `reader_streaming=1` and no further
event arrives, the pipeline never starts and the reader sits on idle black
frames at ~0.5 fps. This is exactly what happens when the relay restarts
(`Restart=always`, crash, `systemctl --user restart`) while `gazed` is
streaming, which is the PR's own target. Reproduced in §6 with a debug print:
`initial reader_streaming=1`, no START over 8 s, and the root reader still
dequeuing frames 2 s apart.

**F3.** The `reader_streaming = 0` reset (`:759`) is in the success branch only.
If re-subscribe fails, `use_events=0` and nothing drains events any more, so a
stale 1 is added to every later count. The pipeline then restarts and never
stops (`clients` is never ≤ 0), which leaves the camera LED on. Re-subscribe
on a freshly opened fd shouldn't fail in practice, but the fix costs one line.

### 5. Hot path (the PR #60 rule) and build

```
$ gcc -O2 -Wall          -o … camera-relay-monitor.c   → clean (base and PR)
$ gcc -O2 -Wall -Wextra -Werror …                      → clean
$ gcc -O3 -Wall -Wextra -Wstrict-aliasing=1 -fsyntax-only … → clean
```

The installers use `gcc -O2 -Wall` (`webcam-fix-libcamera/install.sh:1973`,
`webcam-fix-book5/install.sh:1103`, `nixos/webcam-fix-book5.nix:90`).

`strace -e trace=poll,read,write,ioctl` on the monitor over the same ~10 s
relay window (same-UID `v4l2-ctl --stream-mmap` reader, 30 fps synthetic
640×480 YUY2 source):

| build | frame writes to device | pipe reads | `poll()` total | `poll(POLLPRI, 0)` | `DQEVENT` |
|---|---|---|---|---|---|
| base `1df6dae` | 304 | 3000 | 3004 | 0 | 3 |
| PR (NEW-first) | 304 | 3000 | 3016 | **12** | 4 |

That's about one extra zero-timeout poll per second, inside the existing
`check_tick % 30` block next to a full `/proc` walk. Nothing is added between
`read_full()` and `write()`.

### 6. Runtime A/B on a temporary loopback

Done without touching the live relay or any installed file: `v4l2loopback-ctl`
was built from the 0.15.3 source in a scratch dir, and
`sudo v4l2loopback-ctl add -x 0 -w 1920 -h 1080 63` created `/dev/video63`,
which was deleted afterwards (verified gone). The monitor ran with a Python stand-in
for `camera-relay-gst` (`fdsink fd=3` equivalent). The readers were
`timeout N v4l2-ctl -d /dev/video63 --stream-mmap`. Each scenario records the
monitor's stdout events.

| Scenario | `base` (main) | `pr` (as submitted) | `prnew` (PR, NEW-first = vanilla 0.13+ behaviour) | `prfix` (PR + F1/F2/F3) |
|---|---|---|---|---|
| A. same-UID reader 4 s | START → STOP ✅ | START → STOP ✅ | START → STOP ✅ | START → STOP ✅ |
| B. **root** reader 4 s | READY only ❌ (`clients=0`) | READY only ❌ (`clients=0 streaming=0`, F1) | START → STOP ✅ (`streaming=1`) | START → STOP ✅ |
| C. root reader already streaming, monitor restarted | no START ❌ | no START ❌ | no START ❌ (F2; `initial reader_streaming=1`) | START ✅ (`/proc fallback: clients=0 streaming=1`) |

Row B is the bug the PR fixes. Row C is Copilot's #1, now reproduced. In `prnew`,
the root reader's STOP came ~2 s after the reader exited, the normal
`had_clients && idle_ticks >= 3` path, so the relay still stops when the last
(invisible) reader leaves.

### 7. Tests

`camera-relay/tests/test-*.sh` on the PR worktree **and** on the merged tree
(`main` + #105): chromium-pipewire-flag 61/0, distro-detection 16/0,
egl-vendor-pin 18/0, firefox-pipewire-pref 15/0, gst-tools-check 8/0,
launcher-validation 29/0 (30/0 merged, #104's test), monitor-exit-propagation
5/0, pipewire-restart-guard 17/0, unit-regeneration 15/0,
wireplumber-format-nudge 26/0, writer-format-check 1/0 (build only: the one
loopback here belongs to the live relay, so the test skips by design). None of them
exercise the event path. §6 is the only coverage it has.

## Suggested patch (tested as `prfix` above)

```diff
@@ static __u32 try_subscribe_events(int fd)
 	memset(&sub, 0, sizeof(sub));
-	sub.type = V4L2_EVENT_CLIENT_USAGE_OLD;
+	sub.type = V4L2_EVENT_CLIENT_USAGE_NEW;
 	sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
 	if (xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) == 0) {
 		fprintf(stderr,
-			"[monitor] Using v4l2loopback 0.12.x event API\n");
-		return V4L2_EVENT_CLIENT_USAGE_OLD;
+			"[monitor] Using v4l2loopback 0.13+ event API\n");
+		return V4L2_EVENT_CLIENT_USAGE_NEW;
 	}
 
 	memset(&sub, 0, sizeof(sub));
-	sub.type = V4L2_EVENT_CLIENT_USAGE_NEW;
+	sub.type = V4L2_EVENT_CLIENT_USAGE_OLD;
 	sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
 	if (xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) == 0) {
 		fprintf(stderr,
-			"[monitor] Using v4l2loopback 0.13+ event API\n");
-		return V4L2_EVENT_CLIENT_USAGE_NEW;
+			"[monitor] Using v4l2loopback 0.12.x event API\n");
+		return V4L2_EVENT_CLIENT_USAGE_OLD;
 	}
@@ idle loop, poll-timeout branch
-					if (clients > 0) {
+					if (clients > 0 ||
+					    reader_streaming) {
 						fprintf(stderr,
 							"[monitor] /proc"
 							" fallback:"
-							" clients=%d\n",
-							clients);
+							" clients=%d"
+							" streaming=%d\n",
+							clients,
+							reader_streaming);
@@ after-stop re-open
+					reader_streaming = 0;
 					event_type =
 						try_subscribe_events(fd);
 …
-						reader_streaming = 0;
 						if (poll(&pfd, 1, 200)
```

The F2 change makes the timeout branch retry every 2 s for as long as
`reader_streaming=1` (a reader really is streaming), even after `rapid_fails`
gives up. Same-UID
`/proc` clients already behave that way on `main`, so this is consistent, not
new.

## Knock-on for #102

#102's `camera-relay-monitor.c` is byte-identical to `3aab9dc`. After #105 is
revised and merged, the author must merge `main` back into #102 and take
`main`'s version of this file. The two edits overlap, so expect a conflict
there. The #102 verdict stays **MERGE AFTER #105**. Merging #102 first would
land the F1/F2 version.

## Testing still needed, and by whom

- **@ang3lo-azevedo (NixOS, v4l2loopback 0.15.4, root `gazed`)**: the real
  case. With the revised commit: (a) start `gazed` → relay STARTs, camera works;
  (b) stop `gazed` → relay STOPs within ~3 s; (c) `systemctl --user restart
  camera-relay` **while** `gazed` streams → relay STARTs again (F2).
- **A Fedora or Arch tester (vanilla 0.13+)**: a normal same-user app
  (browser/OBS) start → stop → start, to confirm no change for the common case.
- **Ubuntu 0.13+ (this machine)**: §6 rerun against the revised commit on a
  temporary device. Ubuntu 0.12.7 (24.04 and older) isn't reachable here, but
  per F1 it keeps today's `_OLD` path unchanged.

## Reproduce

```bash
git fetch origin pull/105/head:pr-105
git worktree add --detach "$SCRATCH/pr105" pr-105
gcc -O2 -Wall -Wextra -Werror -o "$SCRATCH/pr" "$SCRATCH/pr105/camera-relay/camera-relay-monitor.c"
for t in "$SCRATCH"/pr105/camera-relay/tests/test-*.sh; do bash "$t"; done
git clone https://github.com/umlaeute/v4l2loopback "$SCRATCH/v4l2lb"
git -C "$SCRATCH/v4l2lb" show v0.15.3:v4l2loopback.c | grep -n 'CLIENT_USAGE\|has_capture_token'
diff <(git -C "$SCRATCH/v4l2lb" show v0.15.3:v4l2loopback.c) /usr/src/v4l2loopback-0.15.3/v4l2loopback.c   # Ubuntu delta
# temp device (never video0):
gcc -O2 -I"$SCRATCH/v4l2lb" -o "$SCRATCH/v4l2loopback-ctl" "$SCRATCH/v4l2lb/utils/v4l2loopback-ctl.c"
sudo "$SCRATCH/v4l2loopback-ctl" add -x 0 -w 1920 -h 1080 63
  … run monitor on /dev/video63 640 480 -- <frame source on fd 3>; readers: [sudo] timeout 4 v4l2-ctl -d /dev/video63 --stream-mmap
sudo "$SCRATCH/v4l2loopback-ctl" delete /dev/video63
```
