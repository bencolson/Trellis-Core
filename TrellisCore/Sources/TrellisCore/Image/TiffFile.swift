//
//  TiffFile.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

import Foundation

extension Tiff {
    /// Reads a TIFF file's raw code values. No colour management.
    public static func read(contentsOf url: URL) throws -> RGBImage {
        try decode([UInt8](Data(contentsOf: url)))
    }

    /// Writes `image` as an uncompressed TIFF, atomically.
    public static func write(_ image: RGBImage, to url: URL, byteOrder: ByteOrder = .littleEndian) throws {
        try Data(encode(image, byteOrder: byteOrder)).write(to: url, options: .atomic)
    }
}
