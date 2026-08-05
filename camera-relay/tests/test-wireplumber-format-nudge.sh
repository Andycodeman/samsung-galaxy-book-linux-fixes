#!/usr/bin/env bash
# Regression tests for the WirePlumber format re-probe (nudge_wireplumber).
#
# v4l2loopback is loaded at boot with no producer, so it advertises a generic
# catch-all format set — BGRx/xRGB at any size from 2x1 to 8192x8192, as a
# Choice:Range. The relay's monitor pins YUYV 1920x1080 only when it starts at
# login, and camera-relay.service is ordered After=wireplumber.service, so
# WirePlumber has already probed the unconfigured device and never looks again.
#
# Firefox never notices — it reads /dev/video0 directly. WebRTC's PipeWire camera
# path (Chrome, Brave, Electron) needs a discrete rectangle out of
# SPA_PARAM_EnumFormat; a range yields no resolution, so the camera arrives with
# zero capabilities and Chrome offers no device at all. This runs from
# ExecStartPost to correct that.
#
# Three properties matter, and all three are easy to break silently:
#   1. It must fire when the formats disagree — that is the whole point.
#   2. It must NOT fire when they agree. This runs on every relay start, and an
#      unconditional WirePlumber restart costs an audio glitch every time.
#   3. It must always exit 0. It is an ExecStartPost, so a non-zero exit fails
#      the relay unit and takes the camera down to fix a format mismatch.
#
# Usage: ./test-wireplumber-format-nudge.sh
# Requires no camera hardware and no PipeWire, and touches no system state.

set -uo pipefail

RELAY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/camera-relay"
PASS=0
FAIL=0

ok()  { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

extract_fn() {
    sed -n "/^$1()/,/^}/p" "$RELAY"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "test-wireplumber-format-nudge ($RELAY)"

# ── Harness ───────────────────────────────────────────────────────────────────
# Stubs for the four tools the function shells out to. systemctl records its
# invocation to a file so we can assert on whether a restart was requested,
# without any user service being touched.
new_env() {
    local device_formats="$1" node_id="$2" pw_rect="$3"
    local d="$TMP/env-$RANDOM$RANDOM"
    mkdir -p "$d/bin"

    # Always shadow v4l2-ctl. Merely omitting the stub would let the real one
    # through — PATH is prepended, not replaced — and the test would silently
    # query this machine's actual camera instead of the case under test.
    if [[ -n "$device_formats" ]]; then
        {
            printf '#!/bin/sh\n'
            printf 'printf "%%s\\n" "ioctl: VIDIOC_ENUM_FMT"\n'
            printf 'printf "\\t%%s\\n" "Type: Video Capture"\n'
            printf 'printf "\\t[0]: %%s\\n" "'"'"'%s'"'"' (raw)"\n' "${device_formats%% *}"
            printf 'printf "\\t\\tSize: Discrete %%s\\n" "%s"\n' "${device_formats##* }"
        } > "$d/bin/v4l2-ctl"
    else
        printf '#!/bin/sh\nexit 1\n' > "$d/bin/v4l2-ctl"
    fi
    chmod +x "$d/bin/v4l2-ctl"

    cat > "$d/bin/pw-dump" << EOF
#!/bin/sh
if [ -n "$node_id" ]; then
  printf '%s' '[{"id":$node_id,"info":{"props":{"media.class":"Video/Source","api.v4l2.path":"/dev/video0"}}}]'
else
  printf '%s' '[]'
fi
EOF

    if [[ -n "$pw_rect" ]]; then
        cat > "$d/bin/pw-cli" << EOF
#!/bin/sh
printf '    Prop: key Format:Video:format\n'
printf '      Id 4        (Spa:Enum:VideoFormat:YUY2)\n'
printf '        Rectangle $pw_rect\n'
EOF
    else
        printf '#!/bin/sh\nexit 0\n' > "$d/bin/pw-cli"
    fi

    cat > "$d/bin/systemctl" << EOF
#!/bin/sh
echo "\$@" >> "$d/systemctl.calls"
exit 0
EOF

    chmod +x "$d/bin/pw-dump" "$d/bin/pw-cli" "$d/bin/systemctl"
    printf '%s\n' "$d"
}

# Runs nudge_wireplumber in isolation; echoes "restart"/"no-restart:<rc>".
run_nudge() {
    local env_dir="$1" rc
    (
        set -uo pipefail
        PATH="$env_dir/bin:$PATH"
        eval "$(extract_fn loopback_real_format)"
        eval "$(extract_fn pipewire_node_for)"
        eval "$(extract_fn nudge_wireplumber)"
        info() { :; }
        nudge_wireplumber /dev/video0
    ) > /dev/null 2>&1
    rc=$?
    if grep -q 'restart' "$env_dir/systemctl.calls" 2>/dev/null; then
        echo "restart:$rc"
    else
        echo "no-restart:$rc"
    fi
}

# ── 1. Decision table ─────────────────────────────────────────────────────────
echo
echo "device format vs PipeWire's view → re-probe decision"

nudge_case() {
    local desc="$1" want="$2" dev_fmt="$3" node="$4" rect="$5"
    local env_dir got verdict rc
    env_dir=$(new_env "$dev_fmt" "$node" "$rect")
    got=$(run_nudge "$env_dir")
    verdict=${got%%:*}
    rc=${got##*:}
    if [[ "$verdict" == "$want" && "$rc" == "0" ]]; then
        ok "$(printf '%-38s %s' "$desc" "$want")"
    elif [[ "$rc" != "0" ]]; then
        bad "$(printf '%-38s exited %s — would fail the relay unit' "$desc" "$rc")"
    else
        bad "$(printf '%-38s expected %s, got %s' "$desc" "$want" "$verdict")"
    fi
}

# The bug this exists for: v4l2loopback's unconfigured catch-all range. pw-cli
# renders the low bound of a Choice:Range first, hence 2x1.
nudge_case "stale range (2x1) vs 1920x1080"  restart    "YUYV 1920x1080" 51 "2x1"
# A resolution that was right for a previous relay config but is not any more.
nudge_case "stale resolution 1280x720"       restart    "YUYV 1920x1080" 51 "1280x720"
# The healthy state. Must stay silent — this runs on every single relay start.
nudge_case "matching 1920x1080"              no-restart "YUYV 1920x1080" 51 "1920x1080"
nudge_case "matching 1280x720"               no-restart "YUYV 1280x720"  51 "1280x720"
# No node at all: WirePlumber never saw the device. A restart conjures nothing
# and would just cost an audio glitch on every relay start.
nudge_case "no PipeWire node for the device" no-restart "YUYV 1920x1080" "" "1920x1080"
# Node exists but reports no format we can read — no evidence of a mismatch,
# so no action. Guessing here would mean restarting WirePlumber forever.
nudge_case "node with unreadable formats"    no-restart "YUYV 1920x1080" 51 ""
# Without a working v4l2-ctl there is no ground truth to compare against, even
# though PipeWire is reporting the exact range that normally means "stale".
nudge_case "v4l2-ctl fails"                  no-restart ""               51 "2x1"

# ── 2. Format parsing ─────────────────────────────────────────────────────────
# The parse must not use a pipeline that exits early: piping v4l2-ctl into an
# awk that exits on first match SIGPIPEs the writer, and under `set -o pipefail`
# that surfaces as rc=141. The function then reports nothing, the caller reads
# it as "no format", and the whole check silently disables itself.
echo
echo "format parsing"

parse_case() {
    local desc="$1" want="$2" dev_fmt="$3"
    local env_dir got rc
    env_dir=$(new_env "$dev_fmt" 51 "1920x1080")
    got=$(
        set -uo pipefail
        PATH="$env_dir/bin:$PATH"
        eval "$(extract_fn loopback_real_format)"
        loopback_real_format /dev/video0
    ); rc=$?
    if [[ "$got" == "$want" && $rc -eq 0 ]]; then
        ok "$(printf '%-30s %-22s rc=%s' "$desc" "$want" "$rc")"
    else
        bad "$(printf '%-30s expected %-18s got %-18s rc=%s' "$desc" "$want" "${got:-<empty>}" "$rc")"
    fi
}

parse_case "YUYV 1920x1080" "YUYV 1920x1080" "YUYV 1920x1080"
parse_case "YUYV 1280x720"  "YUYV 1280x720"  "YUYV 1280x720"
parse_case "MJPG 640x480"   "MJPG 640x480"   "MJPG 640x480"

# rc=0 specifically, not just non-empty output: 141 is what a SIGPIPE'd
# pipeline returns and it is invisible in the output alone.
env_dir=$(new_env "YUYV 1920x1080" 51 "1920x1080")
(
    set -uo pipefail
    PATH="$env_dir/bin:$PATH"
    eval "$(extract_fn loopback_real_format)"
    loopback_real_format /dev/video0 > /dev/null
)
rc=$?
if [[ $rc -eq 0 ]]; then
    ok "parse exits 0 (not 141 from a SIGPIPE'd pipeline)"
else
    bad "parse exited $rc — a SIGPIPE here silently disables the whole check"
fi

# ── 3. The restart invocation itself ─────────────────────────────────────────
# --no-block matters: the relay unit is After=wireplumber.service, so blocking
# on a wireplumber job from inside our own ExecStartPost can deadlock.
echo
echo "restart invocation"

env_dir=$(new_env "YUYV 1920x1080" 51 "2x1")
run_nudge "$env_dir" > /dev/null
calls=$(cat "$env_dir/systemctl.calls" 2>/dev/null)
if grep -q -- '--user' <<< "$calls"; then
    ok "restarts the *user* service (no sudo needed)"
else
    bad "not a --user restart: $calls"
fi
if grep -q -- '--no-block' <<< "$calls"; then
    ok "uses --no-block (cannot deadlock against its own unit's ordering)"
else
    bad "missing --no-block: $calls"
fi
if grep -q 'wireplumber' <<< "$calls"; then
    ok "targets wireplumber"
else
    bad "wrong target: $calls"
fi
if [[ $(wc -l <<< "$calls") -eq 1 ]]; then
    ok "restarts exactly once"
else
    bad "restarted $(wc -l <<< "$calls") times"
fi

# ── 4. Waiting for the monitor ───────────────────────────────────────────────
# The unit is Type=simple, so systemd runs ExecStartPost the moment ExecStart
# forks — before the monitor has pinned YUYV on the loopback. A check that reads
# the format once, right then, sees nothing, cannot tell that apart from
# "nothing to do", and returns silently. The stale node then survives the entire
# session, which is exactly the bug this whole file exists to prevent.
echo
echo "waiting for the monitor to pin the format"

# v4l2-ctl reports no discrete format for the first two calls, as during relay
# startup, then starts reporting 1920x1080.
env_dir=$(new_env "YUYV 1920x1080" 51 "2x1")
cat > "$env_dir/bin/v4l2-ctl" << EOF
#!/bin/sh
n=\$(cat "$env_dir/calls" 2>/dev/null || echo 0)
echo \$((n + 1)) > "$env_dir/calls"
printf 'ioctl: VIDIOC_ENUM_FMT\n'
if [ "\$n" -ge 2 ]; then
  printf '\t[0]: '"'"'YUYV'"'"' (raw)\n'
  printf '\t\tSize: Discrete 1920x1080\n'
fi
EOF
chmod +x "$env_dir/bin/v4l2-ctl"

got=$(
    (
        set -uo pipefail
        PATH="$env_dir/bin:$PATH"
        eval "$(extract_fn loopback_real_format)"
        eval "$(extract_fn pipewire_node_for)"
        eval "$(extract_fn nudge_wireplumber)"
        eval "$(extract_fn cmd_nudge_wireplumber)"
        info() { :; }
        is_running() { return 0; }
        detect_loopback_device() { echo /dev/video0; }
        cmd_nudge_wireplumber
        echo "rc=$?"
    ) 2>&1 | tail -1
)

if grep -q 'restart' "$env_dir/systemctl.calls" 2>/dev/null; then
    ok "waits for a late format, then re-probes ($(cat "$env_dir/calls") v4l2-ctl calls)"
else
    bad "gave up before the monitor pinned the format — stale node would survive the session"
fi
if [[ "$got" == "rc=0" ]]; then
    ok "still exits 0 after waiting"
else
    bad "exited non-zero after waiting: $got"
fi

# A device that never reports a format must not hang the unit forever.
env_dir=$(new_env "" 51 "2x1")
start=$SECONDS
(
    set -uo pipefail
    PATH="$env_dir/bin:$PATH"
    eval "$(extract_fn loopback_real_format)"
    eval "$(extract_fn pipewire_node_for)"
    eval "$(extract_fn nudge_wireplumber)"
    eval "$(extract_fn cmd_nudge_wireplumber)"
    info() { :; }
    is_running() { return 0; }
    detect_loopback_device() { echo /dev/video0; }
    cmd_nudge_wireplumber
) > /dev/null 2>&1
elapsed=$((SECONDS - start))
if (( elapsed <= 20 )); then
    ok "gives up after a bounded wait (${elapsed}s), never hangs the unit"
else
    bad "waited ${elapsed}s — an unbounded wait would stall relay startup"
fi
if ! grep -q 'restart' "$env_dir/systemctl.calls" 2>/dev/null; then
    ok "no restart when the format never appears"
else
    bad "restarted WirePlumber without ever reading a device format"
fi

# systemd runs ExecStartPost even when ExecStart has already failed — the unit
# goes through start-post regardless of the main process's fate. So this can be
# waiting on a format for a relay that is not there, and burning the full 15s
# every time turns a RestartSec=5 recovery loop into 20s a cycle. Observed on a
# real machine whose camera-relay-gst was missing.
env_dir=$(new_env "" 51 "2x1")
start=$SECONDS
(
    set -uo pipefail
    PATH="$env_dir/bin:$PATH"
    eval "$(extract_fn loopback_real_format)"
    eval "$(extract_fn pipewire_node_for)"
    eval "$(extract_fn nudge_wireplumber)"
    eval "$(extract_fn cmd_nudge_wireplumber)"
    info() { :; }
    is_running() { return 1; }          # ExecStart died
    detect_loopback_device() { echo /dev/video0; }
    cmd_nudge_wireplumber
) > /dev/null 2>&1
rc=$?
elapsed=$((SECONDS - start))
if (( elapsed < 12 )); then
    ok "dead relay: gives up early (${elapsed}s), not the full wait"
else
    bad "dead relay: still waited ${elapsed}s — slows every restart attempt"
fi
if [[ $rc -eq 0 ]]; then
    ok "dead relay: still exits 0"
else
    bad "dead relay: exited $rc — would compound the failure"
fi
if ! grep -q 'restart' "$env_dir/systemctl.calls" 2>/dev/null; then
    ok "dead relay: no WirePlumber restart"
else
    bad "dead relay: restarted WirePlumber anyway"
fi

# The grace period matters as much as the check: ExecStartPost can beat
# ExecStart to writing the PID file, and bailing on that would disable the
# whole check on every healthy boot.
env_dir=$(new_env "YUYV 1920x1080" 51 "2x1")
(
    set -uo pipefail
    PATH="$env_dir/bin:$PATH"
    eval "$(extract_fn loopback_real_format)"
    eval "$(extract_fn pipewire_node_for)"
    eval "$(extract_fn nudge_wireplumber)"
    eval "$(extract_fn cmd_nudge_wireplumber)"
    info() { :; }
    is_running() { return 1; }          # PID file not written yet...
    detect_loopback_device() { echo /dev/video0; }
    cmd_nudge_wireplumber
) > /dev/null 2>&1
if grep -q 'restart' "$env_dir/systemctl.calls" 2>/dev/null; then
    ok "format already available: acts before the liveness check can bite"
else
    bad "liveness check disabled a re-probe the device was ready for"
fi

# ── 5. Wiring ────────────────────────────────────────────────────────────────
# The function is only reachable if the unit calls it and the dispatcher routes
# it. Either one missing makes every test above pass while the fix does nothing.
echo
echo "wiring"

if grep -q '^ExecStartPost=-\?/usr/local/bin/camera-relay nudge-wireplumber$' "$RELAY"; then
    ok "generated unit has the ExecStartPost"
else
    bad "unit template is missing ExecStartPost — nudge would never run at boot"
fi
# The '-' prefix makes it advisory. Without it, anything that makes this exit
# non-zero — most realistically a unit regenerated against an older
# /usr/local/bin/camera-relay that has no such subcommand — fails the relay unit
# and takes the camera away from every app to fix a browser-only problem.
if grep -q '^ExecStartPost=-/usr/local/bin/camera-relay nudge-wireplumber$' "$RELAY"; then
    ok "ExecStartPost is advisory ('-' prefix) — cannot take the relay down"
else
    bad "ExecStartPost lacks the '-' prefix — a failure here would kill the relay"
fi
if grep -qE '^\s*nudge-wireplumber\)' "$RELAY"; then
    ok "dispatcher routes 'nudge-wireplumber'"
else
    bad "dispatcher has no nudge-wireplumber case — ExecStartPost would fail"
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
