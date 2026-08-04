#!/usr/bin/env bash
# The on-demand path reads the monitor's event stream through a process
# substitution:
#
#     done < <("$MONITOR_BIN" ... )
#
# which gives no way to observe the child's exit code — it lands in neither $?
# nor PIPESTATUS. So a monitor that gave up looked exactly like a clean
# shutdown, `camera-relay start --on-demand` exited 0, and Restart=on-failure
# never fired: the relay stayed dead until someone restarted it by hand.
#
# That is the same shape as the "Already running" exit-0 bug fixed in v0.3.56,
# which is why it is worth a test rather than just a comment.
#
# The read loop is lifted out of the script itself rather than retyped here, so
# deleting the sentinel in camera-relay fails this test instead of silently
# passing against a stale copy.
#
# Usage: ./test-monitor-exit-propagation.sh
# Requires no camera hardware and touches no system state.

set -uo pipefail

RELAY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/camera-relay"
PASS=0
FAIL=0

ok()  { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "test-monitor-exit-propagation ($RELAY)"

# Pull the real read loop out of cmd_start_on_demand: from the comment that
# introduces it through the closing `return`.
sed -n '/# The monitor manages the pipeline subprocess itself\./,/return "\$monitor_rc"/p' \
    "$RELAY" > "$TMP/loop.sh"

if [[ ! -s "$TMP/loop.sh" ]]; then
    bad "could not locate the read loop in camera-relay"
    echo; echo "  $PASS passed, $FAIL failed"; exit 1
fi
ok "read loop extracted from the script"

# Run the extracted loop against a stub monitor that emits the usual events and
# then exits with a chosen status.
run_loop() {
    local want_rc="$1"
    cat > "$TMP/stub" <<STUB
#!/usr/bin/env bash
echo READY
echo START
echo STOP
exit $want_rc
STUB
    chmod +x "$TMP/stub"

    (
        # Must match camera-relay's own `set -euo pipefail`. With -e missing,
        # the subshell inside the process substitution survives a failing
        # monitor and the sentinel gets emitted either way — so the test would
        # pass against a script that is broken in production.
        set -euo pipefail
        info() { :; }
        warn() { :; }
        MONITOR_BIN="$TMP/stub"
        loopback_dev=/dev/null
        gst_log=/dev/null
        STATE_CACHE="$TMP/state"
        gst_cmd=(/bin/true)
        run_it() {
            # shellcheck disable=SC1090
            source "$TMP/loop.sh"
        }
        run_it
    )
}

run_loop 0 >/dev/null 2>&1
rc=$?
[[ $rc -eq 0 ]] && ok "monitor exiting 0 keeps the function at 0" \
                || bad "monitor exiting 0 produced $rc"

run_loop 42 >/dev/null 2>&1
rc=$?
if [[ $rc -eq 42 ]]; then
    ok "monitor exiting 42 reaches the caller (Restart=on-failure can fire)"
elif [[ $rc -eq 0 ]]; then
    bad "monitor exit status was swallowed — the process substitution hides it"
else
    bad "expected 42, got $rc"
fi

# The EXIT trap gets the last word on the exit status. Under set -e a command
# failing inside it replaces whatever the shell was exiting with — and
# cleanup_on_demand's pkill exits 1 whenever there are no children left, which
# is the normal case. That flattened every status to 1, sentinel or not.
sed -n '/cleanup_on_demand() {/,/^    }/p' "$RELAY" > "$TMP/cleanup.sh"
if [[ ! -s "$TMP/cleanup.sh" ]]; then
    bad "could not locate cleanup_on_demand"
else
    # Run it as its own shell, not a subshell: $$ does not change inside a
    # subshell, so `pkill -P $$` would target this test's children and take the
    # harness down with it.
    {
        echo 'set -euo pipefail'
        echo "PID_FILE=\"$TMP/pid\"; STATE_CACHE=\"$TMP/state\""
        sed 's/^    //' "$TMP/cleanup.sh"
        echo 'trap cleanup_on_demand EXIT'
        echo 'f() { return 42; }'
        echo 'f'
    } > "$TMP/trap-case.sh"
    bash "$TMP/trap-case.sh" >/dev/null 2>&1
    rc=$?
    if [[ $rc -eq 42 ]]; then
        ok "the EXIT trap leaves the exit status alone"
    else
        bad "the EXIT trap rewrote the exit status to $rc"
    fi
fi

# The whole point is that the status keeps going up the call chain, so the
# dispatcher must not flatten it with a bare `cmd_start_on_demand; return 0`.
if sed -n '/^cmd_start()/,/^}/p' "$RELAY" | grep -qE 'cmd_start_on_demand\s*$'; then
    if sed -n '/^cmd_start()/,/^}/p' "$RELAY" | grep -qE '^\s*return\s*$'; then
        ok "cmd_start returns the on-demand status unchanged"
    else
        bad "cmd_start does not propagate the on-demand status"
    fi
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
