//
//  CameraLog.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A camera manufacturer's log curve: code value → scene-linear reflectance.
///
/// Kept apart from `TransferFunction` on purpose: those are display curves
/// that round-trip exactly; these are camera OETFs, used only to decode
/// footage for preview (a CST, as Resolve's Color Space Transform does).
///
/// **Input domain.** Every curve here takes the file's *normalised code
/// value*: the stored word divided by full scale (`cv / 1023` at 10-bit),
/// which is how the vendors' white papers state their curves (S-Log3 18% grey
/// = 420 / 1023). A video-range file therefore has to be mapped back from its
/// range-expanded signal first; see `CameraLog.codeValue(fromVideoRange:)`.
///
/// **Output.** Scene-linear with 0.18 = an 18% grey card, i.e. colour-science's
/// `out_reflection=True`. Formulas are the vendors' published maths; every
/// curve is checked against colour-science (research/reference/camera_reference.py).
public enum LogCurve: String, CaseIterable, Sendable {
    case arriLogC3          // ARRI ALEXA Log C, SUP 3.x, EI 800
    case arriLogC4
    case sonySLog3
    case panasonicVLog
    case canonLog2          // v1.2
    case canonLog3          // v1.2
    case redLog3G10         // v3
    case appleLog
    case fujifilmFLog2
    case djiDLog
    case nikonNLog
    case blackmagicFilmGen5
    case davinciIntermediate

    public var label: String {
        switch self {
        case .arriLogC3: return "ARRI LogC3 (EI 800)"
        case .arriLogC4: return "ARRI LogC4"
        case .sonySLog3: return "Sony S-Log3"
        case .panasonicVLog: return "Panasonic V-Log"
        case .canonLog2: return "Canon Log 2"
        case .canonLog3: return "Canon Log 3"
        case .redLog3G10: return "RED Log3G10"
        case .appleLog: return "Apple Log"
        case .fujifilmFLog2: return "Fujifilm F-Log2"
        case .djiDLog: return "DJI D-Log"
        case .nikonNLog: return "Nikon N-Log"
        case .blackmagicFilmGen5: return "Blackmagic Film Gen 5"
        case .davinciIntermediate: return "DaVinci Intermediate"
        }
    }

    /// Normalised code value → scene-linear reflectance (0.18 = grey card).
    public func decode(_ v: Double) -> Double {
        switch self {
        case .arriLogC3:
            // ALEXA Log C Curve, Usage in VFX (2012): SUP 3.x, EI 800,
            // linear scene exposure factor.
            let cut = 0.010591, a = 5.555556, b = 0.052272, c = 0.24719,
                d = 0.385537, e = 5.367655, f = 0.092809
            return v > e * cut + f ? (pow(10, (v - d) / c) - b) / a : (v - f) / e

        case .arriLogC4:
            // ARRI LogC4 Specification (2022).
            let a = (pow(2, 18) - 16) / 117.45
            let b = (1023 - 95) / 1023.0
            let c = 95 / 1023.0
            let s = (7 * log(2.0) * pow(2, 7 - 14 * c / b)) / (a * b)
            let t = (pow(2, 14 * (-c / b) + 6) - 64) / a
            return v >= 0 ? (pow(2, 14 * (v - c) / b + 6) - 64) / a : v * s + t

        case .sonySLog3:
            // Sony, Technical Summary for S-Gamut3.Cine/S-Log3 and S-Gamut3/S-Log3.
            let cv = v * 1023
            return cv >= 171.2102946929
                ? pow(10, (cv - 420) / 261.5) * (0.18 + 0.01) - 0.01
                : (cv - 95) * 0.01125 / (171.2102946929 - 95)

        case .panasonicVLog:
            // Panasonic, V-Log/V-Gamut Reference Manual (2014).
            let cut2 = 0.181, b = 0.00873, c = 0.241514, d = 0.598206
            return v < cut2 ? (v - 0.125) / 5.6 : pow(10, (v - d) / c) - b

        case .canonLog2:
            // Canon, Canon Log Gamma Curves, v1.2. Formula gives linear
            // relative to 100% white; ×0.9 → reflectance.
            let x = v < 0.092864125
                ? -(pow(10, (0.092864125 - v) / 0.24136077) - 1) / 87.09937546
                : (pow(10, (v - 0.092864125) / 0.24136077) - 1) / 87.09937546
            return x * 0.9

        case .canonLog3:
            // Canon, Canon Log Gamma Curves, v1.2.
            let x: Double
            if v < 0.097465473 {
                x = -(pow(10, (0.12783901 - v) / 0.36726845) - 1) / 14.98325
            } else if v <= 0.15277891 {
                x = (v - 0.12512219) / 1.9754798
            } else {
                x = (pow(10, (v - 0.12240537) / 0.36726845) - 1) / 14.98325
            }
            return x * 0.9

        case .redLog3G10:
            // RED, White Paper on REDWideGamutRGB and Log3G10 (v3, with 0.01 offset).
            let a = 0.224282, b = 155.975327, c = 0.01, g = 15.1927
            return v < 0 ? v / g - c : (pow(10, v / a) - 1) / b - c

        case .appleLog:
            // Apple, Apple Log Profile White Paper (2023).
            let r0 = -0.05641088, rt = 0.01, sigma = 47.28711236,
                beta = 0.00964052, gamma = 0.08550479, delta = 0.69336945
            let pt = sigma * (rt - r0) * (rt - r0)
            if v >= pt { return pow(2, (v - delta) / gamma) - beta }
            if v >= 0 { return (v / sigma).squareRoot() + r0 }
            return r0

        case .fujifilmFLog2:
            // Fujifilm, F-Log2 Data Sheet (v1.0).
            let cut2 = 0.100686685370811, a = 5.555556, b = 0.064829,
                c = 0.245281, d = 0.384316, e = 8.799461, f = 0.092864
            return v < cut2 ? (v - f) / e : pow(10, (v - d) / c) / a - b / a

        case .djiDLog:
            // DJI, White Paper on D-Log and D-Gamut (2017).
            return v <= 0.14
                ? (v - 0.0929) / 6.025
                : (pow(10, 3.89616 * v - 2.27752) - 0.0108) / 0.9892

        case .nikonNLog:
            // Nikon, N-Log Specification Document (v1.0.0).
            let cut2 = 0.4418377321603128, a = 0.635386119257087, b = 0.0075,
                c = 0.1466275659824047, d = 0.6050830889540567
            if v < cut2 {
                let r = v / a
                return (r < 0 ? -pow(-r, 3) : pow(r, 3)) - b
            }
            return exp((v - d) / c)

        case .blackmagicFilmGen5:
            // Blackmagic Design, Blackmagic Generation 5 Color Science (2021).
            let A = 0.08692876065491224, B = 0.005494072432257808,
                C = 0.5300133392291939, D = 8.283605932402494,
                E = 0.09246575342465753, linCut = 0.005
            return v < D * linCut + E ? (v - E) / D : exp((v - C) / A) - B

        case .davinciIntermediate:
            // Blackmagic Design, DaVinci Resolve 17 Wide Gamut Intermediate (2020).
            let a = 0.0075, b = 7.0, c = 0.07329248, m = 10.44426855, logCut = 0.02740668
            return v <= logCut ? v / m : pow(2, v / c - b) - a
        }
    }

    public func decode(_ v: Vector3) -> Vector3 {
        Vector3(decode(v.x), decode(v.y), decode(v.z))
    }
}

/// A camera's recording space: log curve + native gamut.
public struct CameraLog: Equatable, Hashable, Sendable, Identifiable {
    public var curve: LogCurve
    public var primaries: RGBPrimaries

    public init(curve: LogCurve, primaries: RGBPrimaries) {
        self.curve = curve
        self.primaries = primaries
    }

    public var id: String { label }

    /// e.g. "Sony S-Log3 / S-Gamut3.Cine".
    public var label: String { "\(curve.label) / \(primaries.name)" }

    public static let arriLogC3 = CameraLog(curve: .arriLogC3, primaries: .arriWideGamut3)
    public static let arriLogC4 = CameraLog(curve: .arriLogC4, primaries: .arriWideGamut4)
    public static let sonySLog3Cine = CameraLog(curve: .sonySLog3, primaries: .sGamut3Cine)
    public static let sonySLog3 = CameraLog(curve: .sonySLog3, primaries: .sGamut3)
    public static let panasonicVLog = CameraLog(curve: .panasonicVLog, primaries: .vGamut)
    public static let canonLog2 = CameraLog(curve: .canonLog2, primaries: .cinemaGamut)
    public static let canonLog3 = CameraLog(curve: .canonLog3, primaries: .cinemaGamut)
    public static let redLog3G10 = CameraLog(curve: .redLog3G10, primaries: .redWideGamutRGB)
    public static let appleLog = CameraLog(curve: .appleLog, primaries: .rec2020)
    public static let fujifilmFLog2 = CameraLog(curve: .fujifilmFLog2, primaries: .fGamut)
    public static let djiDLog = CameraLog(curve: .djiDLog, primaries: .djiDGamut)
    public static let nikonNLog = CameraLog(curve: .nikonNLog, primaries: .rec2020)
    public static let blackmagicFilmGen5 = CameraLog(curve: .blackmagicFilmGen5, primaries: .blackmagicWideGamut)
    public static let davinciIntermediate = CameraLog(curve: .davinciIntermediate, primaries: .davinciWideGamut)

    /// Every camera space Trellis can preview, in menu order.
    public static let all: [CameraLog] = [
        .arriLogC3, .arriLogC4, .sonySLog3Cine, .sonySLog3, .panasonicVLog,
        .canonLog2, .canonLog3, .redLog3G10, .appleLog, .fujifilmFLog2,
        .djiDLog, .nikonNLog, .blackmagicFilmGen5, .davinciIntermediate,
    ]

    /// Maps a video-range (narrow / legal) signal, as a decoder hands it over
    /// after range expansion (black = 0, white = 1), back to the normalised
    /// code value the curves are defined on. 10-bit quantisation: 64 → 940.
    /// Full-range files need no mapping: their expanded signal *is* the code value.
    @inlinable
    public static func codeValue(fromVideoRange v: Double) -> Double {
        (v * 876 + 64) / 1023
    }
}

extension RGBPrimaries: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

// MARK: - Camera gamuts (all D65)

extension RGBPrimaries {
    /// ITU-R BT.2020. Also the gamut of Apple Log, Nikon N-Log and Fujifilm F-Gamut.
    public static let rec2020 = RGBPrimaries(
        name: "Rec. 2020",
        red: Chromaticity(x: 0.708, y: 0.292),
        green: Chromaticity(x: 0.170, y: 0.797),
        blue: Chromaticity(x: 0.131, y: 0.046),
        white: .d65
    )

    /// Fujifilm F-Gamut: BT.2020 primaries under Fujifilm's name.
    public static let fGamut = RGBPrimaries(
        name: "F-Gamut", red: rec2020.red, green: rec2020.green, blue: rec2020.blue, white: .d65
    )

    public static let arriWideGamut3 = RGBPrimaries(
        name: "ARRI Wide Gamut 3",
        red: Chromaticity(x: 0.6840, y: 0.3130),
        green: Chromaticity(x: 0.2210, y: 0.8480),
        blue: Chromaticity(x: 0.0861, y: -0.1020),
        white: .d65
    )

    public static let arriWideGamut4 = RGBPrimaries(
        name: "ARRI Wide Gamut 4",
        red: Chromaticity(x: 0.7347, y: 0.2653),
        green: Chromaticity(x: 0.1424, y: 0.8576),
        blue: Chromaticity(x: 0.0991, y: -0.0308),
        white: .d65
    )

    public static let sGamut3 = RGBPrimaries(
        name: "S-Gamut3",
        red: Chromaticity(x: 0.730, y: 0.280),
        green: Chromaticity(x: 0.140, y: 0.855),
        blue: Chromaticity(x: 0.100, y: -0.050),
        white: .d65
    )

    public static let sGamut3Cine = RGBPrimaries(
        name: "S-Gamut3.Cine",
        red: Chromaticity(x: 0.766, y: 0.275),
        green: Chromaticity(x: 0.225, y: 0.800),
        blue: Chromaticity(x: 0.089, y: -0.087),
        white: .d65
    )

    public static let vGamut = RGBPrimaries(
        name: "V-Gamut",
        red: Chromaticity(x: 0.730, y: 0.280),
        green: Chromaticity(x: 0.165, y: 0.840),
        blue: Chromaticity(x: 0.100, y: -0.030),
        white: .d65
    )

    public static let cinemaGamut = RGBPrimaries(
        name: "Cinema Gamut",
        red: Chromaticity(x: 0.740, y: 0.270),
        green: Chromaticity(x: 0.170, y: 1.140),
        blue: Chromaticity(x: 0.080, y: -0.100),
        white: .d65
    )

    public static let redWideGamutRGB = RGBPrimaries(
        name: "REDWideGamutRGB",
        red: Chromaticity(x: 0.780308, y: 0.304253),
        green: Chromaticity(x: 0.121595, y: 1.493994),
        blue: Chromaticity(x: 0.095612, y: -0.084589),
        white: .d65
    )

    public static let djiDGamut = RGBPrimaries(
        name: "DJI D-Gamut",
        red: Chromaticity(x: 0.71, y: 0.31),
        green: Chromaticity(x: 0.21, y: 0.88),
        blue: Chromaticity(x: 0.09, y: -0.08),
        white: .d65
    )

    /// Blackmagic Wide Gamut (Gen 5). Blackmagic publishes it with a white of
    /// (0.312717, 0.3290312), 2e-5 off D65; Trellis uses exact D65 so no
    /// chromatic adaptation is needed. The difference is below 1e-4 in RGB.
    public static let blackmagicWideGamut = RGBPrimaries(
        name: "Blackmagic Wide Gamut",
        red: Chromaticity(x: 0.7177215, y: 0.3171181),
        green: Chromaticity(x: 0.2280410, y: 0.8615690),
        blue: Chromaticity(x: 0.1005841, y: -0.0820452),
        white: .d65
    )

    public static let davinciWideGamut = RGBPrimaries(
        name: "DaVinci Wide Gamut",
        red: Chromaticity(x: 0.8000, y: 0.3130),
        green: Chromaticity(x: 0.1682, y: 0.9877),
        blue: Chromaticity(x: 0.0790, y: -0.1155),
        white: .d65
    )
}

// MARK: - CST

/// What happens to scene values above display white after a log CST.
public enum HighlightHandling: String, CaseIterable, Sendable {
    /// Clip at display white, as Resolve's Color Space Transform with
    /// Tone Mapping set to None.
    case clip
    /// Soft shoulder from 80% display-linear, applied to max(R,G,B) so hue
    /// ratios are kept: `y = k + (1−k)·t/(1+t)`, `t = (m−k)/(1−k)`, k = 0.8.
    /// Trellis's own curve; it does not match any Resolve setting exactly.
    case rollOff

    public var label: String {
        switch self {
        case .clip: return "Clip"
        case .rollOff: return "Roll off"
        }
    }

    /// Knee of the roll-off, in display-linear light.
    public static let knee = 0.8

    @inlinable
    public func apply(_ rgb: Vector3) -> Vector3 {
        let v = Vector3(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0))
        switch self {
        case .clip:
            return Vector3(min(v.x, 1), min(v.y, 1), min(v.z, 1))
        case .rollOff:
            let m = max(v.x, v.y, v.z)
            let k = Self.knee
            guard m > k else { return v }
            let t = (m - k) / (1 - k)
            return v * ((k + (1 - k) * t / (1 + t)) / m)
        }
    }
}

/// Camera log → display space, as a Color Space Transform:
/// log decode → gamut matrix (scene-linear) → highlight handling → encode.
///
/// Scene-linear is taken straight as display-linear (18% grey stays 0.18),
/// which is what a plain CST does. Negative (out-of-gamut) components are
/// clipped to 0 before the highlight step.
public struct CameraConversion: Sendable {
    public let source: CameraLog
    public let destination: ColorSpace
    public let highlights: HighlightHandling
    public let matrix: Matrix3x3

    public init(from source: CameraLog, to destination: ColorSpace, highlights: HighlightHandling) {
        self.source = source
        self.destination = destination
        self.highlights = highlights
        self.matrix = source.primaries.matrix(to: destination.primaries)
    }

    /// Normalised code values in → encoded destination values in [0, 1].
    @inlinable
    public func apply(_ codeValues: Vector3) -> Vector3 {
        destination.transfer.encode(highlights.apply(matrix * source.curve.decode(codeValues)))
    }
}
