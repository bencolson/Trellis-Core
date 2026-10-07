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

    /// Output modes. Each mode maps a footage space to itself — the LUT is
    /// applied straight onto matching footage — and differs only in which
    /// transform links that space to the anchor.
    public enum Mode: Equatable, Sendable, CustomStringConvertible {
        case anchor
        case rec709_2_4
        case rec709_2_2

        /// Human label for `TITLE` and reports, e.g. `Rec 709 / 2.4`.
        public var label: String {
            switch self {
            case .anchor: return "Anchor"
            case .rec709_2_4: return "Rec 709 / 2.4"
            case .rec709_2_2: return "Rec 709 / 2.2"
            }
        }

        /// File-name fragment, e.g. `look_rec709-2.4_33.cube`.
        public var fileSuffix: String {
            switch self {
            case .anchor: return "anchor"
            case .rec709_2_4: return "rec709-2.4"
            case .rec709_2_2: return "rec709-2.2"
            }
        }

        public var description: String { label }
    }

    /// The colour space of the footage the baked LUT expects (and produces —
    /// every mode maps a space to itself):
    ///
    /// - `anchor`:      Adobe RGB (1998) / γ563/256 — the look's own space
    /// - `rec709_2_4`:  Rec. 709 / γ2.4
    /// - `rec709_2_2`:  Rec. 709 / γ2.2
    public static func space(_ mode: Mode) -> ColorSpace {
        switch mode {
        case .anchor: return .adobeRGB1998
        case .rec709_2_4: return .rec709Gamma24
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
    public static func chain(_ look: LUT3D, mode: Mode, gamut: @escaping GamutHandler = Bake.hardClip) -> (Vector3) -> Vector3 {
        switch mode {
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
    public static func bake(_ look: LUT3D, mode: Mode, size: Int = 33, gamut: @escaping GamutHandler = Bake.hardClip) -> LUT3D {
        bakeWithReport(look, mode: mode, size: size, gamut: gamut).lut
    }
}