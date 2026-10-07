//
//  HaldSpec.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

/// Geometry of a Hald CLUT image.
///
/// Level `L` gives `N = L²` steps per channel and an `L³ × L³` image. Pixel
/// index `i = x + y·L³` maps to grid point `r = i mod N`, `g = (i / N) mod N`,
/// `b = i / N²` (red fastest, then green, then blue).
public struct HaldSpec: Equatable, Hashable, Sendable {
    public let level: Int

    public init(level: Int) {
        precondition(level >= 2 && level <= 16, "Hald level must be 2…16")
        self.level = level
    }

    /// Default: 64 steps, 512×512.
    public static let level8 = HaldSpec(level: 8)
    /// High quality: 144 steps, 1728×1728.
    public static let level12 = HaldSpec(level: 12)

    /// Steps per channel, `N = L²`.
    public var steps: Int { level * level }
    /// Image width and height in pixels, `L³`.
    public var size: Int { level * level * level }

    /// Infers the level from image dimensions; `nil` unless square with an
    /// integral cube-root side.
    public init?(width: Int, height: Int) {
        guard width == height, width > 0 else { return nil }
        var l = 2
        while l * l * l < width { l += 1 }
        guard l * l * l == width, l <= 16 else { return nil }
        self.level = l
    }

    /// Pixel (x, y) → grid indices (r, g, b), each 0…N−1.
    @inlinable
    public func gridIndex(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let n = steps
        let i = x + y * size
        return (i % n, (i / n) % n, i / (n * n))
    }

    /// Grid indices → pixel (x, y). Inverse of `gridIndex`.
    @inlinable
    public func pixel(r: Int, g: Int, b: Int) -> (x: Int, y: Int) {
        let n = steps
        let i = r + g * n + b * n * n
        return (i % size, i / size)
    }

    /// Exact identity value of grid index `c`, in [0, 1].
    @inlinable
    public func value(_ c: Int) -> Double { Double(c) / Double(steps - 1) }

    /// 16-bit code value written for grid index `c`: `round(c · 65535 / (N − 1))`.
    ///
    /// For L8, 65535/63 is not an integer, so grid points carry up to 0.5 of a
    /// 16-bit step (7.6e-6) of rounding. That's ~130× finer than the 10-bit
    /// identity tolerance, and the reader treats the exact `value(c)` as
    /// the grid input, so the error doesn't compound.
    @inlinable
    public func code16(_ c: Int) -> UInt16 {
        UInt16((Double(c) * 65535 / Double(steps - 1)).rounded())
    }
}
