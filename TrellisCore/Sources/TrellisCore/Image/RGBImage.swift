//
//  RGBImage.swift
//  TrellisCore
//
//  Created by Ben Colson on 07/10/2026.
//

/// Interleaved RGB(A) pixel code values, untouched by any colour management.
///
/// Values are stored exactly as they sit in the file: 0…65535 for 16-bit,
/// 0…255 for 8-bit. Nothing here knows about colour spaces; the attached ICC
/// profile says what the numbers mean, and validation decides whether to trust it.
public struct RGBImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// 3 (RGB) or 4 (RGB + one extra sample, usually alpha).
    public var samplesPerPixel: Int
    /// 8 or 16.
    public var bitsPerSample: Int
    /// `width × height × samplesPerPixel` code values, row-major, interleaved.
    public var samples: [UInt16]
    /// Embedded ICC profile bytes, if any.
    public var iccProfile: [UInt8]?

    public init(width: Int, height: Int, samplesPerPixel: Int = 3, bitsPerSample: Int = 16,
                samples: [UInt16], iccProfile: [UInt8]? = nil) {
        precondition(samplesPerPixel == 3 || samplesPerPixel == 4, "RGBImage needs 3 or 4 samples per pixel")
        precondition(bitsPerSample == 8 || bitsPerSample == 16, "RGBImage supports 8- or 16-bit samples")
        precondition(samples.count == width * height * samplesPerPixel, "Sample count does not match dimensions")
        self.width = width
        self.height = height
        self.samplesPerPixel = samplesPerPixel
        self.bitsPerSample = bitsPerSample
        self.samples = samples
        self.iccProfile = iccProfile
    }

    /// Largest code value at this bit depth (65535 or 255).
    public var maxCodeValue: Int { (1 << bitsPerSample) - 1 }

    /// RGB code values of pixel (x, y). Extra samples are ignored.
    @inlinable
    public func rgb(x: Int, y: Int) -> (UInt16, UInt16, UInt16) {
        let i = (y * width + x) * samplesPerPixel
        return (samples[i], samples[i + 1], samples[i + 2])
    }

    /// RGB of pixel (x, y) normalised to [0, 1] by the bit depth.
    @inlinable
    public func normalized(x: Int, y: Int) -> Vector3 {
        let (r, g, b) = rgb(x: x, y: y)
        let m = Double(maxCodeValue)
        return Vector3(Double(r) / m, Double(g) / m, Double(b) / m)
    }

    /// An image with the same pixels in reverse scan order: the last pixel
    /// becomes the first, etc., while channel order within each pixel is
    /// preserved. Used by the reversed Hald for spatial-operator detection.
    @inlinable
    public func reversedPixelOrder() -> RGBImage {
        let spp = samplesPerPixel
        let pixelCount = samples.count / spp
        var reversed = [UInt16]()
        reversed.reserveCapacity(samples.count)
        for p in (0..<pixelCount).reversed() {
            let base = p * spp
            for c in 0..<spp {
                reversed.append(samples[base + c])
            }
        }
        return RGBImage(width: width, height: height, samplesPerPixel: spp,
                        bitsPerSample: bitsPerSample, samples: reversed,
                        iccProfile: iccProfile)
    }
}
