import Foundation
import ImageIO

/// Next and previous wallpaper on one screen (story 146, card agent-bo-95423316): the images of the picked folders and
/// images (Look › Wallpaper, story 160; ~/Pictures/Wallpapers until one is picked), by name or shuffled, only those of the
/// screen's shape unless none fit or that is switched off (Sven 2026-10-19, Q329). No position is saved: the screen's own current image is found in the list and the
/// step goes from there, so the list is read only on a press.
public enum WallpaperCycle {
    public enum Shape: Sendable { case landscape, portrait }

    /// The cycle's order: file name, or a shuffle that stays the same until Shuffle again, so Previous goes back.
    public enum Order: String, CaseIterable, Sendable { case name, shuffle }

    /// Which screens a press changes: the one the window in front is on, or every screen, each from its own image.
    public enum Scope: String, CaseIterable, Sendable { case focusedScreen, everyScreen }

    /// Where each screen's images come from: the same folders for every screen, or each screen its own, a screen with
    /// none of its own taking the shared ones (Sven 2026-10-17).
    public enum Folders: String, CaseIterable, Sendable { case shared, perScreen }

    /// Whether a workspace can have its own folders, shown on its screen when it is switched to; one with none takes the
    /// screen's (Sven 2026-10-19, Q333).
    public enum Workspaces: String, CaseIterable, Sendable { case shared, perWorkspace }

    /// Change on its own: minutes between steps, 0 for never.
    public static let intervals = [0, 15, 30, 60, 180, 1440]

    public static func intervalName(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Never"
        case 1440: "Every day"
        case 60: "Every hour"
        case let m where m % 60 == 0: "Every \(m / 60) hours"
        default: "Every \(minutes) minutes"
        }
    }

    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]

    /// ~/Pictures/Wallpapers: where images come from when the applied package names no folder.
    public static let standardFolder = URL(filePath: NSHomeDirectory()).appending(path: "Pictures/Wallpapers")

    /// Every image of `sources` by file name, each once: a folder's and below, an image file itself.
    public static func images(in sources: [URL]) -> [URL] {
        var seen = Set<String>()
        let all = sources.flatMap { source in
            isImage(source) ? (FileManager.default.fileExists(atPath: source.path) ? [source] : []) : images(in: source)
        }
        return sortedByName(all.filter { seen.insert($0.standardizedFileURL.path).inserted })
    }

    public static func isImage(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// `images` in `order`: as listed, or shuffled by `seed`, the same order for the same seed and files on every run.
    public static func ordered(_ images: [URL], order: Order, seed: UInt64) -> [URL] {
        guard order == .shuffle else { return images }
        let keyed: [(key: UInt64, url: URL)] = images.map { (mix(seed, $0.standardizedFileURL.path), $0) }
        return keyed.sorted { a, b in a.key == b.key ? a.url.path < b.url.path : a.key < b.key }.map(\.url)
    }

    /// FNV-1a over the seed and the path: Swift's Hasher changes per run, which would reshuffle at every launch.
    static func mix(_ seed: UInt64, _ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let bytes: [UInt8] = withUnsafeBytes(of: seed.littleEndian) { Array($0) } + Array(text.utf8)
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }

    /// Every image file in `folder` and below, by file name, hidden files left out.
    public static func images(in folder: URL) -> [URL] {
        (try? images(in: folder, inspect: { _ in })) ?? []
    }

    /// The same visible-image inventory, with a strict caller's containment check on every visible entry.
    public static func images(in folder: URL, inspect: (URL) throws -> Void) throws -> [URL] {
        var failure: Error?
        guard let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var images: [URL] = []
        for case let entry as URL in entries {
            try inspect(entry)
            if isImage(entry), try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true { images.append(entry) }
        }
        if let failure { throw failure }
        return sortedByName(images)
    }

    public static func sortedByName(_ images: [URL]) -> [URL] {
        images.sorted {
            let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }

    /// The image one step on from `current` among those of `screen`'s shape (all of them when none fits, or when `fit`
    /// is off), wrapping at either end, with its place counted from 1; from an image not in the list, the first or, going
    /// back, the last. Nil for no images.
    public static func step(_ images: [URL], shape: (URL) -> Shape?, screen: Shape, fit: Bool = true, current: URL?,
                            forward: Bool) -> (url: URL, place: Int, count: Int)? {
        let list = cycle(images, shape: shape, screen: screen, fit: fit)
        guard !list.isEmpty else { return nil }
        let at = index(of: current, in: list)
        let next = at.map { ($0 + (forward ? 1 : -1) + list.count) % list.count } ?? (forward ? 0 : list.count - 1)
        return (list[next], next + 1, list.count)
    }

    /// Where `current` sits in `screen`'s cycle, counted from 1, and how many the cycle holds; nil when it is not in it.
    public static func place(of current: URL?, in images: [URL], shape: (URL) -> Shape?, screen: Shape,
                             fit: Bool = true) -> (place: Int, count: Int)? {
        let list = cycle(images, shape: shape, screen: screen, fit: fit)
        return index(of: current, in: list).map { ($0 + 1, list.count) }
    }

    /// The images of `screen`'s shape, or all of them when none fits or `fit` is off; no header is read then.
    static func cycle(_ images: [URL], shape: (URL) -> Shape?, screen: Shape, fit: Bool = true) -> [URL] {
        guard fit else { return images }
        let fitting = images.filter { shape($0) == screen }
        return fitting.isEmpty ? images : fitting
    }

    static func index(of current: URL?, in list: [URL]) -> Int? {
        current.flatMap { now in list.firstIndex { key($0) == key(now) } }
    }

    /// The path two URLs of one image share.
    static func key(_ url: URL) -> String { url.standardizedFileURL.path }
}

/// What Pilot set on each screen, held against macOS's read of it (NSWorkspace.desktopImageURL(for:)), which trails a set
/// by up to half a second (Sven 2026-10-10): while the read is still an image Pilot replaced, the screen shows the one
/// Pilot set. Once the read is that image, or any other (set in System Settings), the read wins and the set is forgotten.
public struct SetWallpapers: Sendable {
    private var screens: [UInt32: (set: URL, replaced: Set<String>)] = [:]

    public init() {}

    public mutating func record(_ url: URL, replacing before: URL?, on screen: UInt32) {
        var replaced = screens[screen]?.replaced ?? []
        if let before { replaced.insert(WallpaperCycle.key(before)) }
        replaced.remove(WallpaperCycle.key(url))
        screens[screen] = (url, replaced)
    }

    public mutating func current(on screen: UInt32, read: URL?) -> URL? {
        guard let kept = screens[screen] else { return read }
        if let read, kept.replaced.contains(WallpaperCycle.key(read)) { return kept.set }
        screens[screen] = nil
        return read
    }
}

/// Each image's shape from its header alone (CGImageSource, no decode), kept in memory by path and modification date so
/// a second press reads no file.
public final class ImageShapes: @unchecked Sendable {
    private var known: [String: (date: Date, shape: WallpaperCycle.Shape?)] = [:]
    private let lock = NSLock()

    public init() {}

    public func shape(_ url: URL) -> WallpaperCycle.Shape? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let hit = lock.withLock({ known[url.path] }), hit.date == date { return hit.shape }
        let shape = Self.read(url)
        lock.withLock { known[url.path] = (date, shape) }
        return shape
    }

    /// Width against height as shown: EXIF orientations 5 to 8 turn the image a quarter.
    static func read(_ url: URL) -> WallpaperCycle.Shape? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return shape(width: width, height: height, orientation: properties[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    /// Shared by header-only cycling and strictly decoded pack assets.
    public static func shape(width: Int, height: Int, orientation: Int) -> WallpaperCycle.Shape {
        let turned = (5...8).contains(orientation)
        return (turned ? height >= width : width >= height) ? .landscape : .portrait
    }
}
