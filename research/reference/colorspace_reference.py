"""Generate colour-science reference values for TrellisCore's ColorSpace tests.

This is the independent side of the cross-check: it uses colour-science's own
colourspace definitions and conversion code, not a port of the Swift.

    python3 research/reference/colorspace_reference.py

writes TrellisCore/Tests/TrellisCoreTests/Fixtures/colorspace_reference.json.

    python3 research/reference/colorspace_reference.py --check

regenerates in memory and fails if the committed fixture differs beyond float
noise. CI runs this so the fixture can't silently drift from colour-science.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import colour

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "TrellisCore/Tests/TrellisCoreTests/Fixtures/colorspace_reference.json"

ADOBE_GAMMA = 563 / 256


def pure_power(gamma: float):
    """Odd-symmetric pure power curve pair (decode, encode), as Trellis defines it."""

    def decode(v):
        v = np.asarray(v, dtype=np.float64)
        return np.sign(v) * np.abs(v) ** gamma

    def encode(v):
        v = np.asarray(v, dtype=np.float64)
        return np.sign(v) * np.abs(v) ** (1 / gamma)

    return decode, encode


def with_power_curve(base: colour.RGB_Colourspace, name: str, gamma: float) -> colour.RGB_Colourspace:
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


def main() -> int:
    adobe = colour.RGB_COLOURSPACES["Adobe RGB (1998)"]
    bt709 = colour.RGB_COLOURSPACES["ITU-R BT.709"]

    # Matrices are always derived from the primaries. Note colour-science's
    # stock Adobe RGB (1998) uses the spec's published 5-decimal matrix instead, which
    # differs from the derived one by up to ~5e-6; with_power_curve() forces derivation.
    #
    # Conversions use the mirrored 563/256 power (Trellis's definition): colour-science's
    # built-in Adobe curve returns NaN for the tiny negative linear values a 3x3 matrix
    # can produce at black. The built-in curve is checked separately below.
    spaces = {
        "adobeRGB1998": with_power_curve(adobe, "Adobe RGB (1998) / gamma 563/256", ADOBE_GAMMA),
        "rec709Gamma24": with_power_curve(bt709, "Rec. 709 / gamma 2.4", 2.4),
        "rec709Gamma22": with_power_curve(bt709, "Rec. 709 / gamma 2.2", 2.2),
    }

    # Sample code values: grid corners, mid-greys, saturated and near-black colours.
    grid = np.linspace(0.0, 1.0, 5)
    samples = np.array(np.meshgrid(grid, grid, grid, indexing="ij")).reshape(3, -1).T
    extra = np.array(
        [
            [0.18, 0.18, 0.18],
            [0.001, 0.002, 0.003],
            [0.9, 0.1, 0.05],
            [0.05, 0.95, 0.1],
            [0.0, 1.0, 1.0],
            [0.7, 0.45, 0.3],
        ]
    )
    samples = np.vstack([samples, extra])

    conversions = []
    pairs = [
        ("rec709Gamma24", "adobeRGB1998"),
        ("adobeRGB1998", "rec709Gamma24"),
        ("rec709Gamma22", "adobeRGB1998"),
        ("adobeRGB1998", "rec709Gamma22"),
        ("rec709Gamma24", "rec709Gamma22"),
    ]
    for src, dst in pairs:
        out = colour.RGB_to_RGB(
            samples,
            spaces[src],
            spaces[dst],
            chromatic_adaptation_transform=None,
            apply_cctf_decoding=True,
            apply_cctf_encoding=True,
        )
        conversions.append(
            {
                "from": src,
                "to": dst,
                "input": samples.tolist(),
                "output": np.asarray(out).tolist(),
            }
        )

    transfer_inputs = np.linspace(0.0, 1.0, 21)
    data = {
        "generator": "research/reference/colorspace_reference.py",
        "colour_science_version": colour.__version__,
        "d65_xy": colour.CCS_ILLUMINANTS["CIE 1931 2 Degree Standard Observer"]["D65"].tolist(),
        "rgb_to_xyz": {
            "adobeRGB1998": colour.normalised_primary_matrix(adobe.primaries, adobe.whitepoint).ravel().tolist(),
            "rec709": colour.normalised_primary_matrix(bt709.primaries, bt709.whitepoint).ravel().tolist(),
        },
        "rec709_to_adobeRGB1998": colour.matrix_RGB_to_RGB(
            spaces["rec709Gamma24"], spaces["adobeRGB1998"], chromatic_adaptation_transform=None
        )
        .ravel()
        .tolist(),
        "adobeRGB1998_to_rec709": colour.matrix_RGB_to_RGB(
            spaces["adobeRGB1998"], spaces["rec709Gamma24"], chromatic_adaptation_transform=None
        )
        .ravel()
        .tolist(),
        "transfer": {
            "input": transfer_inputs.tolist(),
            # colour-science's built-in Adobe RGB (1998) decoding curve.
            "adobeRGB1998_decode": np.asarray(adobe.cctf_decoding(transfer_inputs)).tolist(),
            "gamma24_decode": np.asarray(pure_power(2.4)[0](transfer_inputs)).tolist(),
            "gamma22_decode": np.asarray(pure_power(2.2)[0](transfer_inputs)).tolist(),
        },
        "conversions": conversions,
    }

    # Sanity: colour-science's Adobe curve must be the 563/256 pure power.
    assert np.allclose(adobe.cctf_decoding(transfer_inputs), transfer_inputs**ADOBE_GAMMA, atol=1e-15, rtol=0)

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


def _diff(a, b, path, tol=1e-13):
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
