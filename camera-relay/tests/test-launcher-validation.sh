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

# fd 3 is opened for every run so the --fd-sink liveness check is not what
# rejects these; each case must fail for the reason under test.
reject() {
    local desc="$1"; shift
    local out
    out=$("$TMP/launcher" "$@" 3>/dev/null 2>&1)
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
    out=$("$TMP/launcher" --list-cameras "$opt" /tmp/evil 2>&1)
    if [[ $? -ne 0 && "$out" == *"root-owned"* ]]; then
        ok "--list-cameras $opt /tmp/evil"
    else
        bad "--list-cameras $opt /tmp/evil — not validated"
    fi
done
out=$("$TMP/launcher" --list-cameras --egl-vendor /tmp/evil.json 2>&1)
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
echo "── a trusted plugin path is still accepted ──"
# Validation is the only thing under test here: the exec that follows needs a
# real camera, so anything past argument parsing counts as accepted.
out=$("$TMP/launcher" --camera X --fd-sink 3 --egl-vendor /usr/share/glvnd/egl_vendor.d/50_mesa.json \
        --gst-plugin-path /usr/local/lib --softisp-mode cpu 3>/dev/null 2>&1)
if [[ "$out" == *"must be under a root-owned"* || "$out" == *"not allowed"* ]]; then
    bad "/usr/local/lib was rejected"
else
    ok "/usr/local/lib accepted"
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
