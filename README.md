# TrellisCore

The colour engine and command-line tool for turning a **Capture One** look into
**3D LUTs (.cube)**, so a look built on stills can be used on video in DaVinci
Resolve.

Open source (Apache-2.0), clean-room, and built by a working photographer/DIT
for stills-into-motion people.

**Core principle:** every colour space is explicit, pinned and labelled at both
ends. No "Rec 709" without saying which gamma. That's the fix for LUTs that
come out over-saturated and too contrasty, as if they needed applying at 50%.

> **Status:** in development. Hald generation, reading and validation work;
> baked Rec 709 output and the `build` / `validate` commands are next.

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
- [ ] Baked Rec 709 / 2.4 and 2.2 output
- [ ] `trellis build` and `trellis validate`

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
swift run trellis hald --out work --with-validation   # identity + reversed Hald, validation chart
swift run trellis inspect work/identity-hald-L8.tif   # describe a TIFF's layout and profile
```

Reference values come from [`colour-science`](https://www.colour-science.org):

```sh
pip install -r research/requirements.txt
python3 research/reference/colorspace_reference.py --check
python3 research/reference/deltaE_reference.py --check
```

## Using it from another package

```swift
.package(url: "https://github.com/bencolson/trellis-core", branch: "main")
// target dependency:
.product(name: "TrellisCore", package: "trellis-core")
```

## Licence

[Apache-2.0](LICENSE), except Adobe's Adobe RGB (1998) ICC profile, which is
redistributed unmodified under Adobe's terms. See [`NOTICE`](NOTICE).
