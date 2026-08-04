#!/usr/bin/env bash
# Regression tests for issue #65 — camera-relay reported
#   "GStreamer 'libcamerasrc' element not found. Install it: ... gstreamer1.0-libcamera"
# on a system where that package was already installed and libcamerasrc worked
# fine under gst-launch-1.0. The real cause is that gst-inspect-1.0 (and
# gst-launch-1.0, which IS the relay pipeline) live in a separate package that
# nothing pulls in, so the probe exited 127 and got misreported.
#
# Usage: ./test-gst-tools-check.sh
# Requires no camera hardware and touches no system state.

set -uo pipefail

RELAY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/camera-relay"
PASS=0
FAIL=0

ok()   { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  – skipped: $*"; }

# Pull a single function out of the relay script so we can exercise it directly
# without running the whole command dispatcher.
extract_fn() {
    sed -n "/^$1()/,/^}/p" "$RELAY"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "test-gst-tools-check ($RELAY)"

# ── 1. Missing gst tools must be reported as missing gst tools ────────────────
# An empty PATH guarantees gst-inspect-1.0/gst-launch-1.0 are unreachable.
# XDG_RUNTIME_DIR points at an empty dir so is_running() finds no PID file and
# start proceeds straight into setup_environment.
mkdir -p "$TMP/emptybin" "$TMP/run"
out=$(PATH="$TMP/emptybin" XDG_RUNTIME_DIR="$TMP/run" "$BASH" "$RELAY" start 2>&1)
rc=$?

if [[ $rc -ne 0 ]]; then
    ok "start fails when the GStreamer tools are absent (exit $rc)"
else
    bad "start returned 0 with no gst-launch-1.0 available"
fi

if grep -q "gstreamer1.0-tools" <<<"$out"; then
    ok "error names the package that actually provides the tools"
else
    bad "error does not mention gstreamer1.0-tools; got:
$out"
fi

# The exact issue #65 dead end: telling the user to install the libcamera
# GStreamer plugin when that is not what is missing.
if grep -q "gstreamer1.0-libcamera" <<<"$out"; then
    bad "error still points at gstreamer1.0-libcamera (the issue #65 dead end)"
else
    ok "error no longer blames the libcamera plugin package"
fi

# ── 2. Locating an installed libcamera GStreamer plugin ──────────────────────
eval "$(extract_fn find_libcamera_gst_plugin)"
if plugin_so=$(find_libcamera_gst_plugin); then
    if [[ -f "$plugin_so" ]]; then
        ok "find_libcamera_gst_plugin located $plugin_so"
    else
        bad "find_libcamera_gst_plugin returned a non-file: $plugin_so"
    fi
else
    skip "no libgstlibcamera.so installed on this host"
fi

# ── 3. plugin present but unloadable is diagnosed, not called "missing" ───────
# Stub tools: gst-launch-1.0 exists (so require_gst_tools passes) and
# gst-inspect-1.0 always fails, simulating a plugin GStreamer refuses to load.
# XDG_CACHE_HOME is redirected because the recovery ladder clears the registry
# cache — the test must not blow away the real one.
if find_libcamera_gst_plugin >/dev/null; then
    mkdir -p "$TMP/fakebin" "$TMP/cache" "$TMP/run3"
    printf '#!/bin/sh\necho "no such element or plugin '\''libcamerasrc'\''" >&2\nexit 1\n' \
        > "$TMP/fakebin/gst-inspect-1.0"
    printf '#!/bin/sh\nexit 0\n' > "$TMP/fakebin/gst-launch-1.0"
    chmod +x "$TMP/fakebin"/*

    out=$(PATH="$TMP/fakebin:$PATH" XDG_CACHE_HOME="$TMP/cache" XDG_RUNTIME_DIR="$TMP/run3" \
          "$BASH" "$RELAY" start 2>&1)

    if grep -q "the plugin IS installed" <<<"$out"; then
        ok "unloadable plugin is reported as unloadable, not as missing"
    else
        bad "unloadable plugin still reported as a missing package; got:
$out"
    fi
    # The old message threw GStreamer's own error away; that is what left
    # issue #65 with nothing to go on.
    if grep -q "no such element or plugin" <<<"$out"; then
        ok "gst-inspect-1.0's actual stderr is surfaced to the user"
    else
        bad "gst-inspect-1.0's stderr was swallowed; got:
$out"
    fi
else
    skip "no libgstlibcamera.so installed; cannot test the unloadable-plugin path"
fi

# ── 4. status must not claim the loopback is absent when it is present ────────
eval "$(extract_fn detect_loopback_device)"
if dev=$(detect_loopback_device 2>/dev/null); then
    line=$(XDG_RUNTIME_DIR="$TMP/run" "$BASH" "$RELAY" status 2>/dev/null | grep 'Loopback:')
    if grep -q "$dev" <<<"$line"; then
        ok "status reports the live loopback device ($dev)"
    else
        bad "status hides the loopback device present at $dev; got: $line"
    fi
else
    skip "no v4l2loopback device present on this host"
fi

# ── 5. a failed pipeline must show GStreamer's actual output ─────────────────
# cmd_start tailed "camera-relay.log" (the on-demand daemon's log) while
# start_pipeline writes "camera-relay-gst.log", so "ERROR: Relay failed to
# start. GStreamer output:" was followed by nothing — the reporter in issue #65
# had no way to see why. Force a failure by seeding the camera-name cache with
# a camera that does not exist; libcamerasrc then errors out on its own.
mkdir -p "$TMP/run5"
echo "no-such-camera-xyz" > "$TMP/run5/camera-relay-camera-name"
if command -v gst-launch-1.0 &>/dev/null; then
    out=$(XDG_RUNTIME_DIR="$TMP/run5" "$BASH" "$RELAY" start 2>&1)
    if grep -q "Relay failed to start" <<<"$out"; then
        ok "start reports failure for a camera that does not exist"
        # Anything GStreamer printed proves the right log was read. The banner
        # must not be followed immediately by the closing rule.
        if grep -Pzoq 'GStreamer output:\n[─]+\n[─]+\n' <<<"$out"; then
            bad "GStreamer output section is empty — wrong log file; got:
$out"
        else
            ok "GStreamer's own output is included in the failure report"
        fi
    else
        skip "pipeline did not fail as expected (camera busy?); got: $(head -3 <<<"$out")"
    fi
else
    skip "gst-launch-1.0 not installed"
fi

# ── 6. doctor tells "nothing is feeding the device" apart from "real picture" ──
# This is the distinction issue #65 spent six round trips failing to make: a
# working `gst-launch ... autovideosink` says nothing about the loopback.
if command -v v4l2-ctl &>/dev/null && dev=$(detect_loopback_device 2>/dev/null); then
    mkdir -p "$TMP/run6"
    # Uniform black frames: the device is open and readable, but there is no
    # picture — doctor must not call this success.
    if command -v gst-launch-1.0 &>/dev/null; then
        gst-launch-1.0 videotestsrc pattern=black is-live=true \
            ! video/x-raw,format=YUY2,width=1920,height=1080 \
            ! v4l2sink device="$dev" io-mode=mmap sync=false &>/dev/null &
        black_pid=$!
        sleep 2
        # v4l2loopback takes a single writer. If a real relay already holds the
        # device, our synthetic stream never attached and gst-launch has already
        # exited — doctor is then correctly reporting the live picture, which is
        # not a doctor bug. Assert only once we know we own the writer.
        if kill -0 "$black_pid" 2>/dev/null; then
            out=$(XDG_RUNTIME_DIR="$TMP/run6" "$BASH" "$RELAY" doctor 2>&1)
            if grep -q "BLANK FRAMES" <<<"$out"; then
                ok "doctor calls a uniform stream blank rather than working"
            else
                bad "doctor did not flag black frames; got: $(grep -A2 'Frames on' <<<"$out")"
            fi
        else
            skip "could not synthesise a black stream (a real relay holds the loopback, or the pipeline failed)"
        fi
        kill "$black_pid" 2>/dev/null || true
        wait "$black_pid" 2>/dev/null || true
    else
        skip "gst-launch-1.0 not installed; cannot synthesise a black stream"
    fi

    # doctor must never abort part-way through — it is a bug-report tool, so a
    # failing probe has to degrade to a printed line, not a dead script.
    out=$(XDG_RUNTIME_DIR="$TMP/run6" "$BASH" "$RELAY" doctor 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]] && grep -q "Recent logs" <<<"$out"; then
        ok "doctor runs to completion and exits 0"
    else
        bad "doctor exited $rc or stopped early; tail was: $(tail -3 <<<"$out")"
    fi
else
    skip "v4l2-ctl or loopback device unavailable; cannot test doctor frame check"
fi

# ── 7. a live PID that is not relaying must not count as "already running" ────
# Issue #65's end state: gst-launch-1.0 stayed alive after letting go of the
# loopback, so is_running() said yes. status printed STREAMING, and the
# on-demand service exited 0 with "Already running" — which Restart=on-failure
# reads as success, so systemd never retried. Only a reboot (wiping
# XDG_RUNTIME_DIR) cleared it. A plain `sleep` reproduces the state exactly:
# a live PID that holds nothing.
if [[ -e /proc/modules ]] && ! grep -q '^v4l2loopback .* [1-9]' /proc/modules; then
    mkdir -p "$TMP/run7"
    sleep 60 &
    fake_pid=$!
    echo "$fake_pid" > "$TMP/run7/camera-relay.pid"
    echo "streaming" > "$TMP/run7/camera-relay-state"

    out=$(timeout 20 env XDG_RUNTIME_DIR="$TMP/run7" \
          "$BASH" "$RELAY" start --on-demand 2>&1 | head -8) || true
    kill "$fake_pid" 2>/dev/null || true
    wait "$fake_pid" 2>/dev/null || true

    if grep -q "Already running" <<<"$out"; then
        bad "a live non-relaying PID is still treated as a working relay; got:
$out"
    else
        ok "a live PID that holds no loopback is not treated as a working relay"
    fi
    if grep -q "Clearing stale relay state" <<<"$out"; then
        ok "stale relay state is cleared instead of silently no-opping"
    else
        bad "stale state was not cleared; got:
$out"
    fi
else
    skip "a real relay currently holds the loopback; cannot test the stale-PID path"
fi

echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
