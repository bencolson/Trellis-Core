#!/usr/bin/env python3
"""Regenerate the real Capture One locality measurements recorded in
docs/capture-one-export-notes.md, from on-disk C1 exports.

The full forward/reversed L8 Halds are ~1.5 MB each — too heavy to commit —
so instead of shipping binary fixtures, this script reproduces the numbers
from the user's own C1 session, using the same reversed-Hald comparison as
Swift's ``Validate.locality``. The committed numbers in the notes table
(HSR on: 1286 max / 24.5 mean; HSR off: 0 / 0; identity drift ≤1) are exactly
what this script prints for those files.

    python3 research/reference/c1_fixture_stats.py FORWARD.tif REVERSED.tif

reads one forward-processed Hald and one reversed-processed Hald in the Trellis
recipe layout (little-endian, uncompressed, interleaved 16-bit RGB) and prints:

    forward vs reversed-back: max N codes, mean M codes, exact P%

A value well within a few codes means the style is a pure per-pixel lookup; a
large value (e.g. the 1286 max for Cozy Fall with Highlight/Shadow recovery)
means a spatial operator is present and the .cube will not represent it.
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

THRESHOLD_CODES = 4  # must match Validate.localityThreshold


def read_rgb16(path: Path) -> tuple[int, int, list[int]]:
    """Minimal reader for Trellis-recipe TIFFs (LE, uncompressed, chunky RGB).

    Single- and multi-strip layouts both work (StripOffsets is a table when
    count > 1). Only the first strip is needed: the Hald's own generator writes
    ~64 KiB strips, but the first strip always starts at the first pixel row.
    """
    data = path.read_bytes()
    assert data[:2] == b"II", f"{path}: expect little-endian TIFF"
    assert struct.unpack_from("<H", data, 2)[0] == 42, f"{path}: not classic TIFF"
    ifd = struct.unpack_from("<I", data, 4)[0]
    count = struct.unpack_from("<H", data, ifd)[0]
    tags = {}
    for i in range(count):
        base = ifd + 2 + i * 12
        tag, typ, n = struct.unpack_from("<HHI", data, base)
        # SHORT inline (≤2) or a LONG/offset value; either way the pointer or
        # inline value sits at base+8.
        val = struct.unpack_from("<I", data, base + 8)[0]
        tags[tag] = (typ, n, val)
    w = tags[256][2]
    h = tags[257][2]
    spp = tags[277][2]
    assert spp == 3, f"{path}: expected 3 samples/pixel, got {spp}"
    _, n_strips, so_val = tags[273]
    strip = so_val if n_strips == 1 else struct.unpack_from("<I", data, so_val)[0]
    samples = list(struct.unpack_from("<" + "H" * (w * h * spp), data, strip))
    return w, h, samples


def reversed_pixels(samples: list[int]) -> list[int]:
    """Pixel-order reversal: reverse in RGB triples, keep channel order."""
    pixels = [samples[i : i + 3] for i in range(0, len(samples), 3)]
    return [c for px in reversed(pixels) for c in px]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    fwd_path, rev_path = (Path(p) for p in sys.argv[1:3])
    wf, hf, fwd = read_rgb16(fwd_path)
    wr, hr, rev = read_rgb16(rev_path)
    if (wf, hf) != (wr, hr):
        print(f"dimension mismatch: forward {wf}x{hf}, reversed {wr}x{hr}", file=sys.stderr)
        return 1

    # Reverse the reversed Hald's *pixel* order and compare code values.
    back = reversed_pixels(rev)
    diffs = [abs(a - b) for a, b in zip(fwd, back)]
    max_d = max(diffs)
    mean_d = sum(diffs) / len(diffs)
    exact = sum(1 for d in diffs if d == 0) / len(diffs)

    verdict = (
        "spatial operator present — the look cannot be represented as a LUT"
        if max_d > THRESHOLD_CODES
        else "pure per-pixel look"
    )
    print(f"forward vs reversed-back: max {max_d} codes, mean {mean_d:.2f} codes, exact {exact * 100:.1f}%")
    print(f"verdict: {verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main())