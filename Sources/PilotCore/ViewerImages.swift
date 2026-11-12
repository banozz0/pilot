import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pictures Pilot's image viewer opens (Sven, 2026-11-12, Q158), how it reads them and how mark-up writes one back.
/// Every read turns the picture upright by its EXIF orientation and decodes it no larger than asked, so the viewer holds one
/// picture at screen size and the full size is read only for a press that needs it (mark up, Copy, Copy text).
public enum ViewerImages {
    /// The types Info.plist claims as an Alternate viewer: PNG, JPEG, HEIC, GIF, WebP, TIFF and BMP.
    public static let types = ["public.png", "public.jpeg", "public.heic", "com.compuserve.gif", "org.webmproject.webp", "public.tiff",
                               "com.microsoft.bmp"]

    private static let resolved = types.compactMap(UTType.init)
    /// The types ImageIO writes, read once.
    private static let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])

    /// Whether the viewer opens `url`: its type, by extension, is one of `types` or conforms to one (HEIF, a JPEG variant).
    public static func viewable(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return resolved.contains(where: type.conforms(to:))
    }

    /// The pictures in `url`'s folder the viewer steps through, in Finder's name order, hidden files left out; `url` among them
    /// even when the folder cannot be listed. Names only: no picture is read.
    public static func siblings(of url: URL) -> [URL] {
        let file = url.standardizedFileURL
        let listed = (try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        var all = listed.map(\.standardizedFileURL).filter(viewable)
        if !all.contains(file) { all.append(file) }
        return WallpaperCycle.sortedByName(all)
    }

    /// One read picture: the image, upright; the file's own size upright, in pixels; its points' scale from its DPI (the
    /// editor's rule: 144 when unset); and its frame count (more than one plays).
    public struct Decoded: @unchecked Sendable {
        public let image: CGImage
        public let pixels: CGSize
        public let scale: CGFloat
        public let frames: Int
    }

    /// `url` upright, its longest side at most `longest` pixels (nil: full size); nil when ImageIO cannot read it.
    public static func decode(_ url: URL, longest: Int?) -> Decoded? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0, h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // Orientations 5 to 8 turn the picture a quarter: its width and height swap.
        let pixels = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        let full = max(w, h)
        guard full > 0 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: min(full, longest ?? full)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 144
        return Decoded(image: image, pixels: pixels, scale: CGFloat(max(dpi, 72) / 72), frames: CGImageSourceGetCount(source))
    }

    /// Whether mark-up may be written over `url` in its own type: ImageIO writes that type and the file holds one frame
    /// (WebP is read-only; an animated GIF would lose its frames).
    public static func replaceable(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) == 1 else { return false }
        return writable.contains(type)
    }

    /// `image` encoded in `url`'s own type (never PNG bytes under a .jpg), with the file's own metadata (date taken, place,
    /// camera) kept and its orientation 1, since the pixels are turned already, at `scale`'s DPI (ImageIO's JPEG writer
    /// puts a backdrop's see-through corners on white). Nil when that type cannot be written.
    public static func encode(_ image: CGImage, scale: CGFloat, like url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let dpi = 72 * scale, id = type as String
        var props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        // The size the mark-up has now, not the one the file had.
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] { props[key] = nil }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            props[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        props[kCGImagePropertyOrientation] = 1
        props[kCGImagePropertyDPIWidth] = dpi
        props[kCGImagePropertyDPIHeight] = dpi
        if id == UTType.jpeg.identifier || id == UTType.heic.identifier { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
