import AppKit
import CryptoKit
import Foundation
import ImageScale
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Resize and Upscale (Q246-Q248): Finder's two services, the editor's colour picker and Image size chip, the upscaler's
/// lines.
@MainActor
@Suite("Image tools")
struct ImageToolsTests {
    /// A capture half one colour, half another, at 2x.
    static func capture(_ left: UInt32 = 0x3366CC, _ right: UInt32 = 0xF0443A) -> CGImage {
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (rgb, x) in [(left, 0), (right, 200)] {
            ctx.setFillColor(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
            ctx.fill(CGRect(x: x, y: 0, width: 200, height: 200))
        }
        return ctx.makeImage()!
    }

    @Test("Info.plist offers Resize with Pilot and Upscale with Pilot on images only, after the services before them")
    func plist() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Info.plist")
        let services = try #require((NSDictionary(contentsOf: url) as? [String: Any])?["NSServices"] as? [[String: Any]])
        #expect(services.first?["NSMessage"] as? String == "convertFiles")
        for (message, title) in [("resizeImages", "Resize with Pilot"), ("upscaleImages", "Upscale with Pilot")] {
            let service = try #require(services.first { $0["NSMessage"] as? String == message })
            #expect((service["NSMenuItem"] as? [String: String])?["default"] == title)
            #expect(service["NSPortName"] as? String == "Pilot")
            #expect(service["NSSendFileTypes"] as? [String] == ["public.image"])
            #expect(service["NSSendTypes"] == nil && service["NSReturnTypes"] == nil)
            #expect(PilotServices.instancesRespond(to: NSSelectorFromString("\(message):userData:error:")))
        }
    }

    @Test("The services hand Finder's files to the panel in their mode; none says so")
    func services() {
        var got: [(ImageTools.Mode, [URL])] = []
        let service = PilotServices(images: { got.append(($0, $1)) })
        let board = NSPasteboard(name: NSPasteboard.Name("pilot-image-tools-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([URL(filePath: "/x/a.png") as NSURL])
        var error: NSString?
        service.resizeImages(board, userData: nil, error: &error)
        service.upscaleImages(board, userData: nil, error: &error)
        #expect(got.map(\.0) == [.resize, .upscale])
        #expect(got.allSatisfy { $0.1 == [URL(filePath: "/x/a.png")] })
        #expect(error == nil)
        board.clearContents()
        board.setString("hello", forType: .string)
        service.upscaleImages(board, userData: nil, error: &error)
        #expect(got.count == 2 && error == "No images")
    }

    @Test("The panel opens on the images among the files, and says so when there are none")
    func offer() throws {
        ImageTools.onScreen = false
        defer { ImageTools.close(); ImageTools.onScreen = true }
        let dir = FileManager.default.temporaryDirectory.appending(path: "image-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "shot.png")
        try #require(ImageFormat.png.encode(Self.capture())).write(to: png)
        var said: [String] = []
        ImageTools.offer(.resize, [dir.appending(path: "notes.txt")]) { said.append($0) }
        #expect(said == ["Pilot cannot read that image"] && ImageTools.shown == nil)
        ImageTools.offer(.resize, [dir.appending(path: "notes.txt"), png]) { said.append($0) }
        let card = try #require(ImageTools.shown)
        #expect(card.mode == .resize && card.files == [png])
        #expect(card.target.originalWidth == 400 && card.target.originalHeight == 200)
    }

    @Test("The colour picker takes a pixel's colour for every coloured tool, copies its hex, and goes back to the tool")
    func eyedropper() {
        let model = EditorModel(image: Self.capture(), scale: 2, accent: 0x3CD2DB, dark: true)
        var copied: [String] = []
        model.copyColour = { copied.append($0) }
        model.pick(.arrow)
        #expect(MarkTool.picked(by: "i") == .eyedropper)
        #expect(model.key(.char("i")))
        #expect(model.tool == .eyedropper)
        model.loadGridNow()
        model.hover(CGPoint(x: 150, y: 50))
        #expect(model.sampled == 0xF0443A)
        model.begin(CGPoint(x: 20, y: 20)); model.end(CGPoint(x: 20, y: 20))
        #expect(copied == ["#3366CC"])
        #expect(model.palette.count == 7 && model.pickedColour == 0x3366CC)
        #expect(model.tool == .arrow && model.colour == 0x3366CC)
        #expect(model.colourIndex(of: .pen) == 6)
        #expect(model.document.marks.isEmpty)
        // A second pick replaces the seventh swatch, never adds an eighth.
        model.pick(.eyedropper)
        model.begin(CGPoint(x: 180, y: 20)); model.end(CGPoint(x: 180, y: 20))
        #expect(model.palette.count == 7 && model.pickedColour == 0xF0443A && copied.last == "#F0443A")
    }

    @Test("The colour picker's loupe follows the pointer over the capture with its pixels round it; Esc leaves the picker")
    func loupe() {
        let model = EditorModel(image: Self.capture(), scale: 2, accent: 0x3CD2DB, dark: true)
        model.pick(.pen)
        model.pick(.eyedropper)
        model.loadGridNow()
        #expect(model.loupeAt == nil)
        // The capture is 200 points wide, blue on its left half, red on its right: the loupe straddles the line.
        model.hover(CGPoint(x: 100, y: 50))
        #expect(model.loupeAt == CGPoint(x: 100, y: 50) && model.sampled == 0xF0443A)
        let cells = model.pixels(around: CGPoint(x: 100, y: 50), side: ColourLoupe.side)
        #expect(cells.count == 121 && cells[60] == 0xF0443A && cells[59] == 0x3366CC, "the centre is the pixel sampled, its left neighbour blue")
        let corner = model.pixels(around: .zero, side: ColourLoupe.side)
        #expect(corner[0] == nil && corner[60] == 0x3366CC, "off the capture is empty")
        model.hover(CGPoint(x: 500, y: 50))
        #expect(model.loupeAt == nil, "off the capture the pointer shows again")
        model.hover(CGPoint(x: 20, y: 20))
        #expect(model.key(.escape))
        #expect(model.tool == .pen && model.loupeAt == nil && !model.discardArmed, "Esc goes back to the tool, the editor stays")
    }

    @Test("Upscale's size opens on the image's: the preset picked last stays, a typed one goes back to 4x")
    func upscaleSize() {
        let job = UpscaleJob()
        job.size(width: 1280, height: 720)
        #expect(job.target.width == 5120 && UpscaleOptions.runs(job))
        job.target.setFactor(2)
        job.size(width: 400, height: 200)
        #expect(job.target.width == 800 && job.target.height == 400)
        job.target.setWidth(1000)
        job.size(width: 1280, height: 720)
        #expect(job.target.times == 4)
        job.target.setWidth(1)
        #expect(!UpscaleOptions.runs(job), "nothing to run at the image's own size")
    }

    @Test("The Image size chip's resize changes the export's pixels, not the capture's; Original size takes it back")
    func resize() async throws {
        let model = EditorModel(image: Self.capture(), scale: 2, accent: 0x3CD2DB, dark: true)
        #expect(model.exportSize == CGSize(width: 400, height: 200))
        var target = model.resizeTarget
        #expect(target.locked && target.width == 400)
        target.setPercent(50)
        model.resize(to: target)
        #expect(model.exportSize == CGSize(width: 200, height: 100))
        #expect(model.size == CGSize(width: 200, height: 100))
        let out = try #require(await model.export())
        #expect(out.width == 200 && out.height == 100)
        // Reopened, the popover shows the new size, still locked.
        #expect(model.resizeTarget.width == 200 && model.resizeTarget.locked)
        model.resize(to: nil)
        #expect(model.resized == nil)
        let same = try #require(await model.export())
        #expect(same === model.image)
    }

    @Test("The upscaler's lines: progress as tiles done of all, and the file it wrote")
    func helperLines() {
        #expect(UpscaleJob.progress("progress 3 45")! == (3, 45))
        #expect(UpscaleJob.progress("progress 3 0") == nil)
        #expect(UpscaleJob.progress("wrote /a") == nil)
        #expect(UpscaleJob.written("progress 1 1\nwrote /a/shot 4x.png\n") == URL(filePath: "/a/shot 4x.png"))
    }

    @Test("General ships in the bundle, so a test run has neither it nor the helper; Max quality's download is pinned")
    func models() throws {
        #expect(UpscaleModels.compiled(.general) == nil)
        #expect(throws: UpscaleModels.Failure.self) { try UpscaleModels.helper() }
        #expect(UpscaleModel.general.compiledName == "realesr-general-x4v3.mlmodelc")
        let d = try #require(UpscaleModel.max.download)
        #expect(d.url.absoluteString.contains("/resolve/da0d01ce79946e6a62563eaf900ff9844af1f67f/"))
        #expect(d.sha256.count == 64 && d.bytes > 30_000_000)
        #expect(UpscaleModel.general.download == nil)
    }

    @Test("The download's check hashes the whole file, a chunk at a time")
    func sha256() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "sha-\(UUID().uuidString)")
        try Data(repeating: 0x61, count: 3 << 20).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let hex = try await UpscaleModels.sha256(url)
        #expect(hex == SHA256.hash(data: Data(repeating: 0x61, count: 3 << 20)).map { String(format: "%02x", $0) }.joined())
    }
}

#if DEBUG
extension SharedLook {
/// Finder's panel and the editor's two popovers, Instrument and Toybox, dark and light, offscreen. Opt-in, in a moved
/// home: `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter ImageToolsRenders`
@MainActor
@Suite("Image tools renders")
struct ImageToolsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The resize and upscale panels render in every style at their own size",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("image-tools")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = [URL(filePath: "/Users/ada/Pictures/Pilot/Capture 2026-10-17 at 12.04.11.png")]
        let job = UpscaleJob()
        job.size(width: 3440, height: 1440)
        let maxJob = UpscaleJob()
        maxJob.model = .max
        maxJob.size(width: 3440, height: 1440)
        maxJob.target.setWidth(5000)
        var target = ResizeTarget(width: 3440, height: 1440)
        target.setWidth(1920)
        let cards: [(String, ImageToolCard)] = [
            ("resize", ImageToolCard(mode: .resize, files: files, target: target, job: job, resize: { _ in }, upscale: {}, cancel: {})),
            ("upscale", ImageToolCard(mode: .upscale, files: files, target: target, job: job, resize: { _ in }, upscale: {}, cancel: {})),
            ("upscale-max", ImageToolCard(mode: .upscale, files: files + files, target: target, job: maxJob, resize: { _ in }, upscale: {}, cancel: {})),
        ]
        for pass in CaptureEditorRenders.passes {
            look.style = pass.style
            look.themeID = pass.theme
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            for (name, card) in cards {
                let size = NSHostingView(rootView: card.style(tokens)).fittingSize
                #expect(size.width <= 360 && size.height <= 420, "\(name) \(pass.tag): \(size)")
                let rep = try CaptureEditorRenders.draw(card, tokens: tokens, size: size, scale: 2)
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name)-\(pass.tag).png"))
            }
        }
    }
}
}
#endif
