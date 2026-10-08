"""Generate colour-science reference values for TrellisCore's Bake tests.

This is the independent side of the cross-implementation check: it builds the
same synthetic look LUT and applies the same bake chains, using colour-science
for the primaries matrices and its own numpy port of the tetrahedral
interpolation and power curves — none of the Swift is consulted.

    python3 research/reference/bake_reference.py

writes TrellisCore/Tests/TrellisCoreTests/Fixtures/bake_reference.json:

    look        the 8³ synthetic look LUT (Adobe RGB / γ563/256 code values),
                values of the analytic function `synthetic_look` sampled on the
                grid — this is what both the Swift and this script read;
    modes      the 5³ baked LUT each mode produces from that look (anchor,
                rec709-2.4, rec709-2.2) — the numbers `BakeTests` asserts
                against at 1e-6.

    python3 research/reference/bake_reference.py --check

regenerates in memory and fails if the committed fixture differs beyond float
noise. CI runs this so the fixture can't silently drift.

The chain matches `Bake`: video decode → 3×3 to Adobe → 563/256 encode →
tetrahedral look sample → 563/256 decode → 3×3 to videospace → video encode →
hard clip after the final encode.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import colour

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "TrellisCore/Tests/TrellisCoreTests/Fixtures/bake_reference.json"

ADOBE_GAMMA = 563 / 256
LOOK_SIZE = 8
BAKE_SIZE = 5
LUT_VALUES_TOL = 1e-12
# Encoded code values get the same tolerance as the Swift tests' codeValueTolerance:
# matrix products leave ~1e-16 of float noise in linear light (and it differs by
# CPU/BLAS path), and a power-curve encode is steep at zero, so near black that
# noise becomes up to ~1e-7. Matrices and the curves themselves stay tight.
CODE_VALUE_TOL = 1e-6


def pure_power(gamma: float):
    """Odd-symmetric pure power curve pair, as Trellis defines it."""

    def decode(v):
        v = np.asarray(v, dtype=np.float64)
        return np.sign(v) * np.abs(v) ** gamma

    def encode(v):
        v = np.asarray(v, dtype=np.float64)
        return np.sign(v) * np.abs(v) ** (1 / gamma)

    return decode, encode


def synthetic_look(rgb: np.ndarray) -> np.ndarray:
    """An analytic, smooth look — strong per-channel curvature plus a
    saturation rotation — so tetrahedral interpolation is really exercised
    (linear-only looks would hide a wrong tetrahedron partition)."""
    g = rgb ** 0.85
    w = np.array([0.2126, 0.7152, 0.0722])
    m = 0.8 * np.eye(3) + 0.2 * np.ones((3, 1)) @ w[np.newaxis, ...]
    out = g @ m.T
    return np.clip(out, 0.0, 1.0)


def build_look(n: int) -> np.ndarray:
    """The look LUT as an (n, n, n, 3) array indexed `lut[r, g, b]`, built from
    the red-fastest flat order (r + g·n + b·n²) that `LUT3D` uses — the fixture
    commits `reshape(-1, 3)` of this, in that same order."""
    grid = np.linspace(0.0, 1.0, n)
    arr = np.empty((n, n, n, 3))
    for k in range(n * n * n):
        b, g, r = k // (n * n), (k // n) % n, k % n
        arr[r, g, b] = synthetic_look(np.array([grid[r], grid[g], grid[b]]))
    return arr


def bake_coords(n: int) -> np.ndarray:
    """The n³ output grid in red-fastest flat order (matches `LUT3D` and the
    `.cube` data layout): `[r, g, b]` triples with r fastest."""
    grid = np.linspace(0.0, 1.0, n)
    return np.array([[r, g, b] for b in grid for g in grid for r in grid])


def tetrahedral(lut: np.ndarray, p: np.ndarray) -> np.ndarray:
    """Independent numpy port of LUT3D.sample: the 6-tetrahedron interpolation
    partitioned by the ordering of the fractional coordinates."""
    n = lut.shape[0]
    pc = np.clip(p, 0.0, 1.0) * (n - 1)
    i = np.clip(np.floor(pc).astype(np.int64), 0, n - 2)
    f = pc - i
    r, g, b = i[..., 0], i[..., 1], i[..., 2]
    fr, fg, fb = f[..., 0], f[..., 1], f[..., 2]

    c000 = lut[r, g, b]
    c100 = lut[r + 1, g, b]
    c010 = lut[r, g + 1, b]
    c110 = lut[r + 1, g + 1, b]
    c001 = lut[r, g, b + 1]
    c101 = lut[r + 1, g, b + 1]
    c011 = lut[r, g + 1, b + 1]
    c111 = lut[r + 1, g + 1, b + 1]

    out = np.empty_like(c000)

    t1 = (fr >= fg) & (fg >= fb)                     # r ≥ g ≥ b
    t2 = (fr >= fg) & (fg < fb) & (fr >= fb)         # r ≥ b > g
    t3 = (fr >= fg) & (fg < fb) & (fr < fb)          # b > r ≥ g
    t4 = (fr < fg) & (fb >= fg)                      # b ≥ g > r
    t5 = (fr < fg) & (fb < fg) & (fb >= fr)          # g > b ≥ r
    t6 = (fr < fg) & (fb < fg) & (fb < fr)           # g > r > b

    out[t1] = c000[t1] + (c100[t1] - c000[t1]) * fr[t1, None] \
        + (c110[t1] - c100[t1]) * fg[t1, None] + (c111[t1] - c110[t1]) * fb[t1, None]
    out[t2] = c000[t2] + (c100[t2] - c000[t2]) * fr[t2, None] \
        + (c101[t2] - c100[t2]) * fb[t2, None] + (c111[t2] - c101[t2]) * fg[t2, None]
    out[t3] = c000[t3] + (c001[t3] - c000[t3]) * fb[t3, None] \
        + (c101[t3] - c001[t3]) * fr[t3, None] + (c111[t3] - c101[t3]) * fg[t3, None]
    out[t4] = c000[t4] + (c001[t4] - c000[t4]) * fb[t4, None] \
        + (c011[t4] - c001[t4]) * fg[t4, None] + (c111[t4] - c011[t4]) * fr[t4, None]
    out[t5] = c000[t5] + (c010[t5] - c000[t5]) * fg[t5, None] \
        + (c011[t5] - c010[t5]) * fb[t5, None] + (c111[t5] - c011[t5]) * fr[t5, None]
    out[t6] = c000[t6] + (c010[t6] - c000[t6]) * fg[t6, None] \
        + (c110[t6] - c010[t6]) * fr[t6, None] + (c111[t6] - c110[t6]) * fb[t6, None]
    return out


def chain(look: np.ndarray, mode: str, p: np.ndarray) -> np.ndarray:
    if mode == "anchor":
        return tetrahedral(look, p)

    video_decode, video_encode = pure_power(2.4 if mode == "rec709_2_4" else 2.2)
    adobe_decode, adobe_encode = pure_power(ADOBE_GAMMA)

    adobe = colour.RGB_COLOURSPACES["Adobe RGB (1998)"]
    bt709 = colour.RGB_COLOURSPACES["ITU-R BT.709"]
    m_709_xyz = colour.normalised_primary_matrix(bt709.primaries, bt709.whitepoint)
    m_xyz_adobe = np.linalg.inv(colour.normalised_primary_matrix(adobe.primaries, adobe.whitepoint))
    m_709_to_adobe = m_xyz_adobe @ m_709_xyz
    m_adobe_to_709 = np.linalg.inv(m_709_to_adobe)

    lin = video_decode(p)
    adobe_code = adobe_encode((m_709_to_adobe @ lin[..., None])[..., 0])
    looked = tetrahedral(look, adobe_code)
    out_code = video_encode((m_adobe_to_709 @ adobe_decode(looked)[..., None])[..., 0])
    return np.clip(out_code, 0.0, 1.0)  # hard clip after final encode


def main() -> int:
    look = build_look(LOOK_SIZE)
    # Red-fastest flat order, matching LUT3D.subscript / the .cube data layout.
    flat_look = np.array(
        [look[r, g, b] for b in range(LOOK_SIZE) for g in range(LOOK_SIZE) for r in range(LOOK_SIZE)]
    )
    coords = bake_coords(BAKE_SIZE)

    data = {
        "generator": "research/reference/bake_reference.py",
        "colour_science_version": colour.__version__,
        "adobe_gamma": ADOBE_GAMMA,
        "look_size": LOOK_SIZE,
        "look": flat_look.tolist(),
        "modes": {},
    }
    for mode in ("anchor", "rec709_2_4", "rec709_2_2"):
        data["modes"][mode] = chain(look, mode, coords).tolist()

    if "--check" in sys.argv[1:]:
        committed = json.loads(OUT.read_text())
        for key in ("colour_science_version", "generator"):
            committed.pop(key, None)
            data.pop(key, None)
        problems = [
            p
            for k in committed.keys() | data.keys()
            for p in _diff(committed.get(k), data.get(k), f"$.{k}", CODE_VALUE_TOL if k == "modes" else LUT_VALUES_TOL)
        ]
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


def _diff(a, b, path, tol=LUT_VALUES_TOL):
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