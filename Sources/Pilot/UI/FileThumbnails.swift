import AppKit
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// The Files view's row pictures (Homy-style Files, T3): an image's, a PDF's or a video's QuickLook thumbnail at the row
/// icon's size, made per row as it draws. The row wears the file's icon until its thumbnail is made, then swaps it in,
/// as reading `image` inside a row's body redraws it. At most `limit` are kept, oldest out first; `clear` drops them all,
/// for the menu's close to call.
@Observable @MainActor
final class FileThumbnails {
    static let shared = FileThumbnails()
    static let limit = 48
    /// A side in pixels, Stickers' row pictures' (`Stickers.thumbnailPixels`, internal to PilotCore).
    static let pixels = 56

    /// Makes a file's thumbnail `pixels` a side at most; QuickLook in the app, a fake in tests.
    typealias Make = @Sendable (URL, Int) async -> CGImage?

    private var made: [String: NSImage] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    /// Files QuickLook could not draw: their rows keep the icon without asking again on every redraw.
    @ObservationIgnored private var failed: Set<String> = []
    /// `shows` by extension, so a row's redraw makes no UTType.
    @ObservationIgnored private var showsByExtension: [String: Bool] = [:]
    @ObservationIgnored var make: Make = FileThumbnails.quickLook

    var count: Int { made.count }

    /// Images, PDFs and videos have a picture worth showing; every other file keeps Finder's icon.
    nonisolated static func shows(_ path: String) -> Bool {
        UTType(filenameExtension: (path as NSString).pathExtension).map(shows) ?? false
    }

    /// `shows` by type: the preview pane's picture rule too (FilePreviewPane).
    nonisolated static func shows(_ type: UTType) -> Bool {
        [UTType.image, .pdf, .movie].contains { type.conforms(to: $0) }
    }

    /// The thumbnail when it is made; else nil, and for an image, PDF or video its making starts.
    func image(_ path: String) -> NSImage? {
        if let image = made[path] { return image }
        guard pending[path] == nil, !failed.contains(path) else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        let shows = showsByExtension[ext] ?? Self.shows(path)
        showsByExtension[ext] = shows
        if shows { request(path) }
        return nil
    }

    private func request(_ path: String) {
        let make = make
        pending[path] = Task { [weak self] in
            let image = await make(URL(fileURLWithPath: path), Self.pixels)
            guard !Task.isCancelled, let self else { return }
            self.pending[path] = nil
            if let image { self.keep(path, image) } else { self.failed.insert(path) }
        }
    }

    /// The picture squared into the row's box, as it draws resizable: a wide or tall one letterboxed, never stretched.
    func keep(_ path: String, _ image: CGImage) {
        if made[path] == nil { order.append(path) }
        made[path] = Self.square(image)
        while order.count > Self.limit {
            let old = order.removeFirst()
            made[old] = nil
        }
    }

    /// Every thumbnail dropped and every making stopped, as the menu closes.
    func clear() {
        pending.values.forEach { $0.cancel() }
        pending = [:]
        failed = []
        order = []
        made = [:]
    }

    nonisolated static func quickLook(_ url: URL, _ pixels: Int) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pixels, height: pixels), scale: 1,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    /// `image` centred in a clear square its longest side wide, half that in points (a Retina picture).
    private static func square(_ image: CGImage) -> NSImage {
        let side = max(image.width, image.height)
        let points = NSSize(width: CGFloat(side) / 2, height: CGFloat(side) / 2)
        guard image.width != image.height,
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(cgImage: image, size: points) }
        ctx.draw(image, in: CGRect(x: (side - image.width) / 2, y: (side - image.height) / 2, width: image.width, height: image.height))
        return ctx.makeImage().map { NSImage(cgImage: $0, size: points) } ?? NSImage(cgImage: image, size: points)
    }
}
