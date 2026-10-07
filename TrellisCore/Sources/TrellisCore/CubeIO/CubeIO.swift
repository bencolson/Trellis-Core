//
//  CubeIO.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

/// Writes `.cube` 3D LUT files (Adobe Cube LUT Specification 1.0).
///
/// Write-only for now: nothing in Trellis reads .cube files back yet.
public enum CubeIO {

    /// Serialises `lut` as a `.cube` file: `#` header comments, then `TITLE`,
    /// `LUT_3D_SIZE`, `DOMAIN_MIN`/`DOMAIN_MAX` 0…1, then the `size³` values,
    /// **red fastest, then green, then blue**, at ≥ 6 decimal places.
    ///
    /// `title` is written into `TITLE "…"` and should name the look and mode
    /// (e.g. `Cozy Fall — Rec 709 / 2.4`). Each entry in `comments` becomes one
    /// `# ` line above the keywords, stating the Trellis version,
    /// source, input space + transfer, output space + transfer, gamut
    /// handling, and date — the caller builds them so `TrellisCore` stays
    /// format-only.
    public static func write(_ lut: LUT3D, title: String, comments: [String] = []) -> String {
        var lines: [String] = []
        for comment in comments {
            for line in comment.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("# " + String(line))
            }
        }
        lines.append("TITLE \"\(title)\"")
        lines.append("LUT_3D_SIZE \(lut.size)")
        lines.append("DOMAIN_MIN 0 0 0")
        lines.append("DOMAIN_MAX 1 1 1")
        lines.append("")
        for b in 0..<lut.size {
            for g in 0..<lut.size {
                for r in 0..<lut.size {
                    let v = lut[r, g, b]
                    lines.append("\(component(v.x)) \(component(v.y)) \(component(v.z))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Fixed-point formatting of one component: 6 decimal places, no exponent
    /// notation ("0.123456", "1.000000", "0.000000"). Values are in [0, 1] in
    /// the anchor space, so a leading zero and six decimals are all that's
    /// needed; 6 dps resolves a 16-bit code value (≈0.15 of an LSB).
    @inlinable
    public static func component(_ v: Double) -> String {
        let scaled = Int((v * 1_000_000).rounded())
        let negative = scaled < 0
        let mag = negative ? -scaled : scaled
        let integerPart = String(mag / 1_000_000)
        var frac = String(mag % 1_000_000)
        while frac.count < 6 { frac = "0" + frac }
        return (negative ? "-" : "") + integerPart + "." + frac
    }
}