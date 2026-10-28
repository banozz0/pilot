import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PilotCore

/// Card agent-bo-95423316 (story 146): the cycle on a fresh temp folder of tiny images, and a themes.json from before the
/// package's folder.
@Suite("Wallpaper cycle")
struct WallpaperCycleTests {
    /// A fresh folder: wide a.png and c.png at the top, tall b.png and wide d.png in a subfolder, a note and a hidden image.
    static func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "pilot-wallpapers-\(UUID().uuidString)")
        let sub = root.appending(path: "1440p-ultrawide")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try image(root.appending(path: "c.png"), 4, 2)
        try image(root.appending(path: "a.png"), 4, 2)
        try image(sub.appending(path: "b.png"), 2, 4)
        try image(sub.appending(path: "d.png"), 4, 2)
        try image(root.appending(path: ".hidden.png"), 4, 2)
        try Data("not an image".utf8).write(to: root.appending(path: "notes.txt"))
        return root
    }

    static func image(_ url: URL, _ width: Int, _ height: Int) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    static func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    @Test("Image files in the folder and below, by file name; hidden files and other files left out; shapes from the header")
    func lists() throws {
        let images = WallpaperCycle.images(in: try Self.folder())
        #expect(Self.names(images) == ["a.png", "b.png", "c.png", "d.png"])
        let shapes = ImageShapes()
        #expect(images.map(shapes.shape) == [.landscape, .portrait, .landscape, .landscape])
        #expect(WallpaperCycle.images(in: URL(filePath: "/nonexistent-pilot-folder")).isEmpty)
    }

    @Test("A wide screen steps through the wide images only, wrapping at both ends")
    func wideWraps() throws {
        let images = WallpaperCycle.images(in: try Self.folder()), shapes = ImageShapes()
        func step(_ current: String?, _ forward: Bool) -> String? {
            WallpaperCycle.step(images, shape: shapes.shape, screen: .landscape, current: current.flatMap { name in images.first { $0.lastPathComponent == name } },
                                forward: forward).map { "\($0.url.lastPathComponent) \($0.place)/\($0.count)" }
        }
        #expect(step("a.png", true) == "c.png 2/3")
        #expect(step("d.png", true) == "a.png 1/3", "the end wraps to the start")
        #expect(step("a.png", false) == "d.png 3/3", "the start wraps to the end")
        #expect(step("b.png", true) == "a.png 1/3", "an image not of this shape counts as unknown")
        #expect(step(nil, true) == "a.png 1/3")
        #expect(step(nil, false) == "d.png 3/3")
    }

    @Test("A screen no image fits gets all of them; a lone fit stays put; no images is nil")
    func fallbacks() throws {
        let images = WallpaperCycle.images(in: try Self.folder())
        let allWide: (URL) -> WallpaperCycle.Shape? = { _ in .landscape }
        let all = WallpaperCycle.step(images, shape: allWide, screen: .portrait, current: images[3], forward: true)
        #expect(all.map { "\($0.url.lastPathComponent) \($0.place)/\($0.count)" } == "a.png 1/4")
        let lone = WallpaperCycle.step(images, shape: ImageShapes().shape, screen: .portrait, current: images[1], forward: true)
        #expect(lone.map { "\($0.url.lastPathComponent) \($0.place)/\($0.count)" } == "b.png 1/1")
        #expect(WallpaperCycle.step([], shape: allWide, screen: .landscape, current: nil, forward: true) == nil)
    }
}

/// Story 160: Look › Wallpaper's picked folders and images, the shuffle and a screen's place in the cycle.
@Suite("Wallpaper sources")
struct WallpaperSourcesTests {
    @Test("Folders and single images together, by name, each once; a missing image or a note is left out")
    func sources() throws {
        let folder = try WallpaperCycleTests.folder()
        let other = FileManager.default.temporaryDirectory.appending(path: "pilot-wallpapers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try WallpaperCycleTests.image(other.appending(path: "b2.png"), 4, 2)
        let images = WallpaperCycle.images(in: [folder, other.appending(path: "b2.png"), folder.appending(path: "a.png"),
                                                other.appending(path: "gone.png"), folder.appending(path: "notes.txt")])
        #expect(WallpaperCycleTests.names(images) == ["a.png", "b.png", "b2.png", "c.png", "d.png"])
        #expect(WallpaperCycle.images(in: [URL]()).isEmpty)
    }

    @Test("Shuffle keeps every image, gives one seed the same order every time and another seed another order")
    func shuffle() throws {
        let images = WallpaperCycle.images(in: try WallpaperCycleTests.folder())
        #expect(WallpaperCycle.ordered(images, order: .name, seed: 7) == images)
        let one = WallpaperCycle.ordered(images, order: .shuffle, seed: 7)
        #expect(Set(one) == Set(images) && one.count == images.count)
        #expect(WallpaperCycle.ordered(images, order: .shuffle, seed: 7) == one)
        let orders = Set((1...8).map { WallpaperCycle.ordered(images, order: .shuffle, seed: UInt64($0)).map(\.lastPathComponent) })
        #expect(orders.count > 1, "eight seeds gave one order")
    }

    @Test("A screen's image has its place among its shape's; one outside the cycle has none")
    func place() throws {
        let images = WallpaperCycle.images(in: try WallpaperCycleTests.folder()), shapes = ImageShapes()
        let c = images.first { $0.lastPathComponent == "c.png" }
        #expect(WallpaperCycle.place(of: c, in: images, shape: shapes.shape, screen: .landscape).map { "\($0.place)/\($0.count)" } == "2/3")
        #expect(WallpaperCycle.place(of: URL(filePath: "/elsewhere.png"), in: images, shape: shapes.shape, screen: .landscape) == nil)
        #expect(WallpaperCycle.place(of: nil, in: images, shape: shapes.shape, screen: .portrait) == nil)
    }

    /// Live bug (Sven 2026-10-10): macOS's read of a screen's wallpaper trails a set by up to half a second, so the
    /// Wallpaper rows read just after a step showed the picture before, and a second Next inside that time picked the
    /// same image again ("9/22" twice in the log).
    @Test("A screen's wallpaper is the one Pilot set while macOS still reads one it replaced; any other read wins")
    func settled() {
        let a = URL(filePath: "/w/a.png"), b = URL(filePath: "/w/b.png"), c = URL(filePath: "/w/c.png"), x = URL(filePath: "/x.png")
        var set = SetWallpapers()
        #expect(set.current(on: 1, read: a) == a, "nothing set: macOS's read")
        set.record(b, replacing: a, on: 1)
        #expect(set.current(on: 1, read: a) == b, "the read still trails the set")
        #expect(set.current(on: 2, read: a) == a, "another screen is its own")
        set.record(c, replacing: b, on: 1)
        #expect(set.current(on: 1, read: a) == c, "two quick steps: either image replaced reads as the last set")
        #expect(set.current(on: 1, read: b) == c)
        #expect(set.current(on: 1, read: c) == c, "macOS caught up")
        #expect(set.current(on: 1, read: a) == a, "caught up once, a later read is macOS's own")
        set.record(b, replacing: a, on: 1)
        #expect(set.current(on: 1, read: x) == x, "set elsewhere (System Settings): macOS's read wins")
        #expect(set.current(on: 1, read: a) == a)
    }

    @Test("Intervals read as words")
    func intervals() {
        #expect(WallpaperCycle.intervals.map(WallpaperCycle.intervalName)
                == ["Never", "Every 15 minutes", "Every 30 minutes", "Every hour", "Every 3 hours", "Every day"])
    }
}
