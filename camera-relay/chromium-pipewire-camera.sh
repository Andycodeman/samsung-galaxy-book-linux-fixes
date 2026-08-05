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
# Browser config directory names, matched against three packaging roots rather
# than written out as full paths. Spelling out every combination is what left
# the previous list with native Vivaldi but not the snap, and no Opera at all:
# each new browser needed three entries and nobody adds all three.
#
# Deliberately absent:
#   Edge     — ships no enable-webrtc-pipewire-camera flag; nothing to write.
#   Electron — Slack, Discord, VS Code and friends keep a Local State too, but
#              they never process about:flags, so an entry there is dead weight
#              in someone else's config file. They need
#              --enable-features=WebRTCPipeWireCamera on the command line.
chromium_profile_dirs() {
    local home="$1" root name dir label kind
    local -a names=(
        google-chrome google-chrome-beta google-chrome-unstable
        chromium
        BraveSoftware/Brave-Browser
        vivaldi
        opera opera-beta opera-developer opera-gx
    )
    local -a seen=()

    # "$home/.config" plus every snap and flatpak private home. The globs are
    # guarded because an unmatched glob stays literal under bash.
    for root in "$home/.config" "$home"/snap/*/current/.config "$home"/.var/app/*/config; do
        [[ -d "$root" ]] || continue
        case "$root" in
            "$home"/snap/*)   kind=" (snap)" ;;
            "$home"/.var/app/*) kind=" (flatpak)" ;;
            *)                kind="" ;;
        esac
        for name in "${names[@]}"; do
            dir="$root/$name"
            [[ -f "$dir/Local State" ]] || continue
            # A snap's "current" is a symlink to a revision; without this the
            # same profile can be reported twice under two paths.
            dir=$(cd "$dir" 2>/dev/null && pwd -P) || continue
            [[ " ${seen[*]-} " == *" $dir "* ]] && continue
            seen+=("$dir")
            case "$name" in
                google-chrome)              label="Chrome" ;;
                google-chrome-beta)         label="Chrome Beta" ;;
                google-chrome-unstable)     label="Chrome Unstable" ;;
                chromium)                   label="Chromium" ;;
                BraveSoftware/Brave-Browser) label="Brave" ;;
                vivaldi)                    label="Vivaldi" ;;
                opera)                      label="Opera" ;;
                opera-beta)                 label="Opera Beta" ;;
                opera-developer)            label="Opera Developer" ;;
                opera-gx)                   label="Opera GX" ;;
                *)                          label="$name" ;;
            esac
            printf '%s\t%s\n' "$label$kind" "$dir"
        done
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
    local dir="$1" target pid appid

    # A flatpak browser records its *sandbox* PID in SingletonLock, which on the
    # host is an unrelated process — for a freshly started app, a low PID like 2,
    # i.e. a root-owned kernel thread. `kill -0` on that fails with EPERM, which
    # reads identically to "no such process", so the PID check below concludes
    # "not running" and we write into a live profile. That is the dangerous
    # direction: the write looks successful and the browser discards it on exit.
    # Ask flatpak, which knows what it is running.
    if [[ "$dir" == */.var/app/* ]]; then
        appid=${dir#*/.var/app/}
        appid=${appid%%/*}
        if command -v flatpak >/dev/null 2>&1; then
            if flatpak ps --columns=application 2>/dev/null | grep -qxF "$appid"; then
                return 0
            fi
            return 1
        fi
        # No flatpak CLI to ask: the lock's PID is meaningless here, so treat a
        # present lock as "running" and skip rather than risk a silent no-op.
        [[ -L "$dir/SingletonLock" ]] && return 0
        return 1
    fi

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
hit = [x for x in labs if isinstance(x, str) and pattern.match(x)]
had = len(hit) > 0

# "@2" is Chromium for "the user explicitly chose Disabled". Anything else that
# matches — "@1", or the bare flag name — means enabled.
was_disabled = any(x.endswith("@2") for x in hit)

# Same three words `camera-relay doctor` prints. One fact should not have two
# vocabularies depending on which tool you happen to ask.
if action == "status":
    print("DISABLED" if was_disabled else ("ENABLED" if hit else "not set"))
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

# Distinguished from a plain "changed" so the caller can own up to overriding a
# deliberate choice rather than reporting it as routine.
print("reversed" if (action == "enable" and was_disabled) else "changed")
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
            0:reversed)
                # The profile said Disabled on purpose — quite possibly following
                # this project's own earlier "leave it OFF" advice, which was
                # right for libcamera 0.2.0 and wrong here. Overriding it is
                # correct on 0.7+, but doing so silently is not.
                echo "  ✓ $label: PipeWire camera flag enabled"
                echo "    (it was explicitly set to Disabled — that preference has been"
                echo "     reversed; the original is saved as 'Local State$BACKUP_SUFFIX')" ;;
            0:unchanged)
                echo "  ✓ $label: already correct" ;;
            *)
                echo "  ⚠ $label: could not update profile (${out:-unknown error})" ;;
        esac

        # The backup exists to undo *our* edit. Once the flag is back out, it is
        # a stale copy of the user's browser config sitting in their profile
        # directory forever — so clear it on the way out, but only after a
        # disable that actually succeeded.
        if [[ "$ACTION" == "disable" && "$rc" == "0" ]]; then
            rm -f "$dir/Local State$BACKUP_SUFFIX"
        fi
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
