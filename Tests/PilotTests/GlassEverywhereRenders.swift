#if DEBUG
import AppKit
import Darwin
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Glass everywhere (Sven, 2026-10-19, Q356), opt-in like the other renders: the Keys page in the app window, the Line
/// menu, clipboard history, quick notes and Quick AI, drawn by Pilot's own code at Solid and Glass in Instrument on the
/// picked theme. Offscreen an NSGlassEffectView draws only a flat grey, never what is behind it (the probe says so), so
/// each glass view is hidden for the draw and its frame, corner and tint are written to meta.json beside the layer; the
/// comparison page's script lays the layer over a wallpaper with the glass emulated there. Sven's screen proves the real
/// material.
/// `CFFIXED_USER_HOME=<fresh> PILOT_RENDER_DIR=<fresh> swift test --filter GlassEverywhereRenders`
extension SharedLook {
@MainActor
@Suite("Glass everywhere renders")
struct GlassEverywhereRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("NSGlassEffectView, regular and clear, draws only a flat grey into an offscreen bitmap", .enabled(if: env["PILOT_RENDER_DIR"] != nil))
    func probe() throws {
        testApp()
        for style in [NSGlassEffectView.Style.regular, .clear] {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
            glass.style = style
            glass.tintColor = NSColor.red.withAlphaComponent(0.5)
            let w = NSWindow(contentRect: glass.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.contentView = glass
            defer { w.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let rep = try #require(snapshot(glass, scale: 1))
            print("GLASS-PROBE style=\(style == .regular ? "regular" : "clear") centre=\(rep.colorAt(x: 100, y: 60).map(String.init(describing:)) ?? "-")")
        }
    }

    /// The process's physical footprint in bytes, what Activity Monitor's Memory column shows.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    @Test("Memory: the clipboard panel open and drawn, Solid against Glass, in this process",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func memory() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require((NSHomeDirectory() as NSString).resolvingSymlinksInPath == (home as NSString).resolvingSymlinksInPath,
                     "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass, look.transparency)
        defer { (look.style, look.themeID, look.glass, look.transparency) = saved }
        (look.style, look.themeID, look.transparency) = (.instrument, "void", 100)
        let db = FileManager.default.temporaryDirectory.appending(path: "pilot-render-glass-mem-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } }
        let clips = try ClipboardTabsRenders.sampleStore(at: db)
        func open(_ glass: Bool) throws -> Int {
            look.glass = glass
            let model = PanelModel(store: clips)
            let before = Self.footprint()
            let panel = HUD.makePanel(ClipboardPanelView(model: model, returnCopies: false), surface: .clipboard)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let content = try #require(panel.contentView)
            content.layoutSubtreeIfNeeded()
            _ = snapshot(content, scale: 2)
            let open = Self.footprint() - before
            panel.close()
            return open
        }
        _ = try open(false); _ = try open(true)   // warm both paths once
        var solid: [Int] = [], glass: [Int] = []
        for _ in 0..<4 { solid.append(try open(false)); glass.append(try open(true)) }
        let kb = { (xs: [Int]) in xs.sorted()[xs.count / 2] / 1024 }
        print("GLASS-MEMORY clipboard panel open, median of 4: solid=\(kb(solid)) KB glass=\(kb(glass)) KB (solid \(solid.map { $0 / 1024 }), glass \(glass.map { $0 / 1024 }))")
    }

    /// Every NSGlassEffectView under `view`, taken out, with its frame in `root`'s top-left coordinates, its corner and tint.
    static func hideGlass(in view: NSView, root: NSView) -> [[String: Any]] {
        var found: [[String: Any]] = []
        func walk(_ v: NSView) {
            if let g = v as? NSGlassEffectView {
                let r = root.convert(g.bounds, from: g)
                let top = root.isFlipped ? r.minY : root.bounds.height - r.maxY
                let tint = g.tintColor?.usingColorSpace(.sRGB)
                found.append(["x": r.minX, "y": top, "w": r.width, "h": r.height, "radius": g.cornerRadius,
                              "tint": tint.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent].map(Double.init) } ?? []])
                gone.append(g)
            }
            v.subviews.forEach(walk)
        }
        var gone: [NSGlassEffectView] = []
        walk(view)
        // Hidden is not enough: cacheDisplay still draws a hidden glass view's flat grey. The surface is drawn once and
        // closed, so the views go.
        gone.forEach { $0.removeFromSuperview() }
        return found
    }

    @Test("The surfaces at Solid and Glass, as layers and glass frames for the comparison page",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require((NSHomeDirectory() as NSString).resolvingSymlinksInPath == (home as NSString).resolvingSymlinksInPath,
                     "the home directory did not move; refusing to touch Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("glass-everywhere")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let only = Self.env["PILOT_RENDER_ONLY"]

        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass, look.transparency)
        defer { (look.style, look.themeID, look.glass, look.transparency) = saved }
        look.style = .instrument
        look.themeID = Self.env["PILOT_THEME"] ?? "void"
        look.transparency = Int(Self.env["PILOT_TRANSPARENCY"] ?? "100") ?? 100

        let engine = try ToyboxBindsRenders().engine()
        let db = FileManager.default.temporaryDirectory.appending(path: "pilot-render-glass-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } }
        let clips = try ClipboardTabsRenders.sampleStore(at: db)
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-render-glass-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = try NotesPanelRenders.seed(folder)
        let hero = try #require(try notes.load().first { $0.title == "Ship the notes panel" })
        let menuState = try #require(try LineMenuRenders.states().first { $0.0 == "L1-root" }?.1)
        let chat = await AIChatPanelRenders.model(AIChatPanelRenders.turns, streaming: false)
        defer { chat.clear() }

        var meta: [[String: Any]] = []
        func write(_ rep: NSBitmapImageRep, _ name: String, glass: [[String: Any]], ground: NSColor? = nil) throws {
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
            var entry: [String: Any] = ["file": "\(name).png", "surface": String(name.split(separator: "-")[0]),
                                        "finish": String(name.split(separator: "-")[1]), "glass": glass]
            if let g = ground?.usingColorSpace(.sRGB) { entry["ground"] = [g.redComponent, g.greenComponent, g.blueComponent].map(Double.init) }
            meta.append(entry)
        }
        /// A panel's content drawn at 2x with its glass hidden, after `wait` seconds.
        func panelShot(_ panel: NSPanel, wait: Double) async throws -> (NSBitmapImageRep, [[String: Any]]) {
            defer { panel.close() }
            let content = try #require(panel.contentView)
            try await Task.sleep(for: .seconds(wait))
            if let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor {
                editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
            }
            content.layoutSubtreeIfNeeded()
            let glass = Self.hideGlass(in: content, root: content)
            content.display()
            return (try #require(snapshot(content, scale: 2)), glass)
        }

        for glassOn in [false, true] {
            look.glass = glassOn
            let tag = glassOn ? "glass" : "solid"
            func wanted(_ name: String) -> Bool { only.map(name.contains) ?? true }
            if glassOn {
                let l = look.layers
                print("GLASS-LAYERS ground=\(l.ground) sidebar=\(l.sidebar) card=\(l.card) raised=\(l.raised) keyFree=\(l.keyFree) "
                      + "tint=\(look.glassTint(on: .window)) barShare=\(TopBarColour.tintAlpha(look))")
            }

            if wanted("keys-\(tag)") {
                let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
                let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
                defer { window.close() }
                let backdrop = try #require(window.contentView as? MaterialBackdrop)
                window.setContentSize(NSSize(width: 1440, height: 900))
                model.go(AppPlace(.binds))
                AppWindowController.applyLook(look, to: window)
                try await Task.sleep(for: .seconds(1.2))
                backdrop.layoutSubtreeIfNeeded()
                let glass = Self.hideGlass(in: backdrop, root: backdrop)
                let rep = try #require(snapshot(backdrop.content, scale: 2))
                try write(rep, "keys-\(tag)", glass: glass, ground: window.isOpaque ? window.backgroundColor : nil)
            }
            if wanted("menu-\(tag)") {
                let panel = PilotMenu.makePanel(menuState)
                PilotMenu.fit(panel, face: menuState.instrumentSize)
                let (rep, glass) = try await panelShot(panel, wait: 0.6)
                try write(rep, "menu-\(tag)", glass: glass)
            }
            if wanted("clipboard-\(tag)") {
                let model = PanelModel(store: clips)
                model.tab = .kind(.all)
                let (rep, glass) = try await panelShot(HUD.makePanel(ClipboardPanelView(model: model, returnCopies: false), surface: .clipboard), wait: 0.6)
                try write(rep, "clipboard-\(tag)", glass: glass)
            }
            if wanted("notes-\(tag)") {
                let model = NotesModel(store: notes, defaults: try #require(UserDefaults(suiteName: testSuite())))
                model.reload()
                model.open(hero.id)
                let panel = HUD.makePanel(NotesPanelView(model: model).frame(width: NotesPanel.defaultSize.width,
                                                                             height: NotesPanel.defaultSize.height), surface: .notes)
                let (rep, glass) = try await panelShot(panel, wait: 0.6)
                try write(rep, "notes-\(tag)", glass: glass)
            }
            if wanted("ai-\(tag)") {
                // As Ask AI's drop shows it: the chat on its backdrop (AIChatPanel.backdrop), its glass hidden for the draw.
                let host = NSHostingView(rootView: AIChatPanel.content(chat, look: look))
                host.frame.size = host.fittingSize
                let backdrop = AIChatPanel.backdrop(host, look: look)
                let w = NSWindow(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.isOpaque = false
                w.backgroundColor = .clear
                w.contentView = backdrop
                defer { w.close() }
                try await Task.sleep(for: .seconds(0.6))
                backdrop.layoutSubtreeIfNeeded()
                let glass = Self.hideGlass(in: backdrop, root: backdrop)
                try write(try #require(snapshot(backdrop, scale: 2)), "ai-\(tag)", glass: glass)
            }
        }
        let existing = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json")))) as? [[String: Any]] ?? []
        let files = Set(meta.compactMap { $0["file"] as? String })
        let merged = existing.filter { !files.contains($0["file"] as? String ?? "") } + meta
        try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("meta.json"))
    }
}
}
#endif
