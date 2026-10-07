//
//  Validate.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

/// Validation of a processed Hald before it is trusted as a look LUT: profile,
/// bit depth, geometry, spatial operators and the identity test.
///
/// `Validate.report` never throws — a bad file yields a report with
/// `ok == false` and a message saying what to fix. `Validate.identity` does
/// throw, because its caller (the CLI/app "identity test" flow) treats a
/// non-Hald input as an outright error rather than a reportable result.
import Foundation

public enum Validate {

    /// Codes (16-bit LSB) above which a reversed-Hald locality comparison flags
    /// a spatial operator. Identity drift is ≤1 code and a clean look is 0
    /// (see docs/capture-one-export-notes.md); HR/SR reaches ~1286. "A few codes" of
    /// headroom avoids Capture One's 1-LSB rounding bias.
    public static let localityThreshold: Double = 4

    /// RMS residual on normalised [0,1] above which the 6-neighbour grid
    /// residual flags a gross filter (sharpening, NR, grain). Identity sits at
    /// ~3e-6 (the 16-bit quantisation floor); real colour-editor looks reach
    /// ~2.8e-3 (Cozy Fall). 0.005 lets smooth looks through while catching
    /// genuinely noisy/grainy halides.
    public static let grossRmsThreshold: Double = 0.005

    /// `1/1023` (one 10-bit code value on [0,1]) — the identity tolerance.
    public static let identityTolerance: Double = 1.0 / 1023.0

    // MARK: - Locality (reversed Hald)

    /// Pixel-level comparison of a forward processed Hald against the
    /// reversed-back processed Hald, in 16-bit code values. A purely per-pixel
    /// look round-trips to ≤1 code of Capture One's quantisation drift; a
    /// spatial operator (Highlight/Shadow, Clarity, Structure, Dehaze) shows
    /// up as a large mismatch here.
    public static func locality(forward: RGBImage, reversed reversedImage: RGBImage) -> Locality {
        guard forward.width == reversedImage.width,
              forward.height == reversedImage.height,
              forward.samplesPerPixel == reversedImage.samplesPerPixel else {
            return .unverified
        }
        let back = reversedImage.reversedPixelOrder()
        let spp = forward.samplesPerPixel
        var maxDelta: Double = 0
        var sum: Double = 0
        for p in 0..<(forward.samples.count / spp) {
            let base = p * spp
            for c in 0..<spp {
                let d = abs(Double(forward.samples[base + c]) - Double(back.samples[base + c]))
                if d > maxDelta { maxDelta = d }
                sum += d
            }
        }
        let mean = sum / Double(forward.samples.count)
        return maxDelta <= localityThreshold
            ? .clean(max: maxDelta, mean: mean)
            : .spatialOperator(max: maxDelta, mean: mean)
    }

    // MARK: - Gross-filter residual (6-neighbour grid)

    /// The 6 face-neighbour residual over interior grid points. For a smooth
    /// LUT this is ~the 16-bit quantisation floor (~3e-6); sharp edges (noise,
    /// grain, aggressive sharpening) push it up sharply. Returns (rms, max) on
    /// normalised [0,1] component magnitudes.
    public static func gridResidual(_ lut: LUT3D) -> (rms: Double, max: Double) {
        let n = lut.size
        guard n >= 3 else { return (0, 0) } // no interior points on a 2³ LUT
        var sumSq: Double = 0
        var max: Double = 0
        var evaluated = 0
        for b in 1..<(n - 1) {
            for g in 1..<(n - 1) {
                for r in 1..<(n - 1) {
                    let c = lut[r, g, b]
                    var sum: Vector3 = lut[r - 1, g, b] + lut[r + 1, g, b]
                    sum += lut[r, g - 1, b] + lut[r, g + 1, b]
                    sum += lut[r, g, b - 1] + lut[r, g, b + 1]
                    let pred = sum / 6
                    let d = c - pred
                    let mag = sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
                    sumSq += mag * mag
                    if mag > max { max = mag }
                    evaluated += 1
                }
            }
        }
        return (sqrt(sumSq / Double(evaluated)), max)
    }

    // MARK: - Status types

    /// Per-check status: `nil` means passed. A non-nil string names what
    /// Trellis found instead, so the user is told what to fix.
    public typealias Status = String?

    public enum Locality: Equatable, Sendable, CustomStringConvertible {
        case unverified
        case clean(max: Double, mean: Double)
        case spatialOperator(max: Double, mean: Double)

        public var description: String {
            switch self {
            case .unverified: return "unverified (no reversed Hald)"
            case .clean(let mx, let mean):
                return "clean — " + String(format: "max %.0f codes, mean %.2f codes", mx, mean)
            case .spatialOperator(let mx, let mean):
                return "spatial operator — " + String(format: "max %.0f codes, mean %.2f codes", mx, mean)
                    + "; check Highlight/Shadow, Clarity, Structure, Dehaze"
            }
        }
    }

    public enum GrossFilter: Equatable, Sendable, CustomStringConvertible {
        case clean(rms: Double, max: Double)
        case suspect(rms: Double, max: Double)
        case notAvailable

        public var description: String {
            switch self {
            case .clean(let rms, let max):
                return String(format: "rms %.3e, max %.3e (no gross filter)", rms, max)
            case .suspect(let rms, let max):
                return String(format: "rms %.3e, max %.3e (suspect: sharpening, NR, or grain)", rms, max)
            case .notAvailable:
                return "n/a (could not build LUT)"
            }
        }
    }

    public struct Report: Equatable, Sendable, CustomStringConvertible {
        public let haldLevel: Int?
        public let dimensions: Status
        public let profile: Status
        public let bitDepth: Status
        public let locality: Locality
        public let grossFilters: GrossFilter

        /// `true` only when the hard checks (dimensions, profile, bit depth) all
        /// passed. A failed report must not be trusted to drive a .cube.
        public var ok: Bool {
            dimensions == nil && profile == nil && bitDepth == nil
        }

        public var description: String {
            let dimLine: String
            if let level = haldLevel {
                let side = level * level * level
                dimLine = "  dimensions  \(side)×\(side)  " + String(format: "(Hald level %d)", level)
            } else {
                dimLine = "  dimensions  " + (dimensions ?? "ok")
            }
            let profLine = "  profile     " + (profile ?? "Adobe RGB (1998)")
            let bitLine = "  bit depth   " + (bitDepth ?? "16-bit")
            return [
                "Trellis validation: " + (ok ? "PASS" : "FAIL"),
                dimLine,
                profLine,
                bitLine,
                "  locality    \(locality)",
                "  residual    \(grossFilters)",
            ].joined(separator: "\n")
        }
    }

    /// Builds a full report from a decoded forward image and an optional
    /// reversed image. Hard errors populate the `dimensions`/
    /// `profile`/`bitDepth` fields and leave the LUT-dependent checks as
    /// `notAvailable`; everything else is computed unconditionally.
    public static func report(forward: RGBImage, reversed reversedImage: RGBImage? = nil) -> Report {
        let level = HaldSpec(width: forward.width, height: forward.height)?.level
        let dimensions: Status = level == nil
            ? "image is \(forward.width)×\(forward.height), not L³×L³" : nil
        let bitDepth: Status = forward.bitsPerSample == 16 ? nil
            : "Hald is \(forward.bitsPerSample)-bit; process with a 16-bit recipe"

        var profile: Status = nil
        if let data = forward.iccProfile {
            var parsed: ICCProfile?
            do { parsed = try ICCProfile(data: data) } catch { parsed = nil }
            if let p = parsed, !p.isAdobeRGB1998 {
                profile = "embedded \"\(p.displayName)\""
            } else if parsed == nil {
                profile = "unparseable embedded profile"
            }
        } else {
            profile = "no embedded profile"
        }

        let loc: Locality
        if let rev = reversedImage {
            loc = Self.locality(forward: forward, reversed: rev)
        } else {
            loc = .unverified
        }

        let gross: GrossFilter
        if level == nil || forward.bitsPerSample != 16 || profile != nil {
            gross = .notAvailable
        } else if let lut = try? ProcessedHald.read(forward) {
            let (rms, max) = Self.gridResidual(lut)
            gross = rms > grossRmsThreshold ? .suspect(rms: rms, max: max) : .clean(rms: rms, max: max)
        } else {
            gross = .notAvailable
        }

        return Report(haldLevel: level, dimensions: dimensions, profile: profile,
                      bitDepth: bitDepth, locality: loc, grossFilters: gross)
    }

    // MARK: - Identity test

    /// Result of processing an identity Hald with *no* look applied and
    /// comparing it to the mathematical identity LUT — the user's recipe-
    /// proving step.
    public struct IdentityResult: Equatable, Sendable, CustomStringConvertible {
        public let maxCodeDelta: Double   // max |Δ| in [0,1]
        public let tolerance: Double      // 1/1023
        public let meanDeltaE: Double
        public let maxDeltaE: Double
        public var pass: Bool { maxCodeDelta <= tolerance }

        public var description: String {
            let status = pass ? "PASS" : "FAIL"
            return "identity: " + status + " — " + String(format: "max |d| %.6f on [0,1] (tol %.6f)", maxCodeDelta, tolerance)
                + String(format: "\n         mean dE2000 %.6f, max dE2000 %.6f", meanDeltaE, maxDeltaE)
        }
    }

    /// Reads the processed Hald as a look LUT and compares it to the identity
    /// LUT at the same grid. `space` is the anchor (Adobe RGB / γ563/256 by
    /// default); the ΔE₂₀₀₀ compares the processed colours in that space.
    public static func identity(_ image: RGBImage, in space: ColorSpace = .adobeRGB1998) throws -> IdentityResult {
        let lut = try ProcessedHald.read(image)
        let ident = LUT3D.identity(size: lut.size)
        var maxDelta: Double = 0
        var sumDeltaE: Double = 0
        var maxDeltaE: Double = 0
        for i in 0..<lut.values.count {
            let got = lut.values[i]
            let want = ident.values[i]
            let d = max(abs(got.x - want.x), abs(got.y - want.y), abs(got.z - want.z))
            if d > maxDelta { maxDelta = d }
            let de = Perceptual.deltaE2000(Perceptual.lab(rgb: got, in: space), Perceptual.lab(rgb: want, in: space))
            sumDeltaE += de
            if de > maxDeltaE { maxDeltaE = de }
        }
        let count = Double(lut.values.count)
        return IdentityResult(maxCodeDelta: maxDelta, tolerance: identityTolerance,
                              meanDeltaE: sumDeltaE / count, maxDeltaE: maxDeltaE)
    }
}