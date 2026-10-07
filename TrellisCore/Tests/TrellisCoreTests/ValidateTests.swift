//
//  ValidateTests.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import XCTest
@testable import TrellisCore

/// the validation report, the reversed-Hald locality test, the
/// grid residual and the identity test.
final class ValidateTests: XCTestCase {

    private func hald(_ level: Int = 8) -> RGBImage { HaldGenerator.identityImage(HaldSpec(level: level)) }
    private func reversedHald(_ level: Int = 8) -> RGBImage { HaldGenerator.reversedImage(HaldSpec(level: level)) }

    /// Applies a deterministic per-pixel function to a Hald's samples.
    private func mapSamples(_ image: RGBImage, _ fn: (UInt16) -> UInt16) -> RGBImage {
        let mapped = image.samples.map(fn)
        return RGBImage(width: image.width, height: image.height, samplesPerPixel: image.samplesPerPixel,
                        bitsPerSample: image.bitsPerSample, samples: mapped, iccProfile: image.iccProfile)
    }

    private func offsetImage(_ image: RGBImage, _ offset: Int) -> RGBImage {
        mapSamples(image) { code in UInt16(min(max(Int(code) + offset, 0), 65535)) }
    }

    // MARK: - Report

    func testCleanIdentityReport() {
        let report = Validate.report(forward: hald())
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.haldLevel, 8)
        XCTAssertNil(report.dimensions)
        XCTAssertNil(report.profile)
        XCTAssertNil(report.bitDepth)
        guard case .unverified = report.locality else { return XCTFail("expected unverified, got \(report.locality)") }
        guard case .clean = report.grossFilters else { return XCTFail("expected clean, got \(report.grossFilters)") }
    }

    func testReportWithReversedShowsCleanLocality() {
        let report = Validate.report(forward: hald(), reversed: reversedHald())
        XCTAssertTrue(report.ok)
        guard case .clean(let max, _) = report.locality else { return XCTFail("expected clean, got \(report.locality)") }
        XCTAssertEqual(max, 0)
    }

    func testReportDetectsSpatialOperatorFromReversedMismatch() {
        // Tamper with the reversed Hald: a uniform offset makes the reversed-
        // back comparison differ by > threshold codes, as HR/SR would.
        let tampered = offsetImage(reversedHald(), 20_000)
        let report = Validate.report(forward: hald(), reversed: tampered)
        guard case .spatialOperator = report.locality else { return XCTFail("expected spatialOperator, got \(report.locality)") }
    }

    func testReportRejectsWrongProfile() {
        let image = hald()
        let wrong = RGBImage(width: image.width, height: image.height, samples: image.samples,
                             iccProfile: Array(repeating: UInt8(0xC0), count: 64))
        let report = Validate.report(forward: wrong)
        XCTAssertFalse(report.ok)
        XCTAssertNotNil(report.profile)
        guard case .notAvailable = report.grossFilters else { return XCTFail("expected notAvailable, got \(report.grossFilters)") }
    }

    func testReportRejects8Bit() {
        let image = RGBImage(width: 512, height: 512, bitsPerSample: 8,
                             samples: Array(repeating: UInt16(128), count: 512 * 512 * 3),
                             iccProfile: ICCProfile.adobeRGB1998.data)
        let report = Validate.report(forward: image)
        XCTAssertFalse(report.ok)
        XCTAssertNotNil(report.bitDepth)
    }

    func testReportRejectsBadDimensions() {
        let image = RGBImage(width: 100, height: 100, samples: Array(repeating: UInt16(0), count: 30_000),
                             iccProfile: ICCProfile.adobeRGB1998.data)
        let report = Validate.report(forward: image)
        XCTAssertFalse(report.ok)
        XCTAssertNil(report.haldLevel)
        XCTAssertNotNil(report.dimensions)
    }

    // MARK: - Grid residual

    func testIdentityResidualIsQuantisationFloor() {
        // Reading a byte-exact identity Hald: the LUT is linear, so the
        // 6-neighbour predictor error is only the 16-bit quantisation floor.
        let lut = try! ProcessedHald.read(hald())
        let (rms, max) = Validate.gridResidual(lut)
        XCTAssertLessThanOrEqual(rms, 1e-5)
        XCTAssertLessThanOrEqual(max, 1e-5)
        // And the report verdict is clean.
        guard case .clean = Validate.report(forward: hald()).grossFilters else { return XCTFail("expected clean") }
    }

    func testNoisyResidualTriggersGrossFilter() {
        // Grain model: independent per-grid-point uniform noise, clipped to
        // range. ~±1% per channel gives rms residual ≈ 0.011, well above
        // grossRmsThreshold (0.005) — and ~15× the quantisation floor, so the
        // verdict is unambiguous.
        var state: UInt64 = 0xA076_1D64_78BD_642F
        let image = hald(4)
        var samples = [UInt16]()
        samples.reserveCapacity(image.samples.count)
        for code in image.samples {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(Int(state >> 33) % 2048) / 2048 * 2 - 1   // ≈ uniform [−1, 1)
            let v = Double(code) / 65535 + 0.01 * noise                  // σ ≈ 5.8e-3 per channel
            samples.append(UInt16(min(max(Int((v * 65535).rounded()), 0), 65535)))
        }
        let noisy = RGBImage(width: image.width, height: image.height, samples: samples,
                             iccProfile: image.iccProfile)
        let lut = try! ProcessedHald.read(noisy)
        let (rms, _) = Validate.gridResidual(lut)
        XCTAssertGreaterThan(rms, Validate.grossRmsThreshold)
        guard case .suspect = Validate.report(forward: noisy).grossFilters else { return XCTFail("expected suspect") }
    }

    // MARK: - Identity test

    func testIdentityHaldPassesIdentityTest() throws {
        let result = try Validate.identity(hald())
        XCTAssertTrue(result.pass)
        XCTAssertLessThan(result.maxCodeDelta, 1.0 / 1023.0)
        // The 16-bit Hald round-trips to within a code or two of mathematical
        // identity, so ΔE2000 to identity is tiny.
        XCTAssertLessThan(result.maxDeltaE, 0.01)
    }

    /// A gamma 0.9 look on the Hald breaks identity by far more than the
    /// tolerance, and the ΔE report reflects it.
    func testNonIdentityFailsIdentityTest() throws {
        let looked = mapSamples(hald()) { code in UInt16((pow(Double(code) / 65535, 0.9) * 65535).rounded()) }
        let result = try Validate.identity(looked)
        XCTAssertFalse(result.pass)
        XCTAssertGreaterThan(result.maxCodeDelta, 1.0 / 1023.0)
        XCTAssertGreaterThan(result.meanDeltaE, 0.01)
    }

    func testIdentityResultDescriptionMentionsPass() throws {
        let result = try Validate.identity(hald())
        XCTAssertTrue(result.description.contains("identity: PASS"))
    }

    // MARK: - Locality primitives

    func testLocalityEqualImagesIsClean() {
        let f = hald(4)
        let loc = Validate.locality(forward: f, reversed: reversedHald(4))
        guard case .clean = loc else { return XCTFail("expected clean, got \(loc)") }
    }

    func testLocalityMismatchedDimensionsIsUnverified() {
        let loc = Validate.locality(forward: hald(4), reversed: hald(8))
        guard case .unverified = loc else { return XCTFail("expected unverified, got \(loc)") }
    }
}