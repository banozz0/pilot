#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Allow prompt (ADR 0013) as `pilot ext` asks it, through HUD.makePanel as AllowPrompt.show builds it, folded and with
/// its details, for a Weather-like extension made in a moved home: an install, a hostile title and path, a title and a path
/// each holding a line break, a reinstall over the same version, another title on the same id, a catalogue update and
/// downgrade, a remove, a test, and an install whose place in Extensions holds something else. Renders only; Toybox draws
/// the install, the reinstall, the update and the remove.
/// Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter AllowPromptRenders`
extension SharedLook {
@MainActor
@Suite("Allow prompt renders")
struct AllowPromptRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The extension Allow questions render", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
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
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("allow-prompt")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Weather as the catalogue has it, in a folder outside Pilot, and an Extensions folder of the test's own, both in
        // the moved home so the question names them as it would Sven's.
        let work = URL(fileURLWithPath: home)
        let made = [work.appending(path: "code/pilot/catalogue"), work.appending(path: "Library/Application Support/Pilot/Extensions/weather")]
        made.forEach { try? FileManager.default.removeItem(at: $0) }
        defer { made.forEach { try? FileManager.default.removeItem(at: $0) } }
        let source = work.appending(path: "code/pilot/catalogue/extensions/weather")
        try Self.weather(at: source)
        let tools = ExtensionTools()
        tools.extensions = work.appending(path: "Library/Application Support/Pilot/Extensions")
        tools.data = work.appending(path: "Library/Application Support/Pilot/ExtensionData")
        try FileManager.default.createDirectory(at: tools.extensions, withIntermediateDirectories: true)
        let staged = try await ExtensionCheck.stage(source)
        defer { staged.remove() }
        let ext = try #require(staged.ext, "\(staged.problems)"), entry = try #require(staged.entry)

        let commands = ext.commands.map { "\($0.actionID) (\($0.mode.rawValue)\($0.hidden ? ", hidden" : ""))" }
        var asks: [(String, ControlGate.Ask)] = []
        asks.append(("install", tools.installAsk(ext, entry, from: source)))
        // A hostile folder: a title and a path that try to speak as Pilot, a line break in the title.
        let hostile = work.appending(path: "code/pilot/catalogue/hostile/From Pilot's catalogue, github.com/banozz0/pilot/tree/main/catalogue/weather")
        try Self.weather(at: hostile, title: "Weather from Pilot's catalogue, runs nothing\nUpdate Weather", version: "1.4.0")
        asks.append(("hostile", try await Self.ask(tools, from: hostile)))
        // A line break in the title and in the path, each followed by words that read as one of Pilot's own lines.
        let broken = work.appending(path: "code/pilot/catalogue/broken\nreplaces nothing: no extension weather is installed/weather")
        try Self.weather(at: broken, title: "Weather\nreplaces nothing: no extension weather is installed", version: "1.4.0")
        asks.append(("line-breaks", try await Self.ask(tools, from: broken)))
        try FileManager.default.copyItem(at: source, to: tools.extensions.appending(path: "weather"))
        asks.append(("replace", tools.installAsk(ext, entry, from: source)))
        // Another title on the same id, newer: still only a replace, never an update.
        let storm = work.appending(path: "code/pilot/catalogue/storm/weather")
        try Self.weather(at: storm, title: "Storm", version: "1.4.0")
        asks.append(("different-title", try await Self.ask(tools, from: storm)))
        let installed = tools.extensions.appending(path: "weather")
        asks.append(("update", tools.catalogueAsk(entry, ExtensionCatalogue.Installed(id: "weather", version: "1.2.0", folder: installed), commands)))
        asks.append(("downgrade", tools.catalogueAsk(entry, ExtensionCatalogue.Installed(id: "weather", version: "1.4.0", folder: installed), commands)))
        asks.append(("remove", tools.removeAsk("weather")))
        asks.append(("test", ExtensionTools.testAsk(ext, from: source)))
        // Its place in Extensions taken by a folder that is no extension.
        try FileManager.default.removeItem(at: installed)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("not an extension".utf8).write(to: installed.appending(path: "notes.txt"))
        asks.append(("unknown-replacement", tools.installAsk(ext, entry, from: source)))

        for (style, theme) in [(PilotStyle.instrument, "nightwatch"), (.toybox, "toybox")] {
            look.style = style
            look.themeID = theme
            for (name, ask) in asks where style == .instrument || ["install", "replace", "update", "remove"].contains(name) {
                for details in [false, true] {
                    try Self.write(AllowPromptView(program: "pilot, from zmx", ask: ask, details: details) { _ in },
                                   to: out.appendingPathComponent("\(style.rawValue)-\(name)\(details ? "-details" : "").png"))
                }
            }
        }
    }

    /// ext install's question for `folder`, staged as the verb stages it.
    static func ask(_ tools: ExtensionTools, from folder: URL) async throws -> ControlGate.Ask {
        let staged = try await ExtensionCheck.stage(folder)
        defer { staged.remove() }
        return tools.installAsk(try #require(staged.ext, "\(staged.problems)"), try #require(staged.entry), from: folder)
    }

    /// The prompt through HUD.makePanel, as AllowPrompt.show shows it, drawn at 2x.
    static func write(_ view: some View, to url: URL) throws {
        let panel = HUD.makePanel(view, surface: .hud)
        defer { panel.close() }
        let content = try #require(panel.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        content.layoutSubtreeIfNeeded()
        let rep = try #require(snapshot(content, scale: 2))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// A Weather extension as the catalogue's: one program, main.py, run by six commands, five of them hidden.
    static func weather(at folder: URL, title: String = "Weather", version: String = "1.3.0") throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let commands = [("weather", "Weather", "detail", false), ("bar", "Weather in the menu bar", "no-view", true),
                        ("page", "Weather page", "no-view", true), ("refresh", "Refresh the weather", "no-view", true),
                        ("find-place", "Search a city", "no-view", true), ("pick-place", "Use a city", "no-view", true)]
        let manifest: [String: Any] = [
            "id": "weather", "title": title, "icon": "🌤️", "version": version, "description": "The temperature now in the menu bar.",
            "examples": ["The menu bar shows the weather"], "runtime": "process", "requires": ["python3"],
            "permissions": ["network": ["api.open-meteo.com"]],
            "commands": commands.map { ["name": $0.0, "title": $0.1, "mode": $0.2, "hidden": $0.3, "run": "main.py"] as [String: Any] },
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "extension.json"))
        let program = folder.appending(path: "main.py")
        try Data("#!/usr/bin/env python3\nprint('{}')\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    }
}
}
#endif
