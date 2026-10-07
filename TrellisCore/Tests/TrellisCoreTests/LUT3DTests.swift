//
//  LUT3DTests.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import XCTest
@testable import TrellisCore

/// 3D LUT storage, tetrahedral interpolation and resampling.
final class LUT3DTests: XCTestCase {

    private func distance(_ a: Vector3, _ b: Vector3) -> Double {
        let d = a - b
        return sqrt((d * d).sum())
    }

    private func assertClose(_ a: Vector3, _ b: Vector3, accuracy: Double, _ message: String = "") {
        XCTAssertEqual(distance(a, b), 0, accuracy: accuracy, message)
    }

    // MARK: - Identity LUT

    func testIdentityLUTValues() {
        let lut = LUT3D.identity(size: 4)
        XCTAssertEqual(lut.size, 4)
        XCTAssertEqual(lut.values.count, 64)
        // Red fastest, green, blue; value = index / (N−1).
        XCTAssertTrue(lut[0, 0, 0] == Vector3(0, 0, 0))
        XCTAssertTrue(lut[1, 0, 0] == Vector3(1.0 / 3, 0, 0))
        XCTAssertTrue(lut[0, 1, 0] == Vector3(0, 1.0 / 3, 0))
        XCTAssertTrue(lut[0, 0, 1] == Vector3(0, 0, 1.0 / 3))
        XCTAssertTrue(lut[3, 3, 3] == Vector3(1, 1, 1))
    }

    // MARK: - Tetrahedral sampling

    func testSampleIsExactAtGridPoints() {
        let lut = LUT3D.identity(size: 8)
        for b in 0..<8 {
            for g in 0..<8 {
                for r in 0..<8 {
                    let got = lut.sample(Double(r) / 7, Double(g) / 7, Double(b) / 7)
                    assertClose(got, lut[r, g, b], accuracy: 1e-12, "grid \(r),\(g),\(b)")
                }
            }
        }
    }

    func testSampleInterpolatesLinearlyInsideACell() {
        // size 2 identity: the only cell is the whole unit cube, and
        // tetrahedral interpolation of the identity is the identity.
        let lut = LUT3D.identity(size: 2)
        for (r, g, b) in [(0.5, 0.5, 0.5), (0.25, 0.75, 0.5), (0.1, 0.9, 0.2), (1.0, 1.0, 1.0), (0.0, 0.0, 0.0)] {
            assertClose(lut.sample(r, g, b), Vector3(r, g, b), accuracy: 1e-12, "sample \(r),\(g),\(b)")
        }
    }

    func testSampleClampsOutOfRange() {
        let lut = LUT3D.identity(size: 4)
        // Below the domain clamps to the boundary face.
        assertClose(lut.sample(-0.5, 0.3, 0.3), Vector3(0, 0.3, 0.3), accuracy: 1e-12)
        assertClose(lut.sample(1.5, 0.6, 0.2), Vector3(1, 0.6, 0.2), accuracy: 1e-12)
        assertClose(lut.sample(2.0, 2.0, 2.0), Vector3(1, 1, 1), accuracy: 1e-12)
    }

    /// Tetrahedral interpolation is exact for any LUT that is linear in RGB
    /// coordinates, because every tetrahedron's linear interpolation of a
    /// linear function lands on the function itself. The identity is such a
    /// function; a resampled identity must therefore be the identity again.
    func testResampleIdentityStaysIdentity() {
        let ident = LUT3D.identity(size: 64)
        let resampled = ident.resample(to: 33)
        XCTAssertEqual(resampled.size, 33)
        let want = LUT3D.identity(size: 33)
        for i in 0..<resampled.values.count {
            assertClose(resampled.values[i], want.values[i], accuracy: 1e-12, "node \(i)")
        }
    }

    func testResampleIsAtLeastContinuous() {
        // A resampled non-trivial LUT still maps black↔white endpoints.
        var values = [Vector3]()
        values.reserveCapacity(64)
        let n = 4
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    // Linear like identity but with a per-channel gain + offset.
                    values.append(Vector3(Double(r) / 3 * 1.2, Double(g) / 3 * 0.8 + 0.1, Double(b) / 3))
                }
            }
        }
        let lut = LUT3D(size: n, values: values)
        let small = lut.resample(to: 2)
        assertClose(small[0, 0, 0], Vector3(0, 0.1, 0), accuracy: 1e-12)
        assertClose(small[1, 1, 1], Vector3(1.2, 0.9, 1), accuracy: 1e-12)
    }

    // MARK: - Layout

    func testDescription() {
        XCTAssertEqual(LUT3D.identity(size: 33).description, "33³ LUT (35937 nodes)")
    }
}