//
//  HaldTests.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import XCTest
@testable import TrellisCore

/// Hald geometry, identity generation and the validation chart.
final class HaldTests: XCTestCase {

    func testLevelGeometry() {
        XCTAssertEqual(HaldSpec.level8.steps, 64)
        XCTAssertEqual(HaldSpec.level8.size, 512)
        XCTAssertEqual(HaldSpec.level12.steps, 144)
        XCTAssertEqual(HaldSpec.level12.size, 1728)
    }

    func testLevelInferredFromDimensions() {
        XCTAssertEqual(HaldSpec(width: 512, height: 512), .level8)
        XCTAssertEqual(HaldSpec(width: 1728, height: 1728), .level12)
        XCTAssertNil(HaldSpec(width: 512, height: 511))
        XCTAssertNil(HaldSpec(width: 500, height: 500))
    }

    func testGridIndexAndPixelAreInverse() {
        let spec = HaldSpec(level: 4)
        for y in 0..<spec.size {
            for x in 0..<spec.size {
                let g = spec.gridIndex(x: x, y: y)
                let p = spec.pixel(r: g.r, g: g.g, b: g.b)
                XCTAssertEqual(p.x, x)
                XCTAssertEqual(p.y, y)
            }
        }
    }

    func testIdentityImageL8() {
        let spec = HaldSpec.level8
        let image = HaldGenerator.identityImage(spec)
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 512)
        XCTAssertEqual(image.bitsPerSample, 16)
        XCTAssertEqual(image.samplesPerPixel, 3)
        XCTAssertEqual(image.iccProfile, AdobeRGB1998Profile.bytes)

        // Red fastest, then green, then blue.
        XCTAssertTrue(image.rgb(x: 0, y: 0) == (0, 0, 0))
        XCTAssertTrue(image.rgb(x: 1, y: 0) == (spec.code16(1), 0, 0))
        XCTAssertTrue(image.rgb(x: 64, y: 0) == (0, spec.code16(1), 0))
        XCTAssertTrue(image.rgb(x: 511, y: 511) == (65535, 65535, 65535))
        let p = spec.pixel(r: 10, g: 20, b: 30)
        XCTAssertTrue(image.rgb(x: p.x, y: p.y) == (spec.code16(10), spec.code16(20), spec.code16(30)))

        // Every 16-bit code is within half a step of the exact grid value.
        for c in 0..<spec.steps {
            XCTAssertEqual(Double(spec.code16(c)) / 65535, spec.value(c), accuracy: 0.5 / 65535)
        }
    }

    func testValidationChart() {
        let chart = ValidationChart.standard
        let image = HaldGenerator.validationImage(chart)
        XCTAssertEqual(image.width, 11 * 64)
        XCTAssertEqual(image.height, 5 * 64)
        XCTAssertEqual(image.iccProfile, AdobeRGB1998Profile.bytes)
        XCTAssertEqual(chart.patches.count, 11 + 24)

        for p in chart.patches {
            let cx = p.column * chart.cellSize + chart.cellSize / 2
            let cy = p.row * chart.cellSize + chart.cellSize / 2
            XCTAssertTrue(image.rgb(x: cx, y: cy) == p.code, p.name)
        }
        let ramp = chart.patches.filter { $0.row == 0 }.map { $0.code.0 }
        XCTAssertEqual(ramp.first, 0)
        XCTAssertEqual(ramp.last, 65535)
        XCTAssertEqual(ramp, ramp.sorted())
        let green75 = chart.patches.first { $0.name == "green 75%" }!
        XCTAssertTrue(green75.code == (0, 49151, 0))
    }

    // MARK: - Reversed Hald

    func testReversedImageIsIdentityReversed() {
        let spec = HaldSpec.level8
        let identity = HaldGenerator.identityImage(spec)
        let reversed = HaldGenerator.reversedImage(spec)

        // Same geometry and metadata.
        XCTAssertEqual(reversed.width, identity.width)
        XCTAssertEqual(reversed.height, identity.height)
        XCTAssertEqual(reversed.samplesPerPixel, identity.samplesPerPixel)
        XCTAssertEqual(reversed.bitsPerSample, identity.bitsPerSample)
        XCTAssertEqual(reversed.iccProfile, identity.iccProfile)

        // Pixel 0 of the reversed image is pixel (last) of the identity, and
        // vice-versa. Channel order within each pixel is preserved.
        let last = spec.size - 1
        XCTAssertTrue(reversed.rgb(x: 0, y: 0) == identity.rgb(x: last, y: last))
        XCTAssertTrue(reversed.rgb(x: last, y: last) == identity.rgb(x: 0, y: 0))
        XCTAssertTrue(reversed.rgb(x: 1, y: 0) == identity.rgb(x: last - 1, y: last))
    }

    func testReverseComposeReverseIsIdentity() {
        // reverse ∘ reverse = identity, byte-exact .
        let spec = HaldSpec.level8
        let identity = HaldGenerator.identityImage(spec)
        let reversed = identity.reversedPixelOrder()
        let twice = reversed.reversedPixelOrder()

        XCTAssertEqual(twice.samples, identity.samples)
    }

    func testReversedImageRoundTripsThroughTiff() {
        // The reversed Hald survives a write→read round-trip with identical
        // code values (no colour management sneaking in).
        let spec = HaldSpec.level8
        let reversed = HaldGenerator.reversedImage(spec)
        let data = Tiff.encode(reversed)
        let decoded = try! Tiff.decode(data)

        XCTAssertEqual(decoded.width, reversed.width)
        XCTAssertEqual(decoded.height, reversed.height)
        XCTAssertEqual(decoded.samples, reversed.samples)
        XCTAssertEqual(decoded.iccProfile, reversed.iccProfile)
    }
}
