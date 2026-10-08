//
//  CubeReaderTests.swift
//  TrellisCore
//
//  Created by Ben Colson on 08/10/2026.
//

import XCTest
@testable import TrellisCore

final class CubeReaderTests: XCTestCase {

    private func identity(_ size: Int) -> LUT3D {
        let m = 1.0 / Double(size - 1)
        var values: [Vector3] = []
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            values.append(Vector3(Double(r) * m, Double(g) * m, Double(b) * m))
        } } }
        return LUT3D(size: size, values: values)
    }

    private func cube(_ header: String, size: Int = 2, dataLines: Int? = nil) -> String {
        let n = dataLines ?? size * size * size
        return header + "\n" + Array(repeating: "0.5 0.5 0.5", count: n).joined(separator: "\n")
    }

    private func assertThrows(_ text: String, _ expected: CubeReadError,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CubeIO.read(text), file: file, line: line) { error in
            XCTAssertEqual(error as? CubeReadError, expected, "\(error)", file: file, line: line)
        }
    }

    func testRoundTripsWhatTheWriterProduces() throws {
        let lut = identity(17)
        let text = CubeIO.write(lut, title: "Cozy Fall — Rec 709 / 2.4", comments: ["Trellis 1.0", "input: x"])
        let file = try CubeIO.read(text)
        XCTAssertEqual(file.title, "Cozy Fall — Rec 709 / 2.4")
        XCTAssertEqual(file.comments, ["Trellis 1.0", "input: x"])
        XCTAssertEqual(file.lut.size, 17)
        XCTAssertEqual(file.domainMin, Vector3(0, 0, 0))
        XCTAssertEqual(file.domainMax, Vector3(1, 1, 1))
        XCTAssertTrue(file.warnings.isEmpty)
        for i in 0..<lut.values.count {
            XCTAssertEqual(file.lut.values[i].x, lut.values[i].x, accuracy: 5e-7)
            XCTAssertEqual(file.lut.values[i].z, lut.values[i].z, accuracy: 5e-7)
        }
    }

    func testAcceptsCRLFBOMTabsAndResolveInputRange() throws {
        let text = "\u{FEFF}TITLE \"x\"\r\nLUT_3D_SIZE 2\r\nLUT_3D_INPUT_RANGE 0.0 1.0\r\n"
            + Array(repeating: "0\t0.5  1", count: 8).joined(separator: "\r\n") + "\r\n"
        let file = try CubeIO.read(text)
        XCTAssertEqual(file.lut.size, 2)
        XCTAssertEqual(file.lut.values[7], Vector3(0, 0.5, 1))
    }

    func testUnquotedTitleIsAWarningAndEmptyFileAnError() throws {
        let file = try CubeIO.read(cube("TITLE \t\nLUT_3D_SIZE 2"))
        XCTAssertEqual(file.title, "")
        XCTAssertEqual(file.warnings, ["line 1: TITLE is not in quotes"])
        assertThrows("", .empty)
        assertThrows(" \n\r\n", .empty)
    }

    func testUnknownKeywordIsAWarning() throws {
        let file = try CubeIO.read(cube("LUT_3D_SIZE 2\nLUT_IN_VIDEO_RANGE"))
        XCTAssertEqual(file.warnings, ["line 2: unknown keyword LUT_IN_VIDEO_RANGE ignored"])
    }

    func testErrorsNameTheLine() {
        assertThrows(cube("TITLE \"x\""), .missingSize)
        assertThrows(cube("LUT_3D_SIZE 1"), .invalidSize(line: 1, text: "1"))
        assertThrows(cube("LUT_3D_SIZE 33.5"), .invalidSize(line: 1, text: "33.5"))
        assertThrows(cube("LUT_1D_SIZE 1024"), .oneDimensional(line: 1))
        assertThrows(cube("LUT_3D_SIZE 2\nLUT_3D_SIZE 2"),
                     .duplicateKeyword(line: 2, keyword: "LUT_3D_SIZE", firstLine: 1))
        assertThrows(cube("TITLE \"open"), .unterminatedTitle(line: 1))
        assertThrows(cube("LUT_3D_SIZE 2\nDOMAIN_MIN 0 0"),
                     .wrongValueCount(line: 2, expected: 3, found: 2, text: "0 0"))
        assertThrows(cube("LUT_3D_SIZE 2\nDOMAIN_MIN 1 0 0\nDOMAIN_MAX 1 1 1"),
                     .invalidDomain(min: Vector3(1, 0, 0), max: Vector3(1, 1, 1)))
        assertThrows(cube("LUT_3D_SIZE 2", dataLines: 7), .dataCountMismatch(expected: 8, found: 7, size: 2))
        assertThrows(cube("LUT_3D_SIZE 2", dataLines: 9), .dataCountMismatch(expected: 8, found: 9, size: 2))
        assertThrows(cube("LUT_3D_SIZE 2") + "\nTITLE \"late\"", .keywordAfterData(line: 10, keyword: "TITLE"))
    }

    func testRejectsNaNAndBrokenDataLines() {
        let base = "LUT_3D_SIZE 2\n" + Array(repeating: "0 0 0", count: 7).joined(separator: "\n")
        assertThrows(base + "\nnan 0 0", .notANumber(line: 9, text: "nan"))
        assertThrows(base + "\n0 inf 0", .notANumber(line: 9, text: "inf"))
        assertThrows(base + "\n0,1 0 0", .notANumber(line: 9, text: "0,1"))
        assertThrows(base + "\n0 0", .wrongValueCount(line: 9, expected: 3, found: 2, text: "0 0"))
    }

    func testMessagesAreReadable() {
        XCTAssertEqual(CubeReadError.dataCountMismatch(expected: 35937, found: 35936, size: 33).description,
                       "too few data lines: LUT_3D_SIZE 33 needs 35937 (33³), found 35936")
        XCTAssertEqual(CubeReadError.notANumber(line: 12, text: "nan").description,
                       "line 12: \"nan\" is not a finite number")
    }

    func testRejectsNonUTF8Bytes() {
        XCTAssertThrowsError(try CubeIO.read([0xFF, 0xFE, 0x00, 0x4C])) { error in
            XCTAssertEqual(error as? CubeReadError, .notText)
        }
    }
}
