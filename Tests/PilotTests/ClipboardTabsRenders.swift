#if DEBUG
import AppKit
@testable import Clipboard
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Offscreen renders of the clipboard panel's tabs (card agent-bo-95422970): five tags, so the strip overflows, with the
/// pick on All, Image, Pinned and a tag near the end, then the empty tabs (a tag and a kind with no copies, a search
/// with no match), and the confirm before a tag is deleted, in Tokyo Night and Folio; per theme,
/// one sheet stacks the first four and one the empty ones. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter ClipboardTabsRenders`
extension SharedLook {
@MainActor
@Suite("Clipboard tabs renders")
struct ClipboardTabsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The clipboard tabs render with the pick on a kind, Pinned, a tag and an empty tag", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try Self.prepare("clipboard-tabs")
        let look = Look.shared
        defer { look.glass = false; look.themeID = PilotTheme.defaultID }

        let db = FileManager.default.temporaryDirectory.appending(path: "pilot-render-tabs-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } }
        let store = try Self.sampleStore(at: db)
        let tags = try store.tags()
        try #require(tags.map(\.name) == ["aerospace", "dotfiles", "omarchy", "pilot", "spanish"])

        let states: [(name: String, title: String, tab: PanelTab, query: String)] = [
            ("01-all", "Opened on All: the tags past the edge", .kind(.all), ""),
            ("02-image", "Image", .kind(.image), ""),
            ("03-pinned", "Pinned", .kind(.pinned), ""),
            ("04-tag-pilot", "#pilot, a tag near the end", .tag(tags[3]), ""),
            ("05-tag-empty", "#spanish, a tag with no copies", .tag(tags[4]), ""),
            ("06-kind-empty", "File, a kind with no copies", .kind(.file), ""),
            ("07-search-empty", "Image, searched for a word no image has", .kind(.image), "aerospace"),
        ]
        var strips: [(String, NSBitmapImageRep)] = []
        for theme in ["tokyo-night", "folio"] {
            look.themeID = theme
            var shots: [(String, NSBitmapImageRep)] = []
            for state in states {
                let model = PanelModel(store: store)
                model.tab = state.tab
                model.query = state.query
                let rep = try Self.render(ClipboardPanelView(model: model, returnCopies: false))
                try #require(rep.representation(using: .png, properties: [:]))
                    .write(to: dir.appendingPathComponent("\(theme)-\(state.name).png"))
                shots.append((state.title, rep))
                // The header alone, the search line and the tabs, for a sheet of every strip side by side.
                if state.query.isEmpty, let cg = rep.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: 212)) {
                    strips.append(("\(look.theme.name) · \(state.title)", NSBitmapImageRep(cgImage: cg)))
                }
            }
            // Cmd+Shift+Backspace on #pilot's tab: the confirm before the tag goes (card agent-bo-95422986).
            let asking = PanelModel(store: store)
            asking.tab = .tag(tags[3])
            asking.askDeleteTag()
            try #require(try Self.render(ClipboardPanelView(model: asking, returnCopies: false)).representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("\(theme)-08-delete-tag.png"))
            // One sheet of the tabs with rows, one of the empty tabs.
            try Self.sheet(Array(shots.prefix(4)), dark: look.theme.dark).write(to: dir.appendingPathComponent("sheet-\(theme).png"))
            try Self.sheet(Array(shots.dropFirst(4)), dark: look.theme.dark).write(to: dir.appendingPathComponent("sheet-empty-\(theme).png"))
        }
        try Self.sheet(strips, dark: true).write(to: dir.appendingPathComponent("sheet-strips.png"))
    }

    @Test("A copied colour previews as the menu's colour card: the swatch across the preview, its ramp and five formats (menu Rail and Classic T10)",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderColour() throws {
        let dir = try Self.prepare("clipboard-colour")
        let look = Look.shared
        defer { look.themeID = PilotTheme.defaultID }
        let db = FileManager.default.temporaryDirectory.appending(path: "pilot-render-colour-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } }
        let store = try Self.sampleStore(at: db)
        for theme in ["tokyo-night", "porcelain"] {
            look.themeID = theme
            let model = PanelModel(store: store)
            model.tab = .kind(.colour)
            let clip = try #require(model.selected)
            #expect(clip.swatch == 0x7AA2F7 && StoredClip.colourValues(0x7AA2F7) == ColourAnswer.formats(0x7AA2F7))
            try #require(try Self.render(ClipboardPanelView(model: model, returnCopies: false)).representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("colour-\(look.theme.dark ? "dark" : "light").png"))
        }
    }

    @Test("The Snippets tab: the list, a snippet that asks for an argument, a search, Cmd+K, and none saved (Sven, 2026-10-08)", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderSnippets() throws {
        let dir = try Self.prepare("clipboard-snippets")
        let look = Look.shared
        defer { look.glass = false; look.themeID = PilotTheme.defaultID }
        let db = FileManager.default.temporaryDirectory.appending(path: "pilot-render-snippets-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } }
        let store = try Self.sampleStore(at: db)
        for theme in ["nightwatch", "paper"] {
            look.themeID = theme
            var shots: [(String, NSBitmapImageRep)] = []
            for (name, list, change) in Snippet.renderStates {
                let model = PanelModel(store: store, snippets: { list })
                model.tab = .kind(.snippet)
                change(model)
                let rep = try Self.render(ClipboardPanelView(model: model, returnCopies: false))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(theme)-\(name).png"))
                shots.append((name, rep))
            }
            try Self.sheet(shots, dark: look.theme.dark).write(to: dir.appendingPathComponent("sheet-\(theme).png"))
        }
    }

    @Test("An image with text read from it shows that text under the picture (card agent-bo-95423070)", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderImageText() throws {
        let dir = try Self.prepare("clipboard-ocr")
        let look = Look.shared
        defer { look.glass = false; look.themeID = PilotTheme.defaultID }
        let db = FileManager.default.temporaryDirectory.appending(path: "pilot-render-ocr-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } }
        let store = try Self.sampleStore(at: db)
        let image = try #require(try store.unreadImages().first)
        try store.setRecognised(image, "Invoice 2026-104\nPilot Ltd, Valletta\nTotal due: €1,240.00\nPay by 31 October")
        for theme in ["tokyo-night", "folio"] {
            look.themeID = theme
            let model = PanelModel(store: store)
            model.tab = .kind(.image)
            try #require(model.selected?.id == image)
            try #require(try Self.render(ClipboardPanelView(model: model, returnCopies: false)).representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("\(theme).png"))
        }
    }

    @Test("An image still being read says so under its picture and, while a search misses it, under the list; a tag's tab names ⇧⌘⌫ (Sven, build 31)", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderReading() throws {
        let dir = try Self.prepare("clipboard-reading")
        let look = Look.shared
        defer { look.glass = false; look.themeID = PilotTheme.defaultID; look.style = .instrument }
        let db = FileManager.default.temporaryDirectory.appending(path: "pilot-render-reading-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } }
        // Its two images are unread.
        let store = try Self.sampleStore(at: db)
        let pilot = try #require(try store.tags().first { $0.name == "pilot" })
        var shots: [(String, NSBitmapImageRep)] = []
        for (name, style) in [("instrument", PilotStyle.instrument), ("toybox", .toybox)] {
            look.style = style
            let image = PanelModel(store: store)
            image.tab = .kind(.image)
            try #require(image.selected?.isReadingText == true)
            let searched = PanelModel(store: store)
            searched.query = "omarchy"
            try #require(searched.readingLine == "Reading the text in 2 images…")
            let tag = PanelModel(store: store)
            tag.tab = .tag(pilot)
            for (state, model) in [("image", image), ("search", searched), ("tag", tag)] {
                let rep = try Self.render(ClipboardPanelView(model: model, returnCopies: false))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name)-\(state).png"))
                shots.append(("\(name) · \(state)", rep))
            }
        }
        try Self.sheet(shots, dark: look.theme.dark).write(to: dir.appendingPathComponent("sheet.png"))
    }

    @Test("A search lights its words in the preview: a long text scrolled to its first match, and the words on a screenshot read by Vision (Sven, 2026-10-10)", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderHighlights() async throws {
        let dir = try Self.prepare("clipboard-highlight")
        let look = Look.shared
        defer { look.glass = false; look.themeID = PilotTheme.defaultID; look.style = .instrument }
        let db = FileManager.default.temporaryDirectory.appending(path: "pilot-render-highlight-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } }
        let store = try ClipboardStore(path: db)
        let lines = (1...40).map { $0 == 28 ? "28  ship the Valletta build, then tell valletta-ops" : String(format: "%02d  line of release notes, nothing to see", $0) }
        let note = lines.joined(separator: "\n")
        try store.add(ClipItem(kind: .text, text: note, contents: [[NSPasteboard.PasteboardType.string.rawValue: Data(note.utf8)]], sourceApp: "md.obsidian"))
        let shot = try store.add(ClipItem(kind: .image, text: "", contents: [[NSPasteboard.PasteboardType.png.rawValue: Self.invoice()]],
                                          sourceApp: "com.apple.Preview"))
        // The text Vision reads from it, as ClipboardOCR stores it; the boxes are read again by the real Vision.
        try store.setRecognised(shot, await VisionText().text(in: try #require(try store.image(of: shot))))
        look.style = .instrument
        let text = PanelModel(store: store)
        text.tab = .kind(.text)
        text.query = "valletta"
        try #require(text.selected?.kind == .text)
        try #require(try Self.render(ClipboardPanelView(model: text, returnCopies: false)).representation(using: .png, properties: [:]))
            .write(to: dir.appendingPathComponent("text-instrument.png"))
        let image = PanelModel(store: store)
        image.query = "total"
        try #require(image.selected?.id == shot)
        for _ in 0..<300 where image.previewBoxes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!image.previewBoxes.isEmpty)
        try #require(try Self.render(ClipboardPanelView(model: image, returnCopies: false)).representation(using: .png, properties: [:]))
            .write(to: dir.appendingPathComponent("image-instrument.png"))
    }

    @Test("Three images and two texts picked with Cmd+Return preview as thumbnails and lines in pick order; image rows wear their thumbnails (Sven, build 46)", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderPicked() async throws {
        let dir = try Self.prepare("clipboard-picked")
        let look = Look.shared
        defer { look.glass = false; look.themeID = PilotTheme.defaultID; look.style = .instrument }
        let db = FileManager.default.temporaryDirectory.appending(path: "pilot-render-picked-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } }
        let store = try ClipboardStore(path: db)
        let now = Date()
        // Oldest first, so the list reads: image, text, image, invoice, text.
        let items: [ClipItem] = [
            ClipItem(kind: .text, text: "Ship the Valletta build tonight", contents: [[NSPasteboard.PasteboardType.string.rawValue: Data("Ship the Valletta build tonight".utf8)]], sourceApp: "md.obsidian"),
            ClipItem(kind: .image, text: "", contents: [[NSPasteboard.PasteboardType.png.rawValue: Self.invoice()]], sourceApp: "com.apple.Preview"),
            ClipItem(kind: .image, text: "", contents: [[NSPasteboard.PasteboardType.png.rawValue: Self.png(CGSize(width: 480, height: 480), seed: 1)]], sourceApp: "com.apple.Preview"),
            ClipItem(kind: .text, text: "open -g \"pilot://run?action=windows.close&app=Finder\"", contents: [[NSPasteboard.PasteboardType.string.rawValue: Data("open -g".utf8)]], sourceApp: "com.mitchellh.ghostty"),
            ClipItem(kind: .image, text: "", contents: [[NSPasteboard.PasteboardType.png.rawValue: Self.png(CGSize(width: 1280, height: 720), seed: 0)]], sourceApp: "com.apple.Preview"),
        ]
        for (i, item) in items.enumerated() { try store.add(item, at: now.addingTimeInterval(Double(-60 * (items.count - i)))) }
        var shots: [(String, NSBitmapImageRep)] = []
        for (name, style) in [("instrument", PilotStyle.instrument), ("toybox", .toybox)] {
            look.style = style
            let model = PanelModel(store: store)
            // Cmd+Return on rows 3, 2, 1, 5 then 4: image, text, image, text, the invoice.
            for row in [2, 1, 0, 4, 3] { model.move(row - model.cursor); model.togglePick() }
            try #require(model.picked?.map(\.kind) == [.image, .text, .image, .text, .image])
            for _ in 0..<300 where model.rows.contains(where: { $0.kind == .image && model.thumbnail($0) == nil }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let rep = try Self.render(ClipboardPanelView(model: model, returnCopies: false))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
            shots.append((name, rep))
        }
        try Self.sheet(shots, dark: look.theme.dark).write(to: dir.appendingPathComponent("sheet.png"))
    }

    /// A PNG of an invoice's lines in white on a dark ground, standing in for a screenshot with text in it.
    static func invoice() -> Data {
        let size = CGSize(width: 640, height: 400)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.16, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let lines = ["Invoice 2026-104", "Pilot Ltd, Valletta", "Subtotal: €1,000.00", "Total due: €1,240.00", "Pay by 31 October"]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 48, y: size.height - 80 - CGFloat(i) * 64),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 34, weight: i == 0 ? .bold : .regular), .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// The renders' folder under PILOT_RENDER_DIR, made once the home is known to have moved, with the display faces
    /// registered and the panels drawn without glass; each test puts the look back.
    static func prepare(_ folder: String) throws -> URL {
        let home = try #require(env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        let dir = URL(fileURLWithPath: try #require(env["PILOT_RENDER_DIR"])).appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        Look.shared.glass = false
        return dir
    }

    /// Ten copies over five tags, one tag left with none: text, links, an email, two images and colours, two pinned.
    static func sampleStore(at db: URL) throws -> ClipboardStore {
        let store = try ClipboardStore(path: db)
        let now = Date()
        let texts: [(String, String?)] = [
            ("open -g \"pilot://run?action=windows.close&app=Finder\"", "com.mitchellh.ghostty"),
            ("https://github.com/nikitabobko/AeroSpace", "app.zen-browser.zen"),
            ("Pilot makes a Mac feel as close to Omarchy as macOS allows.", "md.obsidian"),
            ("#7AA2F7", nil),
            ("someone@example.com", "com.apple.mail"),
            ("[mode.main.binding]\nalt-h = 'focus left'", "com.mitchellh.ghostty"),
            ("#BB9AF7", nil),
        ]
        var ids: [Int64] = []
        for (i, (text, app)) in texts.enumerated() {
            let item = ClipItem(kind: text.hasPrefix("#") ? .colour : .text, text: text,
                                contents: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]], sourceApp: app)
            ids.append(try store.add(item, at: now.addingTimeInterval(Double(-90 * (i + 2)))))
        }
        for (i, size) in [(0, CGSize(width: 640, height: 400)), (1, CGSize(width: 480, height: 480))] {
            let item = ClipItem(kind: .image, text: "", contents: [[NSPasteboard.PasteboardType.png.rawValue: Self.png(size, seed: i)]],
                                sourceApp: "com.apple.Preview")
            ids.append(try store.add(item, at: now.addingTimeInterval(Double(-60 * i))))
        }
        try store.setPinned([ids[3], ids[2]], true)
        try store.tag([ids[5], ids[1]], with: "aerospace")
        try store.tag([ids[5]], with: "dotfiles")
        try store.tag([ids[2]], with: "omarchy")
        try store.tag([ids[0], ids[7]], with: "pilot")
        try store.tag([], with: "spanish")
        return store
    }

    /// A PNG of two soft blobs on a dark ground, standing in for a screenshot.
    static func png(_ size: CGSize, seed: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.16, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let colours = seed == 0 ? [NSColor(srgbRed: 0.48, green: 0.64, blue: 0.97, alpha: 1), NSColor(srgbRed: 0.73, green: 0.60, blue: 0.97, alpha: 1)]
                                : [NSColor(srgbRed: 0.62, green: 0.81, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.49, green: 0.81, blue: 1, alpha: 1)]
        for (i, colour) in colours.enumerated() {
            let r = min(size.width, size.height) * (i == 0 ? 0.42 : 0.3)
            let centre = CGPoint(x: size.width * (i == 0 ? 0.36 : 0.68), y: size.height * (i == 0 ? 0.42 : 0.62))
            NSGradient(starting: colour, ending: colour.withAlphaComponent(0))?
                .draw(fromCenter: centre, radius: 0, toCenter: centre, radius: r, options: [])
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// The panel as HUD.makePanel builds it, drawn at Retina scale once its strip has scrolled to the pick.
    static func render(_ view: some View) throws -> NSBitmapImageRep {
        let panel = HUD.makePanel(view)
        defer { panel.close() }
        let content = try #require(panel.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        content.layoutSubtreeIfNeeded()
        return try #require(snapshot(content, scale: 2))
    }

    /// The shots stacked with a caption over each, on the theme's side of grey.
    static func sheet(_ shots: [(String, NSBitmapImageRep)], dark: Bool) throws -> Data {
        let gap = 84, pad = 32
        let width = (shots.map(\.1.pixelsWide).max() ?? 0) + pad * 2
        let height = shots.reduce(pad * 2) { $0 + $1.1.pixelsHigh + gap }
        let sheet = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        (dark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.84, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var top = pad
        for (title, rep) in shots {
            let caption = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .medium),
                                                                          .foregroundColor: dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.15, alpha: 1)])
            caption.draw(at: NSPoint(x: pad, y: height - top - gap + 14))
            rep.draw(in: NSRect(x: pad, y: height - top - gap - rep.pixelsHigh, width: rep.pixelsWide, height: rep.pixelsHigh))
            top += rep.pixelsHigh + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(sheet.representation(using: .png, properties: [:]))
    }
}
}

extension Snippet {
    /// The renders' snippets: one with a keyword and several lines, one that asks for an argument, one with no keyword.
    static let renderSamples = [
        Snippet(name: "Signature", keyword: ";sig", text: "Best,\nAlex\nexample.com"),
        Snippet(name: "Reply to a client", keyword: ";re", text: "Hi {argument},\n\nThanks for getting in touch. {cursor}\n\nAlex"),
        Snippet(name: "Today", keyword: ";date", text: "{date}"),
        Snippet(name: "Meeting link", keyword: "", text: "https://meet.example.com/alex"),
        Snippet(name: "Shipping address", keyword: ";addr", text: "12 Example Street\nSliema\nMalta"),
    ]

    /// The Snippets tab's states each render pass draws, on that tab: the list, an argument snippet, a search, Cmd+K, none.
    @MainActor static let renderStates: [(String, [Snippet], (PanelModel) -> Void)] = [
        ("13-snippets", renderSamples, { _ in }),
        ("14-snippet-argument", renderSamples, { $0.move(1) }),
        ("15-snippets-search", renderSamples, { $0.query = "sig" }),
        ("16-snippets-actions", renderSamples, { $0.open(.actions) }),
        ("17-snippets-none", [], { _ in }),
    ]
}
#endif
