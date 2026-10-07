//
//  ColorSpaceTests.swift
//  TrellisCore
//
//  Created by Ben Colson on 06/10/2026.
//

import Foundation
import XCTest
@testable import TrellisCore

/// matrices derived from primaries, transfer functions, conversions.
/// Checked against published values and against colour-science
/// (see research/reference/colorspace_reference.py).
final class ColorSpaceTests: XCTestCase {

    // MARK: - Fixture

    private struct Reference: Decodable {
        struct Transfer: Decodable {
            let input: [Double]
            let adobeRGB1998_decode: [Double]
            let gamma24_decode: [Double]
            let gamma22_decode: [Double]
        }
        struct Conversion: Decodable {
            let from: String
            let to: String
            let input: [[Double]]
            let output: [[Double]]
        }
        let d65_xy: [Double]
        let rgb_to_xyz: [String: [Double]]
        let rec709_to_adobeRGB1998: [Double]
        let adobeRGB1998_to_rec709: [Double]
        let transfer: Transfer
        let conversions: [Conversion]
    }

    private static let reference: Reference = {
        let url = Bundle.module.url(forResource: "colorspace_reference", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }()

    private func space(named name: String) -> ColorSpace {
        switch name {
        case "adobeRGB1998": return .adobeRGB1998
        case "rec709Gamma24": return .rec709Gamma24
        case "rec709Gamma22": return .rec709Gamma22
        default: fatalError("Unknown space in fixture: \(name)")
        }
    }

    private func assertEqual(_ a: [Double], _ b: [Double], accuracy: Double,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, message, file: file, line: line)
        for (i, (x, y)) in zip(a, b).enumerated() {
            XCTAssertEqual(x, y, accuracy: accuracy, "\(message) [\(i)]", file: file, line: line)
        }
    }

    /// Tolerance for encoded code values after a conversion.
    ///
    /// Matrix products leave ~1e-16 of float noise in linear light. A power curve
    /// is steep at zero, so encoding turns that into up to ~1e-7 near black
    /// (1e-16 ^ (1/2.4) ≈ 2e-7). 1e-6 is still ~0.07 of a 16-bit code value.
    private let codeValueTolerance = 1e-6

    // MARK: - Published values

    func testAdobeRGBMatrixMatchesPublishedSpec() {
        // Adobe RGB (1998) Color Image Encoding, §4.3.4.1 (normalised, Y_white = 1).
        let published: [Double] = [
            0.57667, 0.18556, 0.18823,
            0.29734, 0.62736, 0.07529,
            0.02703, 0.07069, 0.99134,
        ]
        assertEqual(RGBPrimaries.adobeRGB1998.rgbToXYZ.elements, published, accuracy: 5e-6)
    }

    func testRec709MatrixMatchesPublishedValues() {
        // The widely published 4-decimal BT.709 / sRGB RGB→XYZ matrix.
        let published: [Double] = [
            0.4124, 0.3576, 0.1805,
            0.2126, 0.7152, 0.0722,
            0.0193, 0.1192, 0.9505,
        ]
        assertEqual(RGBPrimaries.rec709.rgbToXYZ.elements, published, accuracy: 5e-5)
    }

    func testRec709LumaRowMatchesBT709() {
        // BT.709 Item 3.2: Y = 0.2126 R + 0.7152 G + 0.0722 B.
        let m = RGBPrimaries.rec709.rgbToXYZ
        XCTAssertEqual(m[1, 0], 0.2126, accuracy: 5e-5)
        XCTAssertEqual(m[1, 1], 0.7152, accuracy: 5e-5)
        XCTAssertEqual(m[1, 2], 0.0722, accuracy: 5e-5)
    }

    func testAdobeGammaIsExactly563Over256() {
        XCTAssertEqual(TransferFunction.adobeRGB1998, .power(gamma: 2.19921875))
        XCTAssertNotEqual(TransferFunction.adobeRGB1998, .gamma22)
    }

    // MARK: - Against colour-science

    func testD65MatchesColourScience() {
        XCTAssertEqual(Chromaticity.d65.x, Self.reference.d65_xy[0], accuracy: 1e-12)
        XCTAssertEqual(Chromaticity.d65.y, Self.reference.d65_xy[1], accuracy: 1e-12)
    }

    func testRGBToXYZMatchesColourScience() {
        let ref = Self.reference.rgb_to_xyz
        assertEqual(RGBPrimaries.adobeRGB1998.rgbToXYZ.elements, ref["adobeRGB1998"]!, accuracy: 1e-12, "Adobe RGB")
        assertEqual(RGBPrimaries.rec709.rgbToXYZ.elements, ref["rec709"]!, accuracy: 1e-12, "Rec. 709")
    }

    func testPrimariesMatricesMatchColourScience() {
        assertEqual(RGBPrimaries.rec709.matrix(to: .adobeRGB1998).elements,
                    Self.reference.rec709_to_adobeRGB1998, accuracy: 1e-12, "709 → Adobe")
        assertEqual(RGBPrimaries.adobeRGB1998.matrix(to: .rec709).elements,
                    Self.reference.adobeRGB1998_to_rec709, accuracy: 1e-12, "Adobe → 709")
    }

    func testTransferFunctionsMatchColourScience() {
        let t = Self.reference.transfer
        assertEqual(t.input.map(TransferFunction.adobeRGB1998.decode), t.adobeRGB1998_decode, accuracy: 1e-14, "Adobe")
        assertEqual(t.input.map(TransferFunction.gamma24.decode), t.gamma24_decode, accuracy: 1e-14, "2.4")
        assertEqual(t.input.map(TransferFunction.gamma22.decode), t.gamma22_decode, accuracy: 1e-14, "2.2")
    }

    func testConversionsMatchColourScience() {
        for c in Self.reference.conversions {
            let conversion = ColorSpaceConversion(from: space(named: c.from), to: space(named: c.to))
            for (input, expected) in zip(c.input, c.output) {
                let out = conversion.apply(Vector3(input[0], input[1], input[2]))
                assertEqual([out.x, out.y, out.z], expected, accuracy: codeValueTolerance, "\(c.from) → \(c.to) \(input)")
            }
        }
    }

    // MARK: - Properties

    func testWhiteMapsToWhite() {
        for p in [RGBPrimaries.adobeRGB1998, .rec709] {
            let xyz = p.rgbToXYZ * Vector3(1, 1, 1)
            let d65 = Chromaticity.d65.xyz()
            assertEqual([xyz.x, xyz.y, xyz.z], [d65.x, d65.y, d65.z], accuracy: 1e-14, p.name)
        }
        let m = RGBPrimaries.rec709.matrix(to: .adobeRGB1998)
        let w = m * Vector3(1, 1, 1)
        assertEqual([w.x, w.y, w.z], [1, 1, 1], accuracy: 1e-14)
    }

    func testMatrixInverseRoundTrip() {
        let m = RGBPrimaries.adobeRGB1998.rgbToXYZ
        assertEqual((m * m.inverse!).elements, Matrix3x3.identity.elements, accuracy: 1e-14)
        assertEqual((m.inverse! * m).elements, Matrix3x3.identity.elements, accuracy: 1e-14)
    }

    func testTransferRoundTrip() {
        for tf in [TransferFunction.adobeRGB1998, .gamma24, .gamma22, .linear] {
            for v in stride(from: -0.2, through: 1.2, by: 0.01) {
                XCTAssertEqual(tf.encode(tf.decode(v)), v, accuracy: 1e-13, "\(tf.label) at \(v)")
            }
        }
    }

    func testNegativeValuesAreMirroredNotNaN() {
        XCTAssertEqual(TransferFunction.gamma24.decode(-0.5), -pow(0.5, 2.4), accuracy: 1e-15)
        XCTAssertFalse(TransferFunction.adobeRGB1998.encode(-1e-9).isNaN)
    }

    func testColorSpaceRoundTrip() {
        let there = ColorSpaceConversion(from: .rec709Gamma24, to: .adobeRGB1998)
        let back = ColorSpaceConversion(from: .adobeRGB1998, to: .rec709Gamma24)
        for r in stride(from: 0.0, through: 1.0, by: 0.125) {
            for g in stride(from: 0.0, through: 1.0, by: 0.125) {
                for b in stride(from: 0.0, through: 1.0, by: 0.125) {
                    let v = Vector3(r, g, b)
                    let rt = back.apply(there.apply(v))
                    assertEqual([rt.x, rt.y, rt.z], [r, g, b], accuracy: codeValueTolerance)
                }
            }
        }
    }

    func testRec709IsInsideAdobeRGB() {
        // Rec. 709 → Adobe RGB never goes out of range.
        let conv = ColorSpaceConversion(from: .rec709Gamma24, to: .adobeRGB1998)
        for r in stride(from: 0.0, through: 1.0, by: 0.1) {
            for g in stride(from: 0.0, through: 1.0, by: 0.1) {
                for b in stride(from: 0.0, through: 1.0, by: 0.1) {
                    let o = conv.apply(Vector3(r, g, b))
                    for c in [o.x, o.y, o.z] {
                        XCTAssertGreaterThanOrEqual(c, -codeValueTolerance)
                        XCTAssertLessThanOrEqual(c, 1 + codeValueTolerance)
                    }
                }
            }
        }
    }

    func testAdobeGreenIsOutsideRec709() {
        // Adobe RGB → Rec. 709 can leave [0, 1]; the gamut handler deals with it, not the conversion.
        let o = ColorSpaceConversion(from: .adobeRGB1998, to: .rec709Gamma24).apply(Vector3(0, 1, 0))
        XCTAssertLessThan(o.x, 0)
    }

    func testLabels() {
        XCTAssertEqual(ColorSpace.adobeRGB1998.label, "Adobe RGB (1998) / gamma 563/256 (2.19921875)")
        XCTAssertEqual(ColorSpace.rec709Gamma24.label, "Rec. 709 / gamma 2.4")
        XCTAssertEqual(ColorSpace.rec709Gamma22.label, "Rec. 709 / gamma 2.2")
    }
}
