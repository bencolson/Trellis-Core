//
//  ICCProfile.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

/// The parts of an ICC profile Trellis needs to recognise an encoding: its
/// description, colorants, white point and tone curves.
///
/// Only matrix/TRC RGB profiles are understood, which is what every
/// Adobe RGB (1998) profile is. Anything else parses as far as the header and
/// description, then reports as "not Adobe RGB (1998)" with its name, so the
/// user is told what they actually exported.
public struct ICCProfile: Equatable, Sendable {
    /// Raw profile bytes, exactly as embedded in the file.
    public let data: [UInt8]
    /// Profile description (`desc` tag), e.g. "Adobe RGB (1998)". `nil` if absent.
    public let description: String?
    /// Header data colour space signature, e.g. "RGB ".
    public let colorSpace: String
    /// Colorant tags (`rXYZ`, `gXYZ`, `bXYZ`), PCS-relative (D50-adapted).
    public let colorants: (red: Vector3, green: Vector3, blue: Vector3)?
    /// Tone curves (`rTRC`, `gTRC`, `bTRC`).
    public let toneCurves: (red: ToneCurve, green: ToneCurve, blue: ToneCurve)?

    /// A `curv` or `para` TRC, reduced to what Trellis can compare.
    public enum ToneCurve: Equatable, Sendable {
        /// `curv` with one entry, or `para` function type 0: pure power.
        case gamma(Double)
        /// Anything else (sampled curve, piecewise parametric).
        case other(String)
    }

    public static func == (a: ICCProfile, b: ICCProfile) -> Bool { a.data == b.data }

    /// Adobe's Adobe RGB (1998) profile, embedded in every Hald Trellis writes.
    public static let adobeRGB1998: ICCProfile = {
        do { return try ICCProfile(data: AdobeRGB1998Profile.bytes) } catch {
            preconditionFailure("Embedded Adobe RGB (1998) profile failed to parse: \(error)")
        }
    }()

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case truncated
        case badSignature

        public var description: String {
            switch self {
            case .truncated: return "ICC profile is truncated"
            case .badSignature: return "ICC profile has no 'acsp' signature"
            }
        }
    }

    public init(data: [UInt8]) throws {
        let r = BigEndianReader(data)
        guard data.count >= 132 else { throw ParseError.truncated }
        guard r.fourCC(at: 36) == "acsp" else { throw ParseError.badSignature }
        self.data = data
        self.colorSpace = r.fourCC(at: 16)

        var tags: [String: (offset: Int, size: Int)] = [:]
        let count = Int(r.u32(at: 128) ?? 0)
        for i in 0..<count {
            let base = 132 + i * 12
            guard let off = r.u32(at: base + 4), let size = r.u32(at: base + 8) else { throw ParseError.truncated }
            tags[r.fourCC(at: base)] = (Int(off), Int(size))
        }

        func tag(_ sig: String) -> (offset: Int, size: Int)? {
            guard let t = tags[sig], t.offset >= 0, t.size >= 8, t.offset + t.size <= data.count else { return nil }
            return t
        }

        self.description = tag("desc").flatMap { Self.parseDescription(r, $0.offset, $0.size) }

        if let rx = tag("rXYZ").flatMap({ Self.parseXYZ(r, $0.offset) }),
           let gx = tag("gXYZ").flatMap({ Self.parseXYZ(r, $0.offset) }),
           let bx = tag("bXYZ").flatMap({ Self.parseXYZ(r, $0.offset) }) {
            colorants = (rx, gx, bx)
        } else {
            colorants = nil
        }

        if let rt = tag("rTRC").flatMap({ Self.parseCurve(r, $0.offset) }),
           let gt = tag("gTRC").flatMap({ Self.parseCurve(r, $0.offset) }),
           let bt = tag("bTRC").flatMap({ Self.parseCurve(r, $0.offset) }) {
            toneCurves = (rt, gt, bt)
        } else {
            toneCurves = nil
        }
    }

    /// True if this profile *encodes* Adobe RGB (1998): same colorants and a
    /// pure 563/256 curve on all three channels.
    ///
    /// Compared by content, not by bytes or name, because Capture One (or any
    /// other app) may embed its own copy of the profile with a different
    /// copyright string or tag layout. Colorants are stored as s15Fixed16, so
    /// two faithful copies agree to ~1/65536; the tolerance allows a few steps.
    public var isAdobeRGB1998: Bool {
        guard self.colorSpace == "RGB ",
              let mine = colorants, let curves = toneCurves,
              let ref = ICCProfile.adobeRGB1998.colorants else { return false }
        let tol = 4.0 / 65536.0
        func close(_ a: Vector3, _ b: Vector3) -> Bool {
            let d = a - b
            return abs(d.x) <= tol && abs(d.y) <= tol && abs(d.z) <= tol
        }
        guard close(mine.red, ref.red), close(mine.green, ref.green), close(mine.blue, ref.blue) else { return false }
        // 563/256 is exactly representable in u8Fixed8 (0x0233) and s15Fixed16.
        for c in [curves.red, curves.green, curves.blue] {
            guard case .gamma(let g) = c, abs(g - 563.0 / 256.0) < 1e-4 else { return false }
        }
        return true
    }

    /// Name for reports: the description if present, else "unnamed <space> profile".
    public var displayName: String {
        description ?? "unnamed \(colorSpace.trimmingTrailingSpaces) profile"
    }

    // MARK: - Tag parsers

    private static func parseXYZ(_ r: BigEndianReader, _ off: Int) -> Vector3? {
        guard r.fourCC(at: off) == "XYZ ",
              let x = r.s15Fixed16(at: off + 8), let y = r.s15Fixed16(at: off + 12), let z = r.s15Fixed16(at: off + 16)
        else { return nil }
        return Vector3(x, y, z)
    }

    private static func parseCurve(_ r: BigEndianReader, _ off: Int) -> ToneCurve? {
        switch r.fourCC(at: off) {
        case "curv":
            guard let n = r.u32(at: off + 8) else { return nil }
            switch n {
            case 0: return .gamma(1)
            case 1:
                guard let v = r.u16(at: off + 12) else { return nil }
                return .gamma(Double(v) / 256)
            default: return .other("sampled curve, \(n) entries")
            }
        case "para":
            guard let type = r.u16(at: off + 8) else { return nil }
            guard type == 0, let g = r.s15Fixed16(at: off + 12) else { return .other("parametric curve type \(type)") }
            return .gamma(g)
        case let sig:
            return .other("unknown curve type '\(sig)'")
        }
    }

    private static func parseDescription(_ r: BigEndianReader, _ off: Int, _ size: Int) -> String? {
        switch r.fourCC(at: off) {
        case "desc":
            // v2 textDescriptionType: u32 ASCII length (incl. NUL), then ASCII.
            guard let n = r.u32(at: off + 8), n > 0, off + 12 + Int(n) <= off + size else { return nil }
            let bytes = r.bytes(off + 12, Int(n)).prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        case "mluc":
            // v4 multiLocalizedUnicodeType: take the first record (UTF-16BE).
            guard let count = r.u32(at: off + 8), count > 0,
                  let len = r.u32(at: off + 20), let recOff = r.u32(at: off + 24) else { return nil }
            let start = off + Int(recOff)
            guard start + Int(len) <= off + size else { return nil }
            let raw = r.bytes(start, Int(len))
            var units: [UInt16] = []
            for i in stride(from: 0, to: raw.count - 1, by: 2) {
                units.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1]))
            }
            return String(decoding: units, as: UTF16.self)
        default:
            return nil
        }
    }
}

/// ICC data is always big-endian, whatever the TIFF around it.
private struct BigEndianReader {
    let d: [UInt8]
    init(_ d: [UInt8]) { self.d = d }

    func u16(at o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= d.count else { return nil }
        return UInt16(d[o]) << 8 | UInt16(d[o + 1])
    }

    func u32(at o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= d.count else { return nil }
        return UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
    }

    func s15Fixed16(at o: Int) -> Double? {
        u32(at: o).map { Double(Int32(bitPattern: $0)) / 65536 }
    }

    func fourCC(at o: Int) -> String {
        guard o >= 0, o + 4 <= d.count else { return "" }
        return String(decoding: d[o..<o + 4], as: UTF8.self)
    }

    func bytes(_ o: Int, _ n: Int) -> ArraySlice<UInt8> {
        guard o >= 0, n >= 0, o + n <= d.count else { return [] }
        return d[o..<o + n]
    }
}

extension String {
    var trimmingTrailingSpaces: String {
        var s = self
        while s.last == " " { s.removeLast() }
        return s
    }
}
