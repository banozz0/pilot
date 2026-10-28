import AppKit
import ImageIO
import PilotCore
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Pilot

/// Thumbnails in file rows (Homy-style Files T3, check 5), drawn offscreen: a png row wears its picture once it is
/// made, a folder row keeps Finder's icon. A fake maker reads the png with ImageIO in place of QuickLook's service.
/// PILOT_RENDER_DIR keeps the PNGs.
extension SharedLook {
@MainActor
@Suite("File thumbnail renders")
struct FileThumbnailRenders {
    /// The png's pixels, at most `pixels` a side, as QuickLook would make them.
    static let fake: FileThumbnails.Make = { url, pixels in
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                               kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary)
    }

    /// A pure green png `width` by `height`, a colour no file icon or theme draws.
    static func png(_ url: URL, width: Int = 64, height: Int = 32) throws {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    static func render(_ rows: [MenuEntry], _ name: String) throws -> NSBitmapImageRep {
        var nav = MenuNavigator(entries: [])
        nav.query = "shot"
        // Tab to the Files view, as Search files opens it.
        while nav.only != .file { _ = nav.handle(.tab) }
        nav.provide(.file, rows)
        let panel = HUD.makePanel(MenuView(model: MenuModel(nav: nav)), surface: .menu)
        defer { panel.close() }
        let content = try #require(panel.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        content.layoutSubtreeIfNeeded()
        let rep = try #require(snapshot(content, scale: 2))
        if let dir = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "file-thumbnail-\(name).png"))
        }
        return rep
    }

    /// Pixels drawn green, the png's colour.
    static func green(_ rep: NSBitmapImageRep, from left: Int = 0) -> Int {
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: left, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.greenComponent > 0.8, c.redComponent < 0.4, c.blueComponent < 0.4 { count += 1 }
            }
        }
        return count
    }

    @Test("A png row draws its icon, then its thumbnail; a folder row keeps Finder's icon")
    func rows() async throws {
        testApp()
        let thumbnails = FileThumbnails.shared
        thumbnails.clear()
        thumbnails.make = Self.fake
        defer { thumbnails.clear(); thumbnails.make = FileThumbnails.quickLook }
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-thumbnails-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "Screenshots"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shot = dir.appending(path: "Screenshot 14.png")
        try Self.png(shot)
        let png = MenuEntry(title: "Screenshot 14.png", target: .file(shot.path), detail: "~/Desktop · today")
        let folder = MenuEntry(title: "Screenshots", target: .file(dir.appending(path: "Screenshots").path), detail: "~/Pictures")
        #expect(FileThumbnails.shows(shot.path) && !FileThumbnails.shows(folder.target.filePath!))
        #expect(FileThumbnails.shows("/a.pdf") && FileThumbnails.shows("/a.mov") && !FileThumbnails.shows("/a.md"))

        #expect(Self.green(try Self.render([folder], "folder")) == 0, "a folder never asks for a thumbnail")
        #expect(thumbnails.count == 0)
        #expect(Self.green(try Self.render([png], "icon")) == 0, "the icon draws first")
        let deadline = Date().addingTimeInterval(3)
        while thumbnails.count == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(thumbnails.count == 1, "only the png's thumbnail is made")
        #expect(Self.green(try Self.render([png], "thumbnail")) > 20, "the png's row wears its picture")
    }

    @Test("The cache never holds over 48, oldest out first, and clear empties it")
    func cap() throws {
        let thumbnails = FileThumbnails.shared
        thumbnails.clear()
        defer { thumbnails.clear() }
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        for i in 0..<60 {
            thumbnails.keep("/shot-\(i).png", image)
            #expect(thumbnails.count <= FileThumbnails.limit)
        }
        #expect(thumbnails.count == 48)
        #expect(thumbnails.image("/shot-59.png") != nil, "the newest stays")
        thumbnails.clear()
        #expect(thumbnails.count == 0)
    }
}
}
