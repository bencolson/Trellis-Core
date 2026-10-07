//
//  CameraLogTests.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import Foundation
import XCTest
@testable import TrellisCore

/// Camera log curves, gamuts and CSTs, checked against colour-science
/// (see research/reference/camera_reference.py).
final class CameraLogTests: XCTestCase {

    private struct Reference: Decodable {
        struct Camera: Decodable {
            let curve: String
            let to_rec709: [Double]
            let to_adobeRGB1998: [Double]
            let samples: [[Double]]
            let rec709Gamma24: [String: [[Double]]]
        }
        let code_values: [Double]
        let curves: [String: [Double]]
        let cameras: [String: Camera]
    }

    private static let reference: Reference = {
        let url = Bundle.module.url(forResource: "camera_reference", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }()

    private static let camerasByName: [String: CameraLog] = [
        "arriLogC3": .arriLogC3, "arriLogC4": .arriLogC4,
        "sonySLog3Cine": .sonySLog3Cine, "sonySLog3": .sonySLog3,
        "panasonicVLog": .panasonicVLog, "canonLog2": .canonLog2, "canonLog3": .canonLog3,
        "redLog3G10": .redLog3G10, "appleLog": .appleLog, "fujifilmFLog2": .fujifilmFLog2,
        "djiDLog": .djiDLog, "nikonNLog": .nikonNLog,
        "blackmagicFilmGen5": .blackmagicFilmGen5, "davinciIntermediate": .davinciIntermediate,
    ]

    /// Relative where the value is large (log curves reach ~500 at code 1.0).
    private func assertClose(_ a: Double, _ b: Double, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: 1e-9 * max(1, abs(b)), message, file: file, line: line)
    }

    func testFixtureCoversEveryCurveAndCamera() {
        XCTAssertEqual(Set(Self.reference.curves.keys), Set(LogCurve.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(Self.camerasByName.values.map(\.label)), Set(CameraLog.all.map(\.label)))
        XCTAssertEqual(Set(Self.reference.cameras.keys), Set(Self.camerasByName.keys))
    }

    func testCurvesMatchColourScience() {
        let ref = Self.reference
        for curve in LogCurve.allCases {
            let expected = ref.curves[curve.rawValue]!
            for (v, e) in zip(ref.code_values, expected) {
                assertClose(curve.decode(v), e, "\(curve.label) at code value \(v)")
            }
        }
    }

    func testCameraCurvesMatchFixture() {
        for (name, camera) in Self.camerasByName {
            XCTAssertEqual(camera.curve.rawValue, Self.reference.cameras[name]!.curve, name)
        }
    }

    func testGamutMatricesMatchColourScience() {
        for (name, camera) in Self.camerasByName {
            let ref = Self.reference.cameras[name]!
            for (m, e) in zip(camera.primaries.matrix(to: .rec709).elements, ref.to_rec709) {
                XCTAssertEqual(m, e, accuracy: 1e-12, "\(name) → Rec. 709")
            }
            for (m, e) in zip(camera.primaries.matrix(to: .adobeRGB1998).elements, ref.to_adobeRGB1998) {
                XCTAssertEqual(m, e, accuracy: 1e-12, "\(name) → Adobe RGB (1998)")
            }
        }
    }

    func testCSTMatchesColourScience() {
        for (name, camera) in Self.camerasByName {
            let ref = Self.reference.cameras[name]!
            for mode in HighlightHandling.allCases {
                let cst = CameraConversion(from: camera, to: .rec709Gamma24, highlights: mode)
                for (input, expected) in zip(ref.samples, ref.rec709Gamma24[mode.rawValue]!) {
                    let out = cst.apply(Vector3(input[0], input[1], input[2]))
                    for c in 0..<3 {
                        XCTAssertEqual(out[c], expected[c], accuracy: 1e-12, "\(name) \(mode) \(input)")
                    }
                }
            }
        }
    }

    /// Vendor-published 18% grey code values (10-bit) decode to 0.18.
    func testPublishedGreyCodeValues() {
        XCTAssertEqual(LogCurve.sonySLog3.decode(420 / 1023), 0.18, accuracy: 1e-9)
        XCTAssertEqual(LogCurve.arriLogC3.decode(0.391007), 0.18, accuracy: 1e-5)
        XCTAssertEqual(LogCurve.panasonicVLog.decode(0.423311), 0.18, accuracy: 1e-5)
    }

    func testVideoRangeMapping() {
        XCTAssertEqual(CameraLog.codeValue(fromVideoRange: 0), 64 / 1023, accuracy: 1e-15)
        XCTAssertEqual(CameraLog.codeValue(fromVideoRange: 1), 940 / 1023, accuracy: 1e-15)
    }

    func testRollOffIsContinuousAndBounded() {
        let k = HighlightHandling.knee
        let below = HighlightHandling.rollOff.apply(Vector3(k, k / 2, 0))
        XCTAssertEqual(below, Vector3(k, k / 2, 0))
        let justAbove = HighlightHandling.rollOff.apply(Vector3(k + 1e-9, 0, 0))
        XCTAssertEqual(justAbove.x, k, accuracy: 1e-8)
        let huge = HighlightHandling.rollOff.apply(Vector3(1000, 500, 0))
        XCTAssertLessThan(huge.x, 1)
        XCTAssertEqual(huge.y / huge.x, 0.5, accuracy: 1e-12, "hue ratio kept")
    }
}
