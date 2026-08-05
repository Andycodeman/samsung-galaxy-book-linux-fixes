#!/usr/bin/env bash
# Regression tests for service-unit regeneration on reinstall (issue #82).
#
# cmd_enable_persistent used to return the moment persistent mode was already
# on, and the unit is written well after that point. So a reinstall refreshed
# every binary and left the unit at whatever it was first created with.
#
# That matters because the unit is not static. It carries
# LIBCAMERA_IPA_MODULE_PATH, GST_PLUGIN_PATH, LD_LIBRARY_PATH,
# LIBCAMERA_SOFTISP_MODE, __EGL_VENDOR_LIBRARY_FILENAMES and the
# nudge-wireplumber ExecStartPost — all computed at install time. Two shipped
# fixes died there: the hybrid-GPU EGL pin (#76, black camera) and the
# WirePlumber format re-probe (v0.3.62, no camera in Chrome). Both arrived
# installed and inert while the installer reported success.
#
# Four properties, each easy to break in the opposite direction:
#   1. Already enabled + stale unit  → rewrite it. That is the bug.
#   2. Already enabled + same unit   → touch nothing. An unconditional rewrite
#      would daemon-reload and restart the relay on every reinstall, dropping
#      the camera out from under whoever is using it.
#   3. A changed unit must be followed by a restart, or the running relay keeps
#      the old environment until the next login — which is exactly how the EGL
#      pin stayed inert on machines that had the fix.
#   4. Never leave the .new temp file behind in the unit directory; systemd
#      would not load it, but `camera-relay.service.new` sitting in
#      ~/.config/systemd/user is alarming and looks like a failed install.
#
# Usage: ./test-unit-regeneration.sh
# Requires no camera hardware and touches no system state.

set -uo pipefail

RELAY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/camera-relay"
PASS=0
FAIL=0

ok()  { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "test-unit-regeneration ($RELAY)"

# ── Harness ───────────────────────────────────────────────────────────────────
# Same shape as test-egl-vendor-pin.sh: stub every probe so the run is hermetic,
# point SERVICE_DIR at a temp dir, and record systemctl instead of running it.
#
# $1 = "enabled" | "disabled"  (what is_persistent reports)
# $2 = path to a file to pre-seed as the installed unit, or empty for none
#
# A *path*, not a string: `$(cat unit)` strips the trailing newline, so seeding
# from a captured variable produces a file that differs from the generated one
# by exactly one byte and every "unchanged" case looks changed.
run_enable() {
    local persistent="$1" existing="$2"
    local outdir="$TMP/unit-$RANDOM$RANDOM"
    mkdir -p "$outdir"
    [[ -n "$existing" ]] && cp "$existing" "$outdir/camera-relay.service"
    (
        set -euo pipefail
        # shellcheck disable=SC1090
        source "$RELAY" -h >/dev/null 2>&1 || true
        SERVICE_DIR="$outdir"
        if [[ "$persistent" == enabled ]]; then
            is_persistent() { return 0; }
        else
            is_persistent() { return 1; }
        fi
        require_gst_tools() { return 0; }
        detect_ipa_path() { return 1; }
        detect_gst_plugin_path() { return 1; }
        detect_libcamera_lib_path() { return 1; }
        detect_egl_vendor_pin() { return 1; }
        systemctl() { echo "$*" >> "$outdir/systemctl.calls"; return 0; }
        cmd_enable_persistent --yes >/dev/null 2>&1
        echo "rc=$?" > "$outdir/rc"
    ) >/dev/null 2>&1
    printf '%s\n' "$outdir"
}

calls_of() { cat "$1/systemctl.calls" 2>/dev/null; }
unit_of()  { cat "$1/camera-relay.service" 2>/dev/null; }

# A unit as it would have been generated before v0.3.62 — no ExecStartPost.
# This is the concrete shape of the bug: real machines are running this today.
STALE_UNIT="$TMP/stale.service"
cat > "$STALE_UNIT" <<'EOF'
[Unit]
Description=Camera Relay (on-demand libcamera to v4l2loopback)
After=pipewire.service wireplumber.service

[Service]
Type=simple
ExecStart=/usr/local/bin/camera-relay start --on-demand
ExecStop=/usr/local/bin/camera-relay stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

# ── 1. The bug: already enabled, stale unit ──────────────────────────────────
echo
echo "already enabled, unit predates the current version"

d=$(run_enable enabled "$STALE_UNIT")
if grep -q '^ExecStartPost=-/usr/local/bin/camera-relay nudge-wireplumber$' <<< "$(unit_of "$d")"; then
    ok "stale unit is regenerated (gains the nudge-wireplumber ExecStartPost)"
else
    bad "stale unit left untouched — this is issue #82, the fix is inert"
fi
if grep -q 'daemon-reload' <<< "$(calls_of "$d")"; then
    ok "daemon-reload issued after rewriting"
else
    bad "no daemon-reload — systemd keeps serving the old unit"
fi
if grep -qE '(^|[[:space:]])restart camera-relay\.service$' <<< "$(calls_of "$d")"; then
    ok "relay restarted so the running process picks up the new unit"
else
    bad "no restart — the running relay keeps the old environment until login"
fi
if [[ ! -e "$d/camera-relay.service.new" ]]; then
    ok "no .new temp file left in the unit directory"
else
    bad "left camera-relay.service.new behind"
fi

# ── 2. Already enabled, unit already correct ─────────────────────────────────
# The other half. An unconditional rewrite would restart the relay on every
# single reinstall, which is a dropped camera for anyone mid-call.
echo
echo "already enabled, unit already up to date"

d=$(run_enable enabled "")            # first pass generates the current unit
CURRENT_UNIT="$TMP/current.service"
if [[ -s "$d/camera-relay.service" ]] && cp "$d/camera-relay.service" "$CURRENT_UNIT"; then
    ok "baseline current unit captured"
else
    bad "could not generate a baseline unit"
fi

d=$(run_enable enabled "$CURRENT_UNIT")
if cmp -s "$d/camera-relay.service" "$CURRENT_UNIT"; then
    ok "identical unit left byte-for-byte alone"
else
    bad "rewrote a unit that was already correct"
fi
if [[ -z "$(calls_of "$d")" ]]; then
    ok "no systemctl at all — genuine no-op reinstall"
else
    bad "touched systemd for an unchanged unit: $(calls_of "$d")"
fi
if [[ ! -e "$d/camera-relay.service.new" ]]; then
    ok "no .new temp file left behind on the no-op path"
else
    bad "left camera-relay.service.new behind on the no-op path"
fi

# ── 3. Fresh enable ──────────────────────────────────────────────────────────
# The path that already worked. It has to keep working: `enable --now` is what
# makes the relay start at login in the first place.
echo
echo "not yet enabled"

d=$(run_enable disabled "")
if grep -q '^ExecStart=/usr/local/bin/camera-relay start --on-demand$' <<< "$(unit_of "$d")"; then
    ok "unit written"
else
    bad "no unit written on a fresh enable"
fi
if grep -q 'enable --now camera-relay.service' <<< "$(calls_of "$d")"; then
    ok "enable --now issued"
else
    bad "missing enable --now: $(calls_of "$d")"
fi
if ! grep -qE '(^|[[:space:]])restart camera-relay\.service$' <<< "$(calls_of "$d")"; then
    ok "no redundant restart (enable --now already starts it)"
else
    bad "restarted on top of enable --now"
fi

# ── 4. Already enabled, unit missing entirely ────────────────────────────────
# Someone deleted it by hand, or an older uninstall removed the unit and left
# the symlink. Previously this returned "already enabled" and wrote nothing,
# leaving a service that cannot start.
echo
echo "already enabled, unit file missing"

d=$(run_enable enabled "")
if [[ -n "$(unit_of "$d")" ]]; then
    ok "missing unit is recreated rather than reported as fine"
else
    bad "no unit written — service would stay unstartable"
fi

# ── 5. Exit status ───────────────────────────────────────────────────────────
# install.sh runs this with `&& echo ✓ || echo ⚠`, so a non-zero exit on the
# no-op path would report a failed install on every reinstall.
echo
echo "exit status"

for case_desc in "enabled|$CURRENT_UNIT|unchanged unit" \
                 "enabled|$STALE_UNIT|stale unit" \
                 "disabled||no unit"; do
    IFS='|' read -r state seed label <<< "$case_desc"
    d=$(run_enable "$state" "$seed")
    if [[ "$(cat "$d/rc" 2>/dev/null)" == "rc=0" ]]; then
        ok "$(printf '%-32s exits 0' "$state, $label")"
    else
        bad "$(printf '%-32s exited %s' "$state, $label" "$(cat "$d/rc" 2>/dev/null || echo '?')")"
    fi
done

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
