"""Generate colour-science reference values for TrellisCore's camera log CSTs.

The independent side of the cross-check for CameraLog.swift: log decodings
and gamut matrices come from colour-science's own implementations.

    python3 research/reference/camera_reference.py

writes TrellisCore/Tests/TrellisCoreTests/Fixtures/camera_reference.json.

    python3 research/reference/camera_reference.py --check

regenerates in memory and fails if the committed fixture differs.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import colour
import colour.models.rgb.transfer_functions as tf

from colorspace_reference import _diff

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "TrellisCore/Tests/TrellisCoreTests/Fixtures/camera_reference.json"

# Swift LogCurve raw value → colour-science decoding (normalised code value in,
# reflectance out — colour-science's defaults for every curve that has the options).
CURVES = {
    "arriLogC3": lambda v: tf.log_decoding_ARRILogC3(v, firmware="SUP 3.x", EI=800),
    "arriLogC4": tf.log_decoding_ARRILogC4,
    "sonySLog3": tf.log_decoding_SLog3,
    "panasonicVLog": tf.log_decoding_VLog,
    "canonLog2": lambda v: tf.log_decoding_CanonLog2(v, method="v1.2"),
    "canonLog3": lambda v: tf.log_decoding_CanonLog3(v, method="v1.2"),
    "redLog3G10": lambda v: tf.log_decoding_Log3G10(v, method="v3"),
    "appleLog": tf.log_decoding_AppleLogProfile,
    "fujifilmFLog2": tf.log_decoding_FLog2,
    "djiDLog": tf.log_decoding_DJIDLog,
    "nikonNLog": tf.log_decoding_NLog,
    "blackmagicFilmGen5": tf.oetf_inverse_BlackmagicFilmGeneration5,
    "davinciIntermediate": tf.oetf_inverse_DaVinciIntermediate,
}

# Swift CameraLog static name → (curve, colour-science gamut name).
CAMERAS = {
    "arriLogC3": ("arriLogC3", "ARRI Wide Gamut 3"),
    "arriLogC4": ("arriLogC4", "ARRI Wide Gamut 4"),
    "sonySLog3Cine": ("sonySLog3", "S-Gamut3.Cine"),
    "sonySLog3": ("sonySLog3", "S-Gamut3"),
    "panasonicVLog": ("panasonicVLog", "V-Gamut"),
    "canonLog2": ("canonLog2", "Cinema Gamut"),
    "canonLog3": ("canonLog3", "Cinema Gamut"),
    "redLog3G10": ("redLog3G10", "REDWideGamutRGB"),
    "appleLog": ("appleLog", "ITU-R BT.2020"),
    "fujifilmFLog2": ("fujifilmFLog2", "F-Gamut"),
    "djiDLog": ("djiDLog", "DJI D-Gamut"),
    "nikonNLog": ("nikonNLog", "N-Gamut"),
    "blackmagicFilmGen5": ("blackmagicFilmGen5", "Blackmagic Wide Gamut"),
    "davinciIntermediate": ("davinciIntermediate", "DaVinci Wide Gamut"),
}

D65 = np.array([0.3127, 0.3290])
KNEE = 0.8


def npm(primaries) -> np.ndarray:
    # Trellis uses exact D65 for every camera gamut (Blackmagic publishes
    # a white 2e-5 away from it; see RGBPrimaries.blackmagicWideGamut).
    return colour.normalised_primary_matrix(np.asarray(primaries), D65)


def matrix_to(gamut: str, target: str) -> np.ndarray:
    src = colour.RGB_COLOURSPACES[gamut]
    dst = colour.RGB_COLOURSPACES[target]
    return np.linalg.inv(npm(dst.primaries)) @ npm(src.primaries)


def highlights(rgb: np.ndarray, mode: str) -> np.ndarray:
    v = np.maximum(rgb, 0)
    if mode == "clip":
        return np.minimum(v, 1)
    m = v.max(axis=-1, keepdims=True)
    t = (m - KNEE) / (1 - KNEE)
    rolled = v * (KNEE + (1 - KNEE) * t / (1 + t)) / np.where(m > 0, m, 1)
    return np.where(m > KNEE, rolled, v)


def main() -> int:
    code_values = np.linspace(0.0, 1.0, 41)
    curves = {name: np.asarray(fn(code_values), dtype=np.float64).tolist() for name, fn in CURVES.items()}

    # Spot code values for each camera's CST: grey-ish, saturated, near black, bright.
    samples = np.array(
        [
            [0.0, 0.0, 0.0],
            [0.10, 0.10, 0.10],
            [0.40, 0.40, 0.40],
            [0.55, 0.42, 0.30],
            [0.30, 0.50, 0.35],
            [0.35, 0.38, 0.60],
            [0.70, 0.66, 0.60],
            [0.85, 0.85, 0.85],
        ]
    )

    cameras = {}
    for name, (curve, gamut) in CAMERAS.items():
        m709 = matrix_to(gamut, "ITU-R BT.709")
        m_adobe = matrix_to(gamut, "Adobe RGB (1998)")
        linear = np.asarray(CURVES[curve](samples), dtype=np.float64)
        scene709 = linear @ m709.T
        out = {}
        for mode in ("clip", "rollOff"):
            out[mode] = (highlights(scene709, mode) ** (1 / 2.4)).tolist()
        cameras[name] = {
            "curve": curve,
            "to_rec709": m709.ravel().tolist(),
            "to_adobeRGB1998": m_adobe.ravel().tolist(),
            "samples": samples.tolist(),
            "rec709Gamma24": out,
        }

    data = {
        "generator": "research/reference/camera_reference.py",
        "colour_science_version": colour.__version__,
        "code_values": code_values.tolist(),
        "curves": curves,
        "cameras": cameras,
    }

    # Sanity: each curve puts its published 18% grey code value at 0.18.
    for name, fn in CURVES.items():
        enc = {
            "arriLogC3": tf.log_encoding_ARRILogC3, "arriLogC4": tf.log_encoding_ARRILogC4,
            "sonySLog3": tf.log_encoding_SLog3, "panasonicVLog": tf.log_encoding_VLog,
            "canonLog2": tf.log_encoding_CanonLog2, "canonLog3": tf.log_encoding_CanonLog3,
            "redLog3G10": tf.log_encoding_Log3G10, "appleLog": tf.log_encoding_AppleLogProfile,
            "fujifilmFLog2": tf.log_encoding_FLog2, "djiDLog": tf.log_encoding_DJIDLog,
            "nikonNLog": tf.log_encoding_NLog,
            "blackmagicFilmGen5": tf.oetf_BlackmagicFilmGeneration5,
            "davinciIntermediate": tf.oetf_DaVinciIntermediate,
        }[name]
        assert abs(float(fn(enc(0.18))) - 0.18) < 1e-6, name

    if "--check" in sys.argv[1:]:
        committed = json.loads(OUT.read_text())
        for key in ("colour_science_version", "generator"):
            committed.pop(key, None)
            data.pop(key, None)
        problems = list(_diff(committed, data, "$", tol=1e-11))
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


if __name__ == "__main__":
    sys.exit(main())
