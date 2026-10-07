//
//  Tiff.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

/// Minimal baseline TIFF codec for RGB(A) code values, in pure Swift.
///
/// Pixel code values must be read and written with **no colour
/// management**. Rather than trusting ImageIO/CoreGraphics not to convert, Trellis
/// reads and writes the bytes itself, so there is no colour engine anywhere in
/// the path. This also keeps `TrellisCore` portable (Linux CI).
///
/// Scope is deliberately narrow: first IFD only, chunky (interleaved) RGB,
/// 8- or 16-bit unsigned integer samples, 3 or 4 samples per pixel, strips,
/// uncompressed. Anything else is a clear `Tiff.Error` naming what was found,
/// so the user can be told which recipe setting to change.
public enum Tiff {

    public enum ByteOrder: Sendable {
        case littleEndian  // "II"
        case bigEndian     // "MM"
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case notATiff
        case bigTiffUnsupported
        case truncated(String)
        case missingTag(String)
        case unsupported(String)

        public var description: String {
            switch self {
            case .notATiff: return "Not a TIFF file"
            case .bigTiffUnsupported: return "BigTIFF files are not supported"
            case .truncated(let what): return "TIFF is truncated (\(what))"
            case .missingTag(let tag): return "TIFF is missing required tag \(tag)"
            case .unsupported(let what): return "Unsupported TIFF: \(what)"
            }
        }
    }

    // MARK: - Writing

    /// Encodes `image` as an uncompressed baseline TIFF, embedding its ICC profile.
    public static func encode(_ image: RGBImage, byteOrder: ByteOrder = .littleEndian,
                              software: String = "Trellis \(Trellis.version)") -> [UInt8] {
        let bytesPerSample = image.bitsPerSample / 8
        let rowBytes = image.width * image.samplesPerPixel * bytesPerSample
        // ~64 KiB strips: conventional, and every reader handles them.
        let rowsPerStrip = max(1, min(image.height, 65_536 / max(rowBytes, 1)))
        let stripCount = (image.height + rowsPerStrip - 1) / rowsPerStrip

        var w = ByteWriter(order: byteOrder)
        w.bytes(byteOrder == .littleEndian ? [0x49, 0x49] : [0x4D, 0x4D])
        w.u16(42)
        w.u32(8)

        // Build tag list first, then lay out out-of-line data after the IFD.
        var entries: [IFDEntry] = [
            .long(256, [UInt32(image.width)]),
            .long(257, [UInt32(image.height)]),
            .short(258, Array(repeating: UInt16(image.bitsPerSample), count: image.samplesPerPixel)),
            .short(259, [1]),                            // Compression: none
            .short(262, [2]),                            // Photometric: RGB
            .long(273, Array(repeating: 0, count: stripCount)),  // StripOffsets (patched)
            .short(277, [UInt16(image.samplesPerPixel)]),
            .long(278, [UInt32(rowsPerStrip)]),
            .long(279, (0..<stripCount).map { s in
                UInt32(min(rowsPerStrip, image.height - s * rowsPerStrip) * rowBytes)
            }),
            .rational(282, 72, 1),                       // XResolution
            .rational(283, 72, 1),                       // YResolution
            .short(284, [1]),                            // PlanarConfiguration: chunky
            .short(296, [2]),                            // ResolutionUnit: inch
            .ascii(305, software),
        ]
        if image.samplesPerPixel == 4 {
            entries.append(.short(338, [2]))             // ExtraSamples: unassociated alpha
        }
        entries.append(.short(339, Array(repeating: 1, count: image.samplesPerPixel)))  // SampleFormat: uint
        if let icc = image.iccProfile {
            entries.append(.undefined(34675, icc))       // ICC profile
        }
        entries.sort { $0.tag < $1.tag }

        let ifdSize = 2 + entries.count * 12 + 4
        var dataOffset = 8 + ifdSize
        var outOfLine: [(Int, [UInt8])] = []   // (entry index, payload)
        var valueOffsets: [Int: UInt32] = [:]
        for (i, e) in entries.enumerated() {
            let payload = e.payload(order: byteOrder)
            if payload.count > 4 {
                dataOffset += dataOffset & 1   // word-align
                valueOffsets[i] = UInt32(dataOffset)
                outOfLine.append((i, payload))
                dataOffset += payload.count
            }
        }
        dataOffset += dataOffset & 1
        let pixelStart = dataOffset

        // Patch StripOffsets now that the pixel position is known.
        if let idx = entries.firstIndex(where: { $0.tag == 273 }) {
            entries[idx] = .long(273, (0..<stripCount).map { UInt32(pixelStart + $0 * rowsPerStrip * rowBytes) })
        }

        w.u16(UInt16(entries.count))
        for (i, e) in entries.enumerated() {
            w.u16(e.tag)
            w.u16(e.type)
            w.u32(UInt32(e.count))
            if let off = valueOffsets[i] {
                w.u32(off)
            } else {
                var inline = e.payload(order: byteOrder)
                inline += Array(repeating: 0, count: 4 - inline.count)
                w.bytes(inline)
            }
        }
        w.u32(0)  // no next IFD

        for (i, _) in outOfLine {
            let target = Int(valueOffsets[i]!)
            w.pad(to: target)
            w.bytes(entries[i].payload(order: byteOrder))
        }
        w.pad(to: pixelStart)

        w.reserve(image.samples.count * bytesPerSample)
        if bytesPerSample == 2 {
            for s in image.samples { w.u16(s) }
        } else {
            for s in image.samples { w.u8(UInt8(truncatingIfNeeded: s)) }
        }
        return w.data
    }

    // MARK: - Reading

    /// Byte order + first IFD's tags, keyed by tag number.
    private static func readFirstIFD(_ data: [UInt8]) throws -> (ByteReader, [UInt16: RawEntry]) {
        guard data.count >= 8 else { throw Error.notATiff }
        let order: ByteOrder
        switch (data[0], data[1]) {
        case (0x49, 0x49): order = .littleEndian
        case (0x4D, 0x4D): order = .bigEndian
        default: throw Error.notATiff
        }
        let r = ByteReader(data: data, order: order)
        let magic = try r.u16(2)
        if magic == 43 { throw Error.bigTiffUnsupported }
        guard magic == 42 else { throw Error.notATiff }

        let ifd = Int(try r.u32(4))
        let count = Int(try r.u16(ifd))
        var tags: [UInt16: RawEntry] = [:]
        for i in 0..<count {
            let base = ifd + 2 + i * 12
            let tag = try r.u16(base)
            let type = try r.u16(base + 2)
            let n = Int(try r.u32(base + 4))
            tags[tag] = RawEntry(type: type, count: n, fieldOffset: base + 8)
        }

        return (r, tags)
    }

    /// Structural summary of a TIFF's first image, for diagnosing files Trellis
    /// can't (yet) decode, e.g. a Capture One export with an unexpected layout.
    public struct Info: Sendable, CustomStringConvertible {
        public let byteOrder: ByteOrder
        /// Every tag in the first IFD → its integer values (empty for non-integer tags).
        public let tags: [UInt16: [Int]]
        public let iccProfile: ICCProfile?

        func value(_ tag: UInt16) -> String { tags[tag].map { $0.map(String.init).joined(separator: ",") } ?? "—" }

        public var description: String {
            var lines = [
                "byte order        \(byteOrder == .littleEndian ? "little-endian (II)" : "big-endian (MM)")",
                "dimensions        \(value(256)) × \(value(257))",
                "samples/pixel     \(value(277))",
                "bits/sample       \(value(258))",
                "sample format     \(value(339))  (1 = unsigned int)",
                "compression       \(value(259))  (1 = none, 5 = LZW, 8 = Deflate)",
                "predictor         \(value(317))",
                "photometric       \(value(262))  (2 = RGB)",
                "planar config     \(value(284))  (1 = interleaved)",
                "extra samples     \(value(338))",
                "rows/strip        \(value(278))",
                "strips            \(tags[273]?.count ?? 0)",
                "tiled             \(tags[322] != nil ? "yes" : "no")",
            ]
            if let p = iccProfile {
                lines.append("ICC profile       \(p.displayName), \(p.data.count) bytes, Adobe RGB (1998) by content: \(p.isAdobeRGB1998 ? "yes" : "NO")")
            } else {
                lines.append("ICC profile       none")
            }
            lines.append("all tags          \(tags.keys.sorted().map(String.init).joined(separator: " "))")
            return lines.joined(separator: "\n")
        }
    }

    public static func inspect(_ data: [UInt8]) throws -> Info {
        let (r, raw) = try readFirstIFD(data)
        var tags: [UInt16: [Int]] = [:]
        for (tag, e) in raw where tag != 34675 {
            tags[tag] = (try? e.integers(r)) ?? []
        }
        let icc = try raw[34675].flatMap { try ICCProfile(data: $0.bytes(r)) }
        return Info(byteOrder: r.order, tags: tags, iccProfile: icc)
    }

    /// Decodes the first image in a TIFF to raw code values. No colour management.
    public static func decode(_ data: [UInt8]) throws -> RGBImage {
        let (r, tags) = try readFirstIFD(data)
        let order = r.order

        func ints(_ tag: UInt16, _ name: String) throws -> [Int] {
            guard let e = tags[tag] else { throw Error.missingTag(name) }
            return try e.integers(r)
        }
        func int(_ tag: UInt16, _ name: String, default def: Int? = nil) throws -> Int {
            if tags[tag] == nil, let def { return def }
            guard let v = try ints(tag, name).first else { throw Error.missingTag(name) }
            return v
        }

        let width = try int(256, "ImageWidth")
        let height = try int(257, "ImageLength")
        let spp = try int(277, "SamplesPerPixel", default: 1)
        let bitsList = try tags[258] == nil ? [1] : ints(258, "BitsPerSample")
        let compression = try int(259, "Compression", default: 1)
        let photometric = try int(262, "PhotometricInterpretation")
        let planar = try int(284, "PlanarConfiguration", default: 1)
        let sampleFormat = try tags[339] == nil ? [1] : ints(339, "SampleFormat")

        guard photometric == 2 else {
            throw Error.unsupported("photometric interpretation \(photometric) (\(photometricName(photometric))); expected RGB")
        }
        guard spp == 3 || spp == 4 else {
            throw Error.unsupported("\(spp) samples per pixel; expected RGB (3) or RGBA (4)")
        }
        guard Set(bitsList).count == 1, let bits = bitsList.first, bits == 8 || bits == 16 else {
            throw Error.unsupported("bits per sample \(bitsList); expected 8 or 16")
        }
        guard sampleFormat.allSatisfy({ $0 == 1 }) else {
            throw Error.unsupported("sample format \(sampleFormat) (floating point or signed); expected unsigned integer")
        }
        guard compression == 1 else {
            throw Error.unsupported("compression \(compressionName(compression)); export uncompressed TIFF")
        }
        guard planar == 1 else {
            throw Error.unsupported("planar (separate) sample layout; expected interleaved")
        }
        guard tags[322] == nil else {
            throw Error.unsupported("tiled layout; expected strips")
        }

        let offsets = try ints(273, "StripOffsets")
        let rowsPerStrip = try int(278, "RowsPerStrip", default: height)
        let bytesPerSample = bits / 8
        let rowBytes = width * spp * bytesPerSample
        let total = width * height * spp

        var samples = [UInt16]()
        samples.reserveCapacity(total)
        for (s, off) in offsets.enumerated() {
            let rows = min(rowsPerStrip, height - s * rowsPerStrip)
            guard rows > 0 else { break }
            let n = rows * rowBytes
            guard off >= 0, off + n <= data.count else { throw Error.truncated("strip \(s)") }
            if bytesPerSample == 2 {
                var p = off
                let end = off + n
                if order == .littleEndian {
                    while p < end { samples.append(UInt16(data[p]) | UInt16(data[p + 1]) << 8); p += 2 }
                } else {
                    while p < end { samples.append(UInt16(data[p]) << 8 | UInt16(data[p + 1])); p += 2 }
                }
            } else {
                for p in off..<(off + n) { samples.append(UInt16(data[p])) }
            }
        }
        guard samples.count == total else { throw Error.truncated("expected \(total) samples, found \(samples.count)") }

        var icc: [UInt8]?
        if let e = tags[34675] {
            icc = try e.bytes(r)
        }
        return RGBImage(width: width, height: height, samplesPerPixel: spp, bitsPerSample: bits,
                        samples: samples, iccProfile: icc)
    }

    private static func compressionName(_ c: Int) -> String {
        switch c {
        case 5: return "LZW"
        case 7: return "JPEG"
        case 8, 32946: return "ZIP/Deflate"
        case 32773: return "PackBits"
        default: return "type \(c)"
        }
    }

    private static func photometricName(_ p: Int) -> String {
        switch p {
        case 0, 1: return "greyscale"
        case 3: return "palette"
        case 5: return "CMYK"
        case 6: return "YCbCr"
        case 8: return "CIELab"
        default: return "unknown"
        }
    }
}

// MARK: - IFD plumbing

private enum IFDEntry {
    case short(UInt16, [UInt16])
    case long(UInt16, [UInt32])
    case rational(UInt16, UInt32, UInt32)
    case ascii(UInt16, String)
    case undefined(UInt16, [UInt8])

    var tag: UInt16 {
        switch self {
        case .short(let t, _), .long(let t, _), .rational(let t, _, _), .ascii(let t, _), .undefined(let t, _): return t
        }
    }

    var type: UInt16 {
        switch self {
        case .short: return 3
        case .long: return 4
        case .rational: return 5
        case .ascii: return 2
        case .undefined: return 7
        }
    }

    var count: Int {
        switch self {
        case .short(_, let v): return v.count
        case .long(_, let v): return v.count
        case .rational: return 1
        case .ascii(_, let s): return s.utf8.count + 1
        case .undefined(_, let b): return b.count
        }
    }

    func payload(order: Tiff.ByteOrder) -> [UInt8] {
        var w = ByteWriter(order: order)
        switch self {
        case .short(_, let v): v.forEach { w.u16($0) }
        case .long(_, let v): v.forEach { w.u32($0) }
        case .rational(_, let n, let d): w.u32(n); w.u32(d)
        case .ascii(_, let s): w.bytes(Array(s.utf8) + [0])
        case .undefined(_, let b): w.bytes(b)
        }
        return w.data
    }
}

private struct RawEntry {
    let type: UInt16
    let count: Int
    let fieldOffset: Int

    private var elementSize: Int {
        switch type {
        case 1, 2, 6, 7: return 1   // BYTE, ASCII, SBYTE, UNDEFINED
        case 3, 8: return 2         // SHORT, SSHORT
        case 4, 9, 11: return 4     // LONG, SLONG, FLOAT
        case 5, 10, 12: return 8    // RATIONAL, SRATIONAL, DOUBLE
        default: return 1
        }
    }

    private func valueOffset(_ r: ByteReader) throws -> Int {
        count * elementSize <= 4 ? fieldOffset : Int(try r.u32(fieldOffset))
    }

    func integers(_ r: ByteReader) throws -> [Int] {
        let base = try valueOffset(r)
        return try (0..<count).map { i in
            switch type {
            case 1, 7: return Int(try r.u8(base + i))
            case 3: return Int(try r.u16(base + i * 2))
            case 4: return Int(try r.u32(base + i * 4))
            default: throw Tiff.Error.unsupported("integer tag with field type \(type)")
            }
        }
    }

    func bytes(_ r: ByteReader) throws -> [UInt8] {
        let base = try valueOffset(r)
        let n = count * elementSize
        guard base >= 0, base + n <= r.data.count else { throw Tiff.Error.truncated("tag data") }
        return Array(r.data[base..<base + n])
    }
}

private struct ByteReader {
    let data: [UInt8]
    let order: Tiff.ByteOrder

    func u8(_ o: Int) throws -> UInt8 {
        guard o >= 0, o < data.count else { throw Tiff.Error.truncated("offset \(o)") }
        return data[o]
    }

    func u16(_ o: Int) throws -> UInt16 {
        guard o >= 0, o + 2 <= data.count else { throw Tiff.Error.truncated("offset \(o)") }
        let a = UInt16(data[o]), b = UInt16(data[o + 1])
        return order == .littleEndian ? a | b << 8 : a << 8 | b
    }

    func u32(_ o: Int) throws -> UInt32 {
        guard o >= 0, o + 4 <= data.count else { throw Tiff.Error.truncated("offset \(o)") }
        let b = data[o..<o + 4].map(UInt32.init)
        return order == .littleEndian
            ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24
            : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
    }
}

private struct ByteWriter {
    let order: Tiff.ByteOrder
    var data: [UInt8] = []

    init(order: Tiff.ByteOrder) { self.order = order }

    mutating func reserve(_ n: Int) { data.reserveCapacity(data.count + n) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func bytes(_ b: [UInt8]) { data += b }
    mutating func pad(to offset: Int) {
        if data.count < offset { data += Array(repeating: 0, count: offset - data.count) }
    }

    mutating func u16(_ v: UInt16) {
        if order == .littleEndian {
            data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8))
        } else {
            data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xFF))
        }
    }

    mutating func u32(_ v: UInt32) {
        if order == .littleEndian {
            u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16))
        } else {
            u16(UInt16(v >> 16)); u16(UInt16(v & 0xFFFF))
        }
    }
}
