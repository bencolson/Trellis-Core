//
//  BakeCameraTests.swift
//  TrellisCore
//
//  Created by Ben Colson on 08/10/2026.
//

import XCTest
@testable import TrellisCore

/// Camera log → Rec 709 / 2.4 bakes: a CST and the look in one LUT.
final class BakeCameraTests: XCTestCase {

    private func identity(_ size: Int) -> LUT3D {
        let m = 1.0 / Double(size - 1)
        var values: [Vector3] = []
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            values.append(Vector3(Double(r) * m, Double(g) * m, Double(b) * m))
        } } }
        return LUT3D(size: size, values: values)
    }

    private let grey24 = pow(0.18, 1 / 2.4)

    /// Sony's published 18% grey, 10-bit code 420, through an identity look.
    func testSLog3GreyCardLandsOnRec709Grey() {
        let look = identity(17)
        let video = Bake.bake(look, mode: .camera(.sonySLog3Cine, levels: .video), size: 65)
        let x = (420.0 - 64) / 876      // how Resolve shows code 420 from a legal-range file
        let v = video.sample(x, x, x)
        for c in 0..<3 { XCTAssertEqual(v[c], grey24, accuracy: 2e-3, "video levels") }

        let full = Bake.bake(look, mode: .camera(.sonySLog3Cine, levels: .full), size: 65)
        let f = full.sample(420 / 1023, 420 / 1023, 420 / 1023)
        for c in 0..<3 { XCTAssertEqual(f[c], grey24, accuracy: 2e-3, "full levels") }
    }

    /// Every exportable camera puts its own 18% grey on Rec 709 / 2.4 grey.
    func testEveryExportableCameraMapsGreyToGrey() {
        let look = identity(17)
        for camera in CameraLog.exportable {
            // Code value of 18% grey: invert the curve by bisection.
            var lo = 0.0, hi = 1.0
            for _ in 0..<60 {
                let mid = (lo + hi) / 2
                if camera.curve.decode(mid) < 0.18 { lo = mid } else { hi = mid }
            }
            let cv = (lo + hi) / 2
            let chain = Bake.chain(look, mode: .camera(camera, levels: .full))
            let out = chain(Vector3(repeating: cv))
            for c in 0..<3 { XCTAssertEqual(out[c], grey24, accuracy: 1e-6, camera.label) }
        }
    }

    /// At grid points the baked LUT is exactly the chain (after the safety clip),
    /// and the chain is the preview's path: CST, then the Rec 709 / 2.4 chain.
    func testBakeIsTheCSTThenTheRec709Chain() {
        // A non-trivial look: swap and scale channels a little.
        var look = identity(9)
        look = LUT3D(size: 9, values: look.values.map { Vector3($0.y * 0.9 + 0.05, $0.x, $0.z * 0.8) })
        for highlights in HighlightHandling.allCases {
            let mode = Bake.Mode.camera(.arriLogC3, levels: .video)
            let size = 9
            let baked = Bake.bake(look, mode: mode, size: size, highlights: highlights)
            let display = Bake.chain(look, mode: .rec709_2_4)
            let cst = CameraConversion(from: .arriLogC3, to: .rec709Gamma24, highlights: highlights)
            let m = 1.0 / Double(size - 1)
            for b in 0..<size { for g in 0..<size { for r in 0..<size {
                let v = Vector3(Double(r) * m, Double(g) * m, Double(b) * m)
                let code = Vector3(CameraLog.codeValue(fromVideoRange: v.x),
                                   CameraLog.codeValue(fromVideoRange: v.y),
                                   CameraLog.codeValue(fromVideoRange: v.z))
                let expected = Bake.hardClip(display(cst.apply(code)))
                let got = baked[r, g, b]
                for c in 0..<3 { XCTAssertEqual(got[c], expected[c], accuracy: 1e-12) }
            } } }
        }
    }

    func testLabelsAndFileNames() {
        let mode = Bake.Mode.camera(.sonySLog3Cine, levels: .video)
        XCTAssertEqual(mode.label, "Sony S-Log3 / S-Gamut3.Cine → Rec 709 / 2.4")
        XCTAssertEqual(mode.fileSuffix, "sony-slog3-sgamut3cine-to-rec709-2.4")
        XCTAssertEqual(Bake.Mode.camera(.arriLogC3, levels: .full).fileSuffix, "arri-logc3-awg3-to-rec709-2.4-full")
        XCTAssertEqual(mode.inputLabel, "Sony S-Log3 / S-Gamut3.Cine code values, video levels (64–940 shown as 0–1)")
        XCTAssertEqual(Bake.space(mode), .rec709Gamma24)
        XCTAssertEqual(Bake.Mode.rec709_2_2.inputLabel, "Rec. 709 / gamma 2.2 code values")
        XCTAssertEqual(Set(CameraLog.all.map(\.slug)).count, CameraLog.all.count, "slugs are unique")
        XCTAssertEqual(CameraLog.exportable.map(\.slug), [
            "arri-logc3-awg3", "arri-logc4-awg4", "canon-clog2-cgamut", "canon-clog3-cgamut",
            "sony-slog3-sgamut3cine", "sony-slog3-sgamut3",
        ])
    }
}
