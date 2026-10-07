# Capture One export notes

What Capture One actually writes when an identity Hald goes through the Trellis
recipe. Clean-room: our own exports, inspected with
`trellis inspect`. The TIFF reader is extended only for what is recorded here.

## How to reproduce

```sh
swift run trellis hald --out work --with-validation
```

1. Import `work/identity-hald-L8.tif` (and `validation.tif`) into Capture One.
2. Image adjustments: no style. Input profile = embedded (Adobe RGB (1998)).
   Sharpening, noise reduction, clarity, structure, dehaze, vignetting, lens
   corrections and grain all off/zero.
3. Process recipe: TIFF, 16-bit, ICC profile Adobe RGB (1998), scale 100 %,
   output sharpening off, no watermark, no crop.
4. Export, then run:

```sh
swift run trellis inspect <exported>.tif
```

## Findings

Capture One 16.8.6.25 (macOS), 2026-10-07.

On import of a non-raw 16-bit TIFF, C1's defaults were already clean: ICC
profile "From File", film curve "Auto", sharpening/NR/clarity/structure/dehaze/
vignetting/grain/moiré all 0, no styles. `reset adjustments` keeps them that way.

| Property | Value | Trellis handles it? |
|---|---|---|
| Byte order | little-endian (II) | yes |
| Compression | 1 (none), recipe set to Uncompressed | yes |
| Planar config | 1 (interleaved) | yes |
| Samples / extra samples | 3 / none | yes |
| Bits / sample format | 16,16,16 / tag 339 absent (defaults to unsigned) | yes |
| Rows per strip / tiled | 1024 (> height, so one strip) / not tiled | yes |
| ICC profile name / size / matches by content | Adobe RGB (1998) / 560 B / yes | yes |
| Dimensions unchanged (512×512) | yes; validation stays 704×320 | yes |
| Default sharpening/NR on import? | none (all zero) | n/a |

Extra tags C1 adds: 271/272 (make/model), 274 (Orientation = 1), 700 (XMP),
34665 (EXIF IFD). They are ignored by the reader, which is fine.

**Identity pass-through accuracy** (raw code values, C1 output vs source):

- identity Hald L8: max |Δ| = 1 code (1.5e-5 on [0,1], ~64× under the 1/1023
  gate); mean |Δ| 0.86 code; 14% of samples exact; bias −0.86 code, so C1
  rounds down by 1 LSB (e.g. 65535 → 65534).
- validation.tif: max |Δ| = 1 code, mean 0.31.

So the reader needs no changes: no LZW, no tiling, no planar work for this recipe.
The 1-LSB downward bias is far below anything the identity validation could see.

Not yet tested: LZW/ZIP compression and tiled output (both available in the
recipe).

## Styled Hald: Creative Edits → Cozy Fall (2026-10-07)

Capture One's built-in Creative Edits style "Cozy Fall" was applied to the
identity Hald, then exported through the same recipe. As applied, the style
includes Highlight and Shadow recovery.

- Shift vs identity: max 0.49, mean 0.13 (on [0,1]). Black → (0.039, 0.040,
  0.056), mid grey → (0.600, 0.579, 0.559), white → (1.0, 0.989, 0.972).
- Export format identical to the identity run.

**Locality test.** Write a copy of the identity Hald with its pixel order
reversed. Push it through the same style, reverse the output back, and compare
to the forward run. A pure per-pixel colour transform gives identical output.

| Cozy Fall | max Δ (codes) | mean Δ | exact |
|---|---|---|---|
| as applied (with Highlight/Shadow recovery) | 1286 (1.96e-2) | 24.5 | 0.1 % |
| highlight + shadow recovery zeroed | **0** | 0 | **100 %** |

So **C1's Highlight/Shadow recovery is a spatial (local tone-mapping)
operator**, and no 3D LUT can represent it. Everything else in the style is
pure per-pixel colour and comes through bit-exact.

**A neighbour-residual check on the LUT grid does not catch this.** Here is the
6-face-neighbour residual on the 64³ grid:

| | rms | max |
|---|---|---|
| identity | 4.8e-6 | 7.6e-6 |
| Cozy Fall with HR/SR (spatial) | 3.27e-3 | 5.67e-2 |
| Cozy Fall, HR/SR zeroed (pure colour) | 2.83e-3 | 6.82e-2 |

Legitimate colour-editor curvature dominates the residual, so a threshold
can't separate the two. So Trellis does both of these:

- `trellis hald` also writes a pixel-reversed Hald. The user processes it with
  the same style, and validation compares it with the forward Hald. Any
  difference above 4 codes is reported as a spatial operator, naming the
  settings to check (Highlight, Shadow, Clarity, Structure, Dehaze).
- The residual check stays, but only for gross filters (sharpening, noise
  reduction, grain), which it still separates clearly from identity (flagged
  above rms 0.005).

## CLI validation run (M5, 2026-10-07)

First full run through the complete `trellis` CLI (`hald` → Capture One →
`validate` → `build`), Capture One 16.8.6.25 (macOS), session `Trellis`:

```sh
trellis hald --out work --with-validation --with-reversed
# process identity-hald-L8.tif, reversed-hald-L8.tif and validation.tif
# through the "Trellis Hald" recipe (same settings as above)
trellis validate identity-hald-L8.tif --reversed reversed-hald-L8.tif --identity
trellis build identity-hald-L8.tif --reversed reversed-hald-L8.tif \
    --modes anchor,rec709-2.4,rec709-2.2 --cube-size 33 --out cubes
```

`validate`: PASS — dimensions 512×512 (Hald level 8), profile Adobe RGB (1998)
by content, 16-bit. Locality **clean — max 0 codes** (a pure per-pixel look
round-trips bit-exact through C1). Residual rms 5.7e-6 (the 16-bit
quantisation floor, no gross filter). Identity **PASS — max |d| 0.000023 on
[0,1]** (≈1.5 16-bit codes, well under the 1/1023 gate; matches the 1-LSB
downward bias recorded above), mean ΔE2000 0.0013.

`build` wrote `<look>_<mode>_<size>.cube` for all three modes, 33³ each, with
the §5.7 header comments (Trellis version, source, input/output space +
transfer, gamut, date). Corners exact: black → 0.000000, white → 0.999985
(the 1-LSB C1 bias shows up as the look's white being 65534 instead of 65535).

Recipe note: the session's "Trellis Hald" recipe had `output sub folder` left
set to "Cozy Fall no HDR" from the styled run, so exports landed there rather
than in `Output/` — check the recipe's sub-folder setting before a run.

## Soft gamut compression on real looks (M4.2, 2026-10-07)

Three built-in Capture One 16.8.6 Creative Edits styles (Cozy Fall, Cool
Tones, Airy Summer) applied to clones of the identity Hald L8, exported
through the same recipe, baked at 33³ with both `--gamut clip` and
`--gamut compress` (threshold 1.0, calculated limits). The two handlers
always engage the same grid points — the out-of-Rec-709 population — and
differ only in *how* they land them back inside:

| Look | out-of-gamut (of 35,937) | max \|Δ\| clip→compress | mean \|Δ\| |
|---|---|---|---|
| Cozy Fall | 8,950 (25 %) | 0.125 | 3.8e-3 |
| Cool Tones | 993 (2.8 %) | 0.013 | 4.7e-5 |
| Airy Summer | 8,891 (25 %) | 0.096 | 1.7e-3 |

So the difference is invisible on low-saturation looks (Cool Tones: mean
4.7e-5) and clearly visible on stylised ones (Cozy Fall / Airy Summer clip a
quarter of the grid: the compression pulls the saturated greens/cyans in
smoothly toward white, the clip cuts them). Default stays `clip`; choosing
between them is the last open item of M4.2, to be judged in Resolve.
