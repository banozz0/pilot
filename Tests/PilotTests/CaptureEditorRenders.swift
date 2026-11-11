#if DEBUG
import AppKit
import Clipboard
import Foundation
import ImageScale
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The capture editor in B (Sven, Q805; editors-round-2's 21 parity rows): the real CaptureEditorView over the designer's
/// made-up billing page, in every state Sven leaves it in, plus the smallest window and the two popovers' panels (a
/// popover is a window of its own, which a snapshot never draws), in Instrument (Tokyo Night, Folio) and Toybox
/// (toybox-night, toybox). The window keeps one size whatever the state, the backdrop panel's column aside.
/// Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter CaptureEditorRenders`
extension SharedLook {
@MainActor
@Suite("Capture editor renders")
struct CaptureEditorRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let passes: [(style: PilotStyle, theme: String, tag: String)] = [
        (.instrument, "tokyo-night", "instrument-dark"), (.instrument, "folio", "instrument-light"),
        (.toybox, "toybox-night", "toybox-dark"), (.toybox, "toybox", "toybox-light"),
    ]

    /// The editor's states, each a model set up as Sven would leave it.
    static func states(_ capture: CGImage, tokens: StyleTokens) -> [(String, EditorModel)] {
        func model() -> EditorModel { EditorModel(image: capture, scale: 2, accent: tokens.colors.accent.rgb, dark: tokens.dark) }
        let update = CaptureFixture.updateButton
        // The editor opens on Select (CaptureEditor.show).
        let empty = model()
        empty.pick(.select)

        let marks = model()
        marks.pick(.arrow)
        marks.begin(CGPoint(x: 600, y: 76)); marks.end(CGPoint(x: update.minX - 4, y: update.minY + 6))
        marks.pick(.text); marks.setStyle(1)
        marks.begin(CGPoint(x: 470, y: 58)); marks.typed = "Update the card first"; marks.commitText()
        marks.pick(.blur)
        let key = CaptureFixture.keyValue
        marks.begin(CGPoint(x: key.minX, y: key.minY)); marks.end(CGPoint(x: key.maxX, y: key.maxY))
        marks.say("Saved a copy")

        let selected = model()
        selected.pick(.arrow); selected.setStyle(1); selected.setSize(6)
        selected.begin(CGPoint(x: 600, y: 76)); selected.end(CGPoint(x: update.minX - 4, y: update.minY + 6))
        selected.pick(.rect); selected.setStyle(1); selected.setColour(4)
        let card = CaptureFixture.contactCard
        selected.begin(CGPoint(x: card.minX, y: card.minY)); selected.end(CGPoint(x: card.maxX, y: card.maxY))

        let steps = model()
        steps.pick(.step)
        for p in [CGPoint(x: CaptureFixture.navRow(2).maxX - 18, y: CaptureFixture.navRow(2).midY), CGPoint(x: update.minX - 18, y: update.midY),
                  CGPoint(x: CaptureFixture.editButton.minX - 18, y: CaptureFixture.editButton.midY)] {
            steps.begin(p); steps.end(p)
        }
        steps.pick(.box); steps.setStyle(1)
        let email = CaptureFixture.email
        steps.begin(CGPoint(x: email.minX, y: email.minY)); steps.end(CGPoint(x: email.maxX, y: email.maxY))
        steps.pick(.step)

        let crop = model()
        crop.pick(.crop)
        crop.begin(CGPoint(x: 220, y: 110)); crop.end(CGPoint(x: 900, y: 420))
        let read = model()
        read.readText = {}
        read.startReading()
        let size = CaptureFixture.size
        read.showRead(CaptureFixture.runs.filter { $0.at.x >= 200 }.map { run in
            let r = run.rect
            return ReadLine(text: run.text, box: CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height))
        })
        let ruler = model()
        ruler.pick(.ruler)
        ruler.loadGridNow()
        // Over the solid part of Update card, then over the plan card's white.
        ruler.begin(CGPoint(x: 846, y: 165)); ruler.end(CGPoint(x: 846, y: 165))
        ruler.hover(CGPoint(x: 330, y: 236))

        let backdrop = model()
        backdrop.pick(.arrow)
        backdrop.begin(CGPoint(x: 600, y: 76)); backdrop.end(CGPoint(x: update.minX - 4, y: update.minY + 6))
        backdrop.pick(.select)
        backdrop.begin(CGPoint(x: 120, y: 520)); backdrop.end(CGPoint(x: 120, y: 520))
        backdrop.setBackdrop(Backdrop(fill: .gradient([0xF7B267, 0xF25F5C, 0x8E44AD])))
        let picker = model()
        picker.pick(.eyedropper)
        picker.loadGridNow()
        // On Update card's edge, so the loupe shows the button against the page.
        picker.hover(CGPoint(x: update.minX + 1, y: update.midY))

        // Zoomed in to 200 % about Update card (P33): the room set as the window lays it out, an arrow drawn at the zoom.
        let zoomed = model()
        let window = EditorLayout.window(zoomed.size, fit: 1, tokens: tokens)
        zoomed.setRoom(CGRect(x: 0, y: EditorLayout.bar(tokens) + 1, width: window.width,
                              height: window.height - EditorLayout.bar(tokens) - EditorLayout.foot(tokens) - 2))
        zoomed.zoom(to: 2, about: zoomed.roomPoint(CGPoint(x: update.midX, y: update.midY)))
        zoomed.pick(.arrow)
        zoomed.begin(CGPoint(x: 600, y: 76)); zoomed.end(CGPoint(x: update.minX - 4, y: update.minY + 6))

        // Text's options (Sven after build 82): a Rounded 28 pt pill typed, the footer's Font, Size, Bold and Italic.
        let text = model()
        text.pick(.text); text.setStyle(1)
        text.setFace { $0.family = .rounded; $0.points = 28 }
        text.begin(CGPoint(x: 440, y: 64)); text.typed = "Update the card first"; text.commitText()
        text.pick(.arrow)
        text.begin(CGPoint(x: 640, y: 96)); text.end(CGPoint(x: update.minX - 4, y: update.minY + 6))
        text.pick(.text)

        // A picked rectangle pulled wider by its right handle, mid-drag (the designer's mock).
        let resize = model()
        resize.pick(.rect); resize.setColour(4)
        resize.begin(CGPoint(x: card.minX - 4, y: card.minY - 6)); resize.end(CGPoint(x: card.maxX - 90, y: card.maxY + 6))
        resize.pick(.select)
        resize.begin(CGPoint(x: card.midX, y: card.minY - 6)); resize.end(CGPoint(x: card.midX, y: card.minY - 6))
        if let mark = resize.selectedMark, let right = Grip.grips(of: mark).first(where: { $0.grip == .box(1, 0) })?.at {
            resize.begin(right); resize.drag(CGPoint(x: right.x + 94, y: right.y))
        }

        // History with both steps (B's redo): two marks, the second undone.
        let history = model()
        history.pick(.arrow)
        history.begin(CGPoint(x: 600, y: 76)); history.end(CGPoint(x: update.minX - 4, y: update.minY + 6))
        history.pick(.rect)
        history.begin(CGPoint(x: card.minX, y: card.minY)); history.end(CGPoint(x: card.maxX, y: card.maxY))
        history.undo()

        // The backdrop panel open at the right, a gradient picked and an arrow on the capture (B's first mock).
        let panel = model()
        panel.pick(.arrow)
        panel.begin(CGPoint(x: 600, y: 76)); panel.end(CGPoint(x: update.minX - 4, y: update.minY + 6))
        panel.setBackdrop(Backdrop(fill: .gradient([0xF7B267, 0xF25F5C, 0x8E44AD])))
        panel.panelOpen = true

        // Image size applied: the View pill's size chip lit at 2x.
        let sized = model()
        sized.resize(to: ResizeTarget(width: Int(sized.flatSize.width) * 2, height: Int(sized.flatSize.height) * 2))

        return [("1-empty", empty), ("2-marks", marks), ("3-selected", selected), ("4-steps", steps), ("5-crop", crop), ("6-read", read),
                ("7-ruler", ruler), ("8-backdrop", backdrop), ("9-eyedropper", picker), ("10-zoom", zoomed), ("11-text", text), ("12-resize", resize),
                ("13-history", history), ("14-panel", panel), ("15-image-size", sized)]
    }

    @Test("The editor renders in Instrument and Toybox, dark and light, every state, at one size",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        try Self.rendering { look, out in try Self.renderStates(look: look, out: out) }
    }

    /// The render runs' common setup: the moved home checked, the bundled faces, Glass off, the output folder; the look
    /// put back after.
    static func rendering(_ body: (Look, URL) throws -> Void) throws {
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
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("capture-editor")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try body(look, out)
    }

    static func renderStates(look: Look, out: URL) throws {
        let capture = try #require(CaptureFixture.image())
        var sizes: [String: Set<String>] = [:]
        for pass in Self.passes {
            look.style = pass.style
            look.themeID = pass.theme
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            func write(_ rep: NSBitmapImageRep, _ name: String) throws {
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("B-\(name)-\(pass.tag).png"))
            }
            let states = Self.states(capture, tokens: tokens)
            for (name, model) in states {
                let size = EditorLayout.window(model.size, fit: 1, tokens: tokens, panel: model.panelOpen)
                // The Drag cap shows only with something to drag.
                let rep = try Self.draw(CaptureEditorView(model: model, drag: { NSItemProvider() }), tokens: tokens, size: size, scale: 2)
                try write(rep, name)
                sizes["\(pass.tag) panel \(model.panelOpen)", default: []].insert("\(rep.pixelsWide)x\(rep.pixelsHigh)")
            }
            // The smallest window (EditorLayout.least): the capture fitted, the fourteen tools still in the rail.
            let small = states[1].1
            try write(Self.draw(CaptureEditorView(model: small, drag: { NSItemProvider() }), tokens: tokens,
                                size: EditorLayout.least(panel: false), scale: 2), "16-smallest")
            // Text's options, the widest strip, with a picked colour's seventh swatch, at the smallest window.
            let narrow = states[10].1
            narrow.takeColour(0x7A5CFA)
            narrow.pick(.text)
            try write(Self.draw(CaptureEditorView(model: narrow, drag: { NSItemProvider() }), tokens: tokens,
                                size: EditorLayout.least(panel: false), scale: 2), "16-smallest-text")
            // The View pill's Image size and the actions' Upscale, as their popovers draw them.
            let popovers = states[0].1
            let target = ResizeTarget(width: Int(popovers.flatSize.width), height: Int(popovers.flatSize.height))
            try write(Self.draw(ImageSizePanel(model: popovers, target: target), tokens: tokens, size: CGSize(width: 340, height: 230), scale: 2), "17-image-size-panel")
            popovers.upscale.size(width: target.width, height: target.height)
            try write(Self.draw(UpscalePopover(model: popovers) {}, tokens: tokens, size: CGSize(width: 340, height: 330), scale: 2),
                      "18-upscale-panel")
        }
        for (key, set) in sizes { #expect(set.count == 1, "\(key): the window's size changed with its state: \(set.sorted())") }
    }

    /// Uncrop and backdrop marks (P77, round 2's capture-2 and capture-3): the billing page cut from a desktop of other
    /// windows, that desktop read back as its screen. Crop pulled past two edges mid-drag, the uncrop kept, a title on
    /// the backdrop over a capture mark, and the same grown by an uncrop with the title staying put.
    @Test("Uncrop and backdrop marks render in Instrument and Toybox, dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderUncrop() throws {
        try Self.rendering { look, out in try Self.renderUncrop(look: look, out: out) }
    }

    static func renderUncrop(look: Look, out: URL) throws {
        let capture = try #require(CaptureFixture.image())
        let (screen, taken) = try #require(Self.desktop(around: capture))
        for pass in Self.passes {
            look.style = pass.style
            look.themeID = pass.theme
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            func model() -> EditorModel {
                let m = EditorModel(image: capture, scale: 2, accent: tokens.colors.accent.rgb, dark: tokens.dark,
                                    screen: CaptureGrab(image: screen, taken: taken, scale: 2))
                m.pick(.select)
                return m
            }
            let t = model().taken
            /// Crop's left edge pulled 120 points out, past the capture's.
            func uncropLeft(_ m: EditorModel) {
                m.pick(.crop)
                m.begin(CGPoint(x: t.minX, y: t.midY)); m.end(CGPoint(x: t.minX - 120, y: t.midY))
            }
            // Crop's left edge pulled 120 points out and its top 60, still being dragged.
            let pulling = model()
            uncropLeft(pulling)
            // The top edge's handle, in the middle of the crop as the first pull left it.
            pulling.begin(CGPoint(x: t.midX - 60, y: t.minY)); pulling.drag(CGPoint(x: t.midX - 60, y: t.minY - 60))
            let kept = model()
            uncropLeft(kept)
            kept.applyCrop()
            func titled() -> EditorModel {
                let m = model()
                m.setBackdrop(Backdrop(fill: .gradient([0x1FB5A8, 0x1D5D8C]), pad: 72))
                m.pick(.text)
                m.setFace { $0.points = 30 }
                m.setColour(5)
                m.begin(CGPoint(x: t.minX - 50, y: t.minY - 24)); m.typed = "Billing, after the redesign"; m.commitText()
                m.pick(.arrow)
                let update = CaptureFixture.updateButton.offsetBy(dx: t.minX, dy: t.minY)
                m.begin(CGPoint(x: update.minX - 150, y: update.minY - 30)); m.end(CGPoint(x: update.minX - 4, y: update.minY + 6))
                m.pick(.select)
                return m
            }
            let marked = titled()
            let grown = titled()
            uncropLeft(grown)
            grown.applyCrop()
            let size = EditorLayout.window(CaptureFixture.size, fit: 1, tokens: tokens)
            for (name, m) in [("19-uncrop-pulling", pulling), ("20-uncropped", kept), ("21-backdrop-mark", marked), ("22-backdrop-mark-grown", grown)] {
                let rep = try Self.draw(CaptureEditorView(model: m, drag: { NSItemProvider() }), tokens: tokens, size: size, scale: 2)
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("B-\(name)-\(pass.tag).png"))
            }
            // The crop strip at its widest (the uncrop hint, Whole capture, As taken) in the smallest window.
            let rep = try Self.draw(CaptureEditorView(model: pulling, drag: { NSItemProvider() }), tokens: tokens, size: EditorLayout.least(panel: false), scale: 2)
            try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("B-23-uncrop-smallest-\(pass.tag).png"))
        }
    }

    /// A 1280 × 800 point desktop at 2x with `capture` on it at (180, 110): a menu bar, a notes window at its left, a
    /// terminal at its right, all of which an uncrop brings back. The still and the capture's pixels in it.
    static func desktop(around capture: CGImage) -> (CGImage, CGRect)? {
        let w = 2560, h = 1600
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        func c(_ rgb: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: a)
        }
        /// A rect in points from the top left, as the context's pixels.
        func px(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> CGRect { CGRect(x: x * 2, y: CGFloat(h) - (y + rh) * 2, width: rw * 2, height: rh * 2) }
        let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c(0x2B3A67), c(0x0F1424)] as CFArray, locations: nil)!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        ctx.setFillColor(c(0x000000, 0.35)); ctx.fill(px(0, 0, 1280, 24))
        ctx.setFillColor(c(0xECECEE)); ctx.fill(px(30, 190, 240, 330))
        ctx.setFillColor(c(0xD6D6DA)); ctx.fill(px(30, 190, 240, 26))
        ctx.setFillColor(c(0x9A9CA3))
        for i in 0..<6 { ctx.fill(px(46, 236 + CGFloat(i) * 22, 150 - CGFloat(i % 3) * 30, 9)) }
        ctx.setFillColor(c(0x15171C)); ctx.fill(px(1060, 250, 200, 360))
        ctx.setFillColor(c(0x3FD18A))
        for i in 0..<8 { ctx.fill(px(1150, 272 + CGFloat(i) * 20, 70 - CGFloat(i % 4) * 12, 8)) }
        let at = CGPoint(x: 180, y: 110), size = CaptureFixture.size
        ctx.draw(capture, in: px(at.x, at.y, size.width, size.height))
        guard let image = ctx.makeImage() else { return nil }
        return (image, CGRect(x: at.x * 2, y: at.y * 2, width: CGFloat(capture.width), height: CGFloat(capture.height)))
    }

    /// `view` at a fixed size in a borderless window that is never shown, in `tokens`.
    static func draw(_ view: some View, tokens: StyleTokens, size: CGSize, scale: Int) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.style(tokens).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: tokens.dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        return try #require(snapshot(host, scale: scale))
    }
}
}

// MARK: - The capture: a made-up billing page, fixed light colours as a real capture would be

/// What the editor opens on: a web app's billing settings, 920 × 580 pt, drawn once at 2x. Every text run has a known
/// rectangle (measured with the face it draws in), so marks and OCR boxes land on real words.
@MainActor
enum CaptureFixture {
    static let size = CGSize(width: 920, height: 580)

    struct Run {
        let text: String
        let at: CGPoint
        let size: CGFloat
        var weight: NSFont.Weight = .regular
        var colour: UInt32 = 0x15161A
        var mono = false

        var font: NSFont { mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight) }
        var rect: CGRect {
            let s = (text as NSString).size(withAttributes: [.font: font])
            return CGRect(x: at.x, y: at.y, width: ceil(s.width), height: ceil(s.height))
        }
    }

    static let grey: UInt32 = 0x6B6F78
    static let nav = ["General", "Members", "Billing", "API keys", "Integrations", "Audit log"]
    static let navTop: CGFloat = 70

    /// Every word on the page, top to bottom (OCR's reading order).
    static let runs: [Run] = [
        Run(text: "Northwind", at: CGPoint(x: 44, y: 24), size: 15, weight: .semibold),
    ] + nav.enumerated().map { i, name in
        Run(text: name, at: CGPoint(x: 28, y: navTop + CGFloat(i) * 34 + 8), size: 13, weight: i == 2 ? .semibold : .regular,
            colour: i == 2 ? 0x15161A : 0x4A4E57)
    } + [
        Run(text: "Settings / Billing", at: CGPoint(x: 240, y: 30), size: 12, colour: grey),
        Run(text: "Billing", at: CGPoint(x: 240, y: 50), size: 26, weight: .bold),
        Run(text: "Manage your plan, payment method and invoices.", at: CGPoint(x: 240, y: 88), size: 13, colour: grey),
        Run(text: "PRO PLAN", at: CGPoint(x: 262, y: 144), size: 11, weight: .semibold, colour: 0x5B5FE0),
        Run(text: "$12 / month", at: CGPoint(x: 262, y: 162), size: 22, weight: .semibold),
        Run(text: "Renews on 1 November 2026 · Visa ending 4242", at: CGPoint(x: 262, y: 198), size: 12, colour: grey),
        Run(text: "Update card", at: CGPoint(x: 744, y: 155), size: 13, weight: .medium, colour: 0xFFFFFF),
        Run(text: "Cancel plan", at: CGPoint(x: 752, y: 202), size: 12, colour: 0xB4322A),
        Run(text: "Billing email", at: CGPoint(x: 262, y: 280), size: 12, colour: grey),
        Run(text: "maya.lind@northwind.studio", at: CGPoint(x: 262, y: 298), size: 14),
        Run(text: "Edit", at: CGPoint(x: 828, y: 289), size: 12, weight: .medium),
        Run(text: "Live key", at: CGPoint(x: 262, y: 360), size: 12, colour: grey),
        Run(text: "nw_live_7f3a9c2e81d4b6a0f5e2c9d7", at: CGPoint(x: 262, y: 378), size: 13, mono: true),
        Run(text: "Copy", at: CGPoint(x: 825, y: 369), size: 12, weight: .medium),
        Run(text: "Invoices", at: CGPoint(x: 240, y: 432), size: 14, weight: .semibold),
    ] + [("1 Oct 2026", "INV-0142", "$12.00"), ("1 Sep 2026", "INV-0131", "$12.00"), ("1 Aug 2026", "INV-0117", "$12.00")]
        .enumerated().flatMap { i, row in
            let y = 466 + CGFloat(i) * 34
            return [Run(text: row.0, at: CGPoint(x: 240, y: y), size: 13), Run(text: row.1, at: CGPoint(x: 400, y: y), size: 13, colour: grey, mono: false),
                    Run(text: row.2, at: CGPoint(x: 580, y: y), size: 13), Run(text: "Paid", at: CGPoint(x: 840, y: y), size: 12, weight: .medium, colour: 0x1E7F4F)]
        }

    static func run(_ text: String) -> Run { runs.first { $0.text == text }! }

    // Blocks the marks point at.
    static let planCard = CGRect(x: 240, y: 126, width: 640, height: 124)
    static let updateButton = CGRect(x: 730, y: 148, width: 126, height: 34)
    static let contactCard = CGRect(x: 240, y: 264, width: 640, height: 64)
    static let keyCard = CGRect(x: 240, y: 344, width: 640, height: 64)
    static let editButton = CGRect(x: 814, y: 284, width: 46, height: 26)
    static let copyButton = CGRect(x: 812, y: 364, width: 50, height: 26)
    static var keyValue: CGRect { run("nw_live_7f3a9c2e81d4b6a0f5e2c9d7").rect.insetBy(dx: -6, dy: -1) }
    static var email: CGRect { run("maya.lind@northwind.studio").rect.insetBy(dx: -4, dy: -1) }
    static func navRow(_ i: Int) -> CGRect { CGRect(x: 14, y: navTop + CGFloat(i) * 34, width: 172, height: 30) }

    /// What OCR reads: every run, top to bottom, left to right, one line per row.
    static var lines: [String] {
        let main = runs.filter { $0.at.x >= 200 }
        let rows = Dictionary(grouping: main) { Int(($0.at.y / 8).rounded()) }
        return rows.keys.sorted().map { key in rows[key]!.sorted { $0.at.x < $1.at.x }.map(\.text).joined(separator: "   ") }
    }

    struct Page: View {
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color(hex: 0xFFFFFF)
                // Sidebar.
                Color(hex: 0xF6F6F7).frame(width: 200)
                Color(hex: 0xE6E7EA).frame(width: 1).offset(x: 200)
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x5B5FE0)).frame(width: 18, height: 18).offset(x: 20, y: 25)
                RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0xE9E9EE)).frame(width: navRow(2).width, height: navRow(2).height)
                    .offset(x: navRow(2).minX, y: navRow(2).minY)
                // Cards.
                card(planCard)
                card(contactCard)
                card(keyCard)
                RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x15161A)).frame(width: updateButton.width, height: updateButton.height)
                    .offset(x: updateButton.minX, y: updateButton.minY)
                button(editButton)
                button(copyButton)
                ForEach(0..<4) { i in Color(hex: 0xECEDF0).frame(width: 640, height: 1).offset(x: 240, y: 456 + CGFloat(i) * 34) }
                ForEach(0..<3) { i in
                    Capsule().fill(Color(hex: 0xE3F4EA)).frame(width: 44, height: 20).offset(x: 832, y: 464 + CGFloat(i) * 34)
                }
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    Text(run.text).font(Font(run.font)).foregroundStyle(Color(hex: run.colour)).fixedSize()
                        .offset(x: run.at.x, y: run.at.y)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.colorScheme, .light)
        }

        func card(_ r: CGRect) -> some View {
            RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0xFFFFFF))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0xE3E4E8)) }
                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
        }

        func button(_ r: CGRect) -> some View {
            RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0xF4F4F6))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color(hex: 0xDADBE0)) }
                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
        }
    }

    /// The page drawn at 2x, as SCScreenshotManager hands a Retina capture over.
    static func image() -> CGImage? {
        let renderer = ImageRenderer(content: Page())
        renderer.scale = 2
        return renderer.cgImage
    }
}
#endif
