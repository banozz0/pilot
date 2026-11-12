#if DEBUG
import AppKit
import Foundation
import ImageIO
import PilotCore
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Pilot

/// Pilot's image viewer (Q158), opt-in like the other renders. First the files, in a temporary folder, never Sven's:
/// a 3000 × 2000 JPEG, the same turned by EXIF orientation 6, a PNG, a two-frame GIF and a text file, opened through the
/// route a Finder open takes (ImageViewer.show, never on screen): the folder's pictures listed in name order, the picture
/// read no larger than the screen, turned upright, the GIF's frames counted; then mark-up's Done on the JPEG answered
/// Replace (JPEG bytes written back, never PNG), on the PNG answered Save a Copy (a copy beside it, the PNG untouched) and
/// Cancel (nothing written). Then the window in Instrument under Tokyo Night (dark) and Folio (light): fitted, at 100 %,
/// after a Trash with Undo, and the portrait photo.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter ImageViewerRenders`
extension SharedLook {
@MainActor
@Suite("Image viewer renders")
struct ImageViewerRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let passes: [(theme: String, tag: String)] = [("tokyo-night", "instrument-dark"), ("folio", "instrument-light")]

    @Test("Pictures open upright at screen size, mark-up never writes PNG into a JPEG, and the viewer renders dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("image-viewer")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-viewer-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        ImageViewer.onScreen = false
        CaptureEditor.onScreen = false
        defer { ImageViewer.closeAll(); CaptureEditor.closeAll() }

        let photo = try #require(Self.photo(width: 3000, height: 2000))
        let beach = folder.appending(path: "beach.jpg"), turned = folder.appending(path: "portrait.jpg")
        let png = folder.appending(path: "screen.png"), gif = folder.appending(path: "wave.gif")
        try Self.write(photo, to: beach, type: .jpeg, exif: [kCGImagePropertyExifDateTimeOriginal: "2026:08:14 19:42:07"])
        try Self.write(photo, to: turned, type: .jpeg, orientation: 6)
        try Self.write(try #require(Self.photo(width: 1200, height: 800)), to: png, type: .png)
        try Self.writeGIF([try #require(Self.photo(width: 120, height: 80)), try #require(Self.photo(width: 120, height: 80, sun: 0.7))], to: gif)
        try Data("not a picture".utf8).write(to: folder.appending(path: "notes.txt"))

        // The folder's pictures by name, the text file left out; the picture no larger than the screen.
        #expect(ViewerImages.siblings(of: beach).map(\.lastPathComponent) == ["beach.jpg", "portrait.jpg", "screen.png", "wave.gif"])
        #expect(!ViewerImages.viewable(folder.appending(path: "notes.txt")) && ImageViewer.show(folder.appending(path: "notes.txt")) == nil)
        let model = try #require(ImageViewer.show(beach))
        try await Self.settle(model)
        #expect(model.index == 0 && model.files.count == 4)
        #expect(model.pixels == CGSize(width: 3000, height: 2000))
        let shown = try #require(model.image)
        #expect(max(shown.width, shown.height) <= model.longest && max(shown.width, shown.height) <= 3000)
        // Orientation 6: upright, so the 3000 × 2000 pixels read 2000 × 3000.
        let portrait = try #require(ViewerImages.decode(turned, longest: 600))
        #expect(portrait.pixels == CGSize(width: 2000, height: 3000) && portrait.image.height > portrait.image.width && portrait.image.height == 600)
        let frames = try #require(ViewerImages.decode(gif, longest: nil))
        #expect(frames.frames == 2 && !ViewerImages.replaceable(gif))
        #expect(ViewerImages.replaceable(beach) && ViewerImages.replaceable(png))
        // An iPhone's name: an uppercase HEIC, in a folder of its own.
        let phone = folder.appending(path: "phone")
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
        let heic = phone.appending(path: "IMG_0001.HEIC")
        try Self.write(try #require(Self.photo(width: 400, height: 300)), to: heic, type: .heic)
        #expect(ViewerImages.viewable(heic) && ViewerImages.siblings(of: heic) == [heic] && ViewerImages.decode(heic, longest: nil)?.pixels == CGSize(width: 400, height: 300))

        try await Self.markUps(beach: beach, png: png)
        // The copy mark-up saved (and the test removed) went into the viewer's list and out again.
        model.relist(reload: false)
        await model.settled()
        #expect(model.files.count == 4)

        for pass in Self.passes {
            let look = Look.shared
            let saved = (look.style, look.themeID, look.glass)
            defer { (look.style, look.themeID, look.glass) = saved }
            look.style = .instrument
            look.themeID = pass.theme
            look.glass = false
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            let size = CGSize(width: 1200, height: 800)
            @discardableResult func write(_ name: String) throws -> NSBitmapImageRep {
                let rep = try CaptureEditorRenders.draw(ImageViewerView(model: model), tokens: tokens, size: size, scale: 2)
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("viewer-\(name)-\(pass.tag).png"))
                return rep
            }
            // A point in the room left of the portrait, inside the landscape picture: the ground after a step from one to
            // the other (Q161: the picture before stayed under the next, and the desktop showed through the ground).
            let ground = tokens.colors.canvas.rgb
            func isGround(_ rep: NSBitmapImageRep) throws -> Bool {
                let c = try #require(rep.colorAt(x: 480, y: 800)?.usingColorSpace(.sRGB))
                let want = [CGFloat((ground >> 16) & 0xFF), CGFloat((ground >> 8) & 0xFF), CGFloat(ground & 0xFF)].map { $0 / 255 }
                return c.alphaComponent > 0.99 && abs(c.redComponent - want[0]) < 0.03 && abs(c.greenComponent - want[1]) < 0.03
                    && abs(c.blueComponent - want[2]) < 0.03
            }
            while model.index != 0 { model.step(1); try await Self.settle(model) }
            model.fitToWindow()
            #expect(try !isGround(write("1-fit")), "the landscape picture should cover the probe point")
            model.zoom(to: 1)
            try await Task.sleep(for: .milliseconds(400))
            try write("2-actual-size")
            model.fitToWindow()
            model.say("Moved beach.jpg to the Trash", undo: true)
            try write("3-trashed")
            model.step(1)
            try await Self.settle(model)
            #expect(model.file.lastPathComponent == "portrait.jpg" && model.pixels == CGSize(width: 2000, height: 3000))
            #expect(try isGround(write("4-portrait")), "after the step the ground beside the portrait is not the solid theme ground")
        }

        // Q161: one open of several pictures is ONE window stepping through just those, in Finder's name order.
        ImageViewer.closeAll()
        // Through the route a Finder open of three picked pictures takes: AppDelegate's application(_:open:).
        AppDelegate().application(NSApplication.shared, open: [png, beach, gif])
        let t0 = Date()
        let batch = try #require(ImageViewer.model(showing: png))
        await batch.settled()
        #expect(ImageViewer.openCount == 1)
        #expect(batch.files.map(\.lastPathComponent) == ["beach.jpg", "screen.png", "wave.gif"], "\(batch.files.map(\.lastPathComponent))")
        #expect(batch.file.lastPathComponent == "screen.png" && batch.index == 1)
        var seen = [batch.file.lastPathComponent]
        for _ in 0..<3 { batch.step(1); await batch.settled(); seen.append(batch.file.lastPathComponent) }
        #expect(seen == ["screen.png", "wave.gif", "beach.jpg", "screen.png"])
        // The same open handed over in parts joins that window; a later open of a picture not shown gets its own.
        let joined = try #require(ImageViewer.show([turned], now: t0.addingTimeInterval(0.2)))
        await joined.settled()
        #expect(joined === batch && ImageViewer.openCount == 1 && batch.files.count == 4)
        let later = try #require(ImageViewer.show([heic], now: t0.addingTimeInterval(5)))
        await later.settled()
        #expect(later !== batch && ImageViewer.openCount == 2 && later.files == [heic])
        // A picture already shown, opened again on its own: that window comes forward, no new one.
        #expect(ImageViewer.show([heic], now: t0.addingTimeInterval(10)) === later && ImageViewer.openCount == 2)
        ImageViewer.closeAll()
    }

    /// Mark-up's Done on a picture the viewer opened, each answer to its question.
    static func markUps(beach: URL, png: URL) async throws {
        let capture = PilotCapture.shared
        let saved = (capture.pasteboard, capture.tell, CaptureEditor.askSave)
        defer { (capture.pasteboard, capture.tell, CaptureEditor.askSave) = saved }
        capture.pasteboard = NSPasteboard(name: .init("pilot-viewer-test-\(UUID().uuidString)"))
        var told: [String] = []
        capture.tell = { text, _ in told.append(text) }
        func edit(_ file: URL) async throws -> EditorModel {
            #expect(await ImageViewer.markUp(file))
            let editor = try #require(CaptureEditor.model(file: file))
            editor.pick(.rect)
            editor.begin(CGPoint(x: 100, y: 100)); editor.end(CGPoint(x: 400, y: 300))
            return editor
        }
        func waitTold(_ count: Int) async throws {
            for _ in 0..<200 where told.count < count { try await Task.sleep(for: .milliseconds(25)) }
            try #require(told.count >= count, "nothing was told: \(told)")
        }

        // Replace on the JPEG, framed by a see-through backdrop: written back as JPEG in place, the see-through corners white
        // (ImageIO's JPEG writer puts them on white), the date it was taken kept.
        CaptureEditor.askSave = { _, replaceable in #expect(replaceable); return .replace }
        let framed = try await edit(beach)
        framed.setBackdrop(Backdrop(fill: .clear, pad: 48, radius: 24, shadow: 0))
        framed.finish(.done)
        try await waitTold(1)
        let bytes = try Data(contentsOf: beach)
        #expect(Array(bytes.prefix(3)) == [0xFF, 0xD8, 0xFF], "the JPEG holds \(Array(bytes.prefix(8)))")
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let exif = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:08:14 19:42:07")
        let corner = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rep = NSBitmapImageRep(cgImage: corner)
        let c = try #require(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        #expect(c.redComponent > 0.9 && c.greenComponent > 0.9 && c.blueComponent > 0.9, "the see-through corner came out \(c)")
        #expect(told.last == "Copied, and saved over beach.jpg")
        #expect(!CaptureEditor.isOpen(file: beach))

        // Cancel: the editor stays and nothing is written.
        let before = try Data(contentsOf: png)
        CaptureEditor.askSave = { _, _ in .cancel }
        let cancelled = try await edit(png)
        cancelled.finish(.done)
        try await Task.sleep(for: .milliseconds(300))
        let unchanged = try Data(contentsOf: png) == before
        #expect(CaptureEditor.isOpen(file: png) && unchanged)

        // Save a Copy, the default: a copy beside it, the PNG as it was, nothing in the capture history.
        CaptureEditor.askSave = { _, _ in .copy }
        cancelled.finish(.done)
        try await waitTold(2)
        let copy = png.deletingLastPathComponent().appending(path: "screen edited.png")
        let kept = try Data(contentsOf: png) == before
        #expect(FileManager.default.fileExists(atPath: copy.path) && kept)
        #expect(told.last == "Copied, and saved as screen edited.png")
        #expect(await !CaptureHistoryStore.shared.entries().contains { $0.url.standardizedFileURL == copy.standardizedFileURL })
        try FileManager.default.removeItem(at: copy)
    }

    /// Waits for the viewer's folder and picture.
    static func settle(_ model: ImageViewerModel) async throws {
        await model.settled()
        try #require(model.image != nil, "the picture was never read: \(model.problem ?? "no problem said")")
    }

    /// A made-up landscape: a dusk sky, a sun at `sun` of the width, two hills.
    static func photo(width: Int, height: Int, sun: CGFloat = 0.32) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let sky = CGGradient(colorsSpace: nil, colors: [CGColor(srgbRed: 0.98, green: 0.62, blue: 0.40, alpha: 1), CGColor(srgbRed: 0.36, green: 0.30, blue: 0.62, alpha: 1)] as CFArray,
                             locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.88, blue: 0.62, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w * sun - h * 0.09, y: h * 0.42, width: h * 0.18, height: h * 0.18))
        for (k, colour) in [(0.42, CGColor(srgbRed: 0.20, green: 0.24, blue: 0.40, alpha: 1)), (0.28, CGColor(srgbRed: 0.12, green: 0.14, blue: 0.26, alpha: 1))] {
            let hill = CGMutablePath()
            hill.move(to: .zero)
            hill.addCurve(to: CGPoint(x: w, y: h * k * 0.7), control1: CGPoint(x: w * 0.3, y: h * k * 1.6), control2: CGPoint(x: w * 0.6, y: h * k * 0.2))
            hill.addLine(to: CGPoint(x: w, y: 0))
            hill.closeSubpath()
            ctx.setFillColor(colour)
            ctx.addPath(hill)
            ctx.fillPath()
        }
        return ctx.makeImage()
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, orientation: Int = 1, exif: [CFString: Any]? = nil) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72]
        props[kCGImagePropertyExifDictionary] = exif
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        try #require(CGImageDestinationFinalize(dest))
    }

    static func writeGIF(_ frames: [CGImage], to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil))
        for frame in frames {
            CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(dest))
    }
}
}
#endif
