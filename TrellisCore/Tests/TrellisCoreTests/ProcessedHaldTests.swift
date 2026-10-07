//
//  ProcessedHaldTests.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import Foundation
import XCTest
@testable import TrellisCore

/// reading a processed Hald image back into the anchor look LUT.
final class ProcessedHaldTests: XCTestCase {

    private func assertClose(_ got: Vector3, _ want: Vector3, accuracy: Double, _ message: String = "") {
        let d = got - want
        XCTAssertEqual(sqrt((d * d).sum()), 0, accuracy: accuracy, message)
    }

    /// Runs `fn` on every 16-bit sample value, returning a new image — a way
    /// to apply a synthetic per-pixel look to a Hald *without* any of the real
    /// colour pipeline, so the reader is tested on its own.
    private func mapSamples(_ image: RGBImage, _ fn: (UInt16) -> UInt16) -> RGBImage {
        let mapped = image.samples.map(fn)
        return RGBImage(width: image.width, height: image.height, samplesPerPixel: image.samplesPerPixel,
                        bitsPerSample: image.bitsPerSample, samples: mapped, iccProfile: image.iccProfile)
    }

    // MARK: - Identity

    func testIdentityHaldReadsBackToIdentityLUT() throws {
        let lut = try ProcessedHald.read(HaldGenerator.identityImage(.level8))
        XCTAssertEqual(lut.size, 64)
        let want = LUT3D.identity(size: 64)
        // The 16-bit Hald quantises each grid value to the nearest 1/65535, so
        // the read-back LUT differs from the mathematical identity by ≤ 0.5 LSB
        // **per channel**.
        let halfStep = 0.5 / 65535.0
        for i in 0..<lut.values.count {
            let got = lut.values[i], exp = want.values[i]
            let worst = max(abs(got.x - exp.x), abs(got.y - exp.y), abs(got.z - exp.z))
            XCTAssertLessThanOrEqual(worst, halfStep, "node \(i)")
        }
    }

    func testReadIsByteExactThroughTiff() throws {
        // Encoding and decoding the TIFF must not change a single code value
        //, so the look LUT is identical before and after.
        let image = HaldGenerator.identityImage(HaldSpec(level: 4))
        let direct = try ProcessedHald.read(image)
        let roundTripped = try ProcessedHald.read(try Tiff.decode(Tiff.encode(image)))
        for i in 0..<direct.values.count {
            assertClose(roundTripped.values[i], direct.values[i], accuracy: 0, "node \(i)")
        }
    }

    func testFileConvenience() throws {
        let image = HaldGenerator.identityImage(HaldSpec(level: 4))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        try Tiff.write(image, to: url)
        XCTAssertEqual(try ProcessedHald.read(contentsOf: url), try ProcessedHald.read(image))
    }

    // MARK: - Synthetic looks

    /// A known per-pixel transform: pure gamma 0.9 on the code values. The
    /// read-back LUT must reproduce it at every grid point.
    func testGammaLookComesBackAsExpectedLUT() throws {
        let spec = HaldSpec(level: 4)
        let image = HaldGenerator.identityImage(spec)
        let looked = mapSamples(image) { code in UInt16((pow(Double(code) / 65535, 0.9) * 65535).rounded()) }
        let lut = try ProcessedHald.read(looked)

        // Model the full round trip: input code is quantised to 16-bit by the
        // Hald, the look transforms it, and the read-back normalises the
        // quantised result by its bit depth — so compare exactly, per channel.
        func expected(_ c: Int) -> Double {
            Double(UInt16((pow(Double(spec.code16(c)) / 65535, 0.9) * 65535).rounded())) / 65535
        }
        for b in 0..<spec.steps {
            for g in 0..<spec.steps {
                for r in 0..<spec.steps {
                    let v = lut[r, g, b]
                    let worst = max(abs(v.x - expected(r)), abs(v.y - expected(g)), abs(v.z - expected(b)))
                    XCTAssertEqual(worst, 0, accuracy: 1e-7, "grid \(r),\(g),\(b)")
                }
            }
        }
    }

    /// Reading the reversed Hald gives the identity LUT with its values
    /// reversed (the exact inverse of the generator's reversal).
    func testReversedHaldReadsBackReversed() throws {
        let spec = HaldSpec(level: 4)
        let identity = try ProcessedHald.read(HaldGenerator.identityImage(spec))
        let reversed = try ProcessedHald.read(HaldGenerator.reversedImage(spec))
        let halfStep = 0.5 / 65535.0
        for i in 0..<reversed.values.count {
            let got = reversed.values[i], exp = identity.values[identity.values.count - 1 - i]
            let worst = max(abs(got.x - exp.x), abs(got.y - exp.y), abs(got.z - exp.z))
            XCTAssertLessThanOrEqual(worst, halfStep, "node \(i)")
        }
    }

    // MARK: - Rejections

    func testRejectsWrongDimensions() {
        let image = RGBImage(width: 100, height: 100, samples: Array(repeating: 0, count: 30_000),
                             iccProfile: ICCProfile.adobeRGB1998.data)
        XCTAssertThrowsError(try ProcessedHald.read(image)) { error in
            XCTAssertTrue("\(error)".contains("Not a Hald"), "\(error)")
        }
    }

    func testRejects8Bit() {
        // 8-bit samples stored as 0…255, valid RGBImage, but not a 16-bit Hald.
        let image = RGBImage(width: 512, height: 512, bitsPerSample: 8,
                             samples: Array(repeating: UInt16(128), count: 512 * 512 * 3),
                             iccProfile: ICCProfile.adobeRGB1998.data)
        XCTAssertThrowsError(try ProcessedHald.read(image)) { error in
            XCTAssertTrue("\(error)".contains("8-bit"), "\(error)")
        }
    }

func testRejectsWrongProfileByName() throws {
        // A valid *profile* that is not Adobe RGB (1998): steal Adobe's bytes,
        // flip the gamma to 2.4, and it must be rejected by content.
        var bytes = AdobeRGB1998Profile.bytes
        let curv = try XCTUnwrap(findSubsequence(bytes, Array("curv".utf8)))
        bytes[curv + 13] = 0x66
        let image = HaldGenerator.identityImage(HaldSpec(level: 4))
        let wrong = RGBImage(width: image.width, height: image.height, samplesPerPixel: 3, bitsPerSample: 16,
                             samples: image.samples, iccProfile: bytes)
        XCTAssertThrowsError(try ProcessedHald.read(wrong)) { error in
            XCTAssertTrue("\(error)".contains("not Adobe RGB (1998)"), "\(error)")
        }
    }

    private func findSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) {
            if Array(haystack[i..<i + needle.count]) == needle { return i }
        }
        return nil
    }

    func testRejectsGarbageProfile() {
        let image = HaldGenerator.identityImage(HaldSpec(level: 4))
        let wrong = RGBImage(width: image.width, height: image.height, samplesPerPixel: 3, bitsPerSample: 16,
                             samples: image.samples, iccProfile: Array(repeating: UInt8(0xAB), count: 100))
        XCTAssertThrowsError(try ProcessedHald.read(wrong)) { error in
            XCTAssertTrue("\(error)".contains("not Adobe RGB (1998)"), "\(error)")
        }
    }

    func testRejectsNoProfile() {
        let image = HaldGenerator.identityImage(HaldSpec(level: 4))
        let wrong = RGBImage(width: image.width, height: image.height, samplesPerPixel: 3, bitsPerSample: 16,
                             samples: image.samples, iccProfile: nil)
        XCTAssertThrowsError(try ProcessedHald.read(wrong)) { error in
            XCTAssertTrue("\(error)".contains("no embedded profile"), "\(error)")
        }
    }
}