"""Generate reference values for TrellisCore's soft gamut compression.

Independent numpy port of the compression `Bake.gamutCompress` (which acts on
linear Rec. 709, after the Adobe → Rec 709 matrix): per-pixel achromatic value
`a = max(r, g, b)`, per-channel distance `d = (a − c)/a`, a smooth homotopy on
both `a` and the worst distance `m` from the threshold to the Adobe RGB gamut
boundary (limits), pulling the pixel straight toward the compressed
achromatic value. None of the Swift is consulted.

    python3 research/reference/gamut_reference.py

writes TrellisCore/Tests/TrellisCoreTests/Fixtures/gamut_reference.json:

    limits            per-channel far side of the Adobe RGB gamut in linear
                      Rec 709, over the cube's corners (max of (a − c)/a);
    max_a             largest achromatic value any Adobe corner reaches;
    adobe_to_rec709   the derived primaries matrix (for the matrix itself);
    points            representative linear-Rec 709 inputs → compressed
                      outputs at the default threshold (1.0);
    curve             the same inputs through threshold 0.9, exercising the
                      graded (non-degenerate) part of the curve.

    python3 research/reference/gamut_reference.py --check

regenerates in memory and fails if the committed fixture drifted. CI runs
this so the fixture can't silently change.

Sanity note at the end: OpenColorIO's built-in ACES gamut compression applied
to the same out-of-gamut inputs. The two methods deliberately differ (ACES
uses fixed, tuned parameters and a different curve; ours uses calculated
limits), so differences are expected and recorded, not asserted.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import colour

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "TrellisCore/Tests/TrellisCoreTests/Fixtures/gamut_reference.json"

THRESHOLD = 1.0
GRADED_THRESHOLD = 0.9
TOL = 1e-12

CORNERS = [
    [0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1],
    [1, 1, 0], [1, 0, 1], [0, 1, 1], [1, 1, 1],
]


def adobe_to_rec709() -> np.ndarray:
    adobe = colour.RGB_COLOURSPACES["Adobe RGB (1998)"]
    bt709 = colour.RGB_COLOURSPACES["ITU-R BT.709"]
    m_709_xyz = colour.normalised_primary_matrix(bt709.primaries, bt709.whitepoint)
    m_xyz_adobe = np.linalg.inv(colour.normalised_primary_matrix(adobe.primaries, adobe.whitepoint))
    return np.linalg.inv(m_xyz_adobe @ m_709_xyz)  # Adobe (linear) → Rec 709 (linear)


def limits_and_max_a(m: np.ndarray) -> tuple[np.ndarray, float]:
    limits = np.zeros(3)
    max_a = 0.0
    for corner in CORNERS:
        v = m @ np.array(corner, dtype=np.float64)
        a = float(np.max(v))
        max_a = max(max_a, a)
        if a <= 0:
            continue
        d = (a - v) / a
        limits = np.maximum(limits, np.maximum(d, 0.0))
    return limits, max_a


def smoothstep(x: float) -> float:
    u = min(max(x, 0.0), 1.0)
    return u * u * (3 - 2 * u)


def compress(v, threshold: float, limits: np.ndarray, max_a: float) -> np.ndarray:
    v = np.asarray(v, dtype=np.float64)
    a = float(np.max(v))
    if a <= 0.0:
        return v.copy()
    d = (a - v) / a
    m = float(np.max(d))
    if a <= threshold and m <= threshold:
        return v.copy()
    ap = threshold + (1 - threshold) * smoothstep((a - threshold) / (max_a - threshold)) if a > threshold else a
    k = 1.0
    if m > threshold:
        h = threshold + (1 - threshold) * smoothstep((m - threshold) / (float(np.max(limits)) - threshold))
        k = h / m
    return np.clip(ap - d * k * ap, 0.0, 1.0)


def sample_points(m: np.ndarray) -> list[np.ndarray]:
    """Representative linear-Rec 709 inputs: neutrals + black, the Adobe
    corners (greens/cyans out of gamut), the green out-of-gamut sweep, and a
    luma sweep through the threshold region."""
    points: list[np.ndarray] = []
    for x in (0.0, 0.03, 0.18, 0.5, 1.0):
        points.append(np.array([x, x, x]))
    for corner in CORNERS:
        points.append(m @ np.array(corner, dtype=np.float64))
    for r in (-0.05, -0.1, -0.16, -0.19):
        points.append(np.array([r, 1.0, 0.05]))
    for lum in (0.6, 0.9, 0.98, 1.0, 1.05, 1.1, 1.18):
        points.append(np.array([-0.12, lum, 0.04]))
    return [np.array(p, dtype=np.float64) for p in points]


def ocio_compare(points: np.ndarray, ours: np.ndarray) -> float:
    """OpenColorIO's built-in ACES gamut compression on the same inputs.
    Returns max |Δ| vs ours (expected to be non-trivial — see module doc), or
    NaN when OCIO doesn't expose a gamut compression."""
    try:
        import PyOpenColorIO as ocio
    except ImportError:
        return float("nan")
    transformer = getattr(ocio, "GamutCompressTransform", None)
    transform = None
    if transformer is not None:
        transform = transformer()
    else:
        style = "ACES-LMT - ACES 1.3 Reference Gamut Compression"
        available = [b[0] for b in ocio.BuiltinTransformRegistry.getBuiltins(ocio.BuiltinTransformRegistry())]
        if style in available:
            transform = ocio.BuiltinTransform(style=style)
    if transform is None:
        return float("nan")
    config = ocio.Config.CreateFromStream(
        "ocio_profile_version: 2\nstrictparsing: false\nsearch_path: ''\n"
        "roles:\n  default: raw\n"
        "displays: {}\n"
        "colorspaces:\n - !<ColorSpace>\n   name: raw\n   isdata: true\n"
    )
    group = ocio.GroupTransform(transforms=[transform])
    arr = np.asarray(points, dtype=np.float32).copy()
    config.getProcessor(group).getOptimizedCPUProcessor(ocio.OPTIMIZATION_NONE).applyRGB(arr)
    return float(np.max(np.abs(arr.astype(np.float64) - ours)))


def main() -> int:
    m = adobe_to_rec709()
    limits, max_a = limits_and_max_a(m)
    points = sample_points(m)

    data = {
        "generator": "research/reference/gamut_reference.py",
        "colour_science_version": colour.__version__,
        "threshold": THRESHOLD,
        "limits": limits.tolist(),
        "max_a": max_a,
        "adobe_to_rec709": m.ravel().tolist(),
        "points": [{"in": p.tolist(), "out": compress(p, THRESHOLD, limits, max_a).tolist()} for p in points],
        "curve": {
            "threshold": GRADED_THRESHOLD,
            "points": [{"in": p.tolist(), "out": compress(p, GRADED_THRESHOLD, limits, max_a).tolist()} for p in points],
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
        # OCIO sanity comparison (expected differences; recorded, not a gate).
        out_of_gamut = [p["in"] for p in data["points"] if np.max(p["in"]) > 0 and np.min(p["in"]) < 0]
        ours = np.array([compress(p, THRESHOLD, limits, max_a) for p in out_of_gamut])
        delta = ocio_compare(out_of_gamut, ours)
        if not np.isnan(delta):
            print(f"sanity: OCIO ACES gamut compression vs ours on {len(out_of_gamut)} "
                  f"out-of-gamut inputs — max |Δ| {delta:.3e} "
                  "(expected: methods differ by design — ACES uses fixed tuned "
                  "parameters and its own curve, ours uses calculated limits)")
        print(f"{OUT.relative_to(ROOT)} is up to date")
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, indent=1) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


def _diff(a, b, path, tol=TOL):
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