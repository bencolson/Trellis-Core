//
//  GamutCompressTests.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import Foundation
import XCTest
@testable import TrellisCore

/// Soft gamut compression (M4.2): derived limits, the pre-clip compression
/// maths, the property guarantees, parity with the independent numpy
/// reference (gamut_reference.json), and the bake tally.
final class GamutCompressTests: XCTestCase {

    private struct Reference: Decodable {
        let threshold: Double
        let limits: [Double]
        let max_a: Double
        let adobe_to_rec709: [Double]
        struct Point: Decodable {
            let `in`: [Double]
            let out: [Double]
        }
        let points: [Point]
        struct Curve: Decodable {
            let threshold: Double
            let points: [Point]
        }
        let curve: Curve
    }

    private static let reference: Reference = {
        let url = Bundle.module.url(forResource: "gamut_reference", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }()

    private func vec(_ v: [Double]) -> Vector3 { Vector3(v[0], v[1], v[2]) }

    private func close(_ a: Vector3, _ b: Vector3, accuracy: Double,
                       _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, message, file: file, line: line)
    }

    /// A dense grid of Adobe RGB code values decoded to linear light and run
    /// through the Adobe → Rec 709 matrix: the handler's whole input domain.
    private func adobeLinear709Grid(steps: Int = 17) -> [Vector3] {
        let m = RGBPrimaries.adobeRGB1998.matrix(to: .rec709)
        var grid: [Vector3] = []
        for b in 0..<steps {
            for g in 0..<steps {
                for r in 0..<steps {
                    let code = Vector3(Double(r) / Double(steps - 1),
                                       Double(g) / Double(steps - 1),
                                       Double(b) / Double(steps - 1))
                    grid.append(m * TransferFunction.adobeRGB1998.decode(code))
                }
            }
        }
        return grid
    }

    private func maxNorm(_ v: Vector3) -> Double { max(max(abs(v.x), abs(v.y)), abs(v.z)) }

    // MARK: - Derived limits vs the independent Python reference

    func testLimitsMatchIndependentPythonCalculation() {
        let limits = Bake.adobeToRec709Limits
        let want = vec(Self.reference.limits)
        // colour-science and Trellis derive the matrices independently; D3
        // pins them together at ~5e-6, so assert at 1e-5 with headroom.
        close(limits, want, accuracy: 1e-5, "adobeToRec709Limits")
        XCTAssertEqual(Bake.adobeToRec709MaxA, Self.reference.max_a, accuracy: 1e-5)
    }

    func testLimitsAreTheGreenCyanBoundary() {
        // Only the green/cyan half of the boundary violates Rec 709, and only
        // R (negative) and B (negative) channels — so their limits exceed 1
        // and G's does not.
        XCTAssertGreaterThan(Bake.adobeToRec709Limits.x, 1)
        XCTAssertGreaterThan(Bake.adobeToRec709Limits.z, 1)
        XCTAssertLessThanOrEqual(Bake.adobeToRec709Limits.y, 1)
    }

    // MARK: - Parity with the numpy reference

    func testAllFixturePointsMatchReference() {
        let handler = Bake.gamutCompress(threshold: Self.reference.threshold)
        for p in Self.reference.points {
            close(handler(vec(p.`in`)), vec(p.out), accuracy: 1e-6,
                  "default-threshold point \(p.`in`)")
        }
        let graded = Bake.gamutCompress(threshold: Self.reference.curve.threshold)
        for p in Self.reference.curve.points {
            close(graded(vec(p.`in`)), vec(p.out), accuracy: 1e-6,
                  "graded (t=\(Self.reference.curve.threshold)) point \(p.`in`)")
        }
    }

    // MARK: - The pre-clip maths is the real response (safety net is noise) (M4.2 task 3)

    func testCompressionLandsEveryAdobeColourInsideRec709() {
        let threshold = 1.0
        let maxDistance = max(max(Bake.adobeToRec709Limits.x, Bake.adobeToRec709Limits.y), Bake.adobeToRec709Limits.z)
        let maxA = Bake.adobeToRec709MaxA
        for v in adobeLinear709Grid() {
            let out = Bake.compressInto(v, threshold: threshold, maxDistance: maxDistance, maxA: maxA)
            // Inside [0, 1] to float noise: the safety clip would change nothing.
            XCTAssertGreaterThanOrEqual(out.x, -1e-12, "R for \(v)")
            XCTAssertLessThanOrEqual(out.x, 1 + 1e-12, "R for \(v)")
            XCTAssertGreaterThanOrEqual(out.y, -1e-12, "G for \(v)")
            XCTAssertLessThanOrEqual(out.y, 1 + 1e-12, "G for \(v)")
            XCTAssertGreaterThanOrEqual(out.z, -1e-12, "B for \(v)")
            XCTAssertLessThanOrEqual(out.z, 1 + 1e-12, "B for \(v)")
            // And the clip really is a no-op on that population.
            let net = Bake.hardClip(out)
            XCTAssertLessThanOrEqual(maxNorm(out - net), 1e-12, "hard clip touched \(v)")
        }
    }

    // MARK: - Properties (M4.2 task 4)

    func testIdentityInsideTheThreshold() {
        // In-gamut linear Rec 709 (all channels in [0,1]) must pass through
        // bit-identically at the default threshold.
        let handler = Bake.gamutCompress()
        for v in adobeLinear709Grid() where maxNorm(v) <= 1.0 - 1e-12 && v.x >= 0 && v.y >= 0 && v.z >= 0 {
            XCTAssertEqual(handler(v), v, "in-gamut \(v) changed")
        }
    }

    func testNeutralStaysNeutral() {
        let handler = Bake.gamutCompress()
        for g in stride(from: 0.0, through: 1.4, by: 0.1) {
            XCTAssertEqual(handler(Vector3(g, g, g)), Vector3(min(g, 1), min(g, 1), min(g, 1)))
        }
    }

    func testHuePreservedRatiosOfDistancesUnchanged() {
        // The scalar k scales every channel's distance from the (compressed)
        // achromatic value by the same factor: for every channel whose
        // pre-compression distance is non-zero, post/pre distance equals the
        // same k, so the channel ratios are unchanged.
        let t = 1.0
        let maxDistance = max(max(Bake.adobeToRec709Limits.x, Bake.adobeToRec709Limits.y), Bake.adobeToRec709Limits.z)
        let maxA = Bake.adobeToRec709MaxA
        for v in adobeLinear709Grid(steps: 9) {
            let a = max(max(v.x, v.y), v.z)
            guard a > 0, a > t || max((a - v.x) / a, (a - v.y) / a, (a - v.z) / a) > t else { continue }
            let out = Bake.compressInto(v, threshold: t, maxDistance: maxDistance, maxA: maxA)
            let ap = max(max(out.x, out.y), out.z)
            var ratios: [Double] = []
            for (c, cp) in zip([v.x, v.y, v.z], [out.x, out.y, out.z]) {
                let d = (a - c) / a
                if d > 1e-12 {
                    ratios.append(((ap - cp) / ap) / d)
                }
            }
            XCTAssertGreaterThan(ratios.count, 0, "no quantifiable channels for \(v)")
            XCTAssertLessThanOrEqual(ratios.max()! - ratios.min()!, 1e-9,
                                     "distance ratios not uniform for \(v): \(ratios)")
        }
    }

    func testContinuousAndMonotonicAcrossTheThreshold() {
        // Sweep along the worst out-of-gamut direction (R going negative at
        // high luma) and across the luma side (a going above 1); the output
        // must move monotonically with no steps beyond compression smoothness.
        let handler = Bake.gamutCompress()
        var last: Vector3 = handler(Vector3(0.0, 1.0, 0.05))
        for r in stride(from: -0.02, through: -0.4, by: -0.02) {
            let v = Vector3(r, 1.0, 0.05)
            let out = handler(v)
            XCTAssertLessThanOrEqual(out.x, last.x + 1e-9, "R must not increase as it goes further out")
            XCTAssertLessThanOrEqual(maxNorm(out - last), 0.02 + 1e-9, "no step in the chromatic sweep at R=\(r)")
            last = out
        }
        last = handler(Vector3(-0.1, 0.99, 0.04))
        for a in stride(from: 1.0, through: 1.4, by: 0.04) {
            let out = handler(Vector3(-0.1, a, 0.04))
            XCTAssertLessThanOrEqual(maxNorm(out - last), 0.04 + 1e-9, "no step in the luma sweep at a=\(a)")
            last = out
        }
    }

    func testExtremeGreenCornerLandsExactlyOnTheBoundary() {
        // The pure Adobe green primary's Rec 709 rendition: R is the furthest
        // any Adobe colour goes (its channel's limit), so it must land exactly
        // on the boundary — R = 0 after compression, nothing needs clipping.
        let m = RGBPrimaries.adobeRGB1998.matrix(to: .rec709)
        let green = m * Vector3(0, 1, 0)
        XCTAssertLessThan(green.x, 0)  // confirmed out of gamut
        let handler = Bake.gamutCompress()
        let out = handler(green)
        XCTAssertEqual(out.x, 0, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(out.y, 1 + 1e-12)
    }

    // MARK: - bake tally (M4.2 task: report)

    func testBakeTallyCountsCompressVsClip() {
        // A look that maps everything to saturated Adobe green: its Rec 709
        // rendition genuinely falls out of gamut (R ≈ −0.4).
        let look = LUT3D(size: 4, values: Array(repeating: Vector3(0, 1, 0), count: 64))
        // Same look, both handlers, same grid: hard clip fixes the out-of-gamut
        // points inside the handler (so the safety net never fires — they count
        // as compressed); soft compression moves them too, and the two LUTs
        // differ where out-of-gamut content is.
        let clip = Bake.bakeWithReport(look, mode: .rec709_2_4, size: 4, gamut: Bake.hardClip)
        XCTAssertGreaterThan(clip.tally.compressed, 0)
        XCTAssertEqual(clip.tally.clipped, 0)
        let compress = Bake.bakeWithReport(look, mode: .rec709_2_4, size: 4, gamut: Bake.gamutCompress())
        XCTAssertGreaterThan(compress.tally.compressed, 0)
        XCTAssertEqual(compress.tally.clipped, 0)
        XCTAssertNotEqual(clip.lut.values, compress.lut.values)
        XCTAssertEqual(clip.lut.size, compress.lut.size)
    }

    func testBakeTallyCountsSafetyNetTrims() {
        // A handler that does no clipping passes out-of-gamut values through,
        // so the bake-level safety net is the only thing left — those points
        // report as clipped.
        let look = LUT3D(size: 4, values: Array(repeating: Vector3(0, 1, 0), count: 64))
        let result = Bake.bakeWithReport(look, mode: .rec709_2_4, size: 4, gamut: { $0 })
        XCTAssertEqual(result.tally.compressed, 0)
        XCTAssertGreaterThan(result.tally.clipped, 0)
        for value in result.lut.values {
            XCTAssertGreaterThanOrEqual(value.x, 0)
            XCTAssertLessThanOrEqual(value.x, 1)
        }
    }

    func testBakeTallyIsZeroInsideTheGamut() {
        // The anchor path never sees a gamut handler, so nothing to tally.
        let look = LUT3D.identity(size: 4)
        let result = Bake.bakeWithReport(look, mode: .anchor, size: 4, gamut: Bake.gamutCompress())
        XCTAssertEqual(result.tally.compressed, 0)
        XCTAssertEqual(result.tally.clipped, 0)
    }

    // MARK: - Hard clip at the new (linear) swap point is bit-identical (M4.2 task 1)

    func testHardClipIsBitIdenticalBeforeAndAfterEncode() {
        for gamma in [2.4, 2.2, 563.0 / 256.0] {
            let tf = TransferFunction.power(gamma: gamma)
            for x in stride(from: -0.5, through: 1.5, by: 0.03125) {
                let v = Vector3(x, 0.7, 0.5)
                let before = Bake.hardClip(tf.encode(v))   // M4's swap point (after encode)
                let after = tf.encode(Bake.hardClip(v))    // M4.2's swap point (linear)
                XCTAssertEqual(after.x, before.x, "encode≠clip-commute at \(x) for γ\(gamma)")
            }
        }
    }
}