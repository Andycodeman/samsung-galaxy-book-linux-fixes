#!/usr/bin/env bash
# Regression tests for firefox_pipewire_pref_state (camera-relay doctor).
#
# Background: issue #37. The repo told people that if the xdg-desktop-portal
# permission store had a stale Firefox denial they could simply set
# media.webrtc.camera.allow-pipewire back to false, because Firefox reads the
# v4l2loopback relay node directly and needs no pref. On Fedora 44 the reporter
# measured the opposite — with the pref false NO camera works
# ("NotReadableError: Starting videoinput failed"), with it true both the relay
# and the libcamera source work. So the pref is not a don't-care, and `doctor`
# now reports it the way it already reports the Chromium flag.
#
# Three properties matter here:
#   1. An absent pref must NOT be reported as "false". prefs.js only records
#      prefs that differ from the build's default, and distributions have
#      patched that default both ways — claiming DISABLED would send someone
#      chasing a setting that is actually enabled.
#   2. The LAST assignment wins. Firefox rewrites prefs.js wholesale on exit and
#      a hand-edited file can carry duplicates; reading the first one reports a
#      value the browser is not using.
#   3. Near-miss lines must not match — a commented-out entry, or a longer pref
#      name that merely starts with the same string.
#
# Usage: ./test-firefox-pipewire-pref.sh
# Requires no camera hardware, no Firefox and no PipeWire; touches no state.

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

echo "test-firefox-pipewire-pref ($RELAY)"

fn=$(extract_fn firefox_pipewire_pref_state)
if [[ -z "$fn" ]]; then
    bad "firefox_pipewire_pref_state not found in $RELAY"
    echo "FAIL"
    exit 1
fi
eval "$fn"

# ── Harness ───────────────────────────────────────────────────────────────────
# $1 label, $2 expected output, rest: the lines of a prefs.js.
check() {
    local label="$1" want="$2"; shift 2
    local prefs="$TMP/prefs-$((PASS + FAIL)).js" got
    printf '%s\n' "$@" > "$prefs"
    got=$(firefox_pipewire_pref_state "$prefs")
    if [[ "$got" == "$want" ]]; then
        ok "$label → $got"
    else
        bad "$label → got '$got', want '$want'"
    fi
}

PREF='user_pref("media.webrtc.camera.allow-pipewire"'

# ── 1. The three states ───────────────────────────────────────────────────────
check "pref true"  "ENABLED"  "$PREF, true);"
check "pref false" "DISABLED" "$PREF, false);"
check "pref absent" "not set (build default)" \
    'user_pref("media.navigator.video.default_width", 1920);'

# A real prefs.js is hundreds of unrelated lines with the interesting one buried.
check "pref among other prefs" "ENABLED" \
    '# Mozilla User Preferences' \
    'user_pref("browser.startup.homepage", "about:blank");' \
    "$PREF, true);" \
    'user_pref("media.navigator.video.default_height", 1080);'

# ── 2. Absent must not read as false ──────────────────────────────────────────
# The distinction the whole check exists for: "not set" means we do not know,
# because the build default is not knowable from this file.
got=$(firefox_pipewire_pref_state <(printf '%s\n' 'user_pref("x", 1);'))
if [[ "$got" == "DISABLED" ]]; then
    bad "an absent pref was reported as DISABLED"
else
    ok "an absent pref is not reported as DISABLED (got '$got')"
fi

# ── 3. Last assignment wins ───────────────────────────────────────────────────
check "duplicate, last wins (false→true)" "ENABLED"  "$PREF, false);" "$PREF, true);"
check "duplicate, last wins (true→false)" "DISABLED" "$PREF, true);"  "$PREF, false);"

# ── 4. Near misses must not match ─────────────────────────────────────────────
check "commented out"  "not set (build default)" "// $PREF, true);"
check "longer pref name" "not set (build default)" \
    'user_pref("media.webrtc.camera.allow-pipewire.legacy", true);'
check "non-boolean value" "not set (build default)" "$PREF, \"true\");"

# Leading whitespace is legal in prefs.js and must still match.
check "leading whitespace" "ENABLED" "    $PREF,true);"

# ── 5. Unreadable input fails, it does not report a value ─────────────────────
# doctor skips the profile on a non-zero return. Printing "not set" for a file
# that could not be read would claim a measurement that never happened.
if firefox_pipewire_pref_state "$TMP/does-not-exist.js" >/dev/null 2>&1; then
    bad "a missing prefs.js returned success"
else
    ok "a missing prefs.js returns non-zero"
fi

unreadable="$TMP/unreadable.js"
printf '%s\n' "$PREF, true);" > "$unreadable"
chmod 000 "$unreadable"
if [[ $EUID -eq 0 ]]; then
    ok "skipped unreadable-file case (running as root, mode 000 is not enforced)"
elif firefox_pipewire_pref_state "$unreadable" >/dev/null 2>&1; then
    bad "an unreadable prefs.js returned success"
else
    ok "an unreadable prefs.js returns non-zero"
fi
chmod 644 "$unreadable"

# ── 6. doctor actually calls it ───────────────────────────────────────────────
# A helper nothing invokes is a helper that silently stops being reached.
if grep -q 'firefox_pipewire_pref_state "\$ff_prefs"' "$RELAY"; then
    ok "cmd_doctor calls firefox_pipewire_pref_state"
else
    bad "nothing in $RELAY calls firefox_pipewire_pref_state"
fi

# And it must sit outside the Chromium-only block: a Firefox-only machine is
# exactly the case that got no browser diagnostic before.
# Buffered, not piped into `grep -q`: grep closes the pipe on its first match,
# sed dies of SIGPIPE with rc 141, and `set -o pipefail` turns that into a
# failing test against code that is perfectly fine. Same trap as
# loopback_real_format in camera-relay, which carries the same note.
browsers_section=$(sed -n '/── Browsers ──/,/if \$chromium_family; then/p' "$RELAY")
if grep -q 'firefox_pipewire_pref_state' <<< "$browsers_section"; then
    ok "the Firefox report is not gated behind chromium_family"
else
    bad "the Firefox report sits inside the Chromium-only block"
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
