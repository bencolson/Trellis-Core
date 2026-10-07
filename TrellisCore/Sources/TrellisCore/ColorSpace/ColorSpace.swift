//
//  ColorSpace.swift
//  TrellisCore
//
//  Created by Ben Colson on 06/10/2026.
//

/// A fully specified RGB encoding: gamut + white point + transfer curve.
///
/// Trellis's core rule: every colour space is explicit, pinned and
/// labelled. A `ColorSpace` is always both halves, never just "Rec 709".
public struct ColorSpace: Equatable, Sendable {
    public var primaries: RGBPrimaries
    public var transfer: TransferFunction

    public init(primaries: RGBPrimaries, transfer: TransferFunction) {
        self.primaries = primaries
        self.transfer = transfer
    }

    /// e.g. "Adobe RGB (1998) / gamma 563/256 (2.19921875)", "Rec. 709 / gamma 2.4".
    public var label: String { "\(primaries.name) / \(transfer.label)" }

    /// Anchor / interchange space: Adobe RGB (1998) with its own
    /// 563/256 power curve. This is what Capture One writes when the process
    /// recipe's ICC profile is Adobe RGB (1998).
    public static let adobeRGB1998 = ColorSpace(primaries: .adobeRGB1998, transfer: .adobeRGB1998)

    /// Rec. 709 primaries, pure 2.4 power (BT.1886 with zero black). Video default.
    public static let rec709Gamma24 = ColorSpace(primaries: .rec709, transfer: .gamma24)

    /// Rec. 709 primaries, pure 2.2 power. Desktop/web.
    public static let rec709Gamma22 = ColorSpace(primaries: .rec709, transfer: .gamma22)
}

/// Converts encoded RGB from one `ColorSpace` to another:
/// decode → 3×3 primaries matrix (display-linear) → encode.
///
/// No clipping happens here. Out-of-gamut results (e.g. saturated Adobe RGB
/// greens going to Rec. 709) come back outside [0, 1] and are the gamut
/// handler's job, which is applied explicitly in the bake chain.
public struct ColorSpaceConversion: Sendable {
    public let source: ColorSpace
    public let destination: ColorSpace
    public let matrix: Matrix3x3

    public init(from source: ColorSpace, to destination: ColorSpace) {
        self.source = source
        self.destination = destination
        self.matrix = source.primaries.matrix(to: destination.primaries)
    }

    @inlinable
    public func apply(_ rgb: Vector3) -> Vector3 {
        destination.transfer.encode(matrix * source.transfer.decode(rgb))
    }
}
