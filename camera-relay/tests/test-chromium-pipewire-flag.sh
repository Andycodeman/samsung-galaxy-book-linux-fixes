#!/usr/bin/env bash
# Regression tests for chromium-pipewire-camera.sh.
#
# Chromium filters the relay node out of V4L2 enumeration entirely — it accepts
# a node only when it reports VIDEO_CAPTURE and *not* VIDEO_OUTPUT, and the relay
# under exclusive_caps=0 reports both. The flag this script writes is what routes
# those browsers through PipeWire instead, so it is the only thing standing
# between Chrome and no camera at all.
#
# It edits a live browser profile, which makes three failure modes expensive:
#   1. Clobbering Local State would take the user's whole browser config with it
#      — every other key in that file has to survive untouched.
#   2. Writing while the browser runs looks like it worked and is discarded on
#      quit, so the guard has to hold even against a stale lock from a crash.
#   3. Enabling it on libcamera 0.2.0 (Ubuntu 24.04 / Zorin) sends Chromium down
#      a path with no IPU6 support, which is worse than leaving it alone.
#
# Every case runs the real script against a fake HOME with stubbed getent and
# pkg-config.
#
# Usage: ./test-chromium-pipewire-flag.sh
# Requires no camera hardware and no browser, and touches no system state.

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/chromium-pipewire-camera.sh"
FLAG_ENTRY="enable-webrtc-pipewire-camera@1"
BACKUP_NAME="Local State.camera-relay.bak"
PASS=0
FAIL=0

ok()   { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  – skipped: $*"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "test-chromium-pipewire-flag ($SCRIPT)"

if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available"
    echo
    echo "  $PASS passed, $FAIL failed"
    exit 0
fi

# ── Harness ───────────────────────────────────────────────────────────────────
# A fake home with stubbed getent/pkg-config on PATH. The script resolves the
# profile directory through getent and the libcamera version through pkg-config,
# so those two stubs are the whole isolation boundary.
new_env() {
    # ${1-} not ${1:-}: an explicitly empty version means "pkg-config is broken",
    # which is a case under test, not a request for the default.
    local libcamera_version="${1-0.7.2}"
    local env_dir="$TMP/env-$RANDOM$RANDOM"
    mkdir -p "$env_dir/home" "$env_dir/bin"

    cat > "$env_dir/bin/getent" << EOF
#!/bin/sh
[ "\$1" = passwd ] || exit 2
echo "\$2:x:1000:1000::$env_dir/home:/bin/bash"
EOF

    if [[ -n "$libcamera_version" ]]; then
        cat > "$env_dir/bin/pkg-config" << EOF
#!/bin/sh
[ "\$1" = --modversion ] && [ "\$2" = libcamera ] || exit 1
echo "$libcamera_version"
EOF
    else
        # No pkg-config at all — the version is undeterminable.
        printf '#!/bin/sh\nexit 127\n' > "$env_dir/bin/pkg-config"
    fi

    # `flatpak ps` is the only trustworthy "is it running?" for a sandboxed
    # browser — its SingletonLock holds a sandbox PID that means nothing on the
    # host. Reports whatever the test wrote to flatpak.running.
    cat > "$env_dir/bin/flatpak" << EOF
#!/bin/sh
[ "\$1" = ps ] || exit 0
cat "$env_dir/flatpak.running" 2>/dev/null
exit 0
EOF

    chmod +x "$env_dir/bin/getent" "$env_dir/bin/pkg-config" "$env_dir/bin/flatpak"
    printf '%s\n' "$env_dir"
}

# Writes a profile's Local State and returns its directory.
make_profile() {
    local env_dir="$1" rel="$2" json="$3"
    local dir="$env_dir/home/$rel"
    mkdir -p "$dir"
    printf '%s' "$json" > "$dir/Local State"
    printf '%s\n' "$dir"
}

run_script() {
    local env_dir="$1"; shift
    PATH="$env_dir/bin:$PATH" "$SCRIPT" "$@" 2>&1
}

# Reads back enabled_labs_experiments as a JSON array, or a marker.
labs_of() {
    python3 - "$1/Local State" << 'EOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as exc:
    print("UNPARSEABLE(%s)" % type(exc).__name__)
    sys.exit(0)
browser = data.get("browser")
labs = browser.get("enabled_labs_experiments") if isinstance(browser, dict) else None
if labs is None:
    print("MISSING")
else:
    print(json.dumps(labs, separators=(",", ":")))
EOF
}

# Everything except our one key, so we can assert the rest of the file survived.
rest_of() {
    python3 - "$1/Local State" << 'EOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
browser = data.get("browser")
if isinstance(browser, dict):
    browser.pop("enabled_labs_experiments", None)
    if not browser:
        data.pop("browser", None)
print(json.dumps(data, sort_keys=True))
EOF
}

# ── 1. What lands in enabled_labs_experiments ────────────────────────────────
# The array is shared with every other flag the user has set by hand, so this is
# a merge, not an overwrite.
echo
echo "enable → resulting flag list"

enable_case() {
    local desc="$1" want="$2" json="$3"
    local env_dir dir got
    env_dir=$(new_env)
    dir=$(make_profile "$env_dir" ".config/google-chrome" "$json")
    run_script "$env_dir" enable > /dev/null
    got=$(labs_of "$dir")
    if [[ "$got" == "$want" ]]; then
        ok "$(printf '%-34s %s' "$desc" "$want")"
    else
        bad "$(printf '%-34s expected %s, got %s' "$desc" "$want" "$got")"
    fi
}

enable_case "no browser key"        "[\"$FLAG_ENTRY\"]" '{"foo":1}'
enable_case "browser without labs"  "[\"$FLAG_ENTRY\"]" '{"browser":{"x":2}}'
enable_case "empty labs array"      "[\"$FLAG_ENTRY\"]" '{"browser":{"enabled_labs_experiments":[]}}'
enable_case "already enabled"       "[\"$FLAG_ENTRY\"]" "{\"browser\":{\"enabled_labs_experiments\":[\"$FLAG_ENTRY\"]}}"
# Bare (no @suffix) also means enabled; normalising to @1 keeps one spelling.
enable_case "bare, no @suffix"      "[\"$FLAG_ENTRY\"]" '{"browser":{"enabled_labs_experiments":["enable-webrtc-pipewire-camera"]}}'
# @2 is "Disabled" — the user turned it off explicitly, quite possibly following
# this project's own earlier "leave it OFF" advice. Reversing that is correct on
# libcamera 0.7+, but see the reporting assertion below: the end state is only
# half of what matters here.
enable_case "explicitly disabled"   "[\"$FLAG_ENTRY\"]" '{"browser":{"enabled_labs_experiments":["enable-webrtc-pipewire-camera@2"]}}'
# Other people's flags must survive, and in order.
enable_case "alongside other flags" "[\"ozone-platform-hint@1\",\"vulkan\",\"$FLAG_ENTRY\"]" \
    '{"browser":{"enabled_labs_experiments":["ozone-platform-hint@1","vulkan"]}}'
# A flag that merely starts with the same name is a different flag.
enable_case "similar flag name kept" "[\"enable-webrtc-pipewire-camera-v2\",\"$FLAG_ENTRY\"]" \
    '{"browser":{"enabled_labs_experiments":["enable-webrtc-pipewire-camera-v2"]}}'

# ── 2. The rest of the file ──────────────────────────────────────────────────
# Local State holds profile names, update state, metrics ids. Losing any of it
# to a flag edit would be a far worse bug than the camera it fixes.
echo
echo "everything else in Local State"

env_dir=$(new_env)
rich='{"browser":{"enabled_labs_experiments":["vulkan"],"window_placement":{"maximized":true}},"profile":{"info_cache":{"Default":{"name":"Trabalho — Ação"}}},"user_experience_metrics":{"stability":{"crash_count":3}},"os_crypt":{"encrypted_key":"AAAA"}}'
dir=$(make_profile "$env_dir" ".config/google-chrome" "$rich")
before=$(rest_of "$dir")
run_script "$env_dir" enable > /dev/null
after=$(rest_of "$dir")
if [[ "$before" == "$after" ]]; then
    ok "every other key preserved (incl. non-ASCII profile name)"
else
    bad "other keys changed:\n    before: $before\n    after:  $after"
fi
if [[ "$(labs_of "$dir")" == "[\"vulkan\",\"$FLAG_ENTRY\"]" ]]; then
    ok "pre-existing flag kept alongside ours"
else
    bad "pre-existing flag lost: $(labs_of "$dir")"
fi
# Chromium writes compact JSON; matching it keeps the diff to our entry alone.
if grep -q '", "' "$dir/Local State" || grep -q '": ' "$dir/Local State"; then
    bad "output is pretty-printed — Chromium writes compact JSON"
else
    ok "output stays compact, the way Chromium writes it"
fi

# A byte-identical no-op on the second run: re-running the installer must not
# churn the file.
cp -p "$dir/Local State" "$TMP/idem-before"
run_script "$env_dir" enable > /dev/null
if cmp -s "$TMP/idem-before" "$dir/Local State"; then
    ok "second run is byte-identical (idempotent)"
else
    bad "second run rewrote the file"
fi

# ── 2b. Owning up to reversing a deliberate choice ───────────────────────────
# Rewriting @2 to @1 is the right end state on libcamera 0.7+, and the backup is
# taken first. Saying nothing about it is the problem: the user set Disabled on
# purpose, and "✓ flag enabled" reads like it was simply missing.
echo
echo "reversing an explicit Disabled"

# Distinct variable names: the backup section further down still asserts against
# the `dir`/`env_dir` set up in section 2.
rev_env=$(new_env)
make_profile "$rev_env" ".config/google-chrome" \
    '{"browser":{"enabled_labs_experiments":["enable-webrtc-pipewire-camera@2"]}}' > /dev/null
rev_out=$(run_script "$rev_env" enable)
if grep -qi 'disabled' <<< "$rev_out" && grep -qi 'revers' <<< "$rev_out"; then
    ok "says the preference was reversed, not just 'enabled'"
else
    bad "silently overrode an explicit Disabled: $rev_out"
fi
if grep -q "$BACKUP_NAME" <<< "$rev_out"; then
    ok "points at the backup holding the original"
else
    bad "reversed a deliberate choice without naming the backup: $rev_out"
fi

# A profile that merely lacked the flag must NOT get the reversal wording —
# otherwise the warning is noise on every fresh install and stops being read.
rev_env=$(new_env)
make_profile "$rev_env" ".config/google-chrome" '{"browser":{}}' > /dev/null
rev_out=$(run_script "$rev_env" enable)
if grep -qi 'revers' <<< "$rev_out"; then
    bad "claimed a reversal on a profile that had no preference: $rev_out"
else
    ok "no reversal wording when the flag was simply absent"
fi

# ── 3. Backup ────────────────────────────────────────────────────────────────
# Taken once, before the first write. Refreshing it on every run would quietly
# replace the pre-install original with an already-modified copy.
echo
echo "backup"

if [[ -f "$dir/Local State.camera-relay.bak" ]]; then
    ok "backup created"
    if [[ "$(cat "$dir/Local State.camera-relay.bak")" == "$rich" ]]; then
        ok "backup still holds the pre-install original after a second run"
    else
        bad "backup was refreshed and no longer matches the original"
    fi
else
    bad "no backup created"
fi

# ── 4. libcamera version gate ────────────────────────────────────────────────
# 0.2.0 is Ubuntu 24.04 / Zorin, where the PipeWire camera path has no IPU6
# support. Enabling there trades "Chrome sees nothing" for "Chrome sees nothing
# and the relay is bypassed too", so the gate has to hold.
echo
echo "libcamera version gate"

gate_case() {
    local desc="$1" version="$2" want="$3"; shift 3
    local env_dir dir verdict
    env_dir=$(new_env "$version")
    dir=$(make_profile "$env_dir" ".config/google-chrome" '{"browser":{}}')
    run_script "$env_dir" enable "$@" > /dev/null
    if [[ "$(labs_of "$dir")" == "[\"$FLAG_ENTRY\"]" ]]; then
        verdict="applied"
    else
        verdict="skipped"
    fi
    if [[ "$verdict" == "$want" ]]; then
        ok "$(printf '%-32s %s' "$desc" "$want")"
    else
        bad "$(printf '%-32s expected %s, got %s' "$desc" "$want" "$verdict")"
    fi
}

gate_case "libcamera 0.2.0"          "0.2.0" skipped
gate_case "libcamera 0.5.2"          "0.5.2" skipped
gate_case "libcamera 0.7"            "0.7"   applied
gate_case "libcamera 0.7.2"          "0.7.2" applied
gate_case "libcamera 0.10.0"         "0.10.0" applied
gate_case "libcamera 1.0"            "1.0"   applied
gate_case "version undeterminable"   ""      skipped
gate_case "0.2.0 with --force"       "0.2.0" applied --force

# ── 5. Running-browser guard ─────────────────────────────────────────────────
# Chromium rewrites Local State from memory on exit. A write against a live
# profile reports success and then vanishes, which is the worst outcome of all:
# the installer claims it fixed the camera and it did not.
echo
echo "running-browser guard"

env_dir=$(new_env)
dir=$(make_profile "$env_dir" ".config/google-chrome" '{"browser":{}}')
ln -s "testhost-$$" "$dir/SingletonLock"     # our own PID: definitely alive
out=$(run_script "$env_dir" enable)
if [[ "$(labs_of "$dir")" == "MISSING" ]]; then
    ok "live SingletonLock: profile left untouched"
else
    bad "live SingletonLock: wrote anyway → change would be lost on quit"
fi
if grep -q "is running" <<< "$out" && grep -q "chrome://flags" <<< "$out"; then
    ok "live SingletonLock: says which browser and how to fix it by hand"
else
    bad "live SingletonLock: unhelpful message: $out"
fi
if [[ -f "$dir/Local State.camera-relay.bak" ]]; then
    bad "live SingletonLock: took a backup for a write it never made"
else
    ok "live SingletonLock: no stray backup"
fi

# Flatpak profiles are the dangerous case. SingletonLock records the *sandbox*
# PID — for a freshly started app that is a low number like 2, which on the host
# is a root-owned kernel thread. `kill -0` on it fails with EPERM, which is
# indistinguishable from "no such process", so a PID-based guard concludes "not
# running" and writes into a live profile. The write then looks successful and
# the browser discards it on exit: a silent no-op, the one outcome worse than
# refusing. Ask flatpak instead.
fp_env=$(new_env)
fp_dir=$(make_profile "$fp_env" ".var/app/com.opera.opera-gx/config/opera-gx" '{"browser":{}}')
ln -s "testhost-2" "$fp_dir/SingletonLock"          # PID 2 = kthreadd on the host
echo "com.opera.opera-gx" > "$fp_env/flatpak.running"
fp_out=$(run_script "$fp_env" enable)
if [[ "$(labs_of "$fp_dir")" == "MISSING" ]]; then
    ok "flatpak: running app detected via flatpak ps, profile untouched"
else
    bad "flatpak: wrote into a running sandboxed browser — discarded on exit"
fi
if grep -q "is running" <<< "$fp_out"; then
    ok "flatpak: says which browser is in the way"
else
    bad "flatpak: refused without saying why: $fp_out"
fi

# Same stale lock, but the app is not running: must proceed, or the flag can
# never be set for that browser at all.
fp_env=$(new_env)
fp_dir=$(make_profile "$fp_env" ".var/app/com.opera.opera-gx/config/opera-gx" '{"browser":{}}')
ln -s "testhost-2" "$fp_dir/SingletonLock"
: > "$fp_env/flatpak.running"
run_script "$fp_env" enable > /dev/null
if [[ "$(labs_of "$fp_dir")" == "[\"$FLAG_ENTRY\"]" ]]; then
    ok "flatpak: not running → proceeds despite the leftover lock"
else
    bad "flatpak: stale lock blocked it forever"
fi

# A crash leaves the lock behind. Refusing forever on a dead PID would strand
# the user with no camera and no obvious reason.
dead=$(bash -c 'echo $$')          # exited by the time we read it
while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
env_dir=$(new_env)
dir=$(make_profile "$env_dir" ".config/google-chrome" '{"browser":{}}')
ln -s "testhost-$dead" "$dir/SingletonLock"
run_script "$env_dir" enable > /dev/null
if [[ "$(labs_of "$dir")" == "[\"$FLAG_ENTRY\"]" ]]; then
    ok "stale SingletonLock: proceeds"
else
    bad "stale SingletonLock: refused on a dead PID"
fi

# ── 6. Profile discovery ─────────────────────────────────────────────────────
echo
echo "profile discovery"

env_dir=$(new_env)
chrome_dir=$(make_profile "$env_dir" ".config/google-chrome" '{"browser":{}}')
brave_dir=$(make_profile "$env_dir" ".config/BraveSoftware/Brave-Browser" '{"browser":{}}')
snap_dir=$(make_profile "$env_dir" "snap/chromium/current/.config/chromium" '{"browser":{}}')
flat_dir=$(make_profile "$env_dir" ".var/app/com.google.Chrome/config/google-chrome" '{"browser":{}}')
# The three the old full-path list missed. Writing every browser out once per
# packaging is what let these slip: native Vivaldi was listed, the snap was not,
# and Opera was absent in all three forms.
sv_dir=$(make_profile "$env_dir" "snap/vivaldi/current/.config/vivaldi" '{"browser":{}}')
gx_dir=$(make_profile "$env_dir" ".var/app/com.opera.opera-gx/config/opera-gx" '{"browser":{}}')
opera_dir=$(make_profile "$env_dir" ".config/opera" '{"browser":{}}')
# Edge does not register the entry in edge://flags, so writing it into Edge's
# Local State would do nothing but litter someone's config. (Edge is still
# fixable — the Chromium feature is compiled in and the command-line switch
# works — just not through this file.)
edge_dir=$(make_profile "$env_dir" ".config/microsoft-edge" '{"browser":{}}')
# Electron apps keep a Local State but never process about:flags. Writing there
# leaves dead weight in someone else's config and fixes nothing.
slack_dir=$(make_profile "$env_dir" ".config/Slack" '{"browser":{}}')
run_script "$env_dir" enable > /dev/null
for pair in "Chrome:$chrome_dir" "Brave:$brave_dir" "snap Chromium:$snap_dir" \
            "flatpak Chrome:$flat_dir" "snap Vivaldi:$sv_dir" \
            "flatpak Opera GX:$gx_dir" "Opera:$opera_dir"; do
    if [[ "$(labs_of "${pair#*:}")" == "[\"$FLAG_ENTRY\"]" ]]; then
        ok "${pair%%:*} profile updated"
    else
        bad "${pair%%:*} profile missed"
    fi
done
if [[ "$(labs_of "$edge_dir")" == "MISSING" ]]; then
    ok "Edge left alone (about:flags entry not registered there)"
else
    bad "Edge profile written with a flag Edge does not have"
fi
if [[ "$(labs_of "$slack_dir")" == "MISSING" ]]; then
    ok "Electron app left alone (does not read about:flags)"
else
    bad "wrote the flag into an Electron app's config"
fi

# Labels have to say which packaging, or two Vivaldis are indistinguishable in
# doctor's output — and one of them may be the one that is broken.
out=$(run_script "$env_dir" status)
if grep -q 'Vivaldi (snap)' <<< "$out" && grep -q 'Opera GX (flatpak)' <<< "$out"; then
    ok "labels name the packaging"
else
    bad "labels do not distinguish packaging: $out"
fi
# A snap's "current" is a symlink to a revision; resolving it must not make the
# same profile show up twice.
if [[ "$(grep -c 'Vivaldi' <<< "$out")" == "1" ]]; then
    ok "no duplicate report for a symlinked snap profile"
else
    bad "reported the same profile more than once: $out"
fi

env_dir=$(new_env)
out=$(run_script "$env_dir" enable)
if grep -q "No Chromium-family browser profiles found" <<< "$out"; then
    ok "no profiles: says so and exits clean"
else
    bad "no profiles: unexpected output: $out"
fi

# ── 7. disable / status ──────────────────────────────────────────────────────
# The uninstallers call disable. It has to remove our entry and nothing else.
echo
echo "disable / status"

env_dir=$(new_env)
dir=$(make_profile "$env_dir" ".config/google-chrome" \
    "{\"browser\":{\"enabled_labs_experiments\":[\"vulkan\",\"$FLAG_ENTRY\"]}}")
run_script "$env_dir" disable > /dev/null
if [[ "$(labs_of "$dir")" == '["vulkan"]' ]]; then
    ok "disable removes ours, keeps theirs"
else
    bad "disable mangled the list: $(labs_of "$dir")"
fi

env_dir=$(new_env)
dir=$(make_profile "$env_dir" ".config/google-chrome" \
    "{\"browser\":{\"enabled_labs_experiments\":[\"$FLAG_ENTRY\"],\"x\":1}}")
run_script "$env_dir" disable > /dev/null
if [[ "$(labs_of "$dir")" == "MISSING" ]]; then
    ok "disable drops the key when it empties out"
else
    bad "disable left an empty array behind: $(labs_of "$dir")"
fi

# The backup exists to undo our edit. Once the flag is out, leaving it behind
# parks a stale copy of the user's browser config in their profile forever.
env_dir=$(new_env)
dir=$(make_profile "$env_dir" ".config/google-chrome" '{"browser":{},"keep":1}')
run_script "$env_dir" enable > /dev/null
[[ -f "$dir/$BACKUP_NAME" ]] || bad "enable did not create the backup (setup failed)"
run_script "$env_dir" disable > /dev/null
if [[ -f "$dir/$BACKUP_NAME" ]]; then
    bad "disable left the backup behind in the user's profile"
else
    ok "disable cleans up its backup"
fi
# ...but only after a disable that actually ran. A profile skipped because the
# browser is open still needs its backup.
env_dir=$(new_env)
dir=$(make_profile "$env_dir" ".config/google-chrome" '{"browser":{}}')
run_script "$env_dir" enable > /dev/null
ln -s "testhost-$$" "$dir/SingletonLock"
run_script "$env_dir" disable > /dev/null
if [[ -f "$dir/$BACKUP_NAME" ]]; then
    ok "backup kept when disable was skipped (browser running)"
else
    bad "removed the backup for a profile it never disabled"
fi

# The words must be the ones `camera-relay doctor` prints. One fact reported in
# two vocabularies — `other` here, `DISABLED` there — is worse than either word
# on its own, because it hides that they are the same state.
status_case() {
    local desc="$1" want="$2" json="$3"
    local env_dir out
    env_dir=$(new_env)
    make_profile "$env_dir" ".config/google-chrome" "$json" > /dev/null
    out=$(run_script "$env_dir" status)
    if grep -qE "[[:space:]]$want\$" <<< "$out"; then
        ok "$(printf 'status: %-22s %s' "$desc" "$want")"
    else
        bad "$(printf 'status: %-22s expected %s, got: %s' "$desc" "$want" "$out")"
    fi
}

status_case "no flag"            "not set"  '{"browser":{}}'
status_case "enabled @1"         "ENABLED"  "{\"browser\":{\"enabled_labs_experiments\":[\"$FLAG_ENTRY\"]}}"
status_case "bare, no @suffix"   "ENABLED"  '{"browser":{"enabled_labs_experiments":["enable-webrtc-pipewire-camera"]}}'
status_case "explicitly @2"      "DISABLED" '{"browser":{"enabled_labs_experiments":["enable-webrtc-pipewire-camera@2"]}}'
# status must never write.
cp -p "$dir/Local State" "$TMP/status-before"
run_script "$env_dir" status > /dev/null
cmp -s "$TMP/status-before" "$dir/Local State" \
    && ok "status leaves the file alone" || bad "status modified the profile"

# ── 8. Damaged profile ───────────────────────────────────────────────────────
# Chromium itself recovers from a corrupt Local State. We must not make it worse
# by truncating the file or writing a half-object over it.
echo
echo "damaged profile"

env_dir=$(new_env)
dir=$(make_profile "$env_dir" ".config/google-chrome" '{"browser":{"enabled_labs')
out=$(run_script "$env_dir" enable)
if [[ "$(cat "$dir/Local State")" == '{"browser":{"enabled_labs' ]]; then
    ok "malformed JSON left byte-for-byte intact"
else
    bad "malformed JSON was overwritten"
fi
if grep -q "could not update profile" <<< "$out"; then
    ok "malformed JSON reported, not swallowed"
else
    bad "malformed JSON failed silently: $out"
fi
if [[ -e "$dir/Local State.camera-relay.tmp" ]]; then
    bad "left a temp file behind"
else
    ok "no temp file left behind"
fi

env_dir=$(new_env)
dir=$(make_profile "$env_dir" ".config/google-chrome" '[1,2,3]')
run_script "$env_dir" enable > /dev/null
if [[ "$(cat "$dir/Local State")" == '[1,2,3]' ]]; then
    ok "non-object JSON left intact"
else
    bad "non-object JSON was overwritten"
fi

# ── 9. doctor delegates instead of keeping its own list ──────────────────────
# `camera-relay doctor` used to carry a hand-written 5-profile list while this
# script knew 10, so a Vivaldi-only, Chrome-Beta-only or flatpak-only machine
# got no flag diagnostics at all — even though the installer had edited exactly
# those profiles. Delegating removes the second list; this checks it stayed
# removed, because the failure mode is silence, not an error.
echo
echo "doctor delegation"

RELAY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/camera-relay"
stub_dir="$TMP/doctor-stub"
mkdir -p "$stub_dir/bin"
cat > "$stub_dir/bin/chromium-pipewire-camera" << 'EOF'
#!/bin/sh
[ "$1" = status ] || exit 0
printf '  %-20s %s\n' "Vivaldi:" "not set"
printf '  %-20s %s\n' "Brave (flatpak):" "DISABLED"
EOF
chmod +x "$stub_dir/bin/chromium-pipewire-camera"
sed "s#/usr/local/bin/chromium-pipewire-camera#$stub_dir/bin/chromium-pipewire-camera#g" \
    "$RELAY" > "$stub_dir/camera-relay"
chmod +x "$stub_dir/camera-relay"

doctor_out=$("$stub_dir/camera-relay" doctor 2>&1) || true
if grep -q 'Vivaldi:' <<< "$doctor_out" && grep -q 'Brave (flatpak):' <<< "$doctor_out"; then
    ok "doctor reports profiles only the flag tool knows about"
else
    bad "doctor ignored the flag tool's profile list"
fi
# A DISABLED profile still needs the remedy printed.
if grep -q 'Set it with' <<< "$doctor_out"; then
    ok "doctor still prints the remedy when a delegated profile is not ENABLED"
else
    bad "doctor swallowed the remedy for a non-ENABLED profile"
fi

# ── 10. The feature name we tell people to type ──────────────────────────────
# Chromium feature names are case-sensitive and --enable-features silently
# ignores one it does not recognise, so a wrong spelling looks exactly like a
# right one and simply does nothing. The name is fixed by
#   BASE_FEATURE(kWebRtcPipeWireCamera, ...)   media/capture/capture_switches.cc
# and "WebRTCPipeWireCamera" is the plausible-looking wrong version that shipped
# twice before anyone tried it. Checks every use site, not just this file.
echo
echo "documented feature name"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bad_uses=$(grep -rn -- '--enable-features=[A-Za-z]*[Pp]ipe[Ww]ire[Cc]amera' "$REPO" \
    --exclude-dir=.git 2>/dev/null \
    | grep -v -- '--enable-features=WebRtcPipeWireCamera' || true)
if [[ -z "$bad_uses" ]]; then
    ok "every --enable-features= use site spells it WebRtcPipeWireCamera"
else
    bad "misspelled feature name — silently ignored by Chromium:"
    sed 's/^/      /' <<< "$bad_uses"
fi

# The flag id in the chrome://flags URL is a separate string from the feature
# name and is lowercase-with-dashes. Mixing the two up is the other easy error.
if grep -rq 'chrome://flags/#enable-webrtc-pipewire-camera' "$REPO" --exclude-dir=.git 2>/dev/null; then
    ok "chrome://flags URL uses the flag id, not the feature name"
else
    bad "no chrome://flags/#enable-webrtc-pipewire-camera reference found"
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
