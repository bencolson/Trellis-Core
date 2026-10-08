//
//  TrellisCLITests.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import Foundation
import XCTest
@testable import TrellisCLIKit
import TrellisCore

/// End-to-end through the real CLI command paths: synthetic Hald TIFFs are
/// written with the core's own TIFF writer, driven though `TrellisCLI.run`,
/// and the resulting .cube files are read back off disk.
final class TrellisCLITests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trellis-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func run(_ arguments: [String]) -> TrellisCLI.Result {
        TrellisCLI.run(arguments)
    }

    private func write(_ image: RGBImage, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Tiff.write(image, to: url)
        return url
    }

    private func identityHald(level: Int = 8) -> RGBImage {
        HaldGenerator.identityImage(HaldSpec(level: level))
    }

    private func reversedHald(level: Int = 8) -> RGBImage {
        HaldGenerator.reversedImage(HaldSpec(level: level))
    }

    /// A deterministic per-pixel transform, e.g. a 0.8 darkening "look".
    private func mapSamples(_ image: RGBImage, _ fn: (UInt16) -> UInt16) -> RGBImage {
        RGBImage(width: image.width, height: image.height,
                 samplesPerPixel: image.samplesPerPixel, bitsPerSample: image.bitsPerSample,
                 samples: image.samples.map(fn), iccProfile: image.iccProfile)
    }

    private func scaledHald(_ factor: Double) -> RGBImage {
        mapSamples(identityHald()) { code in
            UInt16(min(max(Double(code) * factor, 0), 65535).rounded())
        }
    }

    private func offsetHald(_ delta: Int) -> RGBImage {
        mapSamples(identityHald()) { code in
            UInt16(min(max(Int(code) + delta, 0), 65535))
        }
    }

    private func eightBitHald() -> RGBImage {
        let image = identityHald()
        return RGBImage(width: image.width, height: image.height, samplesPerPixel: 3,
                        bitsPerSample: 8, samples: image.samples.map { $0 >> 8 },
                        iccProfile: image.iccProfile)
    }

    private struct Cube {
        let title: String
        let size: Int
        let data: [[Double]]
    }

    private func parseCube(_ url: URL) throws -> Cube {
        let text = try String(contentsOf: url, encoding: .utf8)
        var title = ""
        var size = 0
        var data: [[Double]] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("TITLE \"") {
                title = String(line.dropFirst(7).dropLast(1))
            } else if line.hasPrefix("LUT_3D_SIZE ") {
                size = Int(line.dropFirst(12))!
            } else if line.hasPrefix("DOMAIN") || line.isEmpty || line.hasPrefix("#") {
                continue
            } else {
                data.append(line.split(separator: " ").map { Double($0)! })
            }
        }
        return Cube(title: title, size: size, data: data)
    }

    private func json(_ stdout: String) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: Data(stdout.utf8))) as! [String: Any]
    }

    // MARK: - version / spaces / help

    func testVersion() {
        let result = run(["version"])
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.stdout, "trellis \(Trellis.version)\n")
        let jsonResult = run(["version", "--json"])
        XCTAssertEqual(jsonResult.code, 0)
        XCTAssertEqual(json(jsonResult.stdout)["version"] as? String, Trellis.version)
    }

    func testSpaces() {
        let result = run(["spaces"])
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.contains("Adobe RGB (1998)"))
        XCTAssertTrue(result.stdout.contains("Rec. 709 / gamma 2.4"))
    }

    func testUnknownCommandIsUsageError() {
        let result = run(["frobnicate"])
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("unknown command"))
    }

    // MARK: - hald

    func testHaldWritesFiles() throws {
        let result = run(["hald", "--out", dir.path, "--with-validation", "--with-reversed"])
        XCTAssertEqual(result.code, 0)
        for name in ["identity-hald-L8.tif", "reversed-hald-L8.tif", "validation.tif"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), name)
        }
    }

    func testHaldJsonListsFiles() throws {
        let result = run(["hald", "--out", dir.path, "--json"])
        XCTAssertEqual(result.code, 0)
        let object = json(result.stdout)
        XCTAssertEqual(object["command"] as? String, "hald")
        XCTAssertEqual(object["level"] as? Int, 8)
        let files = object["files"] as! [[String: Any]]
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first!["kind"] as? String, "identity")
    }

    // MARK: - build

    func testBuildWritesDefaultCubeFromIdentityHald() throws {
        let haldURL = try write(identityHald(), "look.tif")
        let result = run(["build", haldURL.path, "--out", dir.path])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Trellis validation: PASS"))

        let cubeURL = dir.appendingPathComponent("look_rec709-2.4_33.cube")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cubeURL.path))

        let cube = try parseCube(cubeURL)
        XCTAssertEqual(cube.title, "look — Rec 709 / 2.4")
        XCTAssertEqual(cube.size, 33)
        XCTAssertEqual(cube.data.count, 33 * 33 * 33)
        XCTAssertEqual(cube.data.first!, [0, 0, 0])
        XCTAssertEqual(cube.data.last![0], 1, accuracy: 1e-5)
        XCTAssertEqual(cube.data.last![1], 1, accuracy: 1e-5)
        XCTAssertEqual(cube.data.last![2], 1, accuracy: 1e-5)

        let text = try String(contentsOf: cubeURL, encoding: .utf8)
        XCTAssertTrue(text.contains("# Trellis \(Trellis.version)"))
        XCTAssertTrue(text.contains("# source: look.tif"))
        XCTAssertTrue(text.contains("# input:  Rec. 709 / gamma 2.4 code values"))
        XCTAssertTrue(text.contains("# gamut: hard clip in linear Rec 709"))
    }

    func testBuildAllModesAndCubeSize() throws {
        let haldURL = try write(identityHald(), "look.tif")
        let result = run(["build", haldURL.path, "--out", dir.path,
                          "--modes", "anchor, rec709-2.4,rec709-2.2", "--cube-size", "65"])
        XCTAssertEqual(result.code, 0, result.stderr)

        for suffix in ["anchor", "rec709-2.4", "rec709-2.2"] {
            let url = dir.appendingPathComponent("look_\(suffix)_65.cube")
            let cube = try parseCube(url)
            XCTAssertEqual(cube.size, 65)
            XCTAssertEqual(cube.data.count, 65 * 65 * 65, suffix)
            XCTAssertEqual(cube.title, "look — " + ["Anchor", "Rec 709 / 2.4", "Rec 709 / 2.2"][["anchor", "rec709-2.4", "rec709-2.2"].firstIndex(of: suffix)!])
        }
    }

    func testBuildDarkenedLookFlowsIntoTheCube() throws {
        // A 0.8 darkening "look" must show at the anchor cube's white corner
        // (1,1,1 → 0.8), proving Hald pixels reach the LUT.
        let haldURL = try write(scaledHald(0.8), "dark.tif")
        let result = run(["build", haldURL.path, "--out", dir.path, "--modes", "anchor"])
        XCTAssertEqual(result.code, 0, result.stderr)
        let cube = try parseCube(dir.appendingPathComponent("dark_anchor_33.cube"))
        XCTAssertEqual(cube.data.first!, [0, 0, 0])
        XCTAssertEqual(cube.data.last![0], 0.8, accuracy: 3e-4)
        XCTAssertEqual(cube.data.last![1], 0.8, accuracy: 3e-4)
        XCTAssertEqual(cube.data.last![2], 0.8, accuracy: 3e-4)
    }

    func testBuildJsonListsFiles() throws {
        let haldURL = try write(identityHald(), "look.tif")
        let result = run(["build", haldURL.path, "--out", dir.path, "--modes", "anchor,rec709-2.4", "--json"])
        XCTAssertEqual(result.code, 0)
        let object = json(result.stdout)
        XCTAssertEqual(object["command"] as? String, "build")
        XCTAssertEqual((object["report"] as! [String: Any])["ok"] as? Bool, true)
        let files = object["files"] as! [[String: Any]]
        XCTAssertEqual(files.map { $0["mode"] as? String }, ["anchor", "rec709-2.4"])
        XCTAssertEqual(files.first!["size"] as? Int, 33)
    }

    func testBuildRefusesEightBitHaldAndWritesNothing() throws {
        let haldURL = try write(eightBitHald(), "look.tif")
        let result = run(["build", haldURL.path, "--out", dir.path])
        XCTAssertEqual(result.code, 3)
        XCTAssertTrue(result.stdout.contains("Trellis validation: FAIL"))
        XCTAssertTrue(result.stdout.contains("8-bit"))
        let matches = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".cube") }
        XCTAssertTrue(matches.isEmpty)
    }

    func testBuildGamutCompressReportsTally() throws {
        // A Hald whose look is saturated Adobe green: its Rec 709 rendition is
        // out of gamut, so --gamut compress must engage and report it.
        let base = identityHald()
        var samples = [UInt16](repeating: 0, count: base.width * base.height * 3)
        for i in 0..<(base.width * base.height) { samples[i * 3 + 1] = 65535 }
        let green = RGBImage(width: base.width, height: base.height, samplesPerPixel: 3,
                             bitsPerSample: 16, samples: samples, iccProfile: base.iccProfile)
        let haldURL = try write(green, "green.tif")
        let result = run(["build", haldURL.path, "--out", dir.path, "--gamut", "compress"])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("compressed"), result.stdout)
        let cubeURL = dir.appendingPathComponent("green_rec709-2.4_33.cube")
        let text = try String(contentsOf: cubeURL, encoding: .utf8)
        XCTAssertTrue(text.contains("# gamut: soft compression toward white"), String(text.prefix(400)))
    }

    func testBuildCameraModesWriteLogInputCubes() throws {
        let haldURL = try write(identityHald(), "look.tif")
        let result = run(["build", haldURL.path, "--out", dir.path,
                          "--modes", "arri-logc3-awg3,sony-slog3-sgamut3cine", "--log-levels", "full",
                          "--highlights", "rolloff"])
        XCTAssertEqual(result.code, 0, result.stderr)
        let url = dir.appendingPathComponent("look_sony-slog3-sgamut3cine-to-rec709-2.4-full_33.cube")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# input:  Sony S-Log3 / S-Gamut3.Cine code values, full levels"))
        XCTAssertTrue(text.contains("# output: Rec. 709 / gamma 2.4 code values"))
        XCTAssertTrue(text.contains("highlights rolled off"))
        let file = try CubeIO.read(text)
        XCTAssertEqual(file.title, "look — Sony S-Log3 / S-Gamut3.Cine → Rec 709 / 2.4 (full levels)")
        // 18% grey (S-Log3 code 420) comes out as Rec 709 / 2.4 grey.
        let grey = file.lut.sample(420 / 1023, 420 / 1023, 420 / 1023)
        XCTAssertEqual(grey.y, pow(0.18, 1 / 2.4), accuracy: 3e-3)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("look_arri-logc3-awg3-to-rec709-2.4-full_33.cube").path))
    }

    func testCheckCube() throws {
        let haldURL = try write(identityHald(), "look.tif")
        XCTAssertEqual(run(["build", haldURL.path, "--out", dir.path]).code, 0)
        let good = run(["check-cube", dir.appendingPathComponent("look_rec709-2.4_33.cube").path])
        XCTAssertEqual(good.code, 0, good.stderr)
        XCTAssertTrue(good.stdout.contains("ok: 33³"))

        let bad = dir.appendingPathComponent("bad.cube")
        try Data("LUT_3D_SIZE 2\n0 0 0\n".utf8).write(to: bad)
        let result = run(["check-cube", bad.path])
        XCTAssertEqual(result.code, 3)
        XCTAssertTrue(result.stdout.contains("too few data lines: LUT_3D_SIZE 2 needs 8 (2³), found 1"), result.stdout)
    }

    func testBuildUsageErrors() throws {
        XCTAssertEqual(run(["build"]).code, 2)                                   // no positional
        XCTAssertEqual(run(["build", "x", "--cube-size", "16"]).code, 2)          // bad size
        XCTAssertEqual(run(["build", "x", "--modes", "bogus"]).code, 2)           // bad mode
        XCTAssertEqual(run(["build", "x", "--reversed"]).code, 2)                 // value missing
        XCTAssertEqual(run(["build", "x", "--gamut", "bogus"]).code, 2)           // bad gamut
        XCTAssertEqual(run(["build", "x", "--modes", "red-log3g10-rwg"]).code, 2)  // camera without an export
        XCTAssertEqual(run(["build", "x", "--log-levels", "legal"]).code, 2)      // bad levels
        XCTAssertEqual(run(["build", "x", "--highlights", "soft"]).code, 2)       // bad highlights
    }

    // MARK: - validate

    func testValidateReportsCleanIdentityIncludingReversed() throws {
        let forward = try write(identityHald(), "forward.tif")
        let reversed = try write(reversedHald(), "reversed.tif")
        let result = run(["validate", forward.path, "--reversed", reversed.path])
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.contains("Trellis validation: PASS"))
        XCTAssertTrue(result.stdout.contains("locality"))
    }

    func testValidateIdentityPassesForCleanRecipe() throws {
        let forward = try write(identityHald(), "forward.tif")
        let result = run(["validate", forward.path, "--identity"])
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.contains("identity: PASS"))
    }

    func testValidateIdentityFailsForLook() throws {
        let forward = try write(offsetHald(2_000), "forward.tif")
        let result = run(["validate", forward.path, "--identity"])
        XCTAssertEqual(result.code, 4)
        XCTAssertTrue(result.stdout.contains("identity: FAIL"))
    }

    func testValidateRefusesEightBitHald() throws {
        let forward = try write(eightBitHald(), "forward.tif")
        XCTAssertEqual(run(["validate", forward.path]).code, 3)
    }

    // MARK: - verify-recipe (the standalone recipe check)

    func testVerifyRecipePassesForCleanRecipe() throws {
        let forward = try write(identityHald(), "clean.tif")
        let result = run(["verify-recipe", forward.path])
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.contains("recipe: PASS"))
    }

    func testVerifyRecipeFailsForLook() throws {
        let forward = try write(offsetHald(2_000), "look.tif")
        let result = run(["verify-recipe", forward.path])
        XCTAssertEqual(result.code, 4)
        XCTAssertTrue(result.stdout.contains("recipe: FAIL"))
    }

    func testVerifyRecipeRejectsNonHald() throws {
        let forward = try write(eightBitHald(), "bad.tif")
        XCTAssertEqual(run(["verify-recipe", forward.path]).code, 3)
    }

    func testVerifyRecipeJson() throws {
        let forward = try write(identityHald(), "clean.tif")
        let result = run(["verify-recipe", forward.path, "--json"])
        XCTAssertEqual(result.code, 0)
        let object = json(result.stdout)
        XCTAssertEqual(object["command"] as? String, "verify-recipe")
        XCTAssertEqual(object["pass"] as? Bool, true)
    }

    func testValidateJson() throws {
        let forward = try write(identityHald(), "forward.tif")
        let result = run(["validate", forward.path, "--json"])
        XCTAssertEqual(result.code, 0)
        let object = json(result.stdout)
        XCTAssertEqual(object["command"] as? String, "validate")
        XCTAssertEqual((object["report"] as! [String: Any])["ok"] as? Bool, true)
        XCTAssertEqual((object["report"] as! [String: Any])["hald_level"] as? Int, 8)
    }
}