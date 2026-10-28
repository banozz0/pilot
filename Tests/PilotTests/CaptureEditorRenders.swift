#if DEBUG
import AppKit
import Clipboard
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The capture editor in direction A (spec capture.html CP6, CP7; Sven Q169; the designer's round 1 grown into the real
/// suite): the real CaptureEditorView over the designer's made-up billing page, in ten states (the last zoomed in), in
/// Instrument (Lagoon, Workshop) and Toybox (toybox-night, toybox). The window keeps one size whatever the state.
/// Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter CaptureEditorRenders`
extension SharedLook {
@MainActor
@Suite("Capture editor renders")
struct CaptureEditorRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let passes: [(style: PilotStyle, theme: String, tag: String)] = [
        (.instrument, "lagoon", "instrument-dark"), (.instrument, "workshop", "instrument-light"),
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

        return [("1-empty", empty), ("2-marks", marks), ("3-selected", selected), ("4-steps", steps), ("5-crop", crop), ("6-read", read),
                ("7-ruler", ruler), ("8-backdrop", backdrop), ("9-eyedropper", picker), ("10-zoom", zoomed), ("11-text", text), ("12-resize", resize)]
    }

    @Test("The editor renders in Instrument and Toybox, dark and light, every state, at one size",
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
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("capture-editor")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let capture = try #require(CaptureFixture.image())
        var sizes: [String: Set<String>] = [:]
        for pass in Self.passes {
            look.style = pass.style
            look.themeID = pass.theme
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            for (name, model) in Self.states(capture, tokens: tokens) {
                let size = EditorLayout.window(model.size, fit: 1, tokens: tokens)
                let rep = try Self.draw(CaptureEditorView(model: model), tokens: tokens, size: size, scale: 2)
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("A-\(name)-\(pass.tag).png"))
                sizes[pass.tag, default: []].insert("\(rep.pixelsWide)x\(rep.pixelsHigh)")
            }
        }
        for (key, set) in sizes { #expect(set.count == 1, "\(key): the window's size changed with its state: \(set.sorted())") }
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
