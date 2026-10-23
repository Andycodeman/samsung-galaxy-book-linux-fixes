#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Generate a libcamera Simple-IPA tuning file (BlackLevel + Ccm) from an
Intel IPU6 factory tuning file (.aiqb, "CPFF" container).

Usage:
    python3 aiqb_to_libcamera.py OV02C10_KBFC645_MTL.aiqb > ov02c10.yaml
    python3 aiqb_to_libcamera.py --dump OV02C10_KBFC645_MTL.aiqb

Record layout: see NOTES-aiqb-format.md. Record name IDs come from Intel's
public header ia_cmc_types.h (intel/ipu6-camera-bins, Apache-2.0).
"""
import argparse
import struct
import sys

NAME_IDS = {
    1: "comment", 2: "general_data", 3: "black_level", 7: "module_sensitivity",
    9: "noise", 13: "optics_and_mechanics", 15: "chromaticity_response",
    16: "flash_chromaticity", 17: "nvm_info", 19: "analog_gain_conversion",
    20: "digital_gain", 22: "geometric_distortion_correction2",
    25: "advanced_color_matrices", 26: "hdr", 28: "lens_shading_correction_4x4",
    29: "lateral_chromatic_aberration_correction", 31: "black_level_global",
    33: "lens_shading_correction_4x4_ratio", 34: "multi_gain_conversions",
    37: "media_format",
}


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def f32(b, o):
    return struct.unpack_from("<f", b, o)[0]


def read_records(b):
    """Return {name_id: (offset, size)} for the records inside the AIQB chunk."""
    if b[:4] != b"CPFF" or u32(b, 4) != len(b):
        raise SystemExit("not a CPFF/AIQB file (bad magic or size)")
    aiqb = b.find(b"AIQB", 0x18)
    if aiqb < 0:
        raise SystemExit("AIQB chunk not found")
    end = aiqb + u32(b, aiqb + 4)
    o = aiqb + 0x18  # 16-byte chunk header + 8 bytes of chunk metadata
    recs = {}
    while o < end:
        size = u32(b, o)
        name = u16(b, o + 6)
        if size < 8 or o + size > end:
            raise SystemExit(f"bad record at 0x{o:X} (size {size})")
        recs[name] = (o, size)
        o += size
    if o != end:
        raise SystemExit("record walk did not end on the chunk boundary")
    return recs


def general_data(b, recs):
    o = recs[2][0] + 8
    return {"width": u16(b, o), "height": u16(b, o + 2), "bit_depth": u16(b, o + 4),
            "color_order": u16(b, o + 6)}


def black_level(b, recs):
    """Mean non-zero black level across all exposure/gain LUTs (sensor bit depth)."""
    rec, size = recs[31]
    base = rec + 8
    n = u32(b, base)
    vals = []
    for i in range(n):
        e = base + 16 + i * 72
        if e + 72 > rec + size:
            break
        vals += [v for v in struct.unpack_from("<16f", b, e + 8) if v > 0]
    return sum(vals) / len(vals), n


def color_matrices(b, recs):
    """Traditional 3x3 CCM per characterized light source (record 25)."""
    base = recs[25][0] + 8
    n_ls, n_sec = u16(b, base), u16(b, base + 2)
    g = base + 4 + 4 * n_sec
    group = 24 + (1 + n_sec) * 36  # header + traditional CCM + one CCM per hue sector
    out = []
    for _ in range(n_ls):
        out.append({
            "light_source": u32(b, g),
            "r_per_g": f32(b, g + 4), "b_per_g": f32(b, g + 8),
            "cie_x": f32(b, g + 12), "cie_y": f32(b, g + 16),
            "ct": u32(b, g + 20),
            "ccm": list(struct.unpack_from("<9f", b, g + 24)),
        })
        g += group
    return sorted(out, key=lambda m: m["ct"])


def awb_locus(b, recs):
    """Neutral (grey) locus from record 15: list of (cie_x, cie_y, r_per_g, b_per_g).

    Layout (verified on OV02C10_KBFC645_MTL): u16 num_points, u16 unknown, then
    num_points x {u16 cie_x/65536, u16 cie_y/65536, u16 r_per_g/1024, u16 b_per_g/1024}.
    More sets follow (same xy, slightly different responses); only the first is used.
    """
    base = recs[15][0] + 8
    n = u16(b, base)
    pts = []
    for i in range(n):
        x, y, rg, bg = struct.unpack_from("<4H", b, base + 4 + 8 * i)
        pts.append((x / 65536, y / 65536, rg / 1024, bg / 1024))
    return pts


LSC_ONE = 2048  # grid value for gain 1.0 (centre of every grid reads ~2048)


def lens_shading(b, recs, name=28):
    """Lens shading grids (record 28 = full LSC, 33 = colour-only ratio).

    Layout (verified): char grid_indices[4][4] (2x2 Bayer cells -> channel index),
    u16 num_light_srcs, u16 num_channels, u16 grid_w, u16 grid_h, then per light source
    {u32 light_src_type, f32 r_per_g, f32 b_per_g, f32 cie_x, f32 cie_y, u16 field,
     u16 grid[num_channels][grid_h][grid_w]}.  Gain = value / 2048.
    Channel order follows the sensor colour_order (general_data); for color_order 0 the
    2x2 cell is [[Gr, R], [B, Gb]] -> channels 0=Gr 1=R 2=B 3=Gb (check on the device!).
    """
    rec, size = recs[name]
    base = rec + 8
    idx = list(b[base:base + 16])
    n_ls, n_ch, w, h = struct.unpack_from("<4H", b, base + 16)
    o = base + 24
    sets = []
    for _ in range(n_ls):
        ls_type, rg, bg = u32(b, o) & 0xFFFF, f32(b, o + 4), f32(b, o + 8)
        g = o + 22
        grids = []
        for c in range(n_ch):
            vals = struct.unpack_from(f"<{w * h}H", b, g + c * w * h * 2)
            grids.append([[vals[r * w + col] / LSC_ONE for col in range(w)] for r in range(h)])
        sets.append({"light_source": ls_type, "r_per_g": rg, "b_per_g": bg, "grids": grids})
        o = g + n_ch * w * h * 2
    if o > rec + size:
        raise SystemExit("LSC record overran its size")
    return {"grid_indices": idx, "width": w, "height": h, "sets": sets}


def resample(grid, w, h):
    """Bilinear resample of a 2-D list to w x h (corner-aligned)."""
    gh, gw = len(grid), len(grid[0])
    out = []
    for r in range(h):
        y = r * (gh - 1) / (h - 1)
        y0 = int(y)
        y1 = min(y0 + 1, gh - 1)
        fy = y - y0
        row = []
        for c in range(w):
            x = c * (gw - 1) / (w - 1)
            x0 = int(x)
            x1 = min(x0 + 1, gw - 1)
            fx = x - x0
            top = grid[y0][x0] * (1 - fx) + grid[y0][x1] * fx
            bot = grid[y1][x0] * (1 - fx) + grid[y1][x1] * fx
            row.append(round(top * (1 - fy) + bot * fy, 4))
        out.append(row)
    return out


def write_lsc_json(path, b, recs, ccms, size, name):
    import json
    lsc = lens_shading(b, recs, name)
    ct_of = {m["light_source"]: m["ct"] for m in ccms}
    w, h = size if size else (lsc["width"], lsc["height"])
    out = {"source_record": name, "gain_one": LSC_ONE, "grid_indices": lsc["grid_indices"],
           "channel_names_if_grbg": ["Gr", "R", "B", "Gb"], "width": w, "height": h, "sets": []}
    for s in lsc["sets"]:
        out["sets"].append({
            "ct": ct_of.get(s["light_source"]), "light_source": s["light_source"],
            "r_per_g": round(s["r_per_g"], 4), "b_per_g": round(s["b_per_g"], 4),
            "grids": [resample(g, w, h) for g in s["grids"]],
        })
    out["sets"].sort(key=lambda s: s["ct"] or 0)
    with open(path, "w") as f:
        json.dump(out, f)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("aiqb")
    ap.add_argument("--dump", action="store_true", help="list records and parsed values")
    ap.add_argument("--lsc-json", metavar="PATH", help="also write lens shading grids as JSON")
    ap.add_argument("--lsc-ratio", action="store_true",
                    help="export record 33 (colour-only shading) instead of 28 (full)")
    ap.add_argument("--lsc-size", metavar="WxH", help="resample LSC grids, e.g. 17x17")
    ap.add_argument("--ccm-strength", type=float, default=1.0, metavar="ALPHA",
                    help="blend factory CCM with identity (0..1, e.g. 0.80) for Simple IPA")
    ap.add_argument("--wb-gains", metavar="R,G,B",
                    help="per-row RGB white-balance trim (e.g. 1.06,0.86,1.04) for Grey-World AWB")
    a = ap.parse_args()
    b = open(a.aiqb, "rb").read()
    recs = read_records(b)
    gd = general_data(b, recs)
    bl, n_bl = black_level(b, recs)
    ccms = color_matrices(b, recs)
    locus = awb_locus(b, recs)
    scale = 1 << (16 - gd["bit_depth"])
    # AWB gain limits: gains needed to neutralise the extreme illuminants of the locus,
    # plus 10% headroom (same method as libcamera's OV01A10 tuning patch).
    max_gain_r = round(1.1 / min(p[2] for p in locus), 2)
    max_gain_b = round(1.1 / min(p[3] for p in locus), 2)

    if a.lsc_json:
        size = tuple(int(v) for v in a.lsc_size.lower().split("x")) if a.lsc_size else None
        write_lsc_json(a.lsc_json, b, recs, ccms, size, 33 if a.lsc_ratio else 28)
        print(f"wrote {a.lsc_json}", file=sys.stderr)

    if a.dump:
        for name, (o, s) in sorted(recs.items(), key=lambda r: r[1][0]):
            print(f"0x{o:06X} name={name:3d} {NAME_IDS.get(name, '?'):42s} size={s}")
        print(gd)
        print(f"black level {bl:.2f} ({gd['bit_depth']}-bit, {n_bl} LUTs) -> {round(bl) * scale} (16-bit)")
        for m in ccms:
            print(f"ct={m['ct']} ls={m['light_source']} R/G={m['r_per_g']:.4f} B/G={m['b_per_g']:.4f} "
                  f"xy=({m['cie_x']:.4f},{m['cie_y']:.4f}) ccm={[round(v, 4) for v in m['ccm']]}")
        print("AWB neutral locus (x, y, R/G, B/G):")
        for p in locus:
            print("  " + ", ".join(f"{v:.4f}" for v in p))
        print(f"AWB limits: maxGainR={max_gain_r} maxGainB={max_gain_b}")
        lsc = lens_shading(b, recs)
        print(f"LSC: {len(lsc['sets'])} light sources, {len(lsc['sets'][0]['grids'])} channels, "
              f"{lsc['width']}x{lsc['height']}, grid_indices={lsc['grid_indices'][:8]}")
        for s in lsc["sets"]:
            corners = [round(g[0][0], 2) for g in s["grids"]]
            centres = [round(g[lsc['height'] // 2][lsc['width'] // 2], 2) for g in s["grids"]]
            print(f"  ls={s['light_source']} corner gains={corners} centre={centres}")
        return

    for m in ccms:
        for r in range(3):
            s = sum(m["ccm"][3 * r:3 * r + 3])
            if abs(s - 1.0) > 0.02:
                print(f"warning: ct={m['ct']} row {r} sums to {s:.4f}", file=sys.stderr)

    wb_gains = [float(x) for x in a.wb_gains.split(",")] if a.wb_gains else [1.0, 1.0, 1.0]
    if len(wb_gains) != 3:
        raise SystemExit("--wb-gains requires 3 comma-separated floats: R,G,B")
    alpha = a.ccm_strength
    for m in ccms:
        raw = m["ccm"]
        adj = []
        for r in range(3):
            for c_idx in range(3):
                ident = 1.0 if r == c_idx else 0.0
                val = (alpha * raw[3 * r + c_idx] + (1.0 - alpha) * ident) * wb_gains[r]
                adj.append(val)
        m["ccm_adj"] = adj

    p = print
    p("# SPDX-License-Identifier: CC0-1.0")
    p("%YAML 1.1")
    p("---")
    p(f"# Generated by aiqb_to_libcamera.py from {a.aiqb.split('/')[-1]}")
    p(f"# Sensor {gd['width']}x{gd['height']}, {gd['bit_depth']}-bit. Traditional CCMs from record 25.")
    if alpha != 1.0 or wb_gains != [1.0, 1.0, 1.0]:
        p(f"# Simple IPA compensation: ccm_strength={alpha:.2f}, wb_gains={wb_gains}")
    p("version: 1")
    p("algorithms:")
    p("  - BlackLevel:")
    p(f"      blackLevel: {round(bl) * scale}")
    p("  - Awb:")
    p("      # Gain limits from the factory neutral locus (record 15) + 10% headroom.")
    p("      # Only supported by newer libcamera Simple IPA Awb; uncomment if accepted.")
    p(f"      # maxGainR: {max_gain_r}")
    p(f"      # maxGainB: {max_gain_b}")
    p("  - Ccm:")
    p("      ccms:")
    for m in ccms:
        c = [f"{v:8.4f}" for v in m["ccm_adj"]]
        p(f"        - ct: {m['ct']}  # R/G {m['r_per_g']:.4f}  B/G {m['b_per_g']:.4f}")
        p(f"          ccm: [ {', '.join(c[0:3])},")
        p(f"                 {', '.join(c[3:6])},")
        p(f"                 {', '.join(c[6:9])} ]")
    p("  - Agc:")
    p("...")


if __name__ == "__main__":
    main()
