#!/usr/bin/env bash
# Regression tests for distro detection in webcam-fix-libcamera/install.sh.
#
# The script used to identify the distro purely by which package manager
# binary existed, checking `pacman` first. That heuristic is wrong on any
# distro that ships another distro's package manager — and Fedora does: it
# packages a real `pacman` (e.g. pacman-7.0.0-5.fc43 on Fedora 43). A Fedora
# host with it installed was greeted with "✓ Arch-based detected" and the
# install died at step [9/14] trying Arch package names:
#
#   error: target not found: git
#   error: target not found: meson
#
# Detection now reads /etc/os-release (ID, then the ID_LIKE ancestry list)
# and probes for package managers only when os-release gives no answer.
# These tests drive the extracted detect_distro() against fixture os-release
# files and a stub-only PATH, so they need no root and touch no system state.
#
# Usage: ./test-distro-detection.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$ROOT/webcam-fix-libcamera/install.sh"
PASS=0
FAIL=0

ok()  { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "test-distro-detection ($INSTALL)"

# The function is pure bash (only builtins), so the subshell can run with
# PATH containing nothing but the stub package managers — `command -v` then
# sees exactly the set each scenario declares, never the host's binaries.
FN_SRC=$(sed -n '/^detect_distro()/,/^}/p' "$INSTALL")
if [[ -z "$FN_SRC" ]]; then
    bad "detect_distro() not found in install.sh — tests cannot run"
    echo; echo "$PASS passed, $FAIL failed"
    exit 1
fi

# run_detect <os-release file or -> [pm...] → "DISTRO|DISTRO_LABEL" on stdout.
# "-" means no os-release (a path that does not exist). Exits 9 on rejection.
run_detect() {
    local os_release="$1"; shift
    [[ "$os_release" == "-" ]] && os_release="$TMP/does-not-exist"
    local bindir="$TMP/bin-$RANDOM$RANDOM" pm
    mkdir -p "$bindir"
    for pm in "$@"; do
        printf '#!/bin/sh\nexit 0\n' > "$bindir/$pm"
        chmod +x "$bindir/$pm"
    done
    (
        set -e
        PATH="$bindir"
        DISTRO=""; DISTRO_LABEL=""
        eval "$FN_SRC"
        detect_distro "$os_release" >/dev/null 2>&1 || exit 9
        echo "$DISTRO|$DISTRO_LABEL"
    )
}

check() {
    local desc="$1" want="$2" got
    got=$(run_detect "${@:3}")
    if [[ "$got" == "$want"* ]]; then
        ok "$desc → ${got%%|*}"
    else
        bad "$desc: want '$want*', got '${got:-<rejected>}'"
    fi
}

fixture() {
    local name="$1"; shift
    printf '%s\n' "$@" > "$TMP/$name"
    echo "$TMP/$name"
}

# ── 1. The bug itself ────────────────────────────────────────────────────────
echo
echo "Fedora with pacman installed stays Fedora"

FEDORA=$(fixture fedora 'NAME="Fedora Linux"' 'ID=fedora' \
    'PRETTY_NAME="Fedora Linux 43 (Workstation Edition)"')
check "Fedora 43 with both dnf and pacman" "fedora|Fedora/DNF-based" \
    "$FEDORA" dnf pacman

# ── 2. Every supported distro still detects ──────────────────────────────────
echo
echo "supported distros and derivatives"

ARCH=$(fixture arch 'ID=arch' 'PRETTY_NAME="Arch Linux"')
check "Arch" "arch|Arch-based" "$ARCH" pacman

ENDEAVOUR=$(fixture endeavouros 'ID=endeavouros' 'ID_LIKE=arch' \
    'PRETTY_NAME="EndeavourOS"')
check "EndeavourOS (ID_LIKE=arch)" "arch|Arch-based" "$ENDEAVOUR" pacman

NOBARA=$(fixture nobara 'ID=nobara' 'ID_LIKE="fedora"' \
    'PRETTY_NAME="Nobara Linux 42"')
check "Nobara (ID_LIKE=fedora)" "fedora|Fedora/DNF-based" "$NOBARA" dnf

UBUNTU=$(fixture ubuntu 'ID=ubuntu' 'ID_LIKE=debian' \
    'PRETTY_NAME="Ubuntu 24.04.2 LTS"')
check "Ubuntu" "ubuntu|Ubuntu/Ubuntu-based" "$UBUNTU" apt

POP=$(fixture pop 'ID=pop' 'ID_LIKE="ubuntu debian"' \
    'PRETTY_NAME="Pop!_OS 22.04 LTS"')
check "Pop!_OS" "ubuntu|Ubuntu/Ubuntu-based" "$POP" apt

MINT=$(fixture mint 'ID=linuxmint' 'ID_LIKE="ubuntu debian"' \
    'PRETTY_NAME="Linux Mint 22"')
check "Linux Mint" "ubuntu|Ubuntu/Ubuntu-based" "$MINT" apt

# An Ubuntu descendant known only through ID_LIKE keeps the descriptive label.
ZORIN=$(fixture zorin 'ID=zorin' 'ID_LIKE="ubuntu debian"' \
    'PRETTY_NAME="Zorin OS 17"')
check "Zorin (ID_LIKE ubuntu before debian)" "ubuntu|Ubuntu-based (Zorin OS 17)" \
    "$ZORIN" apt

DEBIAN=$(fixture debian 'ID=debian' 'PRETTY_NAME="Debian GNU/Linux 13"')
check "Debian" "debian|Debian-based" "$DEBIAN" apt

# ── 3. Fallback when os-release is missing ───────────────────────────────────
echo
echo "package-manager fallback without os-release"

check "pacman only" "arch|Arch-based" - pacman
check "dnf only" "fedora|Fedora/DNF-based" - dnf
check "apt only" "debian|Debian-based" - apt

# ── 4. Unsupported systems are rejected ──────────────────────────────────────
echo
echo "unsupported"

GENTOO=$(fixture gentoo 'ID=gentoo' 'PRETTY_NAME="Gentoo Linux"')
if run_detect "$GENTOO" >/dev/null 2>&1; then
    bad "Gentoo without a supported package manager was accepted"
else
    ok "Gentoo without a supported package manager is rejected"
fi
if run_detect - >/dev/null 2>&1; then
    bad "no os-release and no package manager was accepted"
else
    ok "no os-release and no package manager is rejected"
fi

# ── 5. install.sh actually uses the function ─────────────────────────────────
# Guards against the block being reverted to a bare package-manager probe
# while the (then-orphaned) function keeps these tests green.
echo
echo "wiring"

if grep -qE '^detect_distro$' "$INSTALL"; then
    ok "install.sh calls detect_distro at top level"
else
    bad "install.sh does not call detect_distro"
fi
probes=$(grep -c 'command -v pacman' "$INSTALL" || true)
fn_start=$(grep -n '^detect_distro()' "$INSTALL" | cut -d: -f1)
fn_end=$(awk "NR>$fn_start && /^}/{print NR; exit}" "$INSTALL")
outside=$(grep -n 'command -v pacman' "$INSTALL" \
    | awk -F: -v s="$fn_start" -v e="$fn_end" '$1 < s || $1 > e' | wc -l)
if [[ "$outside" == "0" && "$probes" != "0" ]]; then
    ok "every pacman probe lives inside detect_distro's fallback"
else
    bad "$outside pacman probe(s) outside detect_distro — os-release no longer wins"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
