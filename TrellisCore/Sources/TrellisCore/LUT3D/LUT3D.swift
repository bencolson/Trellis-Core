//
//  LUT3D.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

/// An in-memory 3D lookup table (RGB → RGB), the format the anchor/baked
/// outputs are built from. Indexed red-fastest, then green, then
/// blue, matching the .cube data order.
public struct LUT3D: Equatable, Sendable, CustomStringConvertible {
    /// Number of steps per channel, `N` (`LUT_3D_SIZE` in the .cube file).
    public let size: Int
    /// `size³` output colours, indexed `r + g·size + b·size²` (red fastest).
    /// Each value is an encoded RGB triple in [0, 1] (Adobe RGB / γ563/256 for
    /// the anchor LUT).
    public let values: [Vector3]

    public init(size: Int, values: [Vector3]) {
        precondition(size >= 2, "LUT3D needs at least 2 steps per channel")
        precondition(values.count == size * size * size, "LUT3D needs \(size * size * size) values, got \(values.count)")
        self.size = size
        self.values = values
    }

    public static func == (a: LUT3D, b: LUT3D) -> Bool { a.size == b.size && a.values == b.values }

    /// The identity LUT: output equals input at every grid point.
    public static func identity(size: Int) -> LUT3D {
        let m = 1.0 / Double(size - 1)
        var values = [Vector3](repeating: Vector3(0, 0, 0), count: size * size * size)
        for i in 0..<values.count {
            let r = i % size
            let g = (i / size) % size
            let b = i / (size * size)
            values[i] = Vector3(Double(r) * m, Double(g) * m, Double(b) * m)
        }
        return LUT3D(size: size, values: values)
    }

    /// Grid-point output colour at integer indices `(r, g, b)`, each 0…size−1.
    @inlinable
    public subscript(r: Int, g: Int, b: Int) -> Vector3 {
        values[r + g * size + b * size * size]
    }

    /// Tetrahedral interpolation of the LUT at colour `(r, g, b)` in [0, 1].
    ///
    /// The unit cube around the sample is divided into the six tetrahedra on
    /// its main diagonal; the two edge-most corners with a tie on the diagonal
    /// are chosen by the ordering of the fractional parts, and the output is a
    /// single linear combination — so the interpolation is continuous and
    /// exact at grid points. Inputs outside [0, 1] are clamped; that is a
    /// deliberate choice, not a silent pass-through: the gamut handler runs
    /// *after* the final encode in the bake chain, but the look LUT is sampled
    /// in its own (anchor) code space, so out-of-gamut inputs can reach here.
    public func sample(_ r: Double, _ g: Double, _ b: Double) -> Vector3 {
        let n = Double(size - 1)
        // Grid coordinates, clamped to the domain so out-of-range inputs
        // interpolate along the boundary face instead of indexing OOB.
        let gr = min(max(r, 0), 1) * n
        let gg = min(max(g, 0), 1) * n
        let gb = min(max(b, 0), 1) * n
        let ri = Int(gr), gi = Int(gg), bi = Int(gb)
        let fr = gr - Double(ri), fg = gg - Double(gi), fb = gb - Double(bi)
        let r1 = min(ri + 1, size - 1)
        let g1 = min(gi + 1, size - 1)
        let b1 = min(bi + 1, size - 1)

        let c000 = self[ri, gi, bi]
        let c100 = self[r1, gi, bi]
        let c010 = self[ri, g1, bi]
        let c110 = self[r1, g1, bi]
        let c001 = self[ri, gi, b1]
        let c101 = self[r1, gi, b1]
        let c011 = self[ri, g1, b1]
        let c111 = self[r1, g1, b1]

        // Walk one edge of the cube per fractional coordinate, so the
        // interpolation weights all sum to 1 and each is non-negative.
        if fr >= fg {
            if fg >= fb {
                return Self.walk(c000, c100 - c000, fr, c110 - c100, fg, c111 - c110, fb)
            } else if fr >= fb {
                return Self.walk(c000, c100 - c000, fr, c101 - c100, fb, c111 - c101, fg)
            } else {
                return Self.walk(c000, c001 - c000, fb, c101 - c001, fr, c111 - c101, fg)
            }
        } else {
            if fb >= fg {
                return Self.walk(c000, c001 - c000, fb, c011 - c001, fg, c111 - c011, fr)
            } else if fb >= fr {
                return Self.walk(c000, c010 - c000, fg, c011 - c010, fb, c111 - c011, fr)
            } else {
                return Self.walk(c000, c010 - c000, fg, c110 - c010, fr, c111 - c110, fb)
            }
        }
    }

    /// `base + d1·w1 + d2·w2 + d3·w3`, one tetrahedron edge at a time. Written
    /// out step by step: as a single expression, Swift 6.0's type checker
    /// gives up on the SIMD operator overloads.
    @inline(__always)
    private static func walk(_ base: Vector3,
                             _ d1: Vector3, _ w1: Double,
                             _ d2: Vector3, _ w2: Double,
                             _ d3: Vector3, _ w3: Double) -> Vector3 {
        var v = base
        v += d1 * w1
        v += d2 * w2
        v += d3 * w3
        return v
    }

    /// A new LUT of `outputSize` steps, sampled from this one at its grid
    /// points with tetrahedral interpolation. This is how a level-8 Hald
    /// (64³ grid) becomes a 33³ or 65³ .cube.
    public func resample(to outputSize: Int) -> LUT3D {
        precondition(outputSize >= 2, "LUT3D output size must be ≥ 2")
        var out = [Vector3]()
        out.reserveCapacity(outputSize * outputSize * outputSize)
        let m = 1.0 / Double(outputSize - 1)
        for b in 0..<outputSize {
            for g in 0..<outputSize {
                for r in 0..<outputSize {
                    out.append(sample(Double(r) * m, Double(g) * m, Double(b) * m))
                }
            }
        }
        return LUT3D(size: outputSize, values: out)
    }

    /// Human-readable summary for `trellis inspect`/reports.
    public var description: String {
        "\(size)³ LUT (\(size * size * size) nodes)"
    }
}