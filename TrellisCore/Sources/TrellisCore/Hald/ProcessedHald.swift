//
//  ProcessedHald.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import Foundation

/// Reads a Capture One-processed Hald back into the anchor look LUT
///: Adobe RGB (1998) / γ563/256 in, same out.
///
/// Raw code values only: each grid cell's 16-bit RGB is normalised
/// by its bit depth; no colour management touches it. The embedded profile is
/// checked by content, so a file merely *named* Adobe RGB (1998) but with
/// a different curve is rejected here — mismatch is a hard error, not a guess
/// to paper over.
public enum ProcessedHald {

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case notHald(String)
        case not16Bit(Int)
        case notAdobeRGB(String)

        public var description: String {
            switch self {
            case .notHald(let found): return "Not a Hald: \(found)"
            case .not16Bit(let bits): return "Hald is \(bits)-bit; process with a 16-bit recipe"
            case .notAdobeRGB(let found): return "Embedded profile is not Adobe RGB (1998): found \(found)"
            }
        }
    }

    /// Decodes a processed Hald image into an `N³` look LUT in the anchor
    /// space. The image must be Hald-shaped (`L³ × L³`), 16-bit, and tagged
    /// Adobe RGB (1998); anything else is a `ProcessedHald.Error` telling the
    /// user which recipe setting to fix.
    public static func read(_ image: RGBImage) throws -> LUT3D {
        guard let spec = HaldSpec(width: image.width, height: image.height) else {
            throw Error.notHald("image is \(image.width)×\(image.height), not L³×L³")
        }
        guard image.bitsPerSample == 16 else { throw Error.not16Bit(image.bitsPerSample) }
        guard image.iccProfile != nil else { throw Error.notAdobeRGB("no embedded profile") }
        var parsed: ICCProfile?
        do { parsed = try ICCProfile(data: image.iccProfile!) } catch { parsed = nil }
        guard let p = parsed, p.isAdobeRGB1998 else {
            throw Error.notAdobeRGB("\"\(parsed?.displayName ?? "unparseable profile bytes")\"")
        }

        let n = spec.steps
        var values = [Vector3]()
        values.reserveCapacity(n * n * n)
        let inv = 1.0 / 65535.0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let (x, y) = spec.pixel(r: r, g: g, b: b)
                    let (cr, cg, cb) = image.rgb(x: x, y: y)
                    values.append(Vector3(Double(cr) * inv, Double(cg) * inv, Double(cb) * inv))
                }
            }
        }
        return LUT3D(size: n, values: values)
    }

    /// File convenience over `read(RGBImage)`. TIFF-level failures (not a TIFF,
    /// compressed, truncated, …) surface as `Tiff.Error`; content failures as
    /// `ProcessedHald.Error`.
    public static func read(contentsOf url: URL) throws -> LUT3D {
        try read(try Tiff.read(contentsOf: url))
    }
}