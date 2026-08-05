#!/usr/bin/env bash
# Regression tests for the PipeWire restart guard in webcam-fix-libcamera
# (issue #81).
#
# Both scripts used to end with an unconditional
# `systemctl --user restart pipewire wireplumber`. Every application holding a
# stream loses it, and most do not reconnect — browsers and Spotify go silent
# until restarted. The symptom points nowhere near its cause: you run a *camera*
# script and your speakers stop, so the natural read is "the script broke my
# audio". That is exactly what happened during #80 testing, and it took a
# speaker-test to establish the stack was fine.
#
# The restart is not gratuitous in install.sh — the libcamera SPA plugin is
# loaded by the pipewire daemon itself, so bouncing only wireplumber would not
# pick up a freshly built libcamera and the verification would report a false
# negative. So the fix asks instead of dropping it.
#
# Four things have to hold:
#   1. The restart is reachable only through the guard. A second unguarded call
#      would restore the old behaviour while every test here still passed.
#   2. The prompt cannot kill the script. Both run under `set -e`, and `read`
#      returns 1 at EOF — so a piped or redirected stdin would abort the install
#      partway through, which is far worse than an interrupted stream.
#   3. `--no-restart` exists and is documented in --help.
#   4. The app-name parser reads real `pactl` output, including names with
#      spaces, and stays quiet when nothing is streaming.
#
# Usage: ./test-pipewire-restart-guard.sh
# Requires no audio hardware and touches no system state.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$ROOT/webcam-fix-libcamera/install.sh"
UNINSTALL="$ROOT/webcam-fix-libcamera/uninstall.sh"
PASS=0
FAIL=0

ok()  { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "test-pipewire-restart-guard ($INSTALL, $UNINSTALL)"

# ── 1. No unguarded restart survives ─────────────────────────────────────────
# The point of the issue. Grepping for the call is the only way to catch a
# second one added later somewhere else in a 2000-line script.
echo
echo "every restart goes through the guard"

for f in "$INSTALL" "$UNINSTALL"; do
    name=$(basename "$(dirname "$f")")/$(basename "$f")
    calls=$(grep -c 'systemctl --user restart pipewire wireplumber' "$f" || true)
    if [[ "$calls" == "1" ]]; then
        ok "$name: exactly one restart call site"
    else
        bad "$name: $calls restart call sites — each one needs the guard"
    fi
    # The call must sit inside the `if [[ "$_RESTART" == true ]]` block. Checked
    # by position rather than by parsing: the guard opens before it and no other
    # construct closes in between.
    guard_line=$(grep -n 'if \[\[ "\$_RESTART" == true \]\]' "$f" | head -1 | cut -d: -f1)
    call_line=$(grep -n 'systemctl --user restart pipewire wireplumber' "$f" | head -1 | cut -d: -f1)
    if [[ -n "$guard_line" && -n "$call_line" ]] && (( guard_line < call_line )); then
        ok "$name: restart is inside the guard (line $guard_line → $call_line)"
    else
        bad "$name: restart is not guarded (guard=${guard_line:-none} call=${call_line:-none})"
    fi
done

# ── 2. The prompt cannot abort the script ────────────────────────────────────
# `set -e` plus `read` returning 1 on EOF is a documented trap in this repo: it
# is why install.sh must not be run with stdin at /dev/null. A new prompt that
# repeats it would abort the install *after* it had already written system
# files, which is much worse than the stream it is trying to protect.
echo
echo "prompt survives EOF under set -e"

for f in "$INSTALL" "$UNINSTALL"; do
    name=$(basename "$(dirname "$f")")/$(basename "$f")
    if grep -q 'read -rp "  Restart PipeWire now and interrupt them? \[y/N\] " _ans || _ans=""' "$f"; then
        ok "$name: read has an EOF fallback"
    else
        bad "$name: read without '|| _ans=\"\"' — EOF aborts the script under set -e"
    fi
done

# Prove the pattern rather than trusting the grep: same construct, set -e on,
# stdin closed. Without the fallback this subshell dies before the echo.
result=$(
    set -e
    exec < /dev/null
    read -rp "prompt: " _ans || _ans=""
    case "$_ans" in [yY]) echo "yes" ;; *) echo "defaulted-to-no" ;; esac
) 2>/dev/null
if [[ "$result" == "defaulted-to-no" ]]; then
    ok "EOF defaults to 'no' instead of killing the shell"
else
    bad "EOF handling is wrong: got '${result:-<script died>}'"
fi

# ── 3. Flags ─────────────────────────────────────────────────────────────────
echo
echo "--no-restart"

for f in "$INSTALL" "$UNINSTALL"; do
    name=$(basename "$(dirname "$f")")/$(basename "$f")
    if grep -q -- '--no-restart) NO_RESTART=true ;;' "$f"; then
        ok "$name: --no-restart is parsed"
    else
        bad "$name: --no-restart is not parsed"
    fi
    if out=$(bash "$f" --help 2>&1) && grep -q -- '--no-restart' <<< "$out"; then
        ok "$name: --help documents it"
    else
        bad "$name: --help does not mention --no-restart"
    fi
done

# ── 4. The app-name parser ───────────────────────────────────────────────────
# Names come from real pactl output. A name with spaces is the case a naive
# `awk '{print $3}'` gets wrong, and it is common — "Chromium input" and
# "Firefox" sit side by side in the same list.
echo
echo "reading pactl"

extract_fn() { sed -n "/^pipewire_stream_apps()/,/^}/p" "$1"; }

# The stub mimics real pactl's argument handling exactly, because that is where
# the first version of this guard was broken: `pactl list` takes ONE type, and
# given two it exits 0 having printed nothing. A stub that ignores its arguments
# and always cats the fixture passes a parser that can never see a stream on a
# real machine.
run_parser() {
    local script="$1" sink_out="$2" source_out="${3:-}" bindir="$TMP/bin-$RANDOM$RANDOM"
    mkdir -p "$bindir"
    printf '%s\n' "$sink_out"   > "$bindir/sink.out"
    printf '%s\n' "$source_out" > "$bindir/source.out"
    cat > "$bindir/pactl" << EOF
#!/bin/sh
[ "\$1" = list ] || exit 0
[ \$# -eq 2 ] || exit 0
case "\$2" in
    sink-inputs)    cat "$bindir/sink.out" ;;
    source-outputs) cat "$bindir/source.out" ;;
esac
EOF
    chmod +x "$bindir/pactl"
    (
        set -uo pipefail
        PATH="$bindir:$PATH"
        eval "$(extract_fn "$script")"
        pipewire_stream_apps
    ) 2>/dev/null
}

PACTL_TWO='Sink Input #6390
	Driver: PipeWire
	Properties:
		application.name = "Spotify"
		media.name = "Audio Stream"
Sink Input #6412
	Properties:
		application.name = "Chromium input"'

got=$(run_parser "$INSTALL" "$PACTL_TWO")
if [[ "$got" == $'Chromium input\nSpotify' ]]; then
    ok "parses both names, sorted, spaces intact"
else
    bad "parser output wrong: $(tr '\n' '|' <<< "$got")"
fi

# Recording microphones are source-outputs, not sink-inputs, and losing a
# capture stream mid-call is the worse half of this bug. The first version of
# this guard queried both types in one pactl call, which silently returned
# nothing — so this asserts the second type is really reached.
got=$(run_parser "$INSTALL" '		application.name = "Spotify"' \
                            '		application.name = "Zoom"')
if [[ "$got" == $'Spotify\nZoom' ]]; then
    ok "source-outputs are queried too, not just sink-inputs"
else
    bad "capture streams missed — got: $(tr '\n' '|' <<< "$got")"
fi

got=$(run_parser "$INSTALL" "" '		application.name = "OBS"')
if [[ "$got" == "OBS" ]]; then
    ok "a capture-only stream is still detected"
else
    bad "capture-only stream missed: $(tr '\n' '|' <<< "$got")"
fi

got=$(run_parser "$INSTALL" "")
if [[ -z "$got" ]]; then
    ok "no streams → empty, so the guard stays silent"
else
    bad "reported streams from empty pactl output: $got"
fi

# Duplicates are normal — one app can hold several streams — and listing
# "Spotify" three times in a warning is noise.
PACTL_DUP='		application.name = "Spotify"
		application.name = "Spotify"'
got=$(run_parser "$INSTALL" "$PACTL_DUP")
if [[ "$got" == "Spotify" ]]; then
    ok "duplicate streams from one app collapse to one line"
else
    bad "duplicates not collapsed: $(tr '\n' '|' <<< "$got")"
fi

# No pactl at all: must report nothing rather than erroring, so the guard falls
# through to restarting exactly as it did before this change.
nopactl="$TMP/nopactl"; mkdir -p "$nopactl"
# Extracted before PATH is emptied — extract_fn itself needs sed, and losing it
# would fail the test for the wrong reason.
fn_text=$(extract_fn "$INSTALL")
got=$(
    set -uo pipefail
    eval "$fn_text"
    PATH="$nopactl"
    pipewire_stream_apps
    echo "rc=$?"
) 2>/dev/null
if [[ "$got" == "rc=1" ]]; then
    ok "no pactl → returns 1 with no output (guard falls through to restart)"
else
    bad "unexpected behaviour without pactl: $got"
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
