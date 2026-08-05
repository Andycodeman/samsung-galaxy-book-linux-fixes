#!/usr/bin/env bash
# chromium-pipewire-camera.sh — route Chromium-family browsers to the camera
# through PipeWire instead of direct V4L2.
#
# Chromium cannot see the camera relay at all. Its V4L2 enumeration
# (media/capture/video/linux/video_capture_device_factory_v4l2.cc) accepts a
# node only when it reports VIDEO_CAPTURE *and not* VIDEO_OUTPUT:
#
#     (cap.capabilities & V4L2_CAP_VIDEO_CAPTURE &&
#      !(cap.capabilities & V4L2_CAP_VIDEO_OUTPUT)) ||
#     (cap.capabilities & V4L2_CAP_DEVICE_CAPS &&
#      cap.device_caps & V4L2_CAP_VIDEO_CAPTURE &&
#      !(cap.device_caps & V4L2_CAP_VIDEO_OUTPUT))
#
# The relay node is created with exclusive_caps=0, so it advertises both and
# every branch of that condition fails. Firefox accepts dual caps and reads the
# node directly, which is why it works and Chrome silently lists no camera —
# enumerateDevices() returns zero videoinput entries, before any permission
# prompt. Same filter in Edge and in every Electron app.
#
# exclusive_caps=1 would fix it at the source, but the relay deliberately moved
# away from that (see the note above nudge_wireplumber in camera-relay): with
# exclusive_caps=1 WirePlumber classifies the node as an output at boot and the
# PipeWire path breaks instead. So we take the other route — WirePlumber already
# publishes the relay as a Video/Source, and this flag makes Chromium consume it.
#
# This flag is necessary but NOT sufficient on its own. WirePlumber probes the
# loopback at login, before the relay's monitor pins its format, and caches
# v4l2loopback's catch-all range instead. WebRTC cannot parse a range, so Chrome
# finds the camera and still offers no device — same NotFoundError, different
# cause. nudge_wireplumber in camera-relay handles that half, from ExecStartPost.
# If this script reports success and Chrome still sees nothing, check there and
# in `camera-relay doctor` before suspecting the flag.
#
# Usage: ./chromium-pipewire-camera.sh [enable|disable|status] [--force]
#
#   enable    write the flag into every Chromium-family profile found (default)
#   disable   take it back out (used by the uninstallers)
#   status    report per profile, change nothing
#
#   --force   skip the libcamera version gate

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

FLAG="enable-webrtc-pipewire-camera"
FLAG_ENTRY="${FLAG}@1"      # @1 = "Enabled"; @2 would be "Disabled"
BACKUP_SUFFIX=".camera-relay.bak"

ACTION="enable"
FORCE=0
for arg in "$@"; do
    case "$arg" in
        enable|disable|status) ACTION="$arg" ;;
        --force)               FORCE=1 ;;
        -h|--help)
            sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "ERROR: unknown argument: $arg" >&2
            exit 2 ;;
    esac
done

# ── libcamera version gate ───────────────────────────────────────────────────
# On Ubuntu 24.04 / Zorin the system libcamera is 0.2.0, which has no IPU6
# support: there the flag sends Chromium down a PipeWire path that cannot
# produce frames. 0.7+ is where the PipeWire camera path actually works.
version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | LC_ALL=C sort -V | head -1)" == "$2" ]]
}

libcamera_version() {
    command -v pkg-config >/dev/null 2>&1 || return 1
    local v
    v=$(pkg-config --modversion libcamera 2>/dev/null) || return 1
    [[ -n "$v" ]] || return 1
    printf '%s\n' "$v"
}

# ── Target user ──────────────────────────────────────────────────────────────
# We are editing a browser profile, so this has to run as the desktop user even
# when the installer was itself started with sudo. Same seat0 lookup the
# installers already use to find the relay's user.
resolve_target_user() {
    if [[ $EUID -ne 0 ]]; then
        id -un
        return 0
    fi
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
        return 0
    fi
    local u
    u=$(loginctl list-sessions --no-legend 2>/dev/null \
        | awk '$4 == "seat0" {print $3}' | head -1)
    [[ -n "$u" && "$u" != "root" ]] || return 1
    printf '%s\n' "$u"
}

# ── Profile discovery ────────────────────────────────────────────────────────
# Emits "label<TAB>directory holding Local State" for every Chromium-family
# profile that exists under $1. Absent ones are skipped without comment — most
# machines have one of these, not five.
#
# Edge is deliberately absent: it ships no enable-webrtc-pipewire-camera flag,
# so there is nothing to write. It stays blind to the relay.
chromium_profile_dirs() {
    local home="$1" d
    local -a candidates=(
        "Chrome|$home/.config/google-chrome"
        "Chrome Beta|$home/.config/google-chrome-beta"
        "Chrome Unstable|$home/.config/google-chrome-unstable"
        "Chromium|$home/.config/chromium"
        "Chromium (snap)|$home/snap/chromium/current/.config/chromium"
        "Brave|$home/.config/BraveSoftware/Brave-Browser"
        "Vivaldi|$home/.config/vivaldi"
        "Chrome (flatpak)|$home/.var/app/com.google.Chrome/config/google-chrome"
        "Chromium (flatpak)|$home/.var/app/org.chromium.Chromium/config/chromium"
        "Brave (flatpak)|$home/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser"
    )
    for d in "${candidates[@]}"; do
        [[ -f "${d#*|}/Local State" ]] && printf '%s\t%s\n' "${d%%|*}" "${d#*|}"
    done
    return 0
}

# ── Running-browser guard ────────────────────────────────────────────────────
# Chromium rewrites Local State from memory when it exits, so a write against a
# live profile is silently discarded on quit. SingletonLock is the profile's own
# "I am running" marker and points at host-pid, which beats matching process
# names — those get truncated to 15 chars in comm and "chrome" appears in our
# own argv besides.
browser_running() {
    local dir="$1" target pid
    local lock="$dir/SingletonLock"
    [[ -L "$lock" ]] || return 1
    target=$(readlink "$lock" 2>/dev/null) || return 1
    pid=${target##*-}
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null       # stale lock after a crash → not running
}

# ── The edit ─────────────────────────────────────────────────────────────────
# json.dump with compact separators is what Chromium itself writes, so the file
# stays byte-comparable apart from our entry. Written to a temp file in the same
# directory and os.replace'd, so a crash mid-write cannot truncate the profile.
FLAG_PY='
import json, os, re, sys

path, flag, entry, action = sys.argv[1:5]
pattern = re.compile(r"^" + re.escape(flag) + r"(@\d+)?$")

try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError) as exc:
    print("unreadable: %s" % exc, file=sys.stderr)
    sys.exit(3)

if not isinstance(data, dict):
    print("unreadable: top level is not an object", file=sys.stderr)
    sys.exit(3)

browser = data.get("browser")
if not isinstance(browser, dict):
    browser = {}
labs = browser.get("enabled_labs_experiments")
if not isinstance(labs, list):
    labs = []

kept = [x for x in labs if not (isinstance(x, str) and pattern.match(x))]
had = len(kept) != len(labs)

if action == "status":
    print("enabled" if entry in labs else ("other" if had else "absent"))
    sys.exit(0)

if action == "enable":
    new = kept + [entry]
    if new == labs:
        print("unchanged")
        sys.exit(0)
elif action == "disable":
    if not had:
        print("unchanged")
        sys.exit(0)
    new = kept
else:
    print("unreadable: bad action", file=sys.stderr)
    sys.exit(3)

if new:
    browser["enabled_labs_experiments"] = new
else:
    browser.pop("enabled_labs_experiments", None)

if browser:
    data["browser"] = browser

tmp = path + ".camera-relay.tmp"
try:
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, separators=(",", ":"), ensure_ascii=False)
    os.replace(tmp, path)
except OSError as exc:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    print("unwritable: %s" % exc, file=sys.stderr)
    sys.exit(4)

print("changed")
'

flag_state() {
    python3 -c "$FLAG_PY" "$1/Local State" "$FLAG" "$FLAG_ENTRY" status 2>/dev/null
}

apply_flag() {
    python3 -c "$FLAG_PY" "$1/Local State" "$FLAG" "$FLAG_ENTRY" "$2"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "  ⚠ python3 not found — cannot edit browser profiles."
        echo "    Set chrome://flags/#${FLAG} to Enabled by hand."
        return 0
    fi

    local target_user target_home
    if ! target_user=$(resolve_target_user); then
        echo "  ⚠ Could not determine the desktop user — skipping browser setup."
        return 0
    fi
    target_home=$(getent passwd "$target_user" | cut -d: -f6)
    if [[ -z "$target_home" || ! -d "$target_home" ]]; then
        echo "  ⚠ No home directory for '$target_user' — skipping browser setup."
        return 0
    fi

    # Re-exec as the desktop user so every file we touch keeps their ownership.
    if [[ $EUID -eq 0 ]]; then
        exec sudo -u "$target_user" -- "$SELF" "$@"
    fi

    if [[ "$ACTION" == "enable" && $FORCE -eq 0 ]]; then
        local ver
        if ! ver=$(libcamera_version); then
            echo "  – Skipping Chromium PipeWire camera flag: libcamera version unknown."
            echo "    Enable it by hand once you know you are on 0.7+:"
            echo "      chrome://flags/#${FLAG} → Enabled"
            echo "    Or re-run with --force."
            return 0
        fi
        if ! version_ge "$ver" "0.7"; then
            echo "  – Skipping Chromium PipeWire camera flag: libcamera $ver has no IPU6/IPU7"
            echo "    support, and the flag would send Chromium down that broken path."
            return 0
        fi
    fi

    local -a profiles=()
    mapfile -t profiles < <(chromium_profile_dirs "$target_home")
    if [[ ${#profiles[@]} -eq 0 ]]; then
        echo "  – No Chromium-family browser profiles found (nothing to do)."
        return 0
    fi

    local blocked=0 line label dir state out rc
    for line in "${profiles[@]}"; do
        label=${line%%$'\t'*}
        dir=${line#*$'\t'}

        if [[ "$ACTION" == "status" ]]; then
            state=$(flag_state "$dir")
            printf '  %-20s %s\n' "$label:" "${state:-unreadable}"
            continue
        fi

        if browser_running "$dir"; then
            echo "  ⚠ $label is running — not touching its profile."
            echo "    It rewrites this file on exit and would discard the change."
            blocked=1
            continue
        fi

        # One backup per profile, taken before our first write. Never refreshed,
        # so it stays the pre-camera-relay original rather than yesterday's copy.
        [[ -f "$dir/Local State$BACKUP_SUFFIX" ]] || \
            cp -p "$dir/Local State" "$dir/Local State$BACKUP_SUFFIX" 2>/dev/null || true

        out=$(apply_flag "$dir" "$ACTION" 2>&1) && rc=0 || rc=$?
        case "$rc:$out" in
            0:changed)
                if [[ "$ACTION" == "enable" ]]; then
                    echo "  ✓ $label: PipeWire camera flag enabled"
                else
                    echo "  ✓ $label: PipeWire camera flag removed"
                fi ;;
            0:unchanged)
                echo "  ✓ $label: already correct" ;;
            *)
                echo "  ⚠ $label: could not update profile (${out:-unknown error})" ;;
        esac
    done

    if [[ "$ACTION" == "enable" ]]; then
        if [[ $blocked -eq 1 ]]; then
            echo
            echo "  Quit the browser above completely, then re-run:"
            echo "    $SELF"
            echo "  Or set chrome://flags/#${FLAG} to Enabled by hand."
        else
            echo "  Restart any open Chromium-family browser for this to take effect."
        fi
    fi
    return 0
}

main "$@"
