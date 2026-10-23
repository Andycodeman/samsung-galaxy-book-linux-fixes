# Format of Intel IPU6 `.aiqb` Files

Notes on decoding `OV02C10_KBFC645_MTL.aiqb` (425,960 bytes), shipped in the Windows
camera driver package (`ov02c10.inf`). Sensor: OmniVision OV02C10, module: KBFC645.

## Container: CPFF
- `0x00`: ASCII `"CPFF"`, `u32` total size (= file size), 12 zero bytes, `0x14`: `u32` checksum.
- Chunks start at `0x18`: `tag[4]`, `u32 size` (includes the 16-byte chunk header):
  - `LCMC` (293,200 B) -> contains `DFLT` -> contains `AIQB` (each nested header is 16 B).
  - `LAIQ` (34,384 B), `LISP` (98,144 B), `LTHR` (208 B) — unparsed.
- Inside `AIQB`: 16-byte chunk header + 8 bytes chunk metadata, followed by records.

## Records inside AIQB
8-byte record header: `u32 size`, `u16 format_id` (100/101/102/200), `u16 name_id`.
`name_id` values match enum `cmc_name_id` from Intel's public header `ia_cmc_types.h`
(`intel/ipu6-camera-bins`, Apache-2.0).

| `name_id` | Name | Size | Usage |
|---|---|---|---|
| 1 | comment | 224 | Build strings: IQStudio 23.31.3.0, LibIQ 2.0.359.0 |
| 2 | general_data | 40 | 1928x1092, 10-bit, color_order 0 |
| 3 | black_level | 656 | Legacy black level |
| 7 | module_sensitivity | 16 | Base ISO 29 |
| 9 | noise | 32 | Noise model coefficients |
| 13 | optics_and_mechanics | 88 | Lens parameters |
| 15 | chromaticity_response | 712 | AWB neutral locus (R/G, B/G) |
| 22 | geometric_distortion_correction2 | 10,360 | Lens distortion grid |
| 25 | advanced_color_matrices | 4,728 | **CCMs** (used by `aiqb_to_libcamera.py`) |
| 28 / 33 | lens_shading_correction_4x4 / _ratio | 118,584 each | **LSC tables** (full / colour-only) |
| 29 | lateral_chromatic_aberration_correction | 35,736 | Chromatic aberration |
| 31 | black_level_global | 2,920 | **Optical-black pedestal** (used) |

## Record 31 — `black_level_global`
`u32 num_luts` (40), `u32 padding`, 8-byte pointer; followed by `num_luts` x 72 B:
`u32 exposure_time_us`, `f32 total_gain`, `f32 black_level[4][4]`.
All LUT values read ~64 on the sensor's 10-bit scale -> 4096 in libcamera's 16-bit space.

## Record 25 — `advanced_color_matrices`
`u16 num_light_srcs` (5), `u16 num_sectors` (24), `u32 angles[num_sectors]` (15°...360°).
Followed by per-light-source blocks (924 B each = 24 + 25 x 36):
`u32 light_src_type`, `f32 r_per_g`, `f32 b_per_g`, `f32 cie_x`, `f32 cie_y`, `u32 cct`,
`f32 ccm[9]` (traditional 3x3 CCM), `f32 ccm[24][9]` (one per hue sector).
libcamera Simple IPA uses the traditional 3x3 CCM interpolated by CCT. Raw rows sum to ~1.0.

| CCT | Sensor R/G | Sensor B/G |
|---|---|---|
| 2669 | 0.8662 | 0.4289 |
| 3556 | 0.6389 | 0.4642 |
| 3816 | 0.5296 | 0.4456 |
| 4503 | 0.5288 | 0.5980 |
| 5892 | 0.4472 | 0.7164 |

## Record 15 — `chromaticity_response` (AWB neutral locus)
`u16 num_points` (7), `u16 unknown` (2), followed by `num_points` x 8 B:
`u16 cie_x/65536`, `u16 cie_y/65536`, `u16 r_per_g/1024`, `u16 b_per_g/1024`.

| x | y | R/G | B/G | Approx. Illuminant |
|---|---|---|---|---|
| 0.304 | 0.314 | 0.385 | 0.756 | ~7500 K |
| 0.320 | 0.330 | 0.416 | 0.695 | D65 (~6500 K) |
| 0.362 | 0.364 | 0.504 | 0.573 | ~4500 K |
| 0.389 | 0.382 | 0.575 | 0.511 | ~3800 K |
| 0.409 | 0.393 | 0.637 | 0.473 | ~3450 K |
| 0.458 | 0.411 | 0.853 | 0.399 | Illuminant A (~2850 K) |
| 0.491 | 0.415 | 1.128 | 0.365 | ~2300 K |

AWB gain limits with 10% headroom: `maxGainR = 2.86`, `maxGainB = 3.01`.

## Records 28 and 33 — Lens Shading Correction (LSC)
- `char grid_indices[4][4]` = `[[0,1],[2,3]]` across 2x2 Bayer cell (0xFF padding).
- `u16 num_light_srcs` (5), `u16 num_channels` (4), `u16 grid_w` (63), `u16 grid_h` (47).
- Per light source (22-byte header = `SIZEOF cmc_lsc_grid`):
  `u32 light_src_type`, `f32 r_per_g`, `f32 b_per_g`, `f32 cie_x`, `f32 cie_y`, `u16 field`,
  followed by `u16 grid[4][47][63]`.
- Scale: 2048 = gain 1.0 (centre of every grid reads ~2048).
- Record 28: full shading (corners reach 5.5x–6.6x gain).
- Record 33: colour-only ratio (~1.00–1.21x gain).
- Export as JSON: `python3 aiqb_to_libcamera.py --lsc-json lsc.json [--lsc-size 17x17] [--lsc-ratio] <file.aiqb>`

## Precedent
libcamera accepted OV01A10 tuning derived from Intel factory `.aiqb` data
(https://patchwork.libcamera.org/patch/26643/, CC0 license). The `.aiqb` binary is
proprietary vendor data — do not commit the raw `.aiqb` to public git; commit only the
derived parameters and open-source parser.
