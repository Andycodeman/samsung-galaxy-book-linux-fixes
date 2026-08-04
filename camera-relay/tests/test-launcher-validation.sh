#!/usr/bin/env bash
# The raw IPU6/IPU7 ISYS nodes belong to a memberless 'camera-relay' group so
# that ordinary applications cannot open them; camera-relay-gst is setgid to
# that group so the one process that legitimately drives the camera still can.
#
# That makes the launcher's input validation load-bearing. If a caller can talk
# it into running an element of their choosing, or into loading a plugin from a
# directory they control, they get the group back and the nodes are exposed
# again. These tests pin that behaviour down.
#
# Usage: ./test-launcher-validation.sh
# Requires no camera hardware and touches no system state (builds into a
# temporary directory; the binary under test is never setgid here).

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/camera-relay-gst.c"
PASS=0
FAIL=0

ok()   { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "test-launcher-validation ($SRC)"

if [[ ! -f "$SRC" ]]; then
    echo "  ✗ camera-relay-gst.c not found"
    exit 1
fi
if ! command -v gcc >/dev/null 2>&1; then
    echo "  – skipped: gcc not available"
    exit 0
fi
if ! gcc -O2 -Wall -Werror -o "$TMP/launcher" "$SRC" 2>"$TMP/build.log"; then
    echo "  ✗ build failed:"
    sed 's/^/      /' "$TMP/build.log"
    exit 1
fi
ok "builds clean with -Wall -Werror"

# For a setgid binary, memory safety is the property that matters most, and
# input-rejection tests do not exercise it — an off-by-one in the argv guard
# survived a green suite until it was found under ASan. Everything below runs
# against the sanitized build when the toolchain has it.
SAN="$TMP/launcher"
if gcc -g -O1 -fsanitize=address,undefined -o "$TMP/launcher-san" "$SRC" 2>/dev/null; then
    SAN="$TMP/launcher-san"
    # The launcher leaks its escaped camera name on purpose: it is about to
    # execve. That is not the kind of finding this suite is looking for.
    export ASAN_OPTIONS=detect_leaks=0
    ok "builds clean with -fsanitize=address,undefined"
else
    echo "  – note: no sanitizer support in this toolchain, running unsanitized"
fi

# fd 3 is opened for every run so the --fd-sink liveness check is not what
# rejects these; each case must fail for the reason under test.
reject() {
    local desc="$1"; shift
    local out
    out=$("$SAN" "$@" 3>/dev/null 2>&1)
    if [[ $? -eq 0 ]]; then
        bad "$desc — accepted"
    elif [[ "$out" == *"is not open"* ]]; then
        bad "$desc — rejected by the fd check, not the rule under test"
    else
        ok "$desc"
    fi
}

echo
echo "── camera name cannot carry pipeline syntax ──"
reject "'!' in the camera name"        --camera 'X ! filesink location=/tmp/pwn' --fd-sink 3
reject "whitespace in the camera name" --camera 'X filesink'                     --fd-sink 3
reject "quotes in the camera name"     --camera 'a"b'                            --fd-sink 3

echo
echo "── color filter admits only allow-listed video filters ──"
reject "a sink element"        --camera X --fd-sink 3 --color-filter 'filesink location=/tmp/pwn'
reject "a source element"      --camera X --fd-sink 3 --color-filter 'souphttpsrc location=http://x'
reject "a sink after a filter" --camera X --fd-sink 3 \
    --color-filter 'videobalance saturation=0.85 ! filesink location=/tmp/pwn'
reject "a path in a property"  --camera X --fd-sink 3 --color-filter 'videobalance x=/etc/shadow'
reject "a dangling separator"  --camera X --fd-sink 3 --color-filter 'videobalance !'

echo
echo "── code-loading paths must be root-owned ──"
reject "plugin path in \$HOME" --camera X --fd-sink 3 --gst-plugin-path "$HOME/evil"
reject "plugin path in /tmp"   --camera X --fd-sink 3 --gst-plugin-path /tmp/evil
reject "traversal out of a trusted prefix" --camera X --fd-sink 3 \
    --gst-plugin-path '/usr/local/lib/../../tmp/evil'
reject "IPA path in /tmp"      --camera X --fd-sink 3 --ipa-path /tmp/evil

echo
echo "── EGL vendor pin picks the debayer's driver, so it is validated too ──"
reject "ICD in \$HOME"        --camera X --fd-sink 3 --egl-vendor "$HOME/evil.json"
reject "ICD in /tmp"          --camera X --fd-sink 3 --egl-vendor /tmp/evil.json
reject "traversal"            --camera X --fd-sink 3 \
    --egl-vendor '/usr/share/glvnd/egl_vendor.d/../../../tmp/evil.json'
reject "poisoned entry in a list" --camera X --fd-sink 3 \
    --egl-vendor '/usr/share/glvnd/egl_vendor.d/50_mesa.json:/tmp/evil.json'
reject "empty value"          --camera X --fd-sink 3 --egl-vendor ''

echo
echo "── path options are validated on the --list-cameras path too ──"
# This branch also exports them into the child environment; skipping validation
# there would hand the group away just as effectively.
for opt in --ipa-path --gst-plugin-path; do
    out=$("$SAN" --list-cameras "$opt" /tmp/evil 2>&1)
    if [[ $? -ne 0 && "$out" == *"root-owned"* ]]; then
        ok "--list-cameras $opt /tmp/evil"
    else
        bad "--list-cameras $opt /tmp/evil — not validated"
    fi
done
out=$("$SAN" --list-cameras --egl-vendor /tmp/evil.json 2>&1)
if [[ $? -ne 0 && "$out" == *"root-owned"* ]]; then
    ok "--list-cameras --egl-vendor /tmp/evil.json"
else
    bad "--list-cameras --egl-vendor /tmp/evil.json — not validated"
fi

echo
echo "── sinks ──"
reject "no sink"                 --camera X
reject "both sinks"              --camera X --fd-sink 3 --v4l2-sink /dev/video0
reject "sink outside /dev/video" --camera X --v4l2-sink /dev/../etc/passwd
reject "--list-cameras mixed with a pipeline" --camera X --fd-sink 3 --list-cameras

echo
echo "── argv buffer holds at the guard boundary ──"
# The color filter is the only caller-controlled input that grows the argv
# array, so its guard is what stands between argv and a stack overflow. Sweep
# across the boundary on BOTH sink paths: --v4l2-sink emits one more element
# than --fd-sink, and testing only the shorter one is what let an off-by-one
# through. Every length must land in exactly one of two states — accepted, or
# refused by the guard. A sanitizer report is neither.
sweep_ok=1
for sink in "--v4l2-sink /dev/video9" "--fd-sink 3"; do
    for k in $(seq 1 24); do
        filter="videoconvert"
        for ((i = 1; i < k; i++)); do filter="$filter ! videoconvert"; done
        out=$("$SAN" --camera testcam $sink --color-filter "$filter" 3>/dev/null 2>&1)
        if [[ "$out" == *"sanitizer"* || "$out" == *"runtime error"* \
              || "$out" == *"stack-buffer-overflow"* ]]; then
            bad "${sink%% *} with $k filters — sanitizer report"
            echo "$out" | grep -m1 -E "ERROR|runtime error" | sed 's/^/        /'
            sweep_ok=0
            break 2
        fi
    done
done
(( sweep_ok )) && ok "1..24 chained filters on both sink paths, no sanitizer findings"

reject "an over-long device number" --camera X --v4l2-sink "/dev/video$(printf '9%.0s' {1..100})"

echo
echo "── a trusted plugin path is still accepted ──"
# Validation is the only thing under test here: the exec that follows needs a
# real camera, so anything past argument parsing counts as accepted.
out=$("$SAN" --camera X --fd-sink 3 --egl-vendor /usr/share/glvnd/egl_vendor.d/50_mesa.json \
        --gst-plugin-path /usr/local/lib --softisp-mode cpu 3>/dev/null 2>&1)
if [[ "$out" == *"must be under a root-owned"* || "$out" == *"not allowed"* ]]; then
    bad "/usr/local/lib was rejected"
else
    ok "/usr/local/lib accepted"
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
