#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Editor A in Instrument (spec bind-editor T4 and T5, mockups a1–a11 in `~/pages/pilot-bind-editor/img/`), dark and
/// light, at the 1000×660 window and the 760×520 least one: the kinds on a free key, `gho` typed, Ghostty picked, the
/// shell form, a taken key (Replace), a keyed action (Move here), a plain combo's accent, Record listening, editing a bind
/// you set, a menu's items, a site in each browser; Suggest with AI asking, its card and no bind (spec ai-binds T2); a
/// mouse button's bind, Binds › Mouse's wheel click and a Hyper side button (Sven after Build 82). Opt-in
/// like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter BindEditorRenders`
extension SharedLook {
@MainActor
@Suite("Bind editor renders")
struct BindEditorRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// `view` at its own size once its onAppear has run (an edited bind loads its pick there), at 2x, never shown.
    static func drawn(_ view: some View) throws -> NSBitmapImageRep {
        testApp()
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        defer { w.close() }
        PanelTestSupport.pump(0.5)
        host.frame.size = host.fittingSize
        w.setContentSize(host.frame.size)
        PanelTestSupport.pump(0.3)
        host.layoutSubtreeIfNeeded()
        return try #require(snapshot(host, scale: 2))
    }

    @Test("Editor A renders a1–a17 in Instrument dark and light, and fits the least window",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let engine = try ToyboxBindsRenders().engine()
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("bind-editor-a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let look = Look.shared
        let saved = (look.style, look.themeID)
        defer { (look.style, look.themeID) = saved }
        look.style = .instrument
        engine.settings.overlayMode = .pick

        let store = engine.binds.store
        // A free Hyper key, a taken one and a keyed action to pick.
        let letters = "tujkbnmyhgiopqwerasdfzxcvl".map { Key(String($0)) }
        let free = try #require(letters.first { store.action(for: $0) == nil })
        let taken = try #require(store.trigger(for: "apps.terminal"))
        let keyed = try #require(engine.bindActions.first { $0.id != "apps.terminal" && store.trigger(for: $0.id)?.hyper == true }?.id)
        let ghostty = "apps.open:com.mitchellh.ghostty"
        // a9: a bind you set, on a key of its own.
        // The layout holds nearly every Hyper letter now: a Hyper+Shift one when none is left.
        let mine = try #require((letters + "tujkbnmyhgiopqwerasdfzxcvl".map { Key(String($0), .shift) })
            .first { store.action(for: $0) == nil && $0 != free })
        engine.binds.replace("apps.files", with: mine)

        func finder(_ query: String = "", scope: BindSearch.Kind? = nil, picked: String? = nil, ai: BindFinder.AI? = nil) -> BindFinder {
            let finder = BindFinder(query: query, scope: scope, picked: picked, ai: ai)
            finder.load(apps: AppsModule.installedApps(), actions: engine.bindActions)
            return finder
        }
        let actions = engine.bindActions
        // a10: a free Hyper+Shift key.
        let shiftFree = try #require("nmbvcxzqwertyuiop".map { Key(String($0), .shift) }.first { store.action(for: $0) == nil })
        // a10: a browser's menus as AXMenuItems reads them, "new" typed.
        let safari = "com.apple.Safari"
        let menus = MenuItemSearch.entries(BindEditorTests.bar, bundle: safari)
        // a12–a14: Suggest with AI asking, its answer's card, and an answer that binds nothing.
        let asking = finder("go to youtube in chrome", ai: BindEditorTests.slow)
        asking.ask("go to youtube in chrome") { _ in }
        let card = finder(picked: BindEditorTests.youtube)
        card.suggested = true
        let noBind = finder("make coffee", ai: BindEditorTests.ai(#"{"id": null, "reason": "A key cannot make coffee"}"#))
        noBind.ask("make coffee") { _ in }
        await BindEditorTests.settle { noBind.asking?.running == false }
        // a15–a16: the wheel click playing media (its own glyph, never Music's icon: Q552), then Back's Hyper action, new.
        let wheel = MouseTrigger(sends: MouseKeys.button(2), button: 3)
        engine.binds.setMouse(wheel.sends, to: try #require(actions.first { $0.id == "media.playPause" }?.id), button: 3)
        let back = MouseTrigger(sends: MouseKeys.button(3), button: 4, hyper: true)
        let states: [(String, (CGFloat) -> BindEditor)] = [
            ("a1-kinds", { BindEditor(action: nil, actions: actions, startKey: free, windowHeight: $0, finder: finder()) }),
            ("a2-typed", { BindEditor(action: nil, actions: actions, startKey: free, windowHeight: $0, finder: finder("gho")) }),
            ("a3-picked", { BindEditor(action: nil, actions: actions, startKey: free, windowHeight: $0, finder: finder(picked: ghostty)) }),
            ("a4-shell", { BindEditor(action: nil, actions: actions, startKey: free, windowHeight: $0, finder: finder(scope: .shell),
                                      does: .advanced, advanced: .shell, field: "open -g ~/Downloads") }),
            ("a5-replace", { BindEditor(action: nil, actions: actions, startKey: taken, windowHeight: $0, finder: finder(picked: ghostty)) }),
            ("a6-move", { BindEditor(action: nil, actions: actions, startKey: free, windowHeight: $0, finder: finder(picked: keyed)) }),
            ("a7-plain", { BindEditor(action: nil, actions: actions, startKey: Key("e", .leftAlt, hyper: false), windowHeight: $0,
                                      finder: finder(picked: "apps.clipboard")) }),
            ("a8-record", { BindEditor(action: nil, actions: actions, windowHeight: $0, finder: finder()) }),
            ("a9-edit", { BindEditor(action: "apps.files", actions: actions, windowHeight: $0, finder: finder()) }),
            ("a10-menu", { BindEditor(action: nil, actions: actions, startKey: shiftFree,
                                      windowHeight: $0, finder: finder("new", scope: .menu), does: .menu, bundle: safari,
                                      menuItems: (safari, menus)) }),
            ("a11-site", { BindEditor(action: nil, actions: actions, startKey: free, windowHeight: $0, finder: finder("chatgpt.com")) }),
            ("a12-ai-asking", { BindEditor(action: nil, actions: actions, startKey: free, windowHeight: $0, finder: asking) }),
            ("a13-ai-card", { BindEditor(action: nil, actions: actions, startKey: free, windowHeight: $0, finder: card) }),
            ("a14-ai-nobind", { BindEditor(action: nil, actions: actions, startKey: free, windowHeight: $0, finder: noBind) }),
            ("a15-mouse", { BindEditor(action: nil, actions: actions, windowHeight: $0, mouse: wheel, finder: finder()) }),
            ("a16-mouse-hyper", { BindEditor(action: nil, actions: actions, windowHeight: $0, mouse: back, finder: finder()) }),
            // a17: "play" typed for Back: the media key's rows are Pilot's own, never Music's (Q552).
            ("a17-mouse-play", { BindEditor(action: nil, actions: actions, windowHeight: $0, mouse: back, finder: finder("play")) }),
        ]
        for dark in [true, false] {
            // Instrument is dark or light as its theme is: Tokyo Night dark, Porcelain light.
            look.themeID = dark ? "tokyo-night" : "porcelain"
            for (name, editor) in states {
                for (window, height) in [("1000x660", CGFloat(660)), ("760x520", CGFloat(520))] {
                    let view = editor(height).environment(engine).styled(.page(.binds), look: look).pilotTheme(look: look)
                    let rep = try Self.drawn(view)
                    try #require(rep.representation(using: .png, properties: [:]))
                        .write(to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light")-\(window).png"))
                    let points = CGSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
                    #expect(points.width <= 560 && points.height <= height - 60, "\(name) at \(window) is \(Int(points.width))×\(Int(points.height))")
                }
            }
        }
    }
}
}
#endif
