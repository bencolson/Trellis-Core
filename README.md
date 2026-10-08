# TrellisCore

The colour engine and command-line tool for turning a **Capture One** look into
**3D LUTs (.cube)**, so a look built on stills can be used on video in DaVinci
Resolve.

Open source (Apache-2.0), clean-room, and built by a working photographer/DIT
for stills-into-motion people.

**Core principle:** every colour space is explicit, pinned and labelled at both
ends. No "Rec 709" without saying which gamma.

> **Status:** in development. Halds, reading, validation, baked Rec 709 output
> and the `build` / `validate` commands work end to end, verified against a
> real Capture One export.

## How it works

1. `trellis hald` writes an identity Hald (16-bit TIFF, tagged Adobe RGB (1998)),
   plus a pixel-reversed copy and a validation chart.
2. You apply your look to them in Capture One and export through the Trellis
   recipe (TIFF, 16-bit, Adobe RGB (1998), 100 %, no sharpening).
3. Trellis checks what came back (profile, bit depth, spatial filters, local
   tone mapping) and rebuilds the look as a 3D LUT.
4. It bakes .cube files for the space you'll apply them in, with the exact
   input and output encodings written into each file's header.

## Colour spaces

| | Primaries | White | Transfer |
|---|---|---|---|
| Anchor (what Capture One exports) | Adobe RGB (1998) | D65 | pure power 563/256 (2.19921875) |
| Video | Rec. 709 | D65 | pure power 2.4 (BT.1886, zero black) |
| Desktop/web | Rec. 709 | D65 | pure power 2.2 |

Matrices are derived from the primaries in code and tested against the
published values and against `colour-science`. Both spaces are D65, so no
chromatic adaptation is involved.

## Roadmap

- [x] Colour spaces and conversions
- [x] Hald generator, unmanaged 16-bit TIFF I/O, Adobe RGB (1998) ICC
- [x] Hald reader → look LUT, .cube writer, validation (profile, bit depth,
      spatial filters, local tone mapping, identity ΔE2000)
- [x] Baked Rec 709 / 2.4 and 2.2 output
- [x] `trellis build` and `trellis validate`

## Layout

```
Package.swift            SwiftPM manifest (TrellisCore, trellis CLI, tests)
TrellisCore/             Colour maths, Hald, TIFF/ICC, LUT, .cube, validation. No UI.
trellis-cli/             Command-line front end
research/reference/      Python (colour-science) reference values for the tests
docs/                    Capture One export notes
```

## Building

Requires Swift 5.9+ (Xcode 15+ on macOS 14+). Also builds and tests on Linux.

```sh
swift build
swift test
swift run trellis spaces                              # colour spaces and matrices in use
swift run trellis hald --out work --with-validation --with-reversed
swift run trellis build work/identity-hald-L8.tif --reversed work/reversed-hald-L8.tif \
    --modes anchor,rec709-2.4,rec709-2.2 --out work/cubes
swift run trellis validate work/identity-hald-L8.tif --reversed work/reversed-hald-L8.tif --identity
swift run trellis inspect work/identity-hald-L8.tif   # describe a TIFF's layout and profile
```

Reference values come from [`colour-science`](https://www.colour-science.org);
the bake chain is additionally cross-checked against
[OpenColorIO](https://opencolorio.org):

```sh
pip install -r research/requirements.txt
python3 research/reference/colorspace_reference.py --check
python3 research/reference/deltaE_reference.py --check
python3 research/reference/bake_reference.py --check
python3 research/reference/ocio_bake_check.py
python3 research/reference/gamut_reference.py --check
```

`trellis build --gamut compress` swaps the hard clip for soft gamut
compression (out-of-gamut colours pulled toward the white point, limits
calculated from the Adobe RGB → Rec 709 boundary); it defaults to `clip`.
The compression default is provisional until real looks have been judged.

## Using it from another package

```swift
.package(url: "https://github.com/bencolson/trellis-core", branch: "main")
// target dependency:
.product(name: "TrellisCore", package: "trellis-core")
```

## Acknowledgements

- **[Lattice](https://videovillage.co/lattice/)** by Video Village was the
  main inspiration. It showed how good a dedicated Mac tool for inspecting
  and converting LUTs can be, and how much it helps when every input and
  output colour space is stated plainly. Trellis aims for the same clarity
  for the stills-to-motion handoff. If you need the cat's pyjamas, this is
  the one. Trellis isn't affiliated with Video Village, and no Lattice code
  or file internals were used.
- **[colour-science](https://www.colour-science.org)** supplies the reference
  values every colour-maths test is checked against.
- **[OpenColorIO](https://opencolorio.org)** provides the independent
  cross-check of the bake chain.
- **Hald CLUTs**, the identity-image technique Eskil Steenberg devised, are
  what make it possible to capture a look from a raw processor in the
  first place.
- **Adobe** published the Cube LUT format specification and the Adobe RGB
  (1998) ICC profile bundled here (see [`NOTICE`](NOTICE)).

## Licence

[Apache-2.0](LICENSE), except Adobe's Adobe RGB (1998) ICC profile, which is
redistributed unmodified under Adobe's terms. See [`NOTICE`](NOTICE).
