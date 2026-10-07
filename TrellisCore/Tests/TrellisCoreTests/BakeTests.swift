//
//  BakeTests.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import Foundation
import XCTest
@testable import TrellisCore

/// Baked output modes — chains, gamut handling, and parity against the
/// colour-science reference (research/reference/bake_reference.py).
final class BakeTests: XCTestCase {

    private struct Reference: Decodable {
        let adobe_gamma: Double
        let look_size: Int
        let look: [[Double]]
        struct Modes: Decodable {
            let anchor: [[Double]]
            let rec709_2_4: [[Double]]
            let rec709_2_2: [[Double]]
        }
        let modes: Modes
    }

    private static let reference: Reference = {
        let url = Bundle.module.url(forResource: "bake_reference", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }()

    /// The synthetic 8³ look LUT both sides bake.
    private func syntheticLook() -> LUT3D {
        let n = Self.reference.look_size
        let values = Self.reference.look.map { v in Vector3(v[0], v[1], v[2]) }
        return LUT3D(size: n, values: values)
    }

    private func assertLUTClose(_ got: LUT3D, _ want: [[Double]], accuracy: Double, _ message: String) {
        XCTAssertEqual(got.values.count, want.count, message)
        for (i, v) in got.values.enumerated() {
            let e = want[i]
            XCTAssertEqual(v.x, e[0], accuracy: accuracy, "\(message) [\(i)].x")
            XCTAssertEqual(v.y, e[1], accuracy: accuracy, "\(message) [\(i)].y")
            XCTAssertEqual(v.z, e[2], accuracy: accuracy, "\(message) [\(i)].z")
        }
    }

    // MARK: - Modes

    func testModeLabels() {
        XCTAssertEqual(Bake.Mode.anchor.label, "Anchor")
        XCTAssertEqual(Bake.Mode.rec709_2_4.label, "Rec 709 / 2.4")
        XCTAssertEqual(Bake.Mode.rec709_2_2.label, "Rec 709 / 2.2")
        XCTAssertEqual(Bake.Mode.anchor.fileSuffix, "anchor")
        XCTAssertEqual(Bake.Mode.rec709_2_4.fileSuffix, "rec709-2.4")
        XCTAssertEqual(Bake.Mode.rec709_2_2.fileSuffix, "rec709-2.2")
    }

    func testModeSpaces() {
        XCTAssertTrue(Bake.space(.anchor) == ColorSpace.adobeRGB1998)
        XCTAssertTrue(Bake.space(.rec709_2_4) == ColorSpace.rec709Gamma24)
        XCTAssertTrue(Bake.space(.rec709_2_2) == ColorSpace.rec709Gamma22)
    }

    func testHardClip() {
        let clipped = Bake.hardClip(Vector3(1.5, -0.25, 0.5))
        XCTAssertEqual(clipped.x, 1)
        XCTAssertEqual(clipped.y, 0)
        XCTAssertEqual(clipped.z, 0.5)
        // Identity on in-range values.
        let passthrough = Bake.hardClip(Vector3(0.2, 0.7, 0.9))
        XCTAssertEqual(passthrough.x, 0.2)
        XCTAssertEqual(passthrough.y, 0.7)
        XCTAssertEqual(passthrough.z, 0.9)
    }

    // MARK: - Bake chains

    /// Anchor mode is the look LUT only: baking = resampling the look.
    func testAnchorModeIsResample() {
        for size in [4, 33, 65] {
            let baked = Bake.bake(syntheticLook(), mode: .anchor, size: size)
            let resampled = syntheticLook().resample(to: size)
            for (i, v) in baked.values.enumerated() {
                let e = resampled.values[i]
                XCTAssertEqual(v.x, e.x, accuracy: 1e-12, "anchor [\(i)].x")
                XCTAssertEqual(v.y, e.y, accuracy: 1e-12, "anchor [\(i)].y")
                XCTAssertEqual(v.z, e.z, accuracy: 1e-12, "anchor [\(i)].z")
            }
        }
    }

    /// Adobe RGB green leaves the Rec 709 gamut (R comes out negative); the
    /// gamut handler must have clipped it to 0 in the baked chain.
    func testAdobeGreenClippedToRec709() {
        // A look that maps everything to Adobe green: every baked output is
        // the Rec 709 rendition of Adobe green, whose R is out of gamut.
        let green = LUT3D(size: 4, values: Array(repeating: Vector3(0, 1, 0), count: 64))
        let baked = Bake.bake(green, mode: .rec709_2_4, size: 2)
        for v in baked.values {
            XCTAssertEqual(v.x, 0, "R must be clipped to 0, got \(v.x)")
            XCTAssertGreaterThanOrEqual(v.y, 0)
            XCTAssertLessThanOrEqual(v.y, 1)
            XCTAssertGreaterThanOrEqual(v.z, 0)
            XCTAssertLessThanOrEqual(v.z, 1)
        }
        // The un-clipped Rec 709 code of Adobe green is genuinely negative R.
        let raw = ColorSpaceConversion(from: .adobeRGB1998, to: .rec709Gamma24).apply(Vector3(0, 1, 0))
        XCTAssertLessThan(raw.x, 0)
    }

    /// rec709-2.4 and rec709-2.2 differ only in the video curve; both map
    /// black→black and white→white exactly (power curves are 0↔0, 1↔1, and both
    /// matrices map the neutral axis to itself).
    func testRec709ModesKeepBlackAndWhite() {
        for mode in [Bake.Mode.rec709_2_4, .rec709_2_2] {
            let baked = Bake.bake(syntheticLook(), mode: mode, size: 33)
            XCTAssertEqual(baked.size, 33)
            let bottom = baked[0, 0, 0]
            XCTAssertEqual(bottom.x, 0, accuracy: 1e-9)
            XCTAssertEqual(bottom.y, 0, accuracy: 1e-9)
            XCTAssertEqual(bottom.z, 0, accuracy: 1e-9)
            let top = baked[32, 32, 32]
            XCTAssertEqual(top.x, 1, accuracy: 1e-6)
            XCTAssertEqual(top.y, 1, accuracy: 1e-6)
            XCTAssertEqual(top.z, 1, accuracy: 1e-6)
        }
    }

    // MARK: - Cross-implementation parity (colour-science)

    /// Swift `Bake.bake` must match the colour-science reference to 1e-6 for
    /// every mode on the parity grid.
    func testBakedModesMatchReference() {
        let look = syntheticLook()
        func check(_ mode: Bake.Mode, _ want: [[Double]]) {
            let baked = Bake.bake(look, mode: mode, size: 5)
            assertLUTClose(baked, want, accuracy: 1e-6, "\(mode)")
        }
        check(.anchor, Self.reference.modes.anchor)
        check(.rec709_2_4, Self.reference.modes.rec709_2_4)
        check(.rec709_2_2, Self.reference.modes.rec709_2_2)
    }

    func testFullSizes() {
        // The real shipping sizes through the real path.
        let look = syntheticLook()
        for size in [33, 65] {
            for mode in [Bake.Mode.anchor, .rec709_2_4, .rec709_2_2] {
                let baked = Bake.bake(look, mode: mode, size: size)
                XCTAssertEqual(baked.size, size, "\(mode) @ \(size)")
                XCTAssertEqual(baked.values.count, size * size * size)
                // Every baked value is a legal code value.
                for v in baked.values {
                    XCTAssertGreaterThanOrEqual(v.x, 0)
                    XCTAssertLessThanOrEqual(v.x, 1)
                    XCTAssertGreaterThanOrEqual(v.y, 0)
                    XCTAssertLessThanOrEqual(v.y, 1)
                    XCTAssertGreaterThanOrEqual(v.z, 0)
                    XCTAssertLessThanOrEqual(v.z, 1)
                }
            }
        }
    }
}