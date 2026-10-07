//
//  HaldGenerator.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

/// Builds the images the user takes through Capture One.
///
/// Both are 16-bit RGB tagged with Adobe's Adobe RGB (1998) profile, so
/// Capture One reads them as already being in the anchor space and the recipe's
/// Adobe RGB (1998) output is a no-op apart from the look.
public enum HaldGenerator {

    /// Identity Hald CLUT at `spec`'s level.
    public static func identityImage(_ spec: HaldSpec = .level8) -> RGBImage {
        let size = spec.size
        let n = spec.steps
        let codes = (0..<n).map(spec.code16)
        var samples = [UInt16]()
        samples.reserveCapacity(size * size * 3)
        for i in 0..<(size * size) {
            samples.append(codes[i % n])
            samples.append(codes[(i / n) % n])
            samples.append(codes[i / (n * n)])
        }
        return RGBImage(width: size, height: size, samples: samples,
                        iccProfile: ICCProfile.adobeRGB1998.data)
    }

    /// The identity Hald with its **pixel order reversed** .
    ///
    /// The user processes both the identity Hald and this reversed one with the
    /// same Capture One style. `validate`/`build` reverse the returned reversed
    /// file back and compare it with the forward Hald: a purely per-pixel look
    /// (i.e. an ordinary colour LUT) round-trips exactly; any difference beyond
    /// a few code values reveals a spatial operator (Highlight/Shadow, Clarity,
    /// Structure, Dehaze) that no 3D LUT can represent.
    public static func reversedImage(_ spec: HaldSpec = .level8) -> RGBImage {
        identityImage(spec).reversedPixelOrder()
    }

    /// Validation chart (see `ValidationChart`): flat patches whose expected
    /// values are known, so a returned chart can be checked without a LUT.
    public static func validationImage(_ chart: ValidationChart = .standard) -> RGBImage {
        let w = chart.columns * chart.cellSize
        let h = chart.rows * chart.cellSize
        var samples = [UInt16](repeating: chart.background, count: w * h * 3)
        for p in chart.patches {
            for y in (p.row * chart.cellSize)..<((p.row + 1) * chart.cellSize) {
                for x in (p.column * chart.cellSize)..<((p.column + 1) * chart.cellSize) {
                    let i = (y * w + x) * 3
                    samples[i] = p.code.0
                    samples[i + 1] = p.code.1
                    samples[i + 2] = p.code.2
                }
            }
        }
        return RGBImage(width: w, height: h, samples: samples,
                        iccProfile: ICCProfile.adobeRGB1998.data)
    }
}

/// A chart of flat patches with known Adobe RGB (1998) code values.
///
/// A separate file rather than a strip inside the Hald :
/// a strip would change the Hald's dimensions away from `L³ × L³`, which every
/// Hald tool relies on, and flat patches are robust to any spatial filtering
/// that does slip through, so they measure the *colour* path cleanly.
///
/// Layout, `cellSize`-pixel square cells:
/// - row 0: grey ramp, 11 steps, 0…65535 in tenths
/// - rows 1–4: R, G, B, C, M, Y at 25 / 50 / 75 / 100 % code value
///   (encoded Adobe RGB values, not linear light); spare cells are background.
public struct ValidationChart: Equatable, Sendable {
    public struct Patch: Equatable, Sendable {
        public let name: String
        public let column: Int
        public let row: Int
        public let code: (UInt16, UInt16, UInt16)

        public static func == (a: Patch, b: Patch) -> Bool {
            a.name == b.name && a.column == b.column && a.row == b.row
                && a.code.0 == b.code.0 && a.code.1 == b.code.1 && a.code.2 == b.code.2
        }
    }

    public let cellSize: Int
    public let columns: Int
    public let rows: Int
    /// Fill for unused cells: mid grey (the 50 % ramp step).
    public let background: UInt16
    public let patches: [Patch]

    public static let standard = ValidationChart(cellSize: 64)

    public init(cellSize: Int) {
        func level(_ fraction: Double) -> UInt16 { UInt16((fraction * 65535).rounded()) }
        var patches: [Patch] = []
        for k in 0...10 {
            let v = level(Double(k) / 10)
            patches.append(Patch(name: "grey \(k * 10)%", column: k, row: 0, code: (v, v, v)))
        }
        let hues: [(String, (Bool, Bool, Bool))] = [
            ("red", (true, false, false)), ("green", (false, true, false)), ("blue", (false, false, true)),
            ("cyan", (false, true, true)), ("magenta", (true, false, true)), ("yellow", (true, true, false)),
        ]
        for (r, pct) in [25, 50, 75, 100].enumerated() {
            let v = level(Double(pct) / 100)
            for (c, (name, on)) in hues.enumerated() {
                patches.append(Patch(name: "\(name) \(pct)%", column: c, row: r + 1,
                                     code: (on.0 ? v : 0, on.1 ? v : 0, on.2 ? v : 0)))
            }
        }
        self.cellSize = cellSize
        self.columns = 11
        self.rows = 5
        self.background = level(0.5)
        self.patches = patches
    }
}
