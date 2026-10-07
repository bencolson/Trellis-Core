//
//  CubeIOTests.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import Foundation
import XCTest
@testable import TrellisCore

/// .cube emission (Adobe Cube LUT Specification 1.0).
final class CubeIOTests: XCTestCase {

    private func lines(_ cube: String) -> [String] {
        cube.components(separatedBy: .newlines).map { String($0) }
    }

    func testHeaderIsExactlyPerSpec() {
        let cube = CubeIO.write(LUT3D.identity(size: 2), title: "Identity — Anchor")
        let l = lines(cube)
        XCTAssertEqual(l[0], "TITLE \"Identity — Anchor\"")
        XCTAssertEqual(l[1], "LUT_3D_SIZE 2")
        XCTAssertEqual(l[2], "DOMAIN_MIN 0 0 0")
        XCTAssertEqual(l[3], "DOMAIN_MAX 1 1 1")
        XCTAssertEqual(l[4], "")
        XCTAssertEqual(l.count, 13)   // 5 header lines + 2³ data lines
    }

    func testCommentsPrefixedWithHash() {
        let cube = CubeIO.write(LUT3D.identity(size: 2), title: "t",
                                comments: ["Trellis 0.1.0-dev", "source: processed.tif",
                                           "line one\nline two"])
        let l = lines(cube)
        XCTAssertEqual(l[0], "# Trellis 0.1.0-dev")
        XCTAssertEqual(l[1], "# source: processed.tif")
        XCTAssertEqual(l[2], "# line one")
        XCTAssertEqual(l[3], "# line two")
        XCTAssertEqual(l[4], "TITLE \"t\"")
    }

    func testDataIsRedFastest() {
        // size 2 identity: the 8 data lines enumerate red fastest, then green,
        // then blue.
        let cube = CubeIO.write(LUT3D.identity(size: 2), title: "t")
        let l = lines(cube)
        XCTAssertEqual(l[5], "0.000000 0.000000 0.000000")   // r0 g0 b0
        XCTAssertEqual(l[6], "1.000000 0.000000 0.000000")   // r1 g0 b0
        XCTAssertEqual(l[7], "0.000000 1.000000 0.000000")   // r0 g1 b0
        XCTAssertEqual(l[8], "1.000000 1.000000 0.000000")   // r1 g1 b0
        XCTAssertEqual(l[9], "0.000000 0.000000 1.000000")   // r0 g0 b1
        XCTAssertEqual(l[10], "1.000000 0.000000 1.000000")
        XCTAssertEqual(l[11], "0.000000 1.000000 1.000000")
        XCTAssertEqual(l[12], "1.000000 1.000000 1.000000")
    }

    func testComponentFormatting() {
        XCTAssertEqual(CubeIO.component(0), "0.000000")
        XCTAssertEqual(CubeIO.component(1), "1.000000")
        XCTAssertEqual(CubeIO.component(0.5), "0.500000")
        XCTAssertEqual(CubeIO.component(0.12345678), "0.123457")
        // 16-bit quantisation: one LSB is 1.5e-5 — visible at 6 dp.
        XCTAssertEqual(CubeIO.component(1.0 / 65535.0), "0.000015")
        XCTAssertEqual(CubeIO.component(1.0 / 1023.0), "0.000978")
    }

    func testWrittenValuesSurviveAt6DP() {
        // Re-parse the data block and check every value is preserved to within
        // half a 6-dp step (rounding is the only loss; it's a formatting test).
        let lut = LUT3D.identity(size: 4)
        let cube = CubeIO.write(lut, title: "t")
        let l = lines(cube)
        XCTAssertEqual(l.count, 5 + 64)   // 5 header lines + 4³ data lines
        var worst: Double = 0
        for i in 0..<64 {
            let parts = l[5 + i].split(separator: " ").map { Double(String($0))! }
            let want = lut.values[i]
            worst = max(worst, abs(parts[0] - want.x), abs(parts[1] - want.y), abs(parts[2] - want.z))
        }
        XCTAssertLessThanOrEqual(worst, 5.1e-7)
    }

    /// `.cube` output is byte-stable against the committed golden. The golden
    /// is loaded in `research/reference/ocio_bake_check.py` through OCIO's
    /// `FileTransform`, which must read the same values back exactly — proving
    /// Trellis's `.cube` output parses in a strict, widely used reader.
    func testCubeIOGoldenMatchesCommittedFixture() throws {
        let n = 4
        var values: [Vector3] = []
        values.reserveCapacity(n * n * n)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    values.append(Vector3(Double(r) / 3, Double(g) / 3, Double(b) / 3))
                }
            }
        }
        let cube = CubeIO.write(LUT3D(size: n, values: values), title: "Trellis CubeIO golden")
        let url = Bundle.module.url(forResource: "cubeio_golden", withExtension: "cube", subdirectory: "Fixtures")!
        let golden = try Data(contentsOf: url)
        XCTAssertEqual(String(data: golden, encoding: .utf8), cube)
    }
}