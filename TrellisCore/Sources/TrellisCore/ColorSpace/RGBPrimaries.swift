//
//  RGBPrimaries.swift
//  TrellisCore
//
//  Created by Ben Colson on 06/10/2026.
//

/// A CIE 1931 xy chromaticity coordinate.
public struct Chromaticity: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// XYZ of this chromaticity scaled to luminance `Y`.
    public func xyz(luminance Y: Double = 1) -> Vector3 {
        Vector3(x / y * Y, Y, (1 - x - y) / y * Y)
    }

    /// CIE standard illuminant D65, as used by both Adobe RGB (1998) and ITU-R BT.709.
    public static let d65 = Chromaticity(x: 0.3127, y: 0.3290)
}

/// An RGB gamut: three primaries and a white point. Says nothing about the
/// transfer curve. Pair it with a `TransferFunction` in a `ColorSpace`.
public struct RGBPrimaries: Equatable, Sendable {
    public var name: String
    public var red: Chromaticity
    public var green: Chromaticity
    public var blue: Chromaticity
    public var white: Chromaticity

    public init(name: String, red: Chromaticity, green: Chromaticity, blue: Chromaticity, white: Chromaticity) {
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
        self.white = white
    }

    /// The normalised primary matrix: linear RGB → CIE XYZ, with RGB (1,1,1)
    /// mapping to the white point at Y = 1.
    ///
    /// Derived from the chromaticities (SMPTE RP 177 method), never hard-coded.
    /// Tests check it against published values and `colour-science`.
    public var rgbToXYZ: Matrix3x3 {
        let p = Matrix3x3(columns: red.xyz(), green.xyz(), blue.xyz())
        guard let pInv = p.inverse else {
            preconditionFailure("Primaries of \(name) are collinear")
        }
        let s = pInv * white.xyz()
        return Matrix3x3(columns: red.xyz() * s.x, green.xyz() * s.y, blue.xyz() * s.z)
    }

    /// CIE XYZ → linear RGB.
    public var xyzToRGB: Matrix3x3 {
        rgbToXYZ.inverse!
    }

    /// Linear-light matrix taking RGB in `self` to RGB in `target`.
    ///
    /// Trellis only works with D65 spaces, so no chromatic adaptation is applied.
    /// Mixing white points is a programming error, not something to paper over.
    public func matrix(to target: RGBPrimaries) -> Matrix3x3 {
        precondition(white == target.white,
                     "Converting \(name) → \(target.name) needs chromatic adaptation, which Trellis does not do")
        // Same gamut: exact identity, rather than a product that is identity
        // to ~1e-16 and leaves float noise for the encode curve to amplify.
        if self == target { return .identity }
        return target.xyzToRGB * rgbToXYZ
    }

    // MARK: - Spaces Trellis uses

    /// Adobe RGB (1998). Adobe RGB (1998) Color Image Encoding, §4.3.
    public static let adobeRGB1998 = RGBPrimaries(
        name: "Adobe RGB (1998)",
        red: Chromaticity(x: 0.6400, y: 0.3300),
        green: Chromaticity(x: 0.2100, y: 0.7100),
        blue: Chromaticity(x: 0.1500, y: 0.0600),
        white: .d65
    )

    /// ITU-R BT.709 (Rec. 709), Item 1.4.
    public static let rec709 = RGBPrimaries(
        name: "Rec. 709",
        red: Chromaticity(x: 0.640, y: 0.330),
        green: Chromaticity(x: 0.300, y: 0.600),
        blue: Chromaticity(x: 0.150, y: 0.060),
        white: .d65
    )
}
