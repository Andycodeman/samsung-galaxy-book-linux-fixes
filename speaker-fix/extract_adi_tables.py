#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build max98390-galaxybook.bin from the user's own Windows amp driver.

The Windows amp driver ADIAmpDriver.sys (Analog Devices 1.0.0.44) initialises each
MAX98390 with a per-amp register table and loads one DSM coefficient table per amp
pair. It picks the table set from the Realtek codec's subsystem ID (issue #160).
This script reads the set for the user's own codec from the .sys on their Windows
partition, so no vendor binary is redistributed.

Supported codecs (see PROFILES): 144D:C1D8 Galaxy Book4 Ultra, 144D:C890 Galaxy
Book4 Pro 16".

Usage:
    python3 extract_adi_tables.py [-o max98390-galaxybook.bin] [--subsystem 0x144dc890] /mnt/windows/Windows/System32/DriverStore/FileRepository/adiampdriver.inf_amd64_*/ADIAmpDriver.sys
    sudo install -m 644 max98390-galaxybook.bin /lib/firmware/

Output format (little endian), parsed by max98390_hda_windows.c:
    "M98W", u16 version (1), u16 n_amps
    n_amps x { u16 n, n x { u16 reg, u16 val } }          per-amp byte registers
    u16 n_dsm, n_dsm x { u16 n, n x { u16 reg, u16 0, u32 val } }   DSM words
    u8 dsm_index[n_amps]                                   which DSM each amp gets
Amp index follows the I2C address order of the driver: 0x38, 0x39, 0x3C, 0x3D.
"""
import argparse
import glob
import hashlib
import struct

# Table offsets inside each verified ADIAmpDriver.sys, per codec subsystem ID.
# The driver maps the codec SUBSYS to a project ID and indexes six pointer arrays
# with it (project 2 = C1D8, project 3 = C890; decoded in issue #160). Every other
# project in the driver is left out until someone with that laptop tests it.
C1D8_ULTRA = {
    "model": "Galaxy Book4 Ultra (NP960XGL)",
    "amps": [(0x9B10, 35), (0x9BF0, 35), (0x9BA0, 17), (0x9C80, 17)],  # 0x38 0x39 0x3C 0x3D
    "dsm": [(0x9CD0, 95), (0x9FD0, 40)],                                # pair A (0x38/0x39), pair B
    "dsm_index": [0, 0, 1, 1],
}
C890_PRO16 = {
    "model": "Galaxy Book4 Pro 16-inch (NP960XGK)",
    "amps": [(0xA110, 35), (0xA1F0, 35), (0xA1A0, 17), (0xA280, 17)],
    "dsm": [(0xA2D0, 95), (0xA5D0, 40)],
    "dsm_index": [0, 0, 1, 1],
}
PROFILES = {
    # sha256 of ADIAmpDriver.sys 1.0.0.44 -> {codec subsystem id: profile}
    "b24fa0920808d3aa846a5afd973663242fce81d84d13f4836aff95f23ddb8b8e": {
        "0x144dc1d8": C1D8_ULTRA,
    },
    "95b7e6367125bca34ba48e1d32ba3bcb8beebc2473ac7f9bd627cf88b4431f71": {
        "0x144dc1d8": C1D8_ULTRA,
        "0x144dc890": C890_PRO16,
    },
}
SUPPORTED = sorted({sub for p in PROFILES.values() for sub in p})

# Registers that must differ between the left (slot 0) and right (slot 1) amp of a pair.
SLOT_REGS = {0x201B: (0x01, 0x02), 0x201D: (0x01, 0x02), 0x201F: (0xFE, 0xFD), 0x2021: (0x00, 0x01)}


def detect_codec_subsystem():
    found = []
    for p in sorted(glob.glob("/proc/asound/card*/codec#*")):
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith("Subsystem Id:"):
                        sub = line.split(":", 1)[1].strip().lower()
                        if sub in SUPPORTED:
                            return sub
                        found.append(sub)
        except OSError:
            pass
    det = ", ".join(found) if found else "none found in /proc/asound/card*/codec#*"
    raise SystemExit(
        f"refusing to build: no table profile for this machine's codec Subsystem Id "
        f"(detected: {det}; supported: {', '.join(SUPPORTED)}). "
        "Pass --subsystem to build for another machine."
    )


def byte_table(b, off, n):
    t = [struct.unpack_from("<HH", b, off + 4 * i) for i in range(n)]
    if struct.unpack_from("<HH", b, off + 4 * n) != (0, 0):
        raise SystemExit(f"byte table at 0x{off:X} is not zero-terminated")
    for reg, val in t:
        if not (0x2000 <= reg <= 0x24FF and val <= 0xFF):
            raise SystemExit(f"implausible entry {reg:#x}={val:#x} at 0x{off:X}")
    return t


def dsm_table(b, off, n):
    t = []
    for i in range(n):
        reg, pad, val = struct.unpack_from("<HHI", b, off + 8 * i)
        if pad != 0 or not (0x2100 <= reg <= 0x23FF) or reg % 4:
            raise SystemExit(f"implausible DSM entry {reg:#x} at 0x{off + 8 * i:X}")
        t.append((reg, val))
    return t


def main():
    ap = argparse.ArgumentParser(
        description="Build max98390-galaxybook.bin from the user's own ADIAmpDriver.sys."
    )
    ap.add_argument(
        "inputs",
        nargs="+",
        metavar="ADIAmpDriver.sys",
        help="One or more candidate ADIAmpDriver.sys paths (e.g. from a DriverStore glob)",
    )
    ap.add_argument(
        "-o",
        "--output",
        default="max98390-galaxybook.bin",
        help="Output firmware path (default: max98390-galaxybook.bin)",
    )
    ap.add_argument(
        "--subsystem",
        choices=SUPPORTED,
        help="Build for this codec Subsystem Id instead of the one in /proc/asound "
        "(for building on another machine)",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="Old spelling of --subsystem 0x144dc1d8 (Galaxy Book4 Ultra)",
    )
    args = ap.parse_args()

    if args.subsystem:
        sub = args.subsystem
    elif args.force:
        sub = "0x144dc1d8"
    else:
        sub = detect_codec_subsystem()

    chosen_b = None
    k = None
    rejected = []
    for path in args.inputs:
        with open(path, "rb") as f:
            b = f.read()
        digest = hashlib.sha256(b).hexdigest()
        if sub in PROFILES.get(digest, {}):
            chosen_b = b
            k = PROFILES[digest][sub]
            break
        rejected.append((path, digest))

    if chosen_b is None:
        details = "; ".join(f"{p} (sha256 {d})" for p, d in rejected)
        known = ", ".join(d[:8] + "…" for d, p in PROFILES.items() if sub in p)
        raise SystemExit(
            f"no verified tables for codec {sub} in: {details}. Offsets for {sub} are only "
            f"verified in ADIAmpDriver.sys 1.0.0.44 with sha256 {known}. "
            "Do not guess: report the version and sha256 in an issue."
        )

    b = chosen_b
    amps = [byte_table(b, o, n) for o, n in k["amps"]]
    dsms = [dsm_table(b, o, n) for o, n in k["dsm"]]

    # Sanity: L/R amps of each pair must be configured for different TDM slots.
    for idx, t in enumerate(amps):
        side = idx % 2
        regs = dict(t)
        for reg, vals in SLOT_REGS.items():
            if regs.get(reg) != vals[side]:
                raise SystemExit(f"amp {idx}: {reg:#x}={regs.get(reg)} (expected {vals[side]:#x})")

    blob = bytearray(b"M98W") + struct.pack("<HH", 1, len(amps))
    for t in amps:
        blob += struct.pack("<H", len(t)) + b"".join(struct.pack("<HH", r, v) for r, v in t)
    blob += struct.pack("<H", len(dsms))
    for t in dsms:
        blob += struct.pack("<H", len(t)) + b"".join(struct.pack("<HHI", r, 0, v) for r, v in t)
    blob += bytes(k["dsm_index"])
    with open(args.output, "wb") as f:
        f.write(blob)
    print(f"wrote {args.output} ({len(blob)} bytes) for {k['model']}, codec {sub}: "
          f"amps={[len(t) for t in amps]} "
          f"dsm={[len(t) for t in dsms]} sha256={hashlib.sha256(blob).hexdigest()[:16]}…")


if __name__ == "__main__":
    main()
