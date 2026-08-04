#!/usr/bin/env bash
# The monitor writes fixed-size YUYV frames straight into the loopback. If the
# device is on any other format or geometry those writes are garbage to every
# reader — and nothing says so: the device stays open, the relay still reports
# "streaming", and the only trace used to be a warning in a log the next restart
# truncates.
#
# That is reachable in practice. The loopback advertises only the writer's
# format while a writer holds it; with no writer it offers every format it can
# carry (58 of them here) and a reader picks whichever it likes.
#
# These tests check that open_writer() refuses to run in that state instead of
# streaming into the void.
#
# Usage: ./test-writer-format-check.sh
# Needs a v4l2loopback device to talk to; skips cleanly without one, and never
# touches a loopback that a running relay is already driving.

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/camera-relay-monitor.c"
PASS=0
FAIL=0

ok()   { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  – skipped: $*"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "test-writer-format-check ($SRC)"

if ! command -v gcc >/dev/null 2>&1; then
    skip "gcc not available"
    exit 0
fi
if ! gcc -O2 -Wall -Wextra -o "$TMP/monitor" "$SRC" 2>"$TMP/build.log"; then
    echo "  ✗ build failed:"
    sed 's/^/      /' "$TMP/build.log"
    exit 1
fi
ok "builds clean with -Wall -Wextra"

# Find a loopback nobody is driving. A relay holding one would be disrupted by
# opening it as a second writer, and its format would not be ours to change.
LOOPBACK=""
for dev in /sys/devices/virtual/video4linux/video*; do
    [[ -e "$dev/name" ]] || continue
    node="/dev/$(basename "$dev")"
    if pgrep -f "camera-relay-monitor $node" >/dev/null 2>&1; then
        continue
    fi
    LOOPBACK="$node"
    break
done

if [[ -z "$LOOPBACK" ]]; then
    skip "no idle v4l2loopback device to test against"
    echo
    echo "  $PASS passed, $FAIL failed"
    [[ $FAIL -eq 0 ]]
    exit
fi

echo "  using $LOOPBACK"

# A width past the device's max makes the driver report back something other
# than what it was asked for — the same shape of mismatch a foreign format
# produces, without needing to wrestle a second client onto the device.
MAXW=$(cat /sys/module/v4l2loopback/parameters/max_width 2>/dev/null || echo 8192)
out=$(timeout 10 "$TMP/monitor" "$LOOPBACK" $((MAXW + 1000)) 1080 -- /bin/true 2>&1)
rc=$?

if [[ $rc -eq 0 ]]; then
    bad "accepted a geometry the device cannot provide"
elif [[ "$out" != *"stayed on"* ]]; then
    bad "refused, but without saying what the device is actually on: $out"
else
    ok "refuses when the device reports back a different format"
    grep -q "garbage to every" <<<"$out" \
        && ok "explains why it stops rather than streaming" \
        || bad "message does not explain the consequence"
fi

# And the normal case still works, so the check is not simply always-on.
out=$(timeout 6 "$TMP/monitor" "$LOOPBACK" 1920 1080 -- /bin/true 2>&1)
if grep -q "Watching $LOOPBACK" <<<"$out"; then
    ok "still starts normally on a format the device accepts"
else
    bad "rejected a valid 1920x1080 YUYV setup: $out"
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
