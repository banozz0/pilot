#if DEBUG
import AppKit
import Foundation
import PilotCore
import Testing
import WebKit
@testable import Pilot

/// The desk widgets in `Packaging/widgets` (ADR 0016; Sven Q694): six HTML widgets on one look kit, opt-in like the other
/// renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-d PILOT_RENDER_DIR=/tmp/pilot-renders-d PILOT_RESOURCES=Packaging swift test --filter DeskWidgetRenders`
/// (PILOT_RESOURCES bundles them, as the app does: `desk-` ids are Pilot's, so no Widgets folder may hold one).
/// - Each folder reads as a widget the way `pilot widget check` reads one, walks clean, and carries the kit unchanged.
/// - The feeds that need no network (To-do, System, AI usage) run once through Pilot's runner, trusted, against the moved
///   home, and answer data: `desk-widgets/feeds.txt`.
/// - All six pages load offscreen on fixed data with Lagoon's and Porcelain's colours handed in as `theme`, each drawn on a
///   solid tile, one sheet a theme: `desk-widgets/desk-<theme>.png`.
@MainActor
@Suite("Desk widget renders")
struct DeskWidgetRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let ids = ["desk-weather", "desk-system", "desk-ai-usage", "desk-todo", "desk-calendar", "desk-clock"]
    static let kit = ["pilot-kit.css", "pilot-kit.js"]

    /// `Packaging/widgets` in this checkout.
    static let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Packaging/widgets", directoryHint: .isDirectory)

    static func dir() throws -> URL {
        let home = try #require(env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to draw on Sven's data")
        let dir = URL(fileURLWithPath: try #require(env["PILOT_RENDER_DIR"])).appending(path: "desk-widgets")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A store in the moved home, which answers each desk widget as the app does: bundled (PILOT_RESOURCES), Pilot's own
    /// and trusted (ReadyWidgets.desk).
    static func store() throws -> WidgetStore {
        let home = URL(fileURLWithPath: try #require(env["CFFIXED_USER_HOME"]))
        let store = WidgetStore(root: home.appending(path: "desk-renders-\(UUID().uuidString)"), passwords: false)
        for id in ids {
            let widget = try #require(store.widget(id), "\(id) is not bundled: set PILOT_RESOURCES=Packaging")
            #expect(ReadyWidgets.isDesk(widget) && store.trust(of: widget) == .trusted)
        }
        return store
    }

    @Test("Each desk widget reads, walks clean and carries the kit unchanged", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func check() throws {
        _ = try Self.dir()
        let folders = try FileManager.default.contentsOfDirectory(atPath: Self.source.path).filter { !$0.hasPrefix(".") && $0 != "kit" }.sorted()
        #expect(folders == Self.ids.sorted())
        for id in Self.ids {
            let folder = Self.source.appending(path: id, directoryHint: .isDirectory)
            let widget = try Widget(folder: folder)
            #expect(widget.id == id && ReadyWidgets.isReady(id) && widget.draw == .html)
            let walked = Widget.walk(folder)
            #expect(walked.problems.isEmpty, "\(id): \(walked.problems)")
            for name in Self.kit {
                #expect(try Data(contentsOf: folder.appending(path: name)) == Data(contentsOf: Self.source.appending(path: "kit/\(name)")),
                        "\(id)'s \(name) differs from kit/\(name)")
            }
            if case .command(let argv, _) = widget.data {
                let program = try #require(Widget.program(argv[0], folder: folder, path: ""), "\(id): \(argv[0]) is not executable")
                #expect(program.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
            }
        }
    }

    @Test("The offline feeds answer data through Pilot's runner",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_RESOURCES"] != nil))
    func feeds() async throws {
        let dir = try Self.dir()
        let store = try Self.store()
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        // A To-do list in the moved home, as the To-do extension writes it.
        let todo = URL(fileURLWithPath: home).appending(path: "Library/Application Support/Pilot/ExtensionData/todo/data")
        try FileManager.default.createDirectory(at: todo, withIntermediateDirectories: true)
        let today = Date.now.formatted(.iso8601.year().month().day())
        let todos = #"{"version": 2, "items": [{"id": "a", "text": "Ship the desk widgets", "done": false, "due": "\#(today)", "order": 0}, "#
            + #"{"id": "b", "text": "Reply to the review", "done": false, "order": 1}, "#
            + #"{"id": "c", "text": "Water the basil", "done": true, "doneAt": \#(Date.now.timeIntervalSince1970), "order": 2}]}"#
        try Data(todos.utf8).write(to: todo.appending(path: "todos.json"))
        let environment = ["HOME": home, "USER": NSUserName(), "TMPDIR": FileManager.default.temporaryDirectory.path]
        var lines: [String] = []
        for id in ["desk-todo", "desk-system", "desk-ai-usage"] {
            let widget = try #require(store.widget(id))
            let run = await WidgetRunner.run(widget, store: store, environment: environment)
            #expect(run.trust == .trusted)
            guard case .data(let data) = run.answer else {
                Issue.record("\(id) answered \(run.answer)")
                continue
            }
            let text = String(decoding: try JSONEncoder().encode(data), as: UTF8.self)
            lines.append("\(id) (\(run.duration.formatted(.units(allowed: [.milliseconds])))): \(text.prefix(400))")
            switch id {
            case "desk-todo": #expect(text.contains("Ship the desk widgets") && text.contains(#""doneToday":1"#))
            case "desk-system": #expect(text.contains(#""os":"macOS"#) && text.contains(#""memory""#))
            default: #expect(text.contains(#""installed":false"#), "the moved home has no AI usage extension")
            }
        }
        try lines.joined(separator: "\n").appending("\n").write(to: dir.appending(path: "feeds.txt"), atomically: true, encoding: .utf8)
    }

    @Test("All six on fixed data, in Lagoon and Porcelain",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_RESOURCES"] != nil))
    func sheets() async throws {
        let dir = try Self.dir()
        testApp()
        let store = try Self.store()
        for themeID in ["lagoon", "porcelain"] {
            let theme = try #require(PilotTheme.named(themeID))
            var shots: [String: NSImage] = [:]
            for id in Self.ids {
                let widget = try #require(store.widget(id))
                shots[id] = try await Self.shot(widget, store: store, data: Self.fixture(id), theme: Self.theme(theme))
            }
            try Self.sheet(shots, store: store, theme: theme).write(to: dir.appending(path: "desk-\(themeID).png"))
        }
    }

    /// PilotTheme's fields as the kit takes them: what the runtime would hand a page as `theme`.
    static func theme(_ t: PilotTheme) -> JSONValue {
        func hex(_ rgb: UInt32) -> JSONValue { .string(String(format: "#%06x", rgb)) }
        return .object(["dark": .bool(t.dark), "ground": hex(t.ground), "surface": hex(t.surface), "raised": hex(t.raised),
                        "line": hex(t.line), "line2": hex(t.line2), "text": hex(t.text), "text2": hex(t.text2), "text3": hex(t.text3),
                        "accent": hex(t.accent), "second": hex(t.second), "third": hex(t.third), "good": hex(t.good),
                        "amber": hex(t.amber), "problem": hex(t.problem), "graphs": .array(t.graphs.map(hex))])
    }

    /// One page loaded offscreen in a window that is never shown, handed `data` and `theme`, drawn by WebKit; at its own
    /// size, or at `size` (the size class renders), where its `<html>` must carry that size's class.
    static func shot(_ widget: Widget, store: WidgetStore, data: JSONValue, theme: JSONValue, size given: Widget.Size? = nil) async throws -> NSImage {
        let size = given ?? widget.size
        let page = try #require(WidgetWebView(widget: widget, store: store, size: CGSize(width: size.width, height: size.height)))
        defer { page.end() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        defer { window.close() }
        page.view.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        window.contentView = page.view
        for _ in 0..<100 where page.view.isLoading || page.view.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        guard case .object(var fields) = data else { throw CocoaError(.coderInvalidValue) }
        fields["theme"] = theme
        page.send(.object(fields))
        try await Task.sleep(for: .milliseconds(500))
        let errors = try await page.view.callAsyncJavaScript("return document.body.innerText.length", contentWorld: .page) as? Int
        #expect((errors ?? 0) > 0, "\(widget.id) drew no text")
        if given != nil {
            let marked = try await page.view.callAsyncJavaScript("return document.documentElement.className", contentWorld: .page) as? String
            let expected = Widget.SizeClass(width: size.width, height: size.height).css
            #expect(marked == expected, "\(widget.id) at \(Int(size.width))×\(Int(size.height)): <html class=\"\(marked ?? "")\">, not \(expected)")
            // A resize across a line swaps the class live, then back for the picture.
            let strip = Widget.SizeClass.strip.css
            page.view.frame = NSRect(x: 0, y: 0, width: 340, height: 70)
            try await Task.sleep(for: .milliseconds(200))
            let resized = try await page.view.callAsyncJavaScript("return document.documentElement.className", contentWorld: .page) as? String
            #expect(resized == strip, "\(widget.id) resized to 340×70: <html class=\"\(resized ?? "")\">, not \(strip)")
            page.view.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            try await Task.sleep(for: .milliseconds(300))
        }
        let config = WKSnapshotConfiguration()
        config.rect = page.view.bounds
        return try await page.view.takeSnapshot(configuration: config)
    }

    @Test("A list taller than its widget scrolls, and PilotKit.height reads the content's height",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_RESOURCES"] != nil))
    func scrolls() async throws {
        let dir = try Self.dir()
        testApp()
        let store = try Self.store()
        let widget = try #require(store.widget("desk-ai-usage"))
        // Sven's round 2: four accounts and more cut the list off. Six here, each with its two windows.
        guard case .object(var fields) = try Self.fixture("desk-ai-usage"), case .array(var providers)? = fields["providers"],
              case .object(let codex)? = providers.dropFirst().first else { throw CocoaError(.coderInvalidValue) }
        for n in 2...5 { var more = codex; more["name"] = .string("Codex \(n + 1)"); providers.append(.object(more)) }
        fields["providers"] = .array(providers)
        let page = try #require(WidgetWebView(widget: widget, store: store))
        defer { page.end() }
        var height = 0.0
        page.fitted = { height = $0 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: widget.size.width, height: widget.size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        page.view.frame = NSRect(x: 0, y: 0, width: widget.size.width, height: widget.size.height)
        window.contentView = page.view
        for _ in 0..<100 where page.view.isLoading || page.view.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        page.send(.object(fields))
        try await Task.sleep(for: .milliseconds(500))
        let read = try await page.view.callAsyncJavaScript("""
            const g = document.querySelector('.pk-grow'); const before = g.scrollTop; g.scrollTop = 120
            return [getComputedStyle(g).overflowY, g.scrollHeight, g.clientHeight, g.scrollTop, before, g.classList.contains('pk-end')].join(' ')
            """, contentWorld: .page) as? String
        let line = "desk-ai-usage, 6 accounts, \(Int(widget.size.width))×\(Int(widget.size.height)): .pk-grow overflowY, scrollHeight, clientHeight, "
            + "scrollTop after 120, before, end: \(read ?? "none"); PilotKit.height() after the data: \(height)"
        try (line + "\n").write(to: dir.appending(path: "scroll.txt"), atomically: true, encoding: .utf8)
        let parts = (read ?? "").split(separator: " ")
        #expect(parts.first == "auto" && parts.count == 6)
        #expect((Double(parts[1]) ?? 0) > (Double(parts[2]) ?? 0) && parts[3] == "120", "the list does not scroll: \(line)")
        #expect(height > widget.size.height, "PilotKit.height() reads no more than the frame: \(line)")
    }

    /// Every shot on its tile (the theme's raised colour, as a solid tile draws), on a ground like the theme's wallpaper.
    static func sheet(_ shots: [String: NSImage], store: WidgetStore, theme: PilotTheme) throws -> Data {
        let rows = [["desk-weather", "desk-system", "desk-ai-usage"], ["desk-todo", "desk-calendar", "desk-clock"]]
        let gap = 28.0
        let sizes = rows.map { $0.map { store.widget($0)!.size } }
        let width = sizes.map { $0.reduce(gap) { $0 + $1.width + gap } }.max() ?? 0
        let height = sizes.reduce(gap) { $0 + ($1.map(\.height).max() ?? 0) + gap }
        let scale = 2
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        func color(_ rgb: UInt32, _ alpha: Double = 1) -> NSColor {
            NSColor(srgbRed: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, alpha: alpha)
        }
        let ground = NSGradient(colors: [color(theme.wallpaper.base), color(theme.wallpaper.glow, theme.dark ? 0.35 : 0.22), color(theme.wallpaper.base)])
        ground?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -35)
        var top = height - gap
        for (row, ids) in rows.enumerated() {
            var left = gap
            for (i, id) in ids.enumerated() {
                let size = sizes[row][i]
                let frame = NSRect(x: left, y: top - size.height, width: size.width, height: size.height)
                let tile = NSBezierPath(roundedRect: frame, xRadius: 18, yRadius: 18)
                color(theme.raised).setFill()
                tile.fill()
                NSGraphicsContext.saveGraphicsState()
                tile.addClip()
                shots[id]?.draw(in: frame)
                NSGraphicsContext.restoreGraphicsState()
                left += size.width + gap
            }
            top -= (sizes[row].map(\.height).max() ?? 0) + gap
        }
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// Each widget's data as its feed or reading would hand it.
    static func fixture(_ id: String) throws -> JSONValue {
        let now = Date.now.timeIntervalSince1970
        let text: String
        switch id {
        case "desk-weather":
            let temps = [17.9, 18.4, 19.1, 19.6, 19.4, 18.8, 18.2, 17.5, 16.9, 16.5, 16.4, 16.1, 15.8]
            let hours = temps.enumerated().map { i, t in #"{"hour": "\#(String(format: "%02d", (11 + i) % 24))", "temp": \#(t), "rain": \#([25, 43, 45, 35, 13, 13, 8, 0, 3, 0, 0, 0, 5][i]), "code": 2, "day": \#(i < 7)}"# }
            text = #"{"place": "Valletta", "unit": "°C", "wind": "km/h", "updated": "11:02", "stale": false, "#
                + #""now": {"temp": 17.9, "feels": 18.0, "code": 2, "day": true, "humidity": 83, "wind": 10.7, "rain": 25}, "#
                + #""hours": [\#(hours.joined(separator: ","))], "days": ["#
                + #"{"date": "2026-10-31", "code": 80, "high": 19.6, "low": 15.2, "rain": 45}, {"date": "2026-11-01", "code": 2, "high": 21.0, "low": 14.1, "rain": 5}, "#
                + #"{"date": "2026-11-02", "code": 0, "high": 22.3, "low": 15.0, "rain": 0}, {"date": "2026-11-03", "code": 61, "high": 18.4, "low": 13.6, "rain": 70}, "#
                + #"{"date": "2026-11-04", "code": 3, "high": 19.2, "low": 14.4, "rain": 20}]}"#
        case "desk-system":
            text = #"{"user": "robin", "host": "studio", "os": "macOS 27.2", "kernel": "Darwin 27.2.0", "arch": "arm64", "model": "Mac mini", "#
                + #""chip": "Apple M4", "cores": "10 cores (4 P, 6 E)", "gpu": "Apple M4 · 10 cores", "shell": "zsh 5.9", "packages": 210, "#
                + #""uptime": "3d 4h", "cpu": {"percent": 14, "load": "2.10"}, "memory": {"used": 17394000000, "total": 25769803776, "percent": 67}, "#
                + #""disk": {"used": 412000000000, "total": 494384795648, "percent": 83}, "battery": null}"#
        case "desk-ai-usage":
            text = #"{"installed": true, "providers": ["#
                + #"{"name": "Claude", "plan": "Max 20x", "updated": "11:02", "windows": ["#
                + #"{"label": "Session", "percent": 62, "tone": "fine", "mark": 48, "markTone": "fine", "resetsAt": \#(now + 8040), "note": "14% in reserve"}, "#
                + #"{"label": "Weekly", "percent": 78, "tone": "fine", "resetsAt": \#(now + 4.6 * 86400), "note": "On pace"}], "notes": []}, "#
                + #"{"name": "Codex", "plan": "Plus", "updated": "11:01", "windows": ["#
                + #"{"label": "Session", "percent": 23, "tone": "warn", "mark": 51, "markTone": "alert", "resetsAt": \#(now + 3300), "note": "28% in deficit"}, "#
                + #"{"label": "Weekly", "percent": 91, "tone": "fine", "mark": 67, "markTone": "fine", "resetsAt": \#(now + 2.2 * 86400)}], "#
                + #""notes": ["Limit reset credits: 1 available · expire 7 Nov"]}, "#
                + #"{"name": "Codex 2", "state": "Signed out", "windows": [], "notes": []}]}"#
        case "desk-todo":
            text = #"{"installed": true, "open": 6, "doneToday": 2, "groups": ["#
                + #"{"name": "Overdue", "items": [{"text": "Renew the car insurance", "due": "29 Oct"}]}, "#
                + #"{"name": "Today", "items": [{"text": "Ship the desk widgets", "due": "Today"}, {"text": "Reply to the review notes", "due": "Today"}]}, "#
                + #"{"name": "Upcoming", "items": [{"text": "Pay the electricity bill", "due": "Mon"}, {"text": "Read chapter four", "due": "Wed"}]}, "#
                + #"{"name": "No date", "items": [{"text": "Return the drill"}]}], "#
                + #""done": [{"text": "Water the basil"}, {"text": "Book the dentist"}]}"#
        case "desk-calendar":
            text = #"{"clock": {"time": "11:02", "date": "Saturday 31 October", "iso": "\#(Date.now.ISO8601Format())"}, "#
                + #""calendar": {"access": true, "events": [{"title": "Pilot 1.0.2 ship day", "allDay": true, "start": "00:00"}, "#
                + #"{"title": "Stand-up", "allDay": false, "start": "09:30"}, {"title": "Design review: widgets", "allDay": false, "start": "14:00"}, "#
                + #"{"title": "Gym", "allDay": false, "start": "18:30"}, {"title": "Shippers Club call", "allDay": false, "start": "20:00"}]}}"#
        default:
            text = #"{"zone": "America/New_York"}"#
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
#endif
