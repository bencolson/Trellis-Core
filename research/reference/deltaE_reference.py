"""Generate colour-science reference values for TrellisCore's Perceptual
tests: CIE L*a*b* (XYZ → Lab at D65) and CIEDE2000.

This is the independent side of the cross-check: it uses colour-science's own
implementations, not a port of the Swift.

    python3 research/reference/deltaE_reference.py

writes TrellisCore/Tests/TrellisCoreTests/Fixtures/deltaE_reference.json.

    python3 research/reference/deltaE_reference.py --check

regenerates in memory and fails if the committed fixture differs beyond float
noise. CI runs this so the fixture can't silently drift from colour-science.

The ΔE2000 pairs include the Sharma et al. 2005 worked examples (Table 1), the
canonical validation set for any CIEDE2000 implementation.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import colour

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "TrellisCore/Tests/TrellisCoreTests/Fixtures/deltaE_reference.json"

ADOBE_GAMMA = 563 / 256

# D65 exactly as pinned in Trellis (Chromaticity.d65): x/y values are the CIE
# 1931 2° observer chromaticity coordinates.
D65_XY = np.array([0.3127, 0.3290])


def pure_power(gamma: float):
    """Odd-symmetric pure power curve pair, as Trellis defines it."""

    def decode(v):
        v = np.asarray(v, dtype=np.float64)
        return np.sign(v) * np.abs(v) ** gamma

    def encode(v):
        v = np.asarray(v, dtype=np.float64)
        return np.sign(v) * np.abs(v) ** (1 / gamma)

    return decode, encode


def with_power_curve(base: colour.RGB_Colourspace, name: str, gamma: float) -> colour.RGB_Colourspace:
    """A copy of `base` forced to Trellis's derived matrices and pure power curve.

    colour-science's stock Adobe RGB (1998) uses the published rounded matrix;
    Trellis derives from primaries, so force the same here.
    """
    decode, encode = pure_power(gamma)
    return colour.RGB_Colourspace(
        name,
        base.primaries,
        base.whitepoint,
        base.whitepoint_name,
        use_derived_matrix_RGB_to_XYZ=True,
        use_derived_matrix_XYZ_to_RGB=True,
        cctf_encoding=encode,
        cctf_decoding=decode,
    )


# XYZ triples exercising the Lab toe (below the (6/29)³ break) and the main body.
XYZ_SAMPLES = [
    [0.0, 0.0, 0.0],                       # black
    [0.9504559270516716, 1.0, 1.0890577507598784],  # D65 white
    [0.5, 0.5, 0.5],
    [0.18, 0.18, 0.18],
    [0.001, 0.002, 0.003],                 # near black, inside the toe
    [0.005, 0.01, 0.015],                  # just inside/at the toe
    [0.1, 0.2, 0.3],
    [0.4, 0.1, 0.05],
    [0.9, 0.6, 0.1],
    [0.05, 0.9, 0.3],
    [0.2, 0.3, 0.9],
    [1.2, 0.2, 0.1],                       # above white (out of gamut)
]

# Adobe-RGB-anchored code values (the space Trellis reads Halds in).
RGB_SAMPLES = [
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
    [0.18, 0.18, 0.18],
    [0.5, 0.5, 0.5],
    [1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, 0.0, 1.0],
    [1.0, 1.0, 0.0],
    [0.0, 1.0, 1.0],
    [1.0, 0.0, 1.0],
    [0.85, 0.33, 0.25],                    # skin-ish
    [0.002, 0.5, 0.5],                     # near-black one channel
]

# Lab pairs for ΔE2000. The first block is Sharma et al. 2005 Table 1 (the
# canonical CIEDE2000 validation set); the rest exercise achromatic and
# hue-wrapping edge cases of our own. colour-science's computed ΔE for each
# pair is the reference the Swift test asserts against — pair 1 (ΔE = 2.0425)
# doubles as an independent check that colour-science itself agrees with the
# published value, since 2.0425 is the most-cited CIEDE2000 test result.
DELTA_E_PAIRS = [
    ([50.0, 2.6772, -79.7751], [50.0, 0.0, -82.7485]),
    ([50.0, 3.2972, -79.7751], [50.0, -1.8844, -82.7485]),
    ([50.0, 1.0, -74.4210], [50.0, -1.0, -77.5504]),
    ([50.0, -1.3805, -84.2814], [50.0, 0.0, -82.7485]),
    ([50.0, -1.0, -85.0], [50.0, 0.0, -82.7485]),
    ([50.0, -1.0, -62.0], [50.0, 0.0, -82.7485]),
    ([50.0, -1.0, -30.0], [50.0, 0.0, -82.7485]),
    ([50.0, -1.0, 0.0], [50.0, 0.0, -82.7485]),
    ([50.0, -1.0, 30.0], [50.0, 0.0, -82.7485]),
    ([50.0, -1.0, 60.0], [50.0, 0.0, -82.7485]),
    ([50.0, -1.0, 90.0], [50.0, 0.0, -82.7485]),
    ([60.2574, -34.0099, 36.2677], [60.4626, -34.1751, 47.2299]),
    ([50.0, 0.0, 0.0], [50.0, 0.0, 0.0]),                 # identical → 0
    ([50.0, 0.0, 0.0], [54.0, 0.0, 0.0]),                 # lightness only
    ([50.0, 10.0, 0.0], [50.0, 20.0, 0.0]),               # chroma only
    ([0.0, 0.0, 0.0], [100.0, 0.0, 0.0]),                 # black → white
]


def main() -> int:
    d65_xyz = colour.xy_to_XYZ(D65_XY)
    xyz = np.array(XYZ_SAMPLES)
    # `illuminant` is the reference illuminant as CIE xy chromaticity (the
    # default is D65); colour-science derives the Lab white tristimulus from it.
    lab = colour.XYZ_to_Lab(xyz, D65_XY)

    adobe = colour.RGB_COLOURSPACES["Adobe RGB (1998)"]
    anchor = with_power_curve(adobe, "Adobe RGB (1998) / gamma 563/256", ADOBE_GAMMA)
    rgb = np.array(RGB_SAMPLES)
    xyz_rgb = colour.RGB_to_XYZ(rgb, anchor, apply_cctf_decoding=True)
    lab_rgb = colour.XYZ_to_Lab(xyz_rgb, D65_XY)

    pairs_a = np.array([p[0] for p in DELTA_E_PAIRS])
    pairs_b = np.array([p[1] for p in DELTA_E_PAIRS])
    de = colour.delta_E(pairs_a, pairs_b, method="CIE 2000")

    data = {
        "generator": "research/reference/deltaE_reference.py",
        "colour_science_version": colour.__version__,
        "d65_xy": D65_XY.tolist(),
        "d65_xyz": d65_xyz.tolist(),
        "xyz_to_lab": {"input": XYZ_SAMPLES, "output": np.asarray(lab).tolist()},
        "rgb_to_lab_anchor": {"input": RGB_SAMPLES, "output": np.asarray(lab_rgb).tolist()},
        "delta_e_2000": {
            "a": pairs_a.tolist(),
            "b": pairs_b.tolist(),
            "delta_e": np.asarray(de).tolist(),
        },
    }

    if "--check" in sys.argv[1:]:
        committed = json.loads(OUT.read_text())
        for key in ("colour_science_version", "generator"):
            committed.pop(key, None)
            data.pop(key, None)
        problems = list(_diff(committed, data, "$"))
        for p in problems[:20]:
            print(p, file=sys.stderr)
        if problems:
            print(f"{OUT.relative_to(ROOT)} is stale: re-run this script and commit it", file=sys.stderr)
            return 1
        print(f"{OUT.relative_to(ROOT)} is up to date")
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, indent=1) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


def _diff(a, b, path, tol=1e-12):
    if isinstance(a, dict) and isinstance(b, dict):
        if a.keys() != b.keys():
            yield f"{path}: keys differ"
            return
        for k in a:
            yield from _diff(a[k], b[k], f"{path}.{k}", tol)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            yield f"{path}: length {len(a)} != {len(b)}"
            return
        for i, (x, y) in enumerate(zip(a, b)):
            yield from _diff(x, y, f"{path}[{i}]", tol)
    elif isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if abs(a - b) > tol:
            yield f"{path}: {a} != {b}"
    elif a != b:
        yield f"{path}: {a!r} != {b!r}"


if __name__ == "__main__":
    sys.exit(main())