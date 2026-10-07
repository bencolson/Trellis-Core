//
//  TransferFunction.swift
//  TrellisCore
//
//  Created by Ben Colson on 06/10/2026.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A transfer curve between code values and display-linear light.
///
/// Only pure power curves exist here on purpose: no sRGB-style
/// piecewise toe, no camera OETFs. Every curve has a label that says exactly
/// what it is, because "Rec 709" without a gamma is the bug Trellis exists to fix.
public enum TransferFunction: Equatable, Sendable {
    /// Code values are already linear light.
    case linear
    /// `linear = code ^ gamma`.
    case power(gamma: Double)

    /// Adobe RGB (1998) gamma: 563/256 = 2.19921875 exactly (Adobe RGB (1998)
    /// Color Image Encoding, §4.3.1.2). Close to, but not equal to, 2.2.
    public static let adobeRGB1998 = TransferFunction.power(gamma: 563.0 / 256.0)

    /// BT.1886 EOTF with zero black level (Lb = 0, Lw = 1) is a pure 2.4 power.
    public static let gamma24 = TransferFunction.power(gamma: 2.4)

    /// Pure 2.2 power, for desktop/web viewing.
    public static let gamma22 = TransferFunction.power(gamma: 2.2)

    /// Code value → display-linear light.
    ///
    /// Negative inputs are mirrored (`-f(-v)`), so the curve is odd-symmetric
    /// and never produces NaN. In Trellis's chains negative values only appear
    /// transiently, before the gamut handler clips them.
    @inlinable
    public func decode(_ v: Double) -> Double {
        switch self {
        case .linear: return v
        case .power(let g): return v < 0 ? -pow(-v, g) : pow(v, g)
        }
    }

    /// Display-linear light → code value. Exact inverse of `decode`.
    @inlinable
    public func encode(_ v: Double) -> Double {
        switch self {
        case .linear: return v
        case .power(let g): return v < 0 ? -pow(-v, 1 / g) : pow(v, 1 / g)
        }
    }

    @inlinable
    public func decode(_ v: Vector3) -> Vector3 {
        Vector3(decode(v.x), decode(v.y), decode(v.z))
    }

    @inlinable
    public func encode(_ v: Vector3) -> Vector3 {
        Vector3(encode(v.x), encode(v.y), encode(v.z))
    }

    /// Human-readable label used in UI, .cube headers and file names.
    public var label: String {
        switch self {
        case .linear:
            return "linear"
        case .power(let g) where g == 563.0 / 256.0:
            return "gamma 563/256 (2.19921875)"
        case .power(let g):
            return "gamma \(formatGamma(g))"
        }
    }

    private func formatGamma(_ g: Double) -> String {
        // 2.4 → "2.4", 2.2 → "2.2"; never prints a long float tail.
        let rounded = (g * 10_000).rounded() / 10_000
        var s = String(rounded)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }
}
