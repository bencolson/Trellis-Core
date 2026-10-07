"""Cross-check the bake chain with OpenColorIO (OCIO).

`bake_reference.py` re-implements the chain (including tetrahedral
interpolation) in numpy. This script implements nothing: it builds the same
chains out of OpenColorIO transforms and runs them through OCIO's own CPU
processor (float32), asserting each against the committed fixture.

Three independent checks:

1.  Output-grid parity — for each mode, apply the chain at the fixture's 5³
    output grid points and assert max |Δ| < 1e-6 against `bake_reference.json`
    `modes`.
2.  Off-grid parity — a seeded 1000-point set (exercising the tetrahedral
    partition, the part `bake_reference.py` re-implements itself) compared
    against the numpy reference at 1e-6.
3.  `.cube` reader conformance — `cubeio_golden.cube` (committed, written by
    Trellis's `CubeIO`, asserted byte-for-byte by a Swift test) must parse
    through OCIO's `FileTransform` back to the exact values.

Matrices come from colour-science primaries (`colour.normalised_primary_matrix`)
— never from OCIO's built-in config spaces — so this checks the chain, not a
config.

    python3 research/reference/ocio_bake_check.py

Runs from the repository root, like the other reference scripts. Exit 0/1.
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

import numpy as np
import colour
import PyOpenColorIO as ocio

import bake_reference

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "TrellisCore/Tests/TrellisCoreTests/Fixtures"
BAKE_FIXTURE = FIXTURES / "bake_reference.json"
GOLDEN_CUBE = FIXTURES / "cubeio_golden.cube"

ADOBE_GAMMA = 563 / 256
TOL = 1e-6
OFF_GRID_POINTS = 1000
OFF_GRID_SEED = 20261007


def component(v: float, decimals: int = 6) -> str:
    """Fixed-point formatting like Trellis's `CubeIO.component`: N decimal
    places, no exponent notation, half away from zero. Defaults to 6 dp (the
    shipped .cube format); the temporary look cube uses more so carrier
    quantisation never dominates the comparison."""
    scale = 10**decimals
    scaled = int(np.floor(v * scale + 0.5))
    negative = scaled < 0
    mag = -scaled if negative else scaled
    return ("-" if negative else "") + f"{mag // scale}.{mag % scale:0{decimals}d}"


def write_cube(path: Path, size: int, values, title: str, decimals: int = 6) -> None:
    """Write a `.cube` file in Trellis `CubeIO.write`'s format: `TITLE`,
    `LUT_3D_SIZE`, `DOMAIN_MIN`/`DOMAIN_MAX`, a blank line, then the size³
    values red fastest (b slowest, r fastest) at `decimals` places."""
    lines = [f'TITLE "{title}"', f"LUT_3D_SIZE {size}", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 1 1 1", ""]
    values = np.asarray(values).reshape(-1, 3)
    for v in values:
        lines.append(f"{component(v[0], decimals)} {component(v[1], decimals)} {component(v[2], decimals)}")
    path.write_text("\n".join(lines))


def ocio_matrix(m3: np.ndarray) -> list[float]:
    """3×3 RGB matrix → OCIO's flat row-major 4×4 (identity alpha row)."""
    m = np.zeros((4, 4))
    m[:3, :3] = m3
    m[3, 3] = 1.0
    return list(m.ravel())


def chromatic_matrices() -> tuple[np.ndarray, np.ndarray]:
    """709-to-Adobe and Adobe-to-709 linear matrices, colour-science derived."""
    adobe = colour.RGB_COLOURSPACES["Adobe RGB (1998)"]
    bt709 = colour.RGB_COLOURSPACES["ITU-R BT.709"]
    m_709_xyz = colour.normalised_primary_matrix(bt709.primaries, bt709.whitepoint)
    m_xyz_adobe = np.linalg.inv(colour.normalised_primary_matrix(adobe.primaries, adobe.whitepoint))
    m_709_to_adobe = m_xyz_adobe @ m_709_xyz
    return m_709_to_adobe, np.linalg.inv(m_709_to_adobe)


def exponent(gamma: float, inverse: bool = False) -> ocio.ExponentTransform:
    """Odd-symmetric pure power (forwards x^γ, inverse x^(1/γ)); mirrors like
    Trellis's sign(x)·|x|^γ so transient negative values stay finite."""
    return ocio.ExponentTransform(
        value=[gamma, gamma, gamma, 1.0],
        negativeStyle=ocio.NEGATIVE_MIRROR,
        direction=ocio.TRANSFORM_DIR_INVERSE if inverse else ocio.TRANSFORM_DIR_FORWARD,
    )


def mode_transforms(mode: str, look_cube: Path, m709a: np.ndarray, ma709: np.ndarray) -> list[ocio.Transform]:
    """The bake chain for one mode as OCIO transforms (order matters)."""
    look = ocio.FileTransform(src=str(look_cube), interpolation=ocio.INTERP_TETRAHEDRAL)
    if mode == "anchor":
        return [look]
    gamma = 2.4 if mode == "rec709_2_4" else 2.2
    return [
        exponent(gamma),                                   # decode v^γ
        ocio.MatrixTransform(matrix=ocio_matrix(m709a), offset=[0.0, 0.0, 0.0, 0.0]),  # 709 → Adobe (linear)
        exponent(ADOBE_GAMMA, inverse=True),               # encode [γ563/256]: x^(1/γ)
        look,                                               # sample the look (Adobe code)
        exponent(ADOBE_GAMMA),                             # decode [γ563/256]: x^γ
        ocio.MatrixTransform(matrix=ocio_matrix(ma709), offset=[0.0, 0.0, 0.0, 0.0]),  # Adobe → 709
        exponent(gamma, inverse=True),                     # encode v^(1/γ)
        ocio.RangeTransform(minInValue=0.0, maxInValue=1.0, minOutValue=0.0, maxOutValue=1.0),  # hard clip
    ]


def apply_chain(transforms: list[ocio.Transform], points: np.ndarray) -> np.ndarray:
    """Run `points` (N×3 float64 in [0,1]) through the OCIO chain (float32).

    `OPTIMIZATION_NONE` is deliberate: the default CPU processor applies
    OCIO's fast log/exp/pow approximation (~2e-5 relative), which would swamp
    the 1e-6 tolerance. Unoptimized, the check compares OCIO's own transforms
    (matrices, ExponentTransform, .cube reader, tetrahedral interpolation) at
    float32 precision so 1e-6 vs the float64 reference holds by ~4 orders."""
    a = np.asarray(points, dtype=np.float32).reshape(-1, 3)
    group = ocio.GroupTransform(transforms=transforms)
    processor = _CONFIG.getProcessor(group)
    processor.getOptimizedCPUProcessor(ocio.OPTIMIZATION_NONE).applyRGB(a)
    return a.astype(np.float64)


def make_config() -> ocio.Config:
    src = (
        "ocio_profile_version: 2\n"
        "strictparsing: false\n"
        "search_path: ''\n"
        "roles:\n"
        "  default: raw\n"
        "displays: {}\n"
        "colorspaces:\n"
        " - !<ColorSpace>\n"
        "   name: raw\n"
        "   isdata: true\n"
    )
    return ocio.Config.CreateFromStream(src)


def look_lut() -> np.ndarray:
    """The fixture's look LUT as `lut[r, g, b]`. The committed `look` list is
    flat in red-fastest order (`k = b·n² + g·n + r`, .cube order), so a plain
    reshape would C-order it blue-fastest: rebuild explicitly instead."""
    data = json.loads(BAKE_FIXTURE.read_text())
    n = data["look_size"]
    flat = np.asarray(data["look"], dtype=np.float64)
    lut = np.empty((n, n, n, 3))
    for r in range(n):
        for g in range(n):
            for b in range(n):
                lut[r, g, b] = flat[b * n * n + g * n + r]
    return lut


def check_grid(data: dict, look: np.ndarray, look_cube: Path, m709a, ma709) -> list[float]:
    """Check 1 — the fixture's 5³ output grid per mode. Returns max |Δ|."""
    coords = bake_reference.bake_coords(bake_reference.BAKE_SIZE)
    worst: list[float] = []
    for mode in ("anchor", "rec709_2_4", "rec709_2_2"):
        got = apply_chain(mode_transforms(mode, look_cube, m709a, ma709), coords)
        want = np.asarray(data["modes"][mode], dtype=np.float64)
        d = float(np.max(np.abs(got - want)))
        worst.append(d)
        if d > TOL:
            print(f"  FAIL output grid {mode}: max |Δ| {d:.3e} > {TOL}", file=sys.stderr)
        else:
            print(f"  output grid {mode}: max |Δ| {d:.3e}")
    return worst


def check_off_grid(look: np.ndarray, look_cube: Path, m709a, ma709) -> list[float]:
    """Check 2 — 1000 seeded off-grid points vs the numpy reference."""
    rng = np.random.default_rng(OFF_GRID_SEED)
    points = rng.random((OFF_GRID_POINTS, 3))
    worst: list[float] = []
    for mode in ("anchor", "rec709_2_4", "rec709_2_2"):
        got = apply_chain(mode_transforms(mode, look_cube, m709a, ma709), points)
        want = bake_reference.chain(look, mode, points)
        d = float(np.max(np.abs(got - want)))
        worst.append(d)
        if d > TOL:
            print(f"  FAIL off-grid {mode}: max |Δ| {d:.3e} > {TOL}", file=sys.stderr)
        else:
            print(f"  off-grid {mode}: max |Δ| {d:.3e}")
    return worst


def check_golden_cube() -> float:
    """Check 3 — Trellis's .cube output parses exactly through OCIO."""
    if not GOLDEN_CUBE.exists():
        print(f"  FAIL: {GOLDEN_CUBE.relative_to(ROOT)} missing "
              "(regenerate it from the Swift CubeIO golden test)", file=sys.stderr)
        return np.inf
    n = 4
    coords = np.array([[r / 3, g / 3, b / 3] for b in range(n) for g in range(n) for r in range(n)])
    got = apply_chain([ocio.FileTransform(src=str(GOLDEN_CUBE), interpolation=ocio.INTERP_TETRAHEDRAL)], coords)
    want = coords.copy()
    d = float(np.max(np.abs(got - want)))
    if d > TOL:
        print(f"  FAIL cubeio_golden.cube: max |Δ| {d:.3e} > {TOL}", file=sys.stderr)
    else:
        print(f"  cubeio_golden.cube parses: max |Δ| {d:.3e}")
    return d


def main() -> int:
    data = json.loads(BAKE_FIXTURE.read_text())
    look = look_lut()
    m709a, ma709 = chromatic_matrices()
    with tempfile.TemporaryDirectory() as td:
        look_cube = Path(td) / "look.cube"
        n = look.shape[0]
        red_fastest = np.array([look[r, g, b] for b in range(n) for g in range(n) for r in range(n)])
        write_cube(look_cube, n, red_fastest, "Trellis bake look", decimals=12)

        worst = check_grid(data, look, look_cube, m709a, ma709)
        worst += check_off_grid(look, look_cube, m709a, ma709)
        worst += [check_golden_cube()]

    ok = max(worst) <= TOL
    print("bake chain × OpenColorIO: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


_CONFIG = make_config()

if __name__ == "__main__":
    sys.exit(main())