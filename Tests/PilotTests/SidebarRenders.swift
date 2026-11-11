#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The window's areas (Sven 2026-10-16): Ask and Extensions are areas of their own (Cmd+8 and Cmd+9 since Launcher took Cmd+3, P37), and the Extensions
/// area lists every installed extension under its page, a bar-only one (Now playing) and one with neither among them.
/// Drawn in the whole window, rail and toolbar tabs, Instrument on Tokyo Night and Toybox, at 1440 by 900, and the rail at 760
/// tall. A fake Extensions folder in the moved home; nothing runs.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter SidebarRenders`
extension SharedLook {
@MainActor
@Suite("SidebarRenders", .timeLimit(.minutes(1)))
struct SidebarRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// Sven's twelve as the shot shows them: six with a page, Now playing with a bar item alone, five with neither.
    static func seed(_ folder: URL) throws {
        let paged = [("ai-usage", "AI usage", "📊"), ("ghostex", "Ghostex sessions", "👻"), ("git", "lazygit", "🌿"), ("markets", "Markets", "📈"),
                     ("todo", "To-do", "✅"), ("weather", "Weather", "⛅")]
        for (id, title, icon) in paged { try manifest(id, title, icon, surfaces: #"{"page": {"command": "go"}}"#, in: folder) }
        try manifest("now-playing", "Now playing", "🎵", surfaces: #"{"bar": {"command": "go"}}"#, in: folder)
        for (id, title, icon) in [("claude-sessions", "Claude sessions", "🤖"), ("easy-cd", "Easy cd", "📁"), ("obsidian-search", "Obsidian search", "🔮"),
                                  ("ports", "Open ports", "🔌"), ("ssh-hosts", "SSH hosts", "🖥️")] {
            try manifest(id, title, icon, surfaces: nil, in: folder)
        }
    }

    static func manifest(_ id: String, _ title: String, _ icon: String, surfaces: String?, in folder: URL) throws {
        let declared = surfaces.map { #", "surfaces": \#($0)"# } ?? ""
        try ExtensionCatalogueModelTests.write(#"{"id": "\#(id)", "title": "\#(title)", "icon": "\#(icon)"\#(declared), "commands": [{"name": "go", "title": "\#(title)", "mode": "no-view", "run": "run"}]}"#,
                                               as: id, in: folder)
    }

    @Test("Ask and Extensions are areas; Extensions lists every installed extension", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let engine = try ToyboxBindsRenders().engine()
        try Self.seed(Extension.folder)
        await ExtensionPages.shared.reload()
        try #require(ExtensionPages.shared.entries.count == 12)
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("sidebar")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let look = Look.shared
        let saved = (look.themeID, look.style, look.windowShape, look.glass)
        defer { (look.themeID, look.style, look.windowShape, look.glass) = saved }
        look.glass = false

        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        var sources = AIPageSources()
        sources.send = {}
        let settings = try AIRenders.settings(picked: .claudeCode), chat = AIChatModel()
        sources.settings = { settings }
        sources.chat = { chat }
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model)
            .environment(engine).environment(\.aiPageSources, sources)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)

        func shot(_ file: String, width: Int, height: Int, go: () -> Void) throws {
            window.setContentSize(NSSize(width: CGFloat(width), height: CGFloat(height)))
            model.go(AppPlace(.home))
            PanelTestSupport.pump(0.2)
            go()
            PanelTestSupport.pump(0.9)
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 1))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
        }

        for (name, style, theme) in [("instrument", PilotStyle.instrument, "tokyo-night"), ("toybox", .toybox, "toybox")] {
            (look.style, look.themeID) = (style, theme)
            for shape in WindowShape.allCases {
                look.windowShape = shape
                AppWindowController.applyLook(look, to: window)
                try shot("\(shape.rawValue)-\(name)-extensions-1440", width: 1440, height: 900) { model.go(AppPlace(.extensions)) }
                try shot("\(shape.rawValue)-\(name)-now-playing-1440", width: 1440, height: 900) { model.goExtensionPage("now-playing") }
                if shape == .rail {
                    try shot("rail-\(name)-ask-1440", width: 1440, height: 900) { model.go(AppPlace(.ai)) }
                    try shot("rail-\(name)-tools-1440", width: 1440, height: 900) { model.go(AppPlace(.clipboard)) }
                    try shot("rail-\(name)-extensions-1100x760", width: 1100, height: 760) { model.go(AppPlace(.extensions)) }
                }
            }
        }
    }
}
}
#endif
