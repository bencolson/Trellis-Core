"""Cross-check TrellisCore's camera log input domain against OpenColorIO.

CameraLog.swift takes each curve's *normalised code value* (cv / 1023). The
vendor-supplied ACES input transforms that OCIO ships as built-ins use the
same convention, so a mid-grey encoded by colour-science must come out of OCIO's
built-in at 0.18 (ACES2065-1 keeps a neutral neutral). A domain mix-up (e.g.
treating a video-range-expanded signal as code values) shifts grey by several
percent and fails this check.

    python3 research/reference/ocio_camera_check.py
"""

from __future__ import annotations

import sys

import numpy as np
import PyOpenColorIO as ocio
import colour.models.rgb.transfer_functions as tf

# OCIO built-in → colour-science encoding of 18% grey to a normalised code value.
CHECKS = {
    "ARRI_ALEXA-LOGC-EI800-AWG_to_ACES2065-1": lambda: tf.log_encoding_ARRILogC3(0.18),
    "ARRI_LOGC4_to_ACES2065-1": lambda: tf.log_encoding_ARRILogC4(0.18),
    "SONY_SLOG3-SGAMUT3_to_ACES2065-1": lambda: tf.log_encoding_SLog3(0.18),
    "SONY_SLOG3-SGAMUT3.CINE_to_ACES2065-1": lambda: tf.log_encoding_SLog3(0.18),
    "PANASONIC_VLOG-VGAMUT_to_ACES2065-1": lambda: tf.log_encoding_VLog(0.18),
    "CANON_CLOG2-CGAMUT_to_ACES2065-1": lambda: tf.log_encoding_CanonLog2(0.18),
    "CANON_CLOG3-CGAMUT_to_ACES2065-1": lambda: tf.log_encoding_CanonLog3(0.18),
    "RED_LOG3G10-RWG_to_ACES2065-1": lambda: tf.log_encoding_Log3G10(0.18),
    "APPLE_LOG_to_ACES2065-1": lambda: tf.log_encoding_AppleLogProfile(0.18),
}


def main() -> int:
    config = ocio.Config.CreateRaw()
    failures = 0
    for style, encode in CHECKS.items():
        cv = float(encode())
        transform = ocio.BuiltinTransform(style=style)
        cpu = config.getProcessor(transform).getDefaultCPUProcessor()
        out = np.array(cpu.applyRGB([cv, cv, cv]))
        ok = np.allclose(out, 0.18, atol=2e-3)
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {style}: code value {cv:.6f} -> {np.round(out, 5).tolist()}")
    if failures:
        print(f"{failures} camera(s) disagree with OCIO on the input domain", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
