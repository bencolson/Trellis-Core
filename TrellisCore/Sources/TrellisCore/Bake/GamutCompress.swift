//
//  GamutCompress.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import Foundation

extension Bake {

    /// The furthest each channel can sit *outside* the Rec 709 gamut for any
    /// Adobe RGB (1998) colour, in linear Rec 709: the per-channel distance
    /// `(a − c)/a` from the achromatic value `a = max(r, g, b)`.
    ///
    /// Derived in code from the Adobe RGB primaries through the Adobe → Rec 709
    /// matrix — never tuned. The linear map of the code cube is a
    /// parallelepiped whose extremes are at its corners, so taking the max over
    /// the cube's eight corners is exact for every channel.
    public static var adobeToRec709Limits: Vector3 {
        let m = RGBPrimaries.adobeRGB1998.matrix(to: .rec709)
        let corners: [Vector3] = bakeCorners
        var limits = Vector3(0, 0, 0)
        for p in corners {
            let v = m * p
            let a = max(max(v.x, v.y), v.z)
            guard a > 0 else { continue }
            limits.x = max(limits.x, (a - v.x) / a)
            limits.y = max(limits.y, (a - v.y) / a)
            limits.z = max(limits.z, (a - v.z) / a)
        }
        return limits
    }

    /// The largest achromatic value any Adobe RGB (1998) colour reaches in
    /// linear Rec 709 (the green/cyan boundary pushes a channel to ~1.2).
    /// The compression's second half is a homotopy on `a` itself, so the
    /// upper side of the gamut is pulled in as smoothly as the lower.
    public static var adobeToRec709MaxA: Double {
        let m = RGBPrimaries.adobeRGB1998.matrix(to: .rec709)
        var best = 0.0
        for p in bakeCorners {
            let v = m * p
            best = max(best, max(max(v.x, v.y), v.z))
        }
        return best
    }

    private static var bakeCorners: [Vector3] {
        [
            Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1),
            Vector3(1, 1, 0), Vector3(1, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1),
        ]
    }

    /// Soft gamut compression — an optional alternative to `hardClip` for the
    /// saturated greens and cyans that fall outside Rec 709.
    ///
    /// Own implementation, following the *published description* of Jed
    /// Smith's gamut-compress (README and ACES Central threads). That project
    /// carries no licence, so only the description and the maths are used,
    /// never its code.
    ///
    /// In linear Rec 709 (the handler's space) a pixel's achromatic value is
    /// `a = max(r, g, b)` and each channel's distance from it is
    /// `d = (a − c)/a` (0 = neutral, > 1 = outside the gamut). Both the
    /// distances and `a` itself get the same treatment:
    ///
    /// - at or below `threshold` nothing moves;
    /// - above it, a smooth homotopy maps the threshold onto itself and the
    ///   furthest point Adobe RGB can reach exactly onto the Rec 709 boundary
    ///   (distance 1.0 for the chromatic side, `a = 1` for the achromatic),
    ///   pulling the pixel **straight toward the compressed achromatic value**:
    ///   every channel's distance is scaled by the same factor, so hue and
    ///   channel ratios are preserved.
    ///
    /// `hardClip` runs last, catching float noise only — for anything inside
    /// Adobe RGB it changes nothing. `threshold` defaults to 1.0, where the
    /// chromatic homotopy degenerates to a boundary snap for out-of-gamut
    /// channels (monotone, continuous, in-gamut-exact); a threshold below 1.0
    /// gives the graded soft response. The default is provisional until the
    /// shape has been judged on real looks.
    public static func gamutCompress(threshold: Double = 1.0, limits: Vector3? = nil) -> GamutHandler {
        let lim = limits ?? adobeToRec709Limits
        let maxDistance = max(max(lim.x, lim.y), lim.z)
        let maxA = adobeToRec709MaxA
        precondition(threshold > 0 && maxDistance > threshold && maxA > threshold,
                     "gamutCompress: threshold \(threshold) must be below the gamut limits \(maxDistance)/\(maxA)")
        return { v in Bake.hardClip(compressInto(v, threshold: threshold, maxDistance: maxDistance, maxA: maxA)) }
    }

    /// The compression maths, pre-clip: pulls `v` (linear Rec 709, inside an
    /// Adobe RGB input) toward its compressed achromatic value so every
    /// channel lands in [0, 1] — the hard clip in `gamutCompress` is a float-
    /// noise safety net, not part of the response. Internal so the property
    /// tests can prove that.
    static func compressInto(_ v: Vector3, threshold: Double, maxDistance: Double, maxA: Double) -> Vector3 {
        let a = max(max(v.x, v.y), v.z)
        guard a > 0 else { return v }
        let dX = (a - v.x) / a
        let dY = (a - v.y) / a
        let dZ = (a - v.z) / a
        let m = max(max(dX, dY), dZ)
        guard a > threshold || m > threshold else { return v }

        let aCompressed = a > threshold
            ? threshold + (1 - threshold) * smoothstep((a - threshold) / (maxA - threshold))
            : a
        let k: Double
        if m > threshold {
            let h = threshold + (1 - threshold) * smoothstep((m - threshold) / (maxDistance - threshold))
            k = h / m
        } else {
            k = 1
        }
        return Vector3(aCompressed - dX * k * aCompressed,
                       aCompressed - dY * k * aCompressed,
                       aCompressed - dZ * k * aCompressed)
    }

    @inline(__always)
    private static func smoothstep(_ x: Double) -> Double {
        let u = min(max(x, 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// How many of a baked LUT's grid points each gamut-handler behaviour
    /// actually touched, for honest reporting in the .cube header and the CLI.
    ///
    /// There is no way to see inside an opaque handler, so the two numbers are
    /// what `bakeWithReport` can observe:
    ///
    /// - `compressed`: the handler moved the grid point (soft compression, or
    ///   the clip handler's own out-of-gamut fix) and the bake-level safety
    ///   clip did not have to cut it.
    /// - `clipped`: the handler's output still needed the safety clip to reach
    ///   [0, 1]. This is non-zero only for handlers that don't clip
    ///   themselves. `gamutCompress` guarantees its own output is in gamut, so
    ///   it reports `clipped == 0` by design.
    public struct BakeTally: Equatable, Sendable {
        public var compressed: Int
        public var clipped: Int

        public init(compressed: Int = 0, clipped: Int = 0) {
            self.compressed = compressed
            self.clipped = clipped
        }
    }

    /// Below this, bakeWithReport treats a grid point as untouched. Sits above
    /// the chain's float noise (encode/decode + matrix round-trips are ~1e-7
    /// for a perfectly in-gamut look) and far below real out-of-gamut content
    /// (the green boundary pushes a channel to ~−0.4).
    static let tallyEpsilon = 1e-6

    /// `bake` plus a tally of how many grid points were compressed or clipped.
    ///
    /// `compressed` counts points whose handler output differs from the grid
    /// input beyond `tallyEpsilon`; `clipped` counts those whose output the
    /// [0, 1] safety clip then had to trim. With `hardClip` the whole
    /// out-of-gamut population counts as `compressed` (it was fixed by the
    /// handler, so the safety net never fires); a handler that doesn't clip
    /// itself (e.g. the identity) reports those points under `clipped` instead.
    public static func bakeWithReport(_ look: LUT3D, mode: Mode, size: Int = 33,
                                      gamut: @escaping GamutHandler = Bake.hardClip) -> (lut: LUT3D, tally: BakeTally) {
        precondition(size >= 2, "bake size must be ≥ 2")
        let f = chain(look, mode: mode, gamut: gamut)
        let m = 1.0 / Double(size - 1)
        var values = [Vector3]()
        values.reserveCapacity(size * size * size)
        var tally = BakeTally()
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let v = Vector3(Double(r) * m, Double(g) * m, Double(b) * m)
                    let handled = f(v)
                    let clipped = hardClip(handled)
                    if abs(handled.x - v.x) > tallyEpsilon || abs(handled.y - v.y) > tallyEpsilon || abs(handled.z - v.z) > tallyEpsilon {
                        if abs(handled.x - clipped.x) > tallyEpsilon || abs(handled.y - clipped.y) > tallyEpsilon || abs(handled.z - clipped.z) > tallyEpsilon {
                            tally.clipped += 1
                        } else {
                            tally.compressed += 1
                        }
                    }
                    values.append(clipped)
                }
            }
        }
        return (LUT3D(size: size, values: values), tally)
    }
}