#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Pilot's folder designs (P54) as Pilot loads them, through `FolderDesigns.art` into NSImage: each at 16, 32, 128 and
/// 512 px on Finder's light and dark grounds, one sheet of all thirteen (the twelve and plain) per ground, two folders in
/// the moved home dressed and their icons read back as Finder reads them, plain with a picture in its front, and Files ›
/// Folders' Design grid in Lagoon (dark) and Porcelain (light). Opt-in like the other renders:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> PILOT_RESOURCES=Packaging swift test --filter FolderDesignsRenders`
extension SharedLook {
@MainActor
@Suite("Folder designs renders")
struct FolderDesignsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let sizes = [16, 32, 128, 512]
    static let grounds: [(String, NSColor)] = [("light", NSColor(white: 1, alpha: 1)), ("dark", NSColor(white: 0.118, alpha: 1))]

    /// `images` side by side on `ground`, each at its size in pixels, bottoms aligned, 1x.
    static func strip(_ images: [(NSImage, Int)], ground: NSColor, gap: Int = 24) throws -> NSBitmapImageRep {
        let width = images.reduce(gap) { $0 + $1.1 + gap }, height = (images.map(\.1).max() ?? 0) + gap * 2
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        context.imageInterpolation = .high
        NSGraphicsContext.current = context
        ground.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var x = gap
        for (image, side) in images {
            image.draw(in: NSRect(x: x, y: gap, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
            x += side + gap
        }
        return rep
    }

    @Test("Each folder design at 16, 32, 128 and 512 px on light and dark, and the Design grid",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_RESOURCES"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == URL(fileURLWithPath: home).resolvingSymlinksInPath(), "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("folder-designs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ids = FolderDesign.all.map(\.id) + [FolderDesign.plain]
        let art = try ids.map { id in (id, try #require(FolderDesigns.art(id), "\(id) did not load")) }

        for (ground, colour) in Self.grounds {
            for (id, image) in art {
                let rep = try Self.strip(Self.sizes.map { (image, $0) }, ground: colour)
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(id)-\(ground).png"))
            }
            // All thirteen at 128 over their 16 and 32: the set as a whole, and how it reads small.
            let big = try Self.strip(art.map { ($0.1, 128) }, ground: colour)
            let small = try Self.strip(art.flatMap { [($0.1, 16), ($0.1, 32)] }, ground: colour, gap: 20)
            for (name, rep) in [("sheet-\(ground)-128", big), ("sheet-\(ground)-small", small)] {
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
            }
        }

        // Through Finder's path: a folder in the moved home dressed as Pilot dresses one, its icon read back as Finder
        // reads it, so the 32 px small drawing is shown surviving NSWorkspace.setIcon (or not).
        let dressed = URL(fileURLWithPath: home).appending(path: "Dressed", directoryHint: .isDirectory)
        for id in ["terminal", "paper"] {
            let folder = dressed.appending(path: id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FolderDesigns.looks.apply(try #require(FolderDesigns.art(id)), design: id, to: folder)
            defer { _ = try? FolderDesigns.looks.reset(folder) }
            let icon = NSWorkspace.shared.icon(forFile: folder.path)
            for (ground, colour) in Self.grounds {
                let rep = try Self.strip(Self.sizes.map { (icon, $0) }, ground: colour)
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("dressed-\(id)-\(ground).png"))
            }
        }

        // Plain with a picture of your own (any picture that is not cut out) fitted into its front, as `icon` fits it.
        let photo = try #require(FolderDesigns.picture(dir.appendingPathComponent("sheet-light-128.png")))
        for (ground, colour) in Self.grounds {
            let rep = try Self.strip([(photo, 128), (photo, 512)], ground: colour)
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("plain-picture-\(ground).png"))
        }

        // Files › Folders with no folders added: the Design grid as the page shows it.
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.style = .instrument
        for theme in ["lagoon", "porcelain"] where PilotTheme.named(theme) != nil {
            look.themeID = theme
            let view = FolderDesignsView().frame(width: 900, height: 760).background(Theme.background).styled(.page(.files)).pilotTheme(look: look)
            try writeRender(view, to: dir.appendingPathComponent("grid-\(theme).png"))
        }
    }
}

}
#endif
