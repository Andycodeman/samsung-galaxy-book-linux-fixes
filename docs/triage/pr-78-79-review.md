# PRs #78 and #79 review — 2026-08-04

Both from **@4nrry**, both `CHANGES_REQUESTED` posted 2026-08-04. Independent of
each other. Neither should merge as-is; each has exactly one blocking defect.

---

## #79 — "camera-relay-monitor: refuse to stream into a format the device didn't take"

`+148/-3`, `camera-relay-monitor.c` + one new test.
Verdict: 🟡 **merge after one fix.**

The change is correct: `S_FMT` can fail *or* silently adjust what it was given
and report success, and fixed-size YUYV written into whatever it settled on is
garbage to every reader. Checking the returned struct, not just the return code,
is the right instinct. Both call sites handle the new `-1`.

### Blocking — the recovery claim is false

The PR argues the relay self-heals because the unit has `Restart=on-failure`.
It doesn't: `cmd_start_ondemand` runs the monitor inside a **process
substitution**, which discards the child's exit status.

```
$ bash -c 'while IFS= read -r l; do :; done < <(echo hi; exit 42); echo "$? / ${PIPESTATUS[*]}"'
0 / 0
```

The function's last statement is `info "On-demand relay stopped"`, so it returns
0 regardless — `camera-relay start --on-demand` always exits 0 and
`Restart=on-failure` never fires. Separately the re-open call site returns 0 on
its own account (`running = 0; break;` → `return 0`), and that is the path that
runs *after* a pipeline cycle, i.e. exactly when another app may have left the
device on a foreign format.

Merging as-is trades "streams garbage silently" for "exits and stays dead until
someone restarts it by hand."

**Same shape as a bug v0.3.56 already fixed** — clean exit 0, `Restart=on-failure`
reads it as success, systemd never retries. There is a comment about it at
`camera-relay:231`.

### Fix, verified

A sentinel line inside the substitution — fits the existing event protocol and
avoids the subshell a pipe would introduce:

```bash
done < <("$MONITOR_BIN" ... ; echo "__monitor_exit:$?")
# case __monitor_exit:*) rc="${event#__monitor_exit:}" ;;
return "$rc"
```

```
monitor exits 42 → function returns 42    monitor exits 0 → returns 0
```

### Notes

- Test hygiene good — skipped correctly with a live relay holding the loopback.
- **Their "4 passed" figure is unverified here**: reaching it means stopping the
  relay on Andy's daily driver. Only the build assertion was exercised.
- Nit passed on: the check compares pixelformat/width/height but not
  `sizeimage`. Consistent for YUYV since geometry determines it; worth a comment
  so nobody "fixes" it later.

---

## #78 — "webcam-fix-libcamera: actually hide the raw MC-centric camera nodes"

`+973/-62` over 7 files. Introduces a **setgid binary** (`camera-relay-gst.c`,
482 lines), a udev helper (`v4l2-io-mc.c`), a new `camera-relay` group and new
udev rules. Verdict: 🔴 **do not merge.**

The analysis behind it is excellent — tracing the failure to `73-seat-late.rules`
matching the *sticky* tag list that `TAG-=` doesn't touch, demonstrated with
`udevadm test`; reading `v4l_id.c` to establish nothing carries
`V4L2_CAP_IO_MC` into udev; and splitting udev-enumerating apps from libwebrtc's
`open()`-probing walk, which is what forces the permissions approach.

### Blocking — stack buffer overflow in the setgid binary

`camera-relay-gst.c:476`, `gst_argv[n] = NULL;` writes one pointer past
`gst_argv[MAX_ARGS]`.

```
ERROR: AddressSanitizer: stack-buffer-overflow
WRITE of size 8 ... in main camera-relay-gst.c:476
[112, 624) 'gst_argv' (line 339) <== Memory access at offset 624 overflows this variable
```

`append_color_filter` guards at `argc >= MAX_ARGS - 8`, reserving 8 slots. The
tail needs **nine** — `!`, caps, `!`, `v4l2sink`, `device=…`, `io-mode=mmap`,
`sync=false`, plus the `NULL` — and the element branch can push `argc` two past
the guard in one iteration. The `--v4l2-sink` path is one element longer than
`--fd-sink`, so only that path overflows.

Reachable from argv, which for a setgid binary is attacker-controlled. Boundary,
built `-fsanitize=address,undefined`:

```
k=13 clean   k=14 clean   k=15 *** OVERFLOW ***   k=16 rejected by guard
```

Fix verified: `MAX_ARGS - 8` → `MAX_ARGS - 9` → k=14 clean, k=15 rejected, no
overflow at any length.

### Their suite passes and misses it

`tests/test-launcher-validation.sh` is **26/26 green with the overflow present**.
The cases are well chosen but all test *input rejection*, and the suite builds
without sanitizers — so the one property that matters most for a setgid binary
is unexercised. Asked for: build under `-fsanitize=address,undefined`, and a
maximal-length `--color-filter` case on **both** sink paths.

### Non-blocking

- **Stale rules filename.** `camera-relay-gst.c:6` cites
  `90-camera-relay-mc-nodes.rules`; the shipped file is `74-…` (`install.sh:1513`),
  with `90-`/`72-` cleaned up as old names. Normally cosmetic — but the PR says
  "the `74-` prefix is load-bearing", so pointing a maintainer at the wrong
  prefix matters here.
- **`--v4l2-sink` length unbounded.** `valid_ident(v4l2_sink + 10, "")` limits
  characters, not length; `/dev/video` + 100 digits validates then truncates into
  `sink_arg[64]`. `snprintf` keeps it safe, it just fails to open.

### What was *not* verified

- The security design end to end on hardware — the launcher was read and tested
  in isolation only.
- Their own two caveats stand and were repeated back rather than waved through:
  **`install.sh`/`uninstall.sh` were never run end to end** (pieces applied by
  hand), and **Book5/IPU7 is left out** for want of hardware. The installer gap
  matters most: udev rule + new group + setgid binary is exactly where ordering
  bites, and a half-applied state could leave the raw nodes group-owned with no
  launcher able to reach them.

On reading, the two properties the file sets out to hold do hold: it assembles
the pipeline itself rather than exec'ing anything handed to it, replaces the
environment wholesale rather than filtering it, `require_prefix` rejects `..` so
the prefix check isn't defeated by traversal, and the `setresgid` rationale for
avoiding `AT_SECURE` is sound. The narrower prefix list for `--egl-vendor` than
for plugin paths is the right call.
