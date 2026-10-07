//
//  PerceptualTests.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import Foundation
import XCTest
@testable import TrellisCore

/// CIE L*a*b* (D65) and CIEDE2000, checked against colour-science 0.4.7
/// (see research/reference/deltaE_reference.py).
final class PerceptualTests: XCTestCase {

    private struct Set: Decodable {
        let input: [[Double]]
        let output: [[Double]]
    }

    private struct Reference: Decodable {
        let d65_xy: [Double]
        let d65_xyz: [Double]
        let xyz_to_lab: Set
        let rgb_to_lab_anchor: Set
        struct DeltaESet: Decodable {
            let a: [[Double]]
            let b: [[Double]]
            let delta_e: [Double]
        }
        let delta_e_2000: DeltaESet
    }

    private static let reference: Reference = {
        let url = Bundle.module.url(forResource: "deltaE_reference", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }()

    private func assertTripleEqual(_ got: [Double], _ want: [Double], accuracy: Double, _ message: String) {
        XCTAssertEqual(got.count, 3, message)
        for (i, (g, w)) in zip(got, want).enumerated() {
            XCTAssertEqual(g, w, accuracy: accuracy, "\(message) [\(i)]")
        }
    }

    func testD65MatchesReference() {
        XCTAssertEqual(Chromaticity.d65.x, Self.reference.d65_xy[0], accuracy: 1e-12, "d65 x")
        XCTAssertEqual(Chromaticity.d65.y, Self.reference.d65_xy[1], accuracy: 1e-12, "d65 y")
        // The exact XYZ Trellis derives (and colour-science agrees).
        let white = Chromaticity.d65.xyz()
        assertTripleEqual([white.x, white.y, white.z], Self.reference.d65_xyz, accuracy: 1e-12, "d65 xyz")
    }

    func testXYZToLabMatchesColourScience() {
        let white = Chromaticity.d65.xyz()
        for (i, input) in Self.reference.xyz_to_lab.input.enumerated() {
            let xyz = Vector3(input[0], input[1], input[2])
            let lab = Perceptual.lab(xyz: xyz, whitePoint: white)
            let want = Self.reference.xyz_to_lab.output[i]
            assertTripleEqual([lab.l, lab.a, lab.b], want, accuracy: 1e-6, "lab \(input)")
        }
    }

    /// The full anchor-space chain — decode → 3×3 → Lab — compared to
    /// colour-science's equivalent. The matrices are both primaries-derived
    /// and the white points are the same D65, so this is a check of the whole
    /// plumbing, at a looser tolerance than the primitives above.
    func testRGBToLabAnchorMatchesColourScience() {
        for (i, input) in Self.reference.rgb_to_lab_anchor.input.enumerated() {
            let rgb = Vector3(input[0], input[1], input[2])
            let lab = Perceptual.lab(rgb: rgb, in: .adobeRGB1998)
            let want = Self.reference.rgb_to_lab_anchor.output[i]
            assertTripleEqual([lab.l, lab.a, lab.b], want, accuracy: 1e-4, "rgb→lab \(input)")
        }
    }

    func testDeltaE2000MatchesColourScience() {
        for (i, (a, b)) in zip(Self.reference.delta_e_2000.a, Self.reference.delta_e_2000.b).enumerated() {
            let labA = Perceptual.Lab(l: a[0], a: a[1], b: a[2])
            let labB = Perceptual.Lab(l: b[0], a: b[1], b: b[2])
            let got = Perceptual.deltaE2000(labA, labB)
            let want = Self.reference.delta_e_2000.delta_e[i]
            XCTAssertEqual(got, want, accuracy: 1e-6, "ΔE2000 pair \(i)")
        }
    }

    /// The most-cited CIEDE2000 test vector, independent of the fixture
    /// plumbing: Sharma et al. 2005 Table 1, pair 1.
    func testDeltaE2000CanonicalValue() {
        let a = Perceptual.Lab(l: 50.0, a: 2.6772, b: -79.7751)
        let b = Perceptual.Lab(l: 50.0, a: 0.0, b: -82.7485)
        XCTAssertEqual(Perceptual.deltaE2000(a, b), 2.0425, accuracy: 2e-4)
    }

    func testDeltaE2000IdenticalColorsIsZero() {
        let a = Perceptual.Lab(l: 50.0, a: 0.0, b: 0.0)
        XCTAssertEqual(Perceptual.deltaE2000(a, a), 0.0, accuracy: 1e-12)
        // Two neutral colours differing only in lightness: ΔE00 = ΔL′/S_L where
        // S_L at L̄′ = 52 is 1 + 0.015·(L̄′−50)²/√(20+(L̄′−50)²). 4/1.01225 ≈ 3.952.
        let b = Perceptual.Lab(l: 54.0, a: 0.0, b: 0.0)
        let sL = 1 + 0.015 * 4 / sqrt(24)
        XCTAssertEqual(Perceptual.deltaE2000(a, b), 4.0 / sL, accuracy: 1e-6)
    }
}