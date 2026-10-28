import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image's pixels, 8-bit RGBA with straight (not premultiplied) alpha, rows top first, in the image's own RGB colour
/// space (a Display P3 capture stays P3). Owns its memory: a 4x wallpaper's 317 MB is freed with it, never copied
/// into a CGImage.
public final class PixelBuffer: @unchecked Sendable {
    public let width: Int, height: Int
    public let space: CGColorSpace
    /// Whether any pixel is not opaque; an opaque image's alpha is never resampled.
    public let hasAlpha: Bool
    public let bytes: UnsafeMutableBufferPointer<UInt8>

    /// Opaque white, unless `filled` is false for a buffer that is drawn over at once.
    public init(width: Int, height: Int, space: CGColorSpace, hasAlpha: Bool, filled: Bool = true) {
        self.width = width
        self.height = height
        self.space = space
        self.hasAlpha = hasAlpha
        bytes = .allocate(capacity: width * height * 4)
        if filled { bytes.initialize(repeating: 255) }
    }

    deinit { bytes.deallocate() }

    static func space(of image: CGImage) -> CGColorSpace {
        if let s = image.colorSpace, s.model == .rgb { return s }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }

    /// The image copied into `data` at its own size, RGBA premultiplied, rows `width × 4` bytes.
    static func draw(_ image: CGImage, into data: UnsafeMutableRawPointer, space: CGColorSpace) -> Bool {
        guard let ctx = CGContext(data: data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }

    /// The image drawn into a buffer of its own size; alpha made straight again when it has any.
    public convenience init?(_ image: CGImage) {
        self.init(width: image.width, height: image.height, space: Self.space(of: image), hasAlpha: Self.hasAlpha(image), filled: false)
        guard Self.draw(image, into: bytes.baseAddress!, space: space) else { return nil }
        if hasAlpha {
            var buffer = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        }
    }

    /// A CGImage over these pixels, no copy: it keeps the buffer alive.
    public func image() -> CGImage? {
        let info = Unmanaged.passRetained(self).toOpaque()
        guard let provider = CGDataProvider(dataInfo: info, data: bytes.baseAddress!, size: bytes.count, releaseData: { info, _, _ in
            info.map { Unmanaged<PixelBuffer>.fromOpaque($0).release() }
        }) else {
            Unmanaged<PixelBuffer>.fromOpaque(info).release()
            return nil
        }
        let alpha: CGImageAlphaInfo = hasAlpha ? .last : .noneSkipLast
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}

/// High-quality resampling (vImage's Lanczos), on premultiplied pixels so a see-through edge keeps no dark fringe.
public enum Resample {
    public static func image(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let space = PixelBuffer.space(of: image)
        let w = image.width, h = image.height
        let src = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: w * h * 4)
        defer { src.deallocate() }
        guard PixelBuffer.draw(image, into: src.baseAddress!, space: space), let out = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let dst = out.data else { return nil }
        var from = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
        var to = vImage_Buffer(data: dst, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: out.bytesPerRow)
        guard vImageScale_ARGB8888(&from, &to, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { return nil }
        return out.makeImage()
    }

    /// One 8-bit plane scaled to `width` × `height`: an upscaled image's alpha, which the model never sees.
    static func plane(_ plane: UnsafeMutableBufferPointer<UInt8>, width w: Int, height h: Int, to width: Int, _ height: Int) -> UnsafeMutableBufferPointer<UInt8>? {
        let out = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: width * height)
        var from = vImage_Buffer(data: plane.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
        var to = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
        guard vImageScale_Planar8(&from, &to, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { out.deallocate(); return nil }
        return out
    }
}

/// The formats a result is written in.
public enum ImageFormat: String, CaseIterable, Sendable {
    case png, jpeg, heic

    public var title: String { rawValue.uppercased() }
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var type: UTType { switch self { case .png: .png; case .jpeg: .jpeg; case .heic: .heic } }

    /// The original's own format when it is one of these, else PNG: a resized photo stays a JPEG.
    public static func of(_ url: URL) -> ImageFormat {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .png }
        return allCases.first { type.conforms(to: $0.type) } ?? .png
    }

    /// The image encoded; JPEG and HEIC at 0.92 (a JPEG drops any alpha).
    public func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = self == .png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.92]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

public enum ImageFiles {
    /// The image at `url` at its full size, turned upright as its EXIF orientation says (a phone photo's).
    public static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let size = size(source) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                              kCGImageSourceCreateThumbnailWithTransform: true,
                                                              kCGImageSourceShouldCacheImmediately: true,
                                                              kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)] as CFDictionary)
    }

    /// The image's size from its header, never a full read.
    public static func size(_ url: URL) -> (width: Int, height: Int)? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(size)
    }

    static func size(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let turned = (p[kCGImagePropertyOrientation] as? Int).map { $0 >= 5 } ?? false
        return turned ? (h, w) : (w, h)
    }

    /// Writes `data` in `folder` as "<stem><suffix>.<ext>", or "<stem><suffix> 2.<ext>" and on when that is taken: never
    /// over a file, the original least of all.
    public static func write(_ data: Data, in folder: URL, stem: String, suffix: String, ext: String) -> URL? {
        for n in 1...50 {
            let url = folder.appending(path: n == 1 ? "\(stem)\(suffix).\(ext)" : "\(stem)\(suffix) \(n).\(ext)", directoryHint: .notDirectory)
            do { try data.write(to: url, options: .withoutOverwriting); return url } catch CocoaError.fileWriteFileExists { continue } catch { return nil }
        }
        return nil
    }
}
