#!/usr/bin/env bash
# Regression tests for the hybrid-GPU EGL vendor pin.
#
# libcamera's Software ISP debayers through EGL, and GLVND picks the vendor ICD
# by filename order — NVIDIA's 10_nvidia.json sorts ahead of Mesa's
# 50_mesa.json. Under systemd (which inherits none of the session's EGL state)
# the debayer therefore lands on NVIDIA's driver, fails, and the camera goes
# black with the privacy LED lit and the relay reporting STREAMING.
#
# Two things have to hold, and both are easy to break silently:
#   1. Only a mixed NVIDIA-proprietary + Mesa setup gets a pin. Pinning a Mesa
#      ICD on an NVIDIA-only box would break a camera that works today.
#   2. The pin must come with LIBCAMERA_SOFTISP_MODE=gpu on the unit. The
#      installers write cpu to /etc/environment.d for the PipeWire path, the
#      user manager inherits it, and cpu touches no EGL — so without the
#      unit-level override the pin is present and inert.
#
# Usage: ./test-egl-vendor-pin.sh
# Requires no camera hardware, no GPU, and touches no system state.

set -uo pipefail

RELAY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/camera-relay"
PASS=0
FAIL=0

ok()   { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  – skipped: $*"; }

# Pull a single function out of the relay script so we can exercise it directly
# without running the whole command dispatcher.
extract_fn() {
    sed -n "/^$1()/,/^}/p" "$RELAY"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "test-egl-vendor-pin ($RELAY)"

# ── 1. Topology table ─────────────────────────────────────────────────────────
# find_mesa_egl_vendor is stubbed to a sentinel so this exercises the *decision*
# — which topologies deserve a pin — independently of which ICDs the machine
# running the tests happens to have installed. That separation is the point:
# detection is keyed on render nodes, not on the presence of 10_nvidia.json, so
# a box with one i915 node and an NVIDIA ICD lying around is single-GPU.
echo
echo "topology → pin decision"

topology_case() {
    local desc="$1" want="$2" nodes="$3" got rc
    got=$(
        set -euo pipefail
        eval "$(extract_fn detect_egl_vendor_pin)"
        render_node_drivers() { [[ -n "$nodes" ]] && printf '%s\n' "$nodes"; return 0; }
        find_mesa_egl_vendor() { echo "MESA_ICD"; }
        detect_egl_vendor_pin
    ) && rc=0 || rc=$?
    local verdict="nopin"
    [[ $rc -eq 0 && "$got" == "MESA_ICD" ]] && verdict="pin"
    if [[ "$verdict" == "$want" ]]; then
        ok "$(printf '%-26s %s' "$desc" "$want")"
    else
        bad "$(printf '%-26s expected %s, got %s' "$desc" "$want" "$verdict")"
    fi
}

# Single GPU — a pin is redundant at best.
topology_case "i915 only"          nopin "renderD128 i915"
topology_case "xe only"            nopin "renderD128 xe"
topology_case "amdgpu only"        nopin "renderD128 amdgpu"
# NVIDIA-only: pinning Mesa here would point EGL at a driver that cannot drive
# the hardware and break a working camera. This one must never regress to "pin".
topology_case "nvidia only"        nopin "renderD128 nvidia"
topology_case "two nvidia nodes"   nopin "renderD128 nvidia
renderD129 nvidia"
# Both Mesa — no vendor ordering problem to solve.
topology_case "i915 + nouveau"     nopin "renderD128 i915
renderD129 nouveau"
# No GPU at all: the debayer cannot run, but that is not this function's problem.
topology_case "no render nodes"    nopin ""
# An unreadable driver link must not be mistaken for a Mesa node.
topology_case "nvidia + unknown"   nopin "renderD128 nvidia
renderD129 unknown"

# The mixed case this whole feature exists for.
topology_case "i915 + nvidia"      pin   "renderD128 i915
renderD129 nvidia"
topology_case "amdgpu + nvidia"    pin   "renderD128 amdgpu
renderD129 nvidia"
topology_case "xe + nvidia-drm"    pin   "renderD128 xe
renderD129 nvidia-drm"
topology_case "i915 + nvidia + unk" pin  "renderD128 i915
renderD129 nvidia
renderD130 unknown"

# ── 2. find_mesa_egl_vendor against real ICDs ─────────────────────────────────
# The target is derived, not hardcoded to 50_mesa.json: the numeric prefix is a
# GLVND load-order hint and distros renumber it.
echo
echo "Mesa ICD discovery"

mesa_icd=$(
    set -uo pipefail
    eval "$(extract_fn find_mesa_egl_vendor)"
    find_mesa_egl_vendor
) || mesa_icd=""

if [[ -z "$mesa_icd" ]]; then
    if compgen -G "/usr/share/glvnd/egl_vendor.d/*.json" > /dev/null \
       || compgen -G "/etc/glvnd/egl_vendor.d/*.json" > /dev/null; then
        bad "ICDs are installed but no Mesa vendor file was found"
    else
        skip "no GLVND vendor ICDs installed on this machine"
    fi
else
    if [[ -f "$mesa_icd" ]] && grep -q 'libEGL_mesa' "$mesa_icd"; then
        ok "found a real Mesa ICD by content: $mesa_icd"
    else
        bad "returned $mesa_icd, which does not dispatch to libEGL_mesa"
    fi
fi

# ── 3. What actually lands in the service unit ────────────────────────────────
# The pairing from the header: a pin without LIBCAMERA_SOFTISP_MODE=gpu is inert
# on any machine whose /etc/environment.d says cpu, which is exactly the machine
# the installers write that file on.
echo
echo "generated service unit"

# cmd_enable_persistent probes the system hard before it writes anything. Stub
# every probe so the test is hermetic, point SERVICE_DIR at a temp dir, and
# neuter systemctl so nothing on the host is enabled or reloaded.
gen_unit() {
    local pin="$1" glxinfo_says="$2"
    local outdir="$TMP/unit-$RANDOM"
    mkdir -p "$outdir/bin"
    if [[ -n "$glxinfo_says" ]]; then
        printf '#!/bin/sh\necho "OpenGL renderer string: %s"\n' "$glxinfo_says" \
            > "$outdir/bin/glxinfo"
        chmod +x "$outdir/bin/glxinfo"
    fi
    (
        set -euo pipefail
        # shellcheck disable=SC1090
        source "$RELAY" -h >/dev/null 2>&1 || true
        PATH="$outdir/bin:$PATH"
        SERVICE_DIR="$outdir"
        is_persistent() { return 1; }
        require_gst_tools() { return 0; }
        detect_ipa_path() { return 1; }
        detect_gst_plugin_path() { return 1; }
        detect_libcamera_lib_path() { return 1; }
        systemctl() { return 0; }
        if [[ -n "$pin" ]]; then
            detect_egl_vendor_pin() { echo "$pin"; }
        else
            detect_egl_vendor_pin() { return 1; }
        fi
        cmd_enable_persistent --yes >/dev/null 2>&1
    ) || { echo "GENERATION FAILED"; return 1; }
    cat "$outdir/camera-relay.service" 2>/dev/null
}

unit=$(gen_unit "/tmp/mesa_icd.json" "") || unit=""
if [[ -z "$unit" ]]; then
    bad "hybrid: unit generation failed"
else
    if grep -q '^Environment=__EGL_VENDOR_LIBRARY_FILENAMES=/tmp/mesa_icd.json$' <<< "$unit"; then
        ok "hybrid: unit pins the EGL vendor"
    else
        bad "hybrid: unit is missing the EGL vendor pin"
    fi
    # The blocking half. Staying silent here is not the same as choosing gpu:
    # silence inherits cpu from /etc/environment.d and the pin does nothing.
    if grep -q '^Environment=LIBCAMERA_SOFTISP_MODE=gpu$' <<< "$unit"; then
        ok "hybrid: unit states gpu, outranking any inherited cpu"
    else
        bad "hybrid: unit does not state LIBCAMERA_SOFTISP_MODE=gpu — pin would be inert"
    fi
fi

unit=$(gen_unit "" "NVIDIA GeForce RTX 4070 Laptop GPU/PCIe/SSE2") || unit=""
if [[ -z "$unit" ]]; then
    bad "nvidia-only: unit generation failed"
else
    if grep -q '^Environment=LIBCAMERA_SOFTISP_MODE=cpu$' <<< "$unit"; then
        ok "nvidia-only: falls back to CPU debayer"
    else
        bad "nvidia-only: expected LIBCAMERA_SOFTISP_MODE=cpu"
    fi
    if grep -q '__EGL_VENDOR_LIBRARY_FILENAMES' <<< "$unit"; then
        bad "nvidia-only: unit pinned a vendor ICD it has no iGPU for"
    else
        ok "nvidia-only: no vendor pin"
    fi
fi

# Mesa-only needs no override of either kind. /proc/driver/nvidia is real state
# we cannot stub, so skip rather than report a bogus failure on an NVIDIA host.
if [[ -d /proc/driver/nvidia ]]; then
    skip "mesa-only case: /proc/driver/nvidia exists on this host"
else
    unit=$(gen_unit "" "Mesa Intel(R) Arc(tm) Graphics (MTL)") || unit=""
    if [[ -z "$unit" ]]; then
        bad "mesa-only: unit generation failed"
    elif grep -q 'LIBCAMERA_SOFTISP_MODE\|__EGL_VENDOR_LIBRARY_FILENAMES' <<< "$unit"; then
        bad "mesa-only: unit set a GPU override it does not need"
    else
        ok "mesa-only: no GPU overrides"
    fi
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
