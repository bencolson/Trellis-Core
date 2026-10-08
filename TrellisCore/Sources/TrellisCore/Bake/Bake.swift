//
//  Bake.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

/// Bakes the anchor look LUT into a concrete output mode.
///
/// A look LUT read from a processed Hald lives in the anchor space
/// (Adobe RGB / γ563/256). To use it on video a `Bake` composes that space
/// with the target footage space into one .cube: input code value → output
/// code value. The chain mirrors the anchor-to-footage transform, with the
/// anchor side pinned to the 563/256 curve.
public enum Bake {

    /// Output modes. The display modes map a footage space to itself — the
    /// LUT is applied straight onto matching footage — and differ only in which
    /// transform links that space to the anchor. A `camera` mode takes camera
    /// log footage in and gives Rec 709 / 2.4 out: a CST and the look in one LUT.
    public enum Mode: Hashable, Sendable, CustomStringConvertible {
        case anchor
        case rec709_2_4
        case rec709_2_2
        case camera(CameraLog, levels: LogLevels)

        /// Human label for `TITLE` and reports, e.g. `Rec 709 / 2.4`.
        public var label: String {
            switch self {
            case .anchor: return "Anchor"
            case .rec709_2_4: return "Rec 709 / 2.4"
            case .rec709_2_2: return "Rec 709 / 2.2"
            case .camera(let camera, let levels):
                return "\(camera.label) → Rec 709 / 2.4" + (levels == .full ? " (full levels)" : "")
            }
        }

        /// File-name fragment, e.g. `look_rec709-2.4_33.cube`,
        /// `look_sony-slog3-sgamut3cine-to-rec709-2.4_33.cube`.
        public var fileSuffix: String {
            switch self {
            case .anchor: return "anchor"
            case .rec709_2_4: return "rec709-2.4"
            case .rec709_2_2: return "rec709-2.2"
            case .camera(let camera, let levels):
                return "\(camera.slug)-to-rec709-2.4" + (levels == .full ? "-full" : "")
            }
        }

        /// What the LUT expects as input, for `.cube` headers and reports.
        public var inputLabel: String {
            switch self {
            case .camera(let camera, let levels):
                return "\(camera.label) code values, \(levels.label)"
            default:
                return "\(Bake.space(self).label) code values"
            }
        }

        public var description: String { label }
    }

    /// How the grading app hands camera log footage to a LUT.
    public enum LogLevels: String, CaseIterable, Hashable, Sendable {
        /// The file is video (legal) range and the app expands it, so the LUT
        /// sees black at 0 and white at 1: Resolve's "Auto" data levels on
        /// ProRes and most camera files. The LUT maps that back to the code
        /// values the log curve is defined on.
        case video
        /// The LUT sees the file's code values directly (a full-range file,
        /// or an app set to full data levels).
        case full

        public var label: String {
            switch self {
            case .video: return "video levels (64–940 shown as 0–1)"
            case .full: return "full levels"
            }
        }
    }

    /// The colour space the baked LUT produces. For the display modes it is
    /// also the space it expects (they map a space to itself); a `camera` mode
    /// expects camera log (see `Mode.inputLabel`):
    ///
    /// - `anchor`:      Adobe RGB (1998) / γ563/256 — the look's own space
    /// - `rec709_2_4`:  Rec. 709 / γ2.4
    /// - `rec709_2_2`:  Rec. 709 / γ2.2
    /// - `camera`:      Rec. 709 / γ2.4
    public static func space(_ mode: Mode) -> ColorSpace {
        switch mode {
        case .anchor: return .adobeRGB1998
        case .rec709_2_4, .camera: return .rec709Gamma24
        case .rec709_2_2: return .rec709Gamma22
        }
    }

    /// Maps out-of-gamut colour values back into [0, 1]³.
    ///
    /// The handler runs on **linear Rec. 709 light**, immediately after the
    /// Adobe RGB → Rec 709 matrix and before the final video encode. For the
    /// default `hardClip` this is bit-identical to clipping after the encode
    /// (the odd-symmetric power curves map 0↔0 and 1↔1 monotonically, so the
    /// M4/M4.1 parity references pass unchanged). Soft compression
    /// (`Bake.gamutCompress`) works in linear light, which is where gamut
    /// boundaries actually live.
    public typealias GamutHandler = (Vector3) -> Vector3

    /// Hard clip to [0, 1] per channel — the default.
    @inlinable
    public static func hardClip(_ v: Vector3) -> Vector3 {
        Vector3(min(max(v.x, 0), 1), min(max(v.y, 0), 1), min(max(v.z, 0), 1))
    }

    /// The per-pixel transform for one mode: encoded input code value (in the
    /// mode's space) → encoded output code value.
    ///
    /// Anchor mode — look LUT only:
    ///
    ///     input (Adobe RGB / 563) → tetra sample of `look` → output
    ///
    /// Rec 709 / γ2.4 (γ2.2 mode identical, swapping the video curve):
    ///
    ///     input (Rec 709 / γ2.4)
    ///      → decode v^2.4
    ///      → 3×3 Rec 709 → Adobe RGB (D65, no CAT)
    ///      → encode v^(1/2.2)              [γ563/256]
    ///      → tetra sample of `look`        (Adobe RGB / 563 → Adobe RGB / 563)
    ///      → decode v^2.2                  [γ563/256]
    ///     → 3×3 Adobe RGB → Rec 709      (linear Rec 709)
    ///      → gamut handler                (linear: hard clip or soft compression)
    ///      → encode v^(1/2.4)
    ///     output (Rec 709 / γ2.4)
    ///
    /// Camera log (`camera`), the Rec 709 / γ2.4 chain behind a CST:
    ///
    ///     input (camera log, as the app presents it)
    ///      → video levels only: back to code values, (v·876 + 64) / 1023
    ///      → `CameraConversion` to Rec 709 / γ2.4 (log decode, gamut matrix,
    ///        `highlights`: clip or roll-off)
    ///      → the Rec 709 / γ2.4 chain above
    ///     output (Rec 709 / γ2.4)
    public static func chain(_ look: LUT3D, mode: Mode, gamut: @escaping GamutHandler = Bake.hardClip,
                             highlights: HighlightHandling = .clip) -> (Vector3) -> Vector3 {
        switch mode {
        case .camera(let camera, let levels):
            let display = chain(look, mode: .rec709_2_4, gamut: gamut)
            let cst = CameraConversion(from: camera, to: .rec709Gamma24, highlights: highlights)
            return { v in
                let code = levels == .video
                    ? Vector3(CameraLog.codeValue(fromVideoRange: v.x),
                              CameraLog.codeValue(fromVideoRange: v.y),
                              CameraLog.codeValue(fromVideoRange: v.z))
                    : v
                return display(cst.apply(code))
            }
        case .anchor:
            return { v in look.sample(v.x, v.y, v.z) }
        case .rec709_2_4, .rec709_2_2:
            return { v in
                let video = mode == .rec709_2_4 ? TransferFunction.gamma24 : TransferFunction.gamma22
                let inLinear = video.decode(v)
                let adobeCode = TransferFunction.adobeRGB1998.encode(RGBPrimaries.rec709.matrix(to: .adobeRGB1998) * inLinear)
                let looked = look.sample(adobeCode.x, adobeCode.y, adobeCode.z)
                let linear709 = RGBPrimaries.adobeRGB1998.matrix(to: .rec709) * TransferFunction.adobeRGB1998.decode(looked)
                return video.encode(gamut(linear709))
            }
        }
    }

    /// Bakes `look` into a new `size³` LUT in `mode` by evaluating the chain at
    /// each grid point of the output cube. `size` is the .cube `LUT_3D_SIZE`:
    /// 33 (default) or 65 (high quality). `mode` and `size` follow
    /// `Bake.space(mode)`, which is the space the result is in. All outputs
    /// are hard-clipped to [0, 1] as a final safety net.
    public static func bake(_ look: LUT3D, mode: Mode, size: Int = 33, gamut: @escaping GamutHandler = Bake.hardClip,
                            highlights: HighlightHandling = .clip) -> LUT3D {
        bakeWithReport(look, mode: mode, size: size, gamut: gamut, highlights: highlights).lut
    }
}