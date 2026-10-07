//
//  Perceptual.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

/// Perceptual colour metrics: CIE L*a*b* (D65) and the CIEDE2000 colour
/// difference, for the identity validation and error reports.
///
/// All of it is driven off the primaries/matrices already in `ColorSpace`, so
/// there is no third copy of the colour pipeline here.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum Perceptual {

    /// CIE L*a*b* coordinates. `a*`/`b*` are unbounded (can leave ±128 for
    /// display-referred RGB gamuts); no clamping is done.
    public struct Lab: Equatable, Sendable {
        public let l: Double
        public let a: Double
        public let b: Double

        public init(l: Double, a: Double, b: Double) {
            self.l = l
            self.a = a
            self.b = b
        }

        public static func == (x: Lab, y: Lab) -> Bool { x.l == y.l && x.a == y.a && x.b == y.b }
    }

    /// CIE XYZ → L*a*b*, using the given white point's XYZ (D65 for every
    /// space Trellis works in). The standard piecewise cube-root
    /// with the (6/29)³ break point; linear in the toe.
    public static func lab(xyz: Vector3, whitePoint: Vector3) -> Lab {
        func f(_ t: Double) -> Double {
            let breakpoint = 216.0 / 24389.0           // (6/29)³
            if t > breakpoint { return pow(t, 1.0 / 3.0) }
            return t * (841.0 / 108.0) + 4.0 / 29.0    // 1/(3(6/29)²), continuous at the break
        }
        let fx = f(xyz.x / whitePoint.x)
        let fy = f(xyz.y / whitePoint.y)
        let fz = f(xyz.z / whitePoint.z)
        return Lab(l: 116.0 * fy - 16.0,
                   a: 500.0 * (fx - fy),
                   b: 200.0 * (fy - fz))
    }

    /// Encoded RGB (code values in [0,1]) in `space` → L*a*b* at the space's
    /// white point (D65 for Adobe RGB (1998) and Rec. 709).
    public static func lab(rgb: Vector3, in space: ColorSpace) -> Lab {
        let linear = space.transfer.decode(rgb)
        let xyz = space.primaries.rgbToXYZ * linear
        return lab(xyz: xyz, whitePoint: space.primaries.white.xyz())
    }

    /// CIEDE2000 colour difference between two L*a*b* colours, with unit
    /// weighting factors (k_L = k_C = k_H = 1). CIE 15:2004 / Sharma et al.
    /// "The CIEDE2000 Color-Difference Formula: Implementation Notes".
    ///
    /// The two `atan2`-derived hue terms are handled per the standard: when
    /// either colour is on the achromatic axis (C₁′C₂′ = 0), the hue difference
    /// is taken as 0 and the mean hue as h₁′ + h₂′.
    public static func deltaE2000(_ c1: Lab, _ c2: Lab) -> Double {
        let (l1, a1, b1) = (c1.l, c1.a, c1.b)
        let (l2, a2, b2) = (c2.l, c2.a, c2.b)

        // Chroma and the G factor that rotates a* towards a1'/a2'.
        let c1s = sqrt(a1 * a1 + b1 * b1)
        let c2s = sqrt(a2 * a2 + b2 * b2)
        let cBar = (c1s + c2s) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1 - sqrt(cBar7 / (cBar7 + pow(25.0, 7))))
        let a1p = (1 + g) * a1
        let a2p = (1 + g) * a2
        let c1p = sqrt(a1p * a1p + b1 * b1)
        let c2p = sqrt(a2p * a2p + b2 * b2)
        let h1p = hueDegrees(a1p, b1)
        let h2p = hueDegrees(a2p, b2)

        let dLp = l2 - l1
        let dCp = c2p - c1p
        let achromatic = c1p * c2p == 0
        let dHp: Double
        if achromatic {
            dHp = 0
        } else {
            let diff = h2p - h1p
            dHp = 2 * sqrt(c1p * c2p) * sin(radians(diff / 2))
        }

        let lBar = (l1 + l2) / 2
        let cBarP = (c1p + c2p) / 2
        let hBarP = meanHue(h1p, h2p, achromatic)

        let t = 1 - 0.17 * cos(radians(hBarP - 30))
                + 0.24 * cos(radians(2 * hBarP))
                + 0.32 * cos(radians(3 * hBarP + 6))
                - 0.20 * cos(radians(4 * hBarP - 63))
        let dTheta = 30 * exp(-pow((hBarP - 275) / 25, 2))
        let rC = 2 * sqrt(pow(cBarP, 7) / (pow(cBarP, 7) + pow(25.0, 7)))
        let sL = 1 + 0.015 * pow(lBar - 50, 2) / sqrt(20 + pow(lBar - 50, 2))
        let sC = 1 + 0.045 * cBarP
        let sH = 1 + 0.015 * cBarP * t
        let rT = -sin(radians(2 * dTheta)) * rC

        let x = dLp / sL
        let y = dCp / sC
        let z = dHp / sH
        return sqrt(x * x + y * y + z * z + rT * y * z)
    }

    /// Hue angle in degrees, normalized to [0, 360).
    private static func hueDegrees(_ a: Double, _ b: Double) -> Double {
        var h = degrees(atan2(b, a))
        if h < 0 { h += 360 }
        return h
    }

    /// Mean hue h̄′ from the CIE standard: if either colour is achromatic use
    /// h₁′ + h₂′; otherwise the bisector of the shorter arc, adjusted when the
    /// difference is > 180°.
    private static func meanHue(_ h1: Double, _ h2: Double, _ achromatic: Bool) -> Double {
        if achromatic { return h1 + h2 }
        let diff = h1 - h2
        if abs(diff) <= 180 { return (h1 + h2) / 2 }
        return (h1 + h2 + (h1 + h2 < 360 ? 360 : -360)) / 2
    }

    private static func radians(_ d: Double) -> Double { d * (Double.pi / 180) }
    private static func degrees(_ r: Double) -> Double { r * (180 / Double.pi) }
}