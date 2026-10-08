//
//  CubeReader.swift
//  TrellisCore
//
//  Created by Ben Colson on 08/10/2026.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A parsed `.cube` 3D LUT.
public struct CubeFile: Sendable {
    public var title: String?
    public var lut: LUT3D
    public var domainMin: Vector3
    public var domainMax: Vector3
    /// Header comments (`#` lines before the data), without the `# `.
    public var comments: [String]
    /// Things that were accepted but worth knowing, e.g. an unknown keyword.
    public var warnings: [String]
}

/// Why a `.cube` file couldn't be read. Every case that points at a place in
/// the file carries its 1-based line number.
public enum CubeReadError: Error, Equatable, Sendable, CustomStringConvertible {
    case notText
    case empty
    case missingSize
    case oneDimensional(line: Int)
    case invalidSize(line: Int, text: String)
    case duplicateKeyword(line: Int, keyword: String, firstLine: Int)
    case keywordAfterData(line: Int, keyword: String)
    case wrongValueCount(line: Int, expected: Int, found: Int, text: String)
    case notANumber(line: Int, text: String)
    case invalidDomain(min: Vector3, max: Vector3)
    case unterminatedTitle(line: Int)
    case dataCountMismatch(expected: Int, found: Int, size: Int)

    public var description: String {
        switch self {
        case .notText:
            return "not a text file"
        case .empty:
            return "the file is empty"
        case .missingSize:
            return "no LUT_3D_SIZE line before the data"
        case .oneDimensional(let line):
            return "line \(line): 1D LUTs (LUT_1D_SIZE) aren't supported, only 3D"
        case .invalidSize(let line, let text):
            return "line \(line): LUT_3D_SIZE must be a whole number from 2 to 256, found \"\(text)\""
        case .duplicateKeyword(let line, let keyword, let first):
            return "line \(line): \(keyword) appears again (first on line \(first))"
        case .keywordAfterData(let line, let keyword):
            return "line \(line): \(keyword) after the LUT data started"
        case .wrongValueCount(let line, let expected, let found, let text):
            return "line \(line): expected \(expected) numbers, found \(found) (\"\(text)\")"
        case .notANumber(let line, let text):
            return "line \(line): \"\(text)\" is not a finite number"
        case .invalidDomain(let min, let max):
            return "DOMAIN_MIN \(min) must be below DOMAIN_MAX \(max) on every channel"
        case .unterminatedTitle(let line):
            return "line \(line): TITLE is missing its closing quote"
        case .dataCountMismatch(let expected, let found, let size):
            let relation = found < expected ? "too few" : "too many"
            return "\(relation) data lines: LUT_3D_SIZE \(size) needs \(expected) (\(size)³), found \(found)"
        }
    }
}

extension CubeIO {

    /// Parses a `.cube` 3D LUT (Adobe Cube LUT Specification 1.0, plus the
    /// `LUT_3D_INPUT_RANGE` form Resolve writes). Strict: anything the
    /// specification doesn't allow is an error naming the line, never a guess.
    /// Unknown keywords before the data are accepted with a warning, since
    /// several tools add their own.
    public static func read(_ text: String) throws -> CubeFile {
        try read(Array(text.utf8))
    }

    /// Reads a `.cube` from raw bytes, which must be UTF-8 (or ASCII).
    ///
    /// Works on bytes rather than `String` lines: a 65³ cube is 274 625 data
    /// lines, and grapheme-aware splitting made that take over a second.
    public static func read(_ bytes: [UInt8]) throws -> CubeFile {
        var title: String?
        var size: Int?
        var domainMin = Vector3(0, 0, 0)
        var domainMax = Vector3(1, 1, 1)
        var comments: [String] = []
        var warnings: [String] = []
        var seen: [String: Int] = [:]
        var values: [Vector3] = []
        var dataStarted = false

        if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
            throw CubeReadError.empty
        }
        // Binary or non-UTF-8 input: decoding would have to repair it.
        if bytes.contains(0) || !String(decoding: bytes, as: UTF8.self).utf8.elementsEqual(bytes) {
            throw CubeReadError.notText
        }
        var start = 0
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { start = 3 }   // UTF-8 BOM
        var lineNumber = 0

        while start <= bytes.count {
            lineNumber += 1
            var end = start
            while end < bytes.count, bytes[end] != 0x0A, bytes[end] != 0x0D { end += 1 }
            let next = end + ((end < bytes.count && bytes[end] == 0x0D && end + 1 < bytes.count && bytes[end + 1] == 0x0A) ? 2 : 1)
            defer { start = next }

            // Trim spaces / tabs.
            var lo = start, hi = end
            while lo < hi, bytes[lo] == 0x20 || bytes[lo] == 0x09 { lo += 1 }
            while hi > lo, bytes[hi - 1] == 0x20 || bytes[hi - 1] == 0x09 { hi -= 1 }
            if lo == hi { if end >= bytes.count { break } else { continue } }

            if bytes[lo] == UInt8(ascii: "#") {
                if !dataStarted {
                    var c = lo + 1
                    if c < hi, bytes[c] == 0x20 { c += 1 }
                    comments.append(try text(bytes[c..<hi]))
                }
                continue
            }

            if isLetter(bytes[lo]) && !looksNumeric(bytes, lo, hi) {
                var k = lo
                while k < hi, bytes[k] != 0x20, bytes[k] != 0x09 { k += 1 }
                let keyword = try text(bytes[lo..<k])
                var r = k
                while r < hi, bytes[r] == 0x20 || bytes[r] == 0x09 { r += 1 }
                let rest = try text(bytes[r..<hi])

                if dataStarted { throw CubeReadError.keywordAfterData(line: lineNumber, keyword: keyword) }
                if let earlier = seen[keyword] {
                    throw CubeReadError.duplicateKeyword(line: lineNumber, keyword: keyword, firstLine: earlier)
                }
                seen[keyword] = lineNumber

                switch keyword {
                case "TITLE":
                    if rest.hasPrefix("\"") {
                        guard rest.count >= 2, rest.hasSuffix("\"") else {
                            throw CubeReadError.unterminatedTitle(line: lineNumber)
                        }
                        title = String(rest.dropFirst().dropLast())
                    } else {
                        // Unquoted (or empty) titles are outside the spec but
                        // common, and Resolve reads them.
                        title = rest
                        warnings.append("line \(lineNumber): TITLE is not in quotes")
                    }
                case "LUT_3D_SIZE":
                    guard let n = Int(rest), (2...256).contains(n) else {
                        throw CubeReadError.invalidSize(line: lineNumber, text: rest)
                    }
                    size = n
                    values.reserveCapacity(n * n * n)
                case "LUT_1D_SIZE":
                    throw CubeReadError.oneDimensional(line: lineNumber)
                case "DOMAIN_MIN":
                    let n = try numbers(bytes, lo: r, hi: hi, count: 3, line: lineNumber)
                    domainMin = Vector3(n.0, n.1, n.2)
                case "DOMAIN_MAX":
                    let n = try numbers(bytes, lo: r, hi: hi, count: 3, line: lineNumber)
                    domainMax = Vector3(n.0, n.1, n.2)
                case "LUT_3D_INPUT_RANGE":
                    let n = try numbers(bytes, lo: r, hi: hi, count: 2, line: lineNumber)
                    domainMin = Vector3(repeating: n.0)
                    domainMax = Vector3(repeating: n.1)
                default:
                    warnings.append("line \(lineNumber): unknown keyword \(keyword) ignored")
                }
                continue
            }

            // A data line.
            if !dataStarted {
                dataStarted = true
                guard size != nil else { throw CubeReadError.missingSize }
            }
            let n = try numbers(bytes, lo: lo, hi: hi, count: 3, line: lineNumber)
            values.append(Vector3(n.0, n.1, n.2))
        }

        guard let size else { throw CubeReadError.missingSize }
        guard domainMin.x < domainMax.x, domainMin.y < domainMax.y, domainMin.z < domainMax.z else {
            throw CubeReadError.invalidDomain(min: domainMin, max: domainMax)
        }
        let expected = size * size * size
        guard values.count == expected else {
            throw CubeReadError.dataCountMismatch(expected: expected, found: values.count, size: size)
        }
        return CubeFile(title: title, lut: LUT3D(size: size, values: values),
                        domainMin: domainMin, domainMax: domainMax,
                        comments: comments, warnings: warnings)
    }

    // MARK: - Byte helpers

    private static func isLetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    /// "nan", "inf", "infinity" start with letters but are (bad) data, not
    /// keywords: let the number parser reject them with a precise error.
    private static func looksNumeric(_ bytes: [UInt8], _ lo: Int, _ hi: Int) -> Bool {
        var k = lo
        while k < hi, bytes[k] != 0x20, bytes[k] != 0x09 { k += 1 }
        let word = String(decoding: bytes[lo..<k], as: UTF8.self).lowercased()
        return word == "nan" || word == "inf" || word == "infinity"
    }

    /// The whole file was checked as UTF-8 up front, so this never repairs.
    private static func text(_ slice: ArraySlice<UInt8>) throws -> String {
        String(decoding: slice, as: UTF8.self)
    }

    /// Parses exactly `count` (2 or 3) whitespace-separated finite numbers in
    /// `bytes[lo..<hi]`.
    private static func numbers(_ bytes: [UInt8], lo: Int, hi: Int, count: Int,
                                line: Int) throws -> (Double, Double, Double) {
        var out = (0.0, 0.0, 0.0)
        var found = 0
        var i = lo
        var tooMany = false
        while i < hi {
            while i < hi, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
            if i >= hi { break }
            var j = i
            while j < hi, bytes[j] != 0x20, bytes[j] != 0x09 { j += 1 }
            if found == count { tooMany = true; found += 1; i = j; continue }
            let v = try parseDouble(bytes, i, j, line: line)
            switch found {
            case 0: out.0 = v
            case 1: out.1 = v
            default: out.2 = v
            }
            found += 1
            i = j
        }
        if found != count || tooMany {
            let t = String(decoding: bytes[lo..<hi], as: UTF8.self)
            throw CubeReadError.wrongValueCount(line: line, expected: count, found: found, text: t)
        }
        return out
    }

    private static func parseDouble(_ bytes: [UInt8], _ lo: Int, _ hi: Int, line: Int) throws -> Double {
        let length = hi - lo
        var parsed: Double?
        if length < 64 {
            withUnsafeTemporaryAllocation(of: CChar.self, capacity: length + 1) { buf in
                for k in 0..<length { buf[k] = CChar(bitPattern: bytes[lo + k]) }
                buf[length] = 0
                var endPtr: UnsafeMutablePointer<CChar>?
                let v = strtod(buf.baseAddress!, &endPtr)
                if endPtr == buf.baseAddress! + length { parsed = v }
            }
        }
        guard let v = parsed, v.isFinite else {
            throw CubeReadError.notANumber(line: line, text: String(decoding: bytes[lo..<hi], as: UTF8.self))
        }
        return v
    }
}
