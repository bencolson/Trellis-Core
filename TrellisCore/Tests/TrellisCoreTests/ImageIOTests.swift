//
//  ImageIOTests.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import Foundation
import XCTest
@testable import TrellisCore
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// unmanaged 16-bit TIFF I/O and the embedded ICC profile.
final class ImageIOTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return [UInt8](try Data(contentsOf: url))
    }

    /// Deterministic pseudo-random image covering the full 16-bit range.
    private func noiseImage(width: Int, height: Int, spp: Int = 3, bits: Int = 16) -> RGBImage {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let max = UInt64((1 << bits) - 1)
        let samples = (0..<(width * height * spp)).map { _ -> UInt16 in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt16((state >> 33) % (max + 1))
        }
        return RGBImage(width: width, height: height, samplesPerPixel: spp, bitsPerSample: bits,
                        samples: samples, iccProfile: ICCProfile.adobeRGB1998.data)
    }

    // MARK: - ICC

    func testEmbeddedProfileMatchesCommittedFile() throws {
        XCTAssertEqual(AdobeRGB1998Profile.bytes, try fixture("AdobeRGB1998", "icc"))
        XCTAssertEqual(AdobeRGB1998Profile.bytes.count, 560)
    }

    func testAdobeProfileIsRecognised() {
        let p = ICCProfile.adobeRGB1998
        XCTAssertEqual(p.description, "Adobe RGB (1998)")
        XCTAssertEqual(p.colorSpace, "RGB ")
        XCTAssertTrue(p.isAdobeRGB1998)
        guard case .gamma(let g)? = p.toneCurves?.red else { return XCTFail("expected a gamma curve") }
        XCTAssertEqual(g, 563.0 / 256.0)
    }

    /// The profile's colorants are our D65-derived matrix, Bradford-adapted to
    /// the ICC's D50 PCS white. An independent check that the parser reads the
    /// right bytes and that Adobe's profile really is the space Trellis derives.
    func testAdobeProfileColorantsMatchDerivedMatrix() throws {
        let c = try XCTUnwrap(ICCProfile.adobeRGB1998.colorants)
        let bradford = Matrix3x3(rows: [0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296])
        let d50 = Vector3(0.9642, 1.0, 0.8249)   // ICC PCS illuminant
        let d65 = Chromaticity.d65.xyz()
        let gain = (bradford * d50) / (bradford * d65)
        let scale = Matrix3x3(rows: [gain.x, 0, 0], [0, gain.y, 0], [0, 0, gain.z])
        let adapt = try XCTUnwrap(bradford.inverse) * scale * bradford
        let m = adapt * RGBPrimaries.adobeRGB1998.rgbToXYZ
        let derived = [Vector3(m[0, 0], m[1, 0], m[2, 0]), Vector3(m[0, 1], m[1, 1], m[2, 1]), Vector3(m[0, 2], m[1, 2], m[2, 2])]
        for (name, got, want) in zip3(["red", "green", "blue"], [c.red, c.green, c.blue], derived) {
            for k in 0..<3 { XCTAssertEqual(got[k], want[k], accuracy: 5e-4, "\(name)[\(k)]") }
        }
    }

    func testProfileWithDifferentGammaIsRejected() throws {
        var bytes = AdobeRGB1998Profile.bytes
        // Every TRC tag in Adobe's profile points at the same `curv`, value 0x0233.
        let curv = try XCTUnwrap(findSubsequence(bytes, Array("curv".utf8)))
        XCTAssertEqual(bytes[curv + 12], 0x02)
        XCTAssertEqual(bytes[curv + 13], 0x33)
        bytes[curv + 13] = 0x66  // 2.4
        let p = try ICCProfile(data: bytes)
        XCTAssertEqual(p.description, "Adobe RGB (1998)", "name alone must not be trusted")
        XCTAssertFalse(p.isAdobeRGB1998)
    }

    func testProfileWithDifferentPrimariesIsRejected() throws {
        var bytes = AdobeRGB1998Profile.bytes
        let rXYZ = try XCTUnwrap(tagOffset(bytes, "rXYZ"))
        bytes[rXYZ + 10] ^= 0x40   // nudge red X by ~1/1000
        XCTAssertFalse(try ICCProfile(data: bytes).isAdobeRGB1998)
    }

    func testGarbageIsNotAProfile() {
        XCTAssertThrowsError(try ICCProfile(data: Array(repeating: 0, count: 200)))
        XCTAssertThrowsError(try ICCProfile(data: [1, 2, 3]))
    }

    // MARK: - TIFF round trip

    func testRoundTripIsByteExactBothEndians() throws {
        for order in [Tiff.ByteOrder.littleEndian, .bigEndian] {
            for spp in [3, 4] {
                let image = noiseImage(width: 37, height: 23, spp: spp)
                let bytes = Tiff.encode(image, byteOrder: order)
                let back = try Tiff.decode(bytes)
                XCTAssertEqual(back, image, "\(order) spp=\(spp): code values must survive untouched")
                XCTAssertEqual(back.iccProfile, AdobeRGB1998Profile.bytes)
                XCTAssertEqual(Tiff.encode(back, byteOrder: order), bytes, "re-encode must be byte-identical")
            }
        }
    }

    func testRoundTrip8Bit() throws {
        let image = noiseImage(width: 10, height: 7, bits: 8)
        XCTAssertEqual(try Tiff.decode(Tiff.encode(image)), image)
    }

    func testRoundTripThroughFile() throws {
        let image = HaldGenerator.identityImage(HaldSpec(level: 4))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        try Tiff.write(image, to: url)
        XCTAssertEqual(try Tiff.read(contentsOf: url), image)
    }

    func testMultiStripImage() throws {
        // 512×512×6 bytes spans many 64 KiB strips.
        let image = HaldGenerator.identityImage(.level8)
        XCTAssertEqual(try Tiff.decode(Tiff.encode(image, byteOrder: .bigEndian)), image)
    }

    /// A big-endian TIFF built by hand, byte by byte, so the reader is checked
    /// against the TIFF 6.0 layout and not just against our own writer.
    func testDecodesHandBuiltBigEndianTiff() throws {
        var b: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
        let tags: [(UInt16, UInt16, UInt32, UInt32)] = [
            (256, 3, 1, 0x0002_0000),   // width 2 (SHORT, left-justified)
            (257, 3, 1, 0x0001_0000),   // height 1
            (258, 3, 3, 0),             // BitsPerSample → offset patched below
            (262, 3, 1, 0x0002_0000),   // RGB
            (273, 4, 1, 0),             // StripOffsets → patched
            (277, 3, 1, 0x0003_0000),   // 3 samples
            (279, 4, 1, 12),            // 12 bytes
        ]
        let ifdEnd = 8 + 2 + tags.count * 12 + 4
        let bpsOffset = UInt32(ifdEnd)
        let pixelOffset = UInt32(ifdEnd + 6)
        b += [0x00, UInt8(tags.count)]
        for (tag, type, count, value) in tags {
            let v = tag == 258 ? bpsOffset : tag == 273 ? pixelOffset : value
            b += be16(tag) + be16(type) + be32(count) + be32(v)
        }
        b += be32(0)
        b += be16(16) + be16(16) + be16(16)
        b += be16(0x0102) + be16(0x0304) + be16(0xFFFF) + be16(0) + be16(0x8000) + be16(0x00FF)

        let image = try Tiff.decode(b)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(image.bitsPerSample, 16)
        XCTAssertEqual(image.samples, [0x0102, 0x0304, 0xFFFF, 0, 0x8000, 0x00FF])
        XCTAssertNil(image.iccProfile)
    }

    func testCompressedTiffIsRejectedByName() throws {
        var bytes = Tiff.encode(noiseImage(width: 4, height: 4))
        // Little-endian IFD at 8; find tag 259 and set compression to LZW (5).
        let count = Int(bytes[8]) | Int(bytes[9]) << 8
        for i in 0..<count {
            let e = 10 + i * 12
            if bytes[e] == 0x03, bytes[e + 1] == 0x01 { bytes[e + 8] = 5 }
        }
        XCTAssertThrowsError(try Tiff.decode(bytes)) { error in
            XCTAssertTrue("\(error)".contains("LZW"), "\(error)")
        }
    }

    func testTruncatedAndNonTiffRejected() {
        let bytes = Tiff.encode(noiseImage(width: 8, height: 8))
        XCTAssertThrowsError(try Tiff.decode(Array(bytes.dropLast(10))))
        XCTAssertThrowsError(try Tiff.decode(Array("not a tiff at all".utf8)))
    }

    #if canImport(ImageIO)
    /// Independent reader: ImageIO must see the same dimensions, depth, profile
    /// and *raw* code values. Read from the data provider only, never drawn,
    /// because drawing is exactly where silent colour conversion happens.
    func testImageIOReadsSameCodeValues() throws {
        let image = noiseImage(width: 19, height: 11)
        for order in [Tiff.ByteOrder.littleEndian, .bigEndian] {
            let data = Data(Tiff.encode(image, byteOrder: order)) as CFData
            let src = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            XCTAssertEqual(cg.width, 19)
            XCTAssertEqual(cg.height, 11)
            XCTAssertEqual(cg.bitsPerComponent, 16)
            XCTAssertEqual(cg.bitsPerPixel, 48)
            let iccData = try XCTUnwrap(cg.colorSpace?.copyICCData()) as Data
            XCTAssertTrue(try ICCProfile(data: [UInt8](iccData)).isAdobeRGB1998)

            let raw = try XCTUnwrap(cg.dataProvider?.data) as Data
            let little = cg.bitmapInfo.contains(.byteOrder16Little)
            var values: [UInt16] = []
            for y in 0..<cg.height {
                let row = y * cg.bytesPerRow
                for i in 0..<(cg.width * 3) {
                    let a = UInt16(raw[row + 2 * i]), b = UInt16(raw[row + 2 * i + 1])
                    values.append(little ? a | b << 8 : a << 8 | b)
                }
            }
            XCTAssertEqual(values, image.samples, "\(order)")
        }
    }
    #endif

    // MARK: - Helpers

    private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private func be32(_ v: UInt32) -> [UInt8] { be16(UInt16(v >> 16)) + be16(UInt16(v & 0xFFFF)) }

    private func zip3<A, B, C>(_ a: [A], _ b: [B], _ c: [C]) -> [(A, B, C)] {
        zip(a, zip(b, c)).map { ($0, $1.0, $1.1) }
    }

    /// Data offset of an ICC tag, from the tag table.
    private func tagOffset(_ icc: [UInt8], _ sig: String) -> Int? {
        func u32(_ o: Int) -> Int { Int(icc[o]) << 24 | Int(icc[o + 1]) << 16 | Int(icc[o + 2]) << 8 | Int(icc[o + 3]) }
        for i in 0..<u32(128) where Array(icc[(132 + i * 12)..<(136 + i * 12)]) == Array(sig.utf8) {
            return u32(136 + i * 12)
        }
        return nil
    }

    private func findSubsequence(_ haystack: [UInt8], _ needle: [UInt8], from start: Int = 0) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for i in start...(haystack.count - needle.count) where Array(haystack[i..<i + needle.count]) == needle {
            return i
        }
        return nil
    }
}
