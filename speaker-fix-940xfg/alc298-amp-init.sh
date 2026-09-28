#!/bin/bash
#
# alc298-amp-init.sh — Initialize internal speaker amps on
# Samsung Galaxy Book3 Pro 14" (940XFG, ALC298, SSID 0x144dc882).
#
# This board has no SND_PCI_QUIRK entry in the kernel's ALC298 fixup table
# (sound/hda/codecs/realtek/alc269.c), so the codec's internal class-D amps
# at NIDs 0x38, 0x39, 0x3C, 0x3D never get initialized at boot, leaving the
# internal speakers silent.
#
# This script writes the same COEF init sequence that Windows performs,
# matching upstream V2_4_AMPS layout (which the 16" Book3 Pro NP964XFG uses)
# but with the SKU-specific {0x239e, 0x0004} enable extension that mainline
# V2_4 omits — that is the missing piece for the 14" 940XFG variant.
#
# Run at boot via systemd; re-run on resume from sleep via the system-sleep
# hook installed by this package.
#
# Source intel: https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/44

set -e

# Locate the ALC298 codec — almost always /dev/snd/hwC0D0, but tolerate cards
# being renumbered on systems with extra audio devices.
DEV=""
for d in /sys/class/sound/hwC*D*; do
    [ -r "$d/vendor_id" ] || continue
    if [ "$(cat "$d/vendor_id")" = "0x10ec0298" ] && \
       [ "$(cat "$d/subsystem_id")" = "0x144dc882" ]; then
        DEV="/dev/snd/$(basename "$d")"
        break
    fi
done

if [ -z "$DEV" ]; then
    echo "alc298-amp-init: no ALC298 codec with SSID 0x144dc882 found, exiting" >&2
    exit 0   # exit 0 so systemd doesn't log a failure on hardware that already works
fi

if ! command -v hda-verb >/dev/null 2>&1; then
    echo "alc298-amp-init: hda-verb not found (install alsa-tools)" >&2
    exit 1
fi

NID_PROC=0x20

# ---------------------------------------------------------------------------
# Realtek COEF write helpers
# ---------------------------------------------------------------------------
# hda-verb encodes 4-bit verb in the high nibble of "verb" + 8-bit upper
# payload in the low nibble of verb + 8-bit lower payload as the param arg.
# Writing a 16-bit COEF value requires splitting hi/lo across the args.

set_idx() { hda-verb "$DEV" $NID_PROC 0x500 "$1" >/dev/null; }

set_val16() {
    local v=$1
    local hi=$(( (v >> 8) & 0xff ))
    local lo=$(( v & 0xff ))
    hda-verb "$DEV" $NID_PROC \
        "$(printf '0x%x' $((0x400 | hi)))" \
        "$(printf '0x%x' $lo)" >/dev/null
}

write_coef() { set_idx "$1"; set_val16 "$2"; }

# Indirect amp write pack:
#   COEF[0x23] = subindex   (16-bit)
#   COEF[0x25] = value      (16-bit)
#   COEF[0x26] = 0xb011     (trigger)
write_pack() {
    write_coef 0x23 "$1"
    write_coef 0x25 "$2"
    write_coef 0x26 0xb011
}

select_amp() { write_coef 0x22 "$1"; }

# ---------------------------------------------------------------------------
# Per-amp init sequences — match upstream V2_4_AMPS for these NIDs
# ---------------------------------------------------------------------------

# Main amps (NIDs 0x38, 0x39): 18-pair init, 0x23ba=0x0094
init_main_left() {
    select_amp 0x38
    write_pack 0x23e1 0x0000; write_pack 0x2012 0x006f; write_pack 0x2014 0x0000
    write_pack 0x201b 0x0001; write_pack 0x201d 0x0001; write_pack 0x201f 0x00fe
    write_pack 0x2021 0x0000; write_pack 0x2022 0x0010; write_pack 0x203d 0x0005
    write_pack 0x203f 0x0003; write_pack 0x2050 0x002c; write_pack 0x2076 0x000e
    write_pack 0x207c 0x004a; write_pack 0x2081 0x0003; write_pack 0x2399 0x0003
    write_pack 0x23a4 0x00b5; write_pack 0x23a5 0x0001; write_pack 0x23ba 0x0094
    write_coef 0x89 0x0000
}

init_main_right() {
    select_amp 0x39
    write_pack 0x23e1 0x0000; write_pack 0x2012 0x006f; write_pack 0x2014 0x0000
    write_pack 0x201b 0x0002; write_pack 0x201d 0x0002; write_pack 0x201f 0x00fd
    write_pack 0x2021 0x0001; write_pack 0x2022 0x0010; write_pack 0x203d 0x0005
    write_pack 0x203f 0x0003; write_pack 0x2050 0x002c; write_pack 0x2076 0x000e
    write_pack 0x207c 0x004a; write_pack 0x2081 0x0003; write_pack 0x2399 0x0003
    write_pack 0x23a4 0x00b5; write_pack 0x23a5 0x0001; write_pack 0x23ba 0x0094
    write_coef 0x89 0x0000
}

# Secondary amps (NIDs 0x3C, 0x3D): 15-pair init, 0x23ba=0x008d (no 0x2399/23a4/23a5)
init_sec_left() {
    select_amp 0x3C
    write_pack 0x23e1 0x0000; write_pack 0x2012 0x006f; write_pack 0x2014 0x0000
    write_pack 0x201b 0x0001; write_pack 0x201d 0x0001; write_pack 0x201f 0x00fe
    write_pack 0x2021 0x0000; write_pack 0x2022 0x0010; write_pack 0x203d 0x0005
    write_pack 0x203f 0x0003; write_pack 0x2050 0x002c; write_pack 0x2076 0x000e
    write_pack 0x207c 0x004a; write_pack 0x2081 0x0003; write_pack 0x23ba 0x008d
    write_coef 0x89 0x0000
}

init_sec_right() {
    select_amp 0x3D
    write_pack 0x23e1 0x0000; write_pack 0x2012 0x006f; write_pack 0x2014 0x0000
    write_pack 0x201b 0x0002; write_pack 0x201d 0x0002; write_pack 0x201f 0x00fd
    write_pack 0x2021 0x0001; write_pack 0x2022 0x0010; write_pack 0x203d 0x0005
    write_pack 0x203f 0x0003; write_pack 0x2050 0x002c; write_pack 0x2076 0x000e
    write_pack 0x207c 0x004a; write_pack 0x2081 0x0003; write_pack 0x23ba 0x008d
    write_coef 0x89 0x0000
}

# Enable: V2 enable_seq + the {0x239e, 0x0004} write that V2_4 upstream omits.
enable_amp() {
    select_amp "$1"
    write_pack 0x203a 0x0081
    write_pack 0x23ff 0x0001
    write_pack 0x239e 0x0004
}

# Disable: the exact inverse, matching upstream alc298_samsung_v2_disable_amps().
# Upstream runs this across every amp *before* writing any init sequence — see
# the "Disable speaker amps before init to prevent any physical damage" comment
# in alc298_samsung_v2_init_amps() — because the init writes retune the DSM
# excursion, boost and limiter parameters, which must not land on an amp whose
# output stage is live. Relevant here on the resume hook and on any re-run while
# audio is playing, where the amps are still enabled from before.
disable_amp() {
    select_amp "$1"
    write_pack 0x23ff 0x0000
    write_pack 0x203a 0x0080
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
# Mute every amp before retuning it (upstream order).
disable_amp 0x38
disable_amp 0x39
disable_amp 0x3C
disable_amp 0x3D

init_main_left
init_main_right
init_sec_left
init_sec_right

enable_amp 0x38
enable_amp 0x39
enable_amp 0x3C
enable_amp 0x3D

# Assert speaker pin output and unmute (idempotent — safe to repeat).
hda-verb "$DEV" 0x17 SET_PIN_WIDGET_CONTROL 0x40 >/dev/null
hda-verb "$DEV" 0x17 SET_AMP_GAIN_MUTE       0xb000 >/dev/null

logger -t alc298-amp-init "Initialized ALC298 internal speaker amps on $DEV"
