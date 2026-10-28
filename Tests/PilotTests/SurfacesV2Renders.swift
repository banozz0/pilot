#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Surfaces v2 drawn (SPEC story 165): the gauge icon as the macOS menu bar shows it, the top bar with two extensions'
/// own items, in Instrument and Toybox; the AI usage popover (Q138 design A) and provider gauges. Opt-in like the
/// other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter SurfacesV2Renders`
extension SharedLook {
@MainActor
@Suite("Surfaces v2 renders")
struct SurfacesV2Renders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let styles: [(PilotStyle, String)] = [(.instrument, "nightwatch"), (.toybox, "toybox")]

    static func out() throws -> URL {
        let home = try #require(env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        let out = URL(fileURLWithPath: try #require(env["PILOT_RENDER_DIR"])).appendingPathComponent("surfaces-v2")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        return out
    }

    @Test("The gauge icon and the top bar's extension items render in every style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func bar() async throws {
        let out = try Self.out()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        look.glass = false
        defer { (look.themeID, look.style, look.glass) = saved }

        // The menu bar's picture, on a dark and a light strip.
        let face = ExtensionBarFace(id: "ai", title: "AI usage", answer: Extension.BarAnswer(text: "", gauges: SurfacesV2Tests.gauges))
        let icon = try #require(ExtensionGaugeIcon.image(face))
        for (name, appearance, ground) in [("dark", NSAppearance.Name.darkAqua, Color(white: 0.16)), ("light", .aqua, Color(white: 0.92))] {
            let strip = HStack(spacing: 12) {
                Image(nsImage: icon)
                Image(nsImage: try! #require(ExtensionGaugeIcon.image(ExtensionBarFace(id: "git", title: "Git", answer: Extension.BarAnswer(text: "⎇ 2", tone: .warn)))))
                Text("Sat 11:18").font(.system(size: 13))
            }
            .padding(.horizontal, 12).frame(height: 24).background(ground).environment(\.colorScheme, name == "dark" ? .dark : .light)
            NSApp.appearance = NSAppearance(named: appearance)
            try writeRender(strip, to: out.appendingPathComponent("menubar-\(name).png"), wait: 0.3)
        }
        NSApp.appearance = nil

        let (dir, exts, storage) = try SurfacesV2Tests.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ExtensionSurfaceTests.write("git", title: "Git", in: exts)
        let bar = ExtensionBar(folder: exts, storage: storage, run: { surface, _ in
            surface.command.id.extension == "git" ? .bar(Extension.BarAnswer(text: "⎇ 2", tone: .warn)) : .bar(Extension.BarAnswer(text: "", gauges: SurfacesV2Tests.gauges))
        })
        await bar.round()
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: BarReadingsTests.Sources()),
                                   readBattery: { nil }, readWiFi: { nil }, clock: { ClockRenders.now }, watchStats: { _ in Task {} },
                                   calendar: ClockCalendar { ClockPopoverTests.FakeStore() }, extensionBar: bar)
        let sources = BarSources(readings: readings, observers: EngineObservers(), sampler: .shared, keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                                 timer: ExtensionTimer(), extensionBar: bar, pilotTitle: { "2" })
        var s = BarSettings.defaults
        s.set(.clock, style: .time)
        let sides: [TopBarSide: [BarSlot]] = [.left: [.item(s.entry(.pilot))], .right: [.item(s.entry(.extensions)), .item(s.entry(.clock))]]
        for (style, theme) in Self.styles {
            (look.themeID, look.style) = (theme, style)
            let strip = TopBarStrip(sides: sides) { TopBarSlotView(slot: $0, screen: "Studio", sources: sources, store: .shared) }
                .styled(.topBar, look: look).pilotTheme(look: look).frame(width: 700, height: 32)
            try writeRender(strip, to: out.appendingPathComponent("topbar-\(style.rawValue).png"), wait: 0.6)
        }
    }

    @Test("Q138 design A: the AI usage popover as the user's 22:50 read, light and dark, and the provider gauges 4x on grey",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func codexBar() async throws {
        let out = try Self.out()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        look.glass = false
        defer { (look.themeID, look.style, look.glass) = saved }
        let (dir, exts, storage) = try SurfacesV2Tests.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let today = Calendar.current.startOfDay(for: Date()), at = { (days: Double, hours: Double) in today.addingTimeInterval((days * 24 + hours) * 3600) }
        let open = { (url: String, title: String) in Extension.Item.Action(kind: .open(url), title: title) }
        // As the ai-usage extension (3.3.0) answers a Pilot that draws notes and links.
        let blocks: [Extension.Block] = [
            .section(title: "Claude", subtitle: nil, aside: "ada", asideNote: "Max 20x", blocks: [
                .meter(.init(label: "Session", percent: 81, tone: .fine, resetsAt: at(1, 1), mark: 43, value: "81% left", markTone: .fine,
                             help: "38% in reserve · Lasts until reset")),
                .meter(.init(label: "Weekly", percent: 96, tone: .fine, resetsAt: at(7, 20), value: "96% left")),
                .meter(.init(label: "Fable weekly", percent: 100, value: "100% left", help: "Reset since your last Claude Code reply (was 0% used)")),
            ], icon: .claude, help: "ada@example.com · Updated 22:50"),
            .section(title: "Codex", subtitle: nil, aside: "ada.work", asideNote: "Plus", blocks: [
                .meter(.init(label: "Session", percent: 5, tone: .alert, resetsAt: at(0, 22 + 52 / 60), mark: 1, value: "5% left", markTone: .fine,
                             help: "4% in reserve · Lasts until reset")),
                .meter(.init(label: "Weekly", percent: 85, tone: .fine, resetsAt: at(7, 9 + 1 / 60), mark: 92, value: "85% left", markTone: .alert,
                             help: "7% in deficit · Runs out in 3d 6h")),
                .note(.init(text: "2 reset credits", aside: "next expires 29 Oct", help: "Expire 29 Oct 19:35, 6 Nov 23:11", icon: "reset")),
            ], icon: .openai, help: "ada.work@example.com · Updated 22:50"),
            .section(title: "Codex", subtitle: nil, aside: "ada.home", asideNote: "Plus", blocks: [
                .meter(.init(label: "Session", percent: 88, tone: .fine, resetsAt: at(1, 2 + 1 / 60), mark: 64, value: "88% left", markTone: .fine,
                             help: "24% in reserve · Lasts until reset · 1.5× headroom")),
                .meter(.init(label: "Weekly", percent: 83, tone: .fine, resetsAt: at(7, 15 + 57 / 60), mark: 96, value: "83% left", markTone: .alert,
                             help: "13% in deficit · Runs out in 1d 9h")),
                .note(.init(text: "3 reset credits", aside: "next expires 22 Oct", help: "Expire 22 Oct 21:42, 29 Oct 20:14, 7 Nov 00:39", icon: "reset")),
            ], icon: .openai, help: "ada.home@example.com · Updated 22:50"),
            .section(title: "Codex", subtitle: "not asked", aside: "~/.codex-pro", blocks: [], icon: .openai,
                     help: "Not asked: Pilot asks Codex only for the folders in this extension's Codex accounts setting and its own accounts, and this one has no run in 8 days."),
            .links([
                Extension.Block.Link(title: "Claude", tone: .fine, help: "Claude status: All Systems Operational", actions: [open("https://status.claude.com/", "Open Claude status page")])!,
                Extension.Block.Link(title: "Codex", tone: .warn, word: "minor", help: "Codex status: Partial System Degradation · updated 1 d ago",
                                     actions: [open("https://status.openai.com/", "Open Codex status page")])!,
                Extension.Block.Link(icon: "chart", help: "Usage dashboards", actions: [open("https://claude.ai/settings/usage", "Claude usage dashboard"),
                                                                                       open("https://chatgpt.com/codex/", "Codex usage dashboard")])!,
                Extension.Block.Link(icon: "plus", help: "Add Codex account…", actions: [open("pilot://x", "Add Codex account…")])!,
            ]),
        ]
        let item = ExtensionBar.Item(id: "surfaces-demo", title: "AI usage", icon: "📊", hasPage: true, answer: nil, problem: nil)
        for (name, theme) in [("dark", "lagoon"), ("light", "workshop")] {
            (look.themeID, look.style) = (theme, .instrument)
            let tokens = StyleTokens.of(.instrument, theme: look.theme)
            let model = SurfacesV2Tests.popover(exts, storage: storage) { _, _ in .blocks(blocks) }
            await model.open()
            try writeRender(ExtensionPopoverView(item: item, model: model).styled(.barPopovers, look: look).pilotTheme(look: look).padding(24)
                .background(Color(tokens.colors.canvas)), to: out.appendingPathComponent("ai-usage-popover-\(name).png"), wait: 0.6)
        }
        // The menu bar's picture, 4x on mid-grey: white as on a dark menu bar, black as on a light one.
        let icon = try #require(ExtensionGaugeIcon.image(ExtensionBarFace(id: "ai", title: "AI usage", answer: Extension.BarAnswer(text: "", gauges: SurfacesV2Tests.providers))))
        let big = VStack(spacing: 12) {
            ForEach([Color.white, .black], id: \.self) { ink in
                Image(nsImage: icon).resizable().renderingMode(.template).foregroundStyle(ink).frame(width: icon.size.width * 4, height: icon.size.height * 4)
            }
        }
        .padding(16).background(Color(white: 0.5))
        try writeRender(big, to: out.appendingPathComponent("codexbar-menubar-4x.png"), wait: 0.3)
    }

    /// The fixture's own answer for `command` (its popover's by default), run for real.
    static func fixtureBlocks(_ command: String = "bar", context: JSONValue? = nil, surface: Extension.Surface.Kind = .popover,
                              in exts: URL, storage: ExtensionStorage) async throws -> [Extension.Block] {
        let ext = try #require(Extension.find(in: exts).extensions.first { $0.id == "surfaces-demo" })
        let inputs = try #require(await ExtensionsModule.inputs(for: ext, storage: storage, hud: { _ in }))
        guard case .blocks(let blocks, _) = await ExtensionRun.blocks(try #require(ext.noView(command)), surface: surface, context: context, inputs: inputs,
                                                                   timeout: .seconds(10)) else { throw CancellationError() }
        return blocks
    }

    @Test("The fixture's popover renders in every style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func popover() async throws {
        let out = try Self.out()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        look.glass = false
        defer { (look.themeID, look.style, look.glass) = saved }
        let (dir, exts, storage) = try SurfacesV2Tests.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocks = try await Self.fixtureBlocks(in: exts, storage: storage)
        let item = ExtensionBar.Item(id: "surfaces-demo", title: "Surfaces demo", icon: "🧪", hasPage: true, answer: nil, problem: nil)
        for (style, theme) in Self.styles {
            (look.themeID, look.style) = (theme, style)
            let model = SurfacesV2Tests.popover(exts, storage: storage) { _, _ in .blocks(blocks) }
            await model.open()
            let tokens = StyleTokens.of(style, theme: look.theme)
            try writeRender(ExtensionPopoverView(item: item, model: model).styled(.barPopovers, look: look).pilotTheme(look: look).padding(24)
                .background(Color(tokens.colors.canvas)), to: out.appendingPathComponent("popover-\(style.rawValue).png"), wait: 0.6)
        }
    }

    @Test("P3: the fixture's chat with its reply box in the popover, the page with its pane, the three asks, and a row's inline buttons and badges render in every style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func interactive() async throws {
        let out = try Self.out()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        look.glass = false
        defer { (look.themeID, look.style, look.glass) = saved }
        let (dir, exts, storage) = try SurfacesV2Tests.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref: JSONValue = .object(["ref": .string("s1")])
        let bar = try await Self.fixtureBlocks(in: exts, storage: storage)
        let chat = try await Self.fixtureBlocks("chat", context: ref, in: exts, storage: storage)
        let page = try await Self.fixtureBlocks("page", surface: .page, in: exts, storage: storage)
        let item = ExtensionBar.Item(id: "surfaces-demo", title: "Surfaces demo", icon: "🧪", hasPage: true, answer: nil, problem: nil)
        let rename = Extension.Item.Action(kind: .run(command: "rename", context: ref), title: "Rename…", ask: .text("Pilot coordinator 2"))
        let tag = Extension.Item.Action(kind: .run(command: "tag", context: ref), title: "Tag",
                                        ask: .choices([.init(title: "review", value: "review"), .init(title: "No tag", value: "none")]))
        let close = Extension.Item.Action(kind: .run(command: "close", context: ref), title: "Close…", destructive: true,
                                          ask: .confirm("Close Pilot coordinator 2? Its terminal ends."))
        let inline = [Extension.Item.Action(kind: .run(command: "reply", context: ref), title: "Reply", icon: "bubble"),
                      Extension.Item.Action(kind: .run(command: "close", context: ref), title: "Close", icon: "xmark", destructive: true),
                      Extension.Item.Action(kind: .run(command: "stop", context: ref), title: "Stop", destructive: true)]
        for (style, theme) in Self.styles {
            (look.themeID, look.style) = (theme, style)
            let tokens = StyleTokens.of(style, theme: look.theme)
            // The popover, pushed to the chat.
            let model = SurfacesV2Tests.popover(exts, storage: storage) { command, _ in .blocks(command == "chat" ? chat : bar) }
            await model.open()
            await model.push("chat", title: "Pilot coordinator 2", context: ref)
            try writeRender(ExtensionPopoverView(item: item, model: model).styled(.barPopovers, look: look).pilotTheme(look: look).padding(24)
                .background(Color(tokens.colors.canvas)), to: out.appendingPathComponent("popover-chat-\(style.rawValue).png"), wait: 0.6)
            // The page, its rows' badges and inline buttons, the chat in its pane.
            let pageModel = ExtensionPageModel(id: "surfaces-demo", folder: exts, storage: storage, run: { _, _ in .blocks(page) })
            await pageModel.refresh()
            await pageModel.open("chat", title: "Pilot coordinator 2", context: ref, run: { _, _, _ in .blocks(chat, refresh: 2) })
            let view = SurfaceGround { ExtensionSurfacePage(id: "surfaces-demo", onScreen: false, model: pageModel) { _ in }.frame(width: 1100, height: 860) }
                .styled(.page(.extensions), look: look).pilotTheme(look: look)
            try writeRender(view, to: out.appendingPathComponent("page-pane-\(style.rawValue).png"), wait: 0.8)
            // The three asks, in a row's place.
            let asks = VStack(alignment: .leading, spacing: 12) {
                ForEach([rename, tag, close].indices, id: \.self) { i in
                    ExtensionAskView(asking: Extension.Asking([rename, tag, close][i])!, compact: true) { _ in }
                }
                // A row's inline buttons, the destructive ones red, by icon from Pilot's list or by title; its badges.
                HStack(spacing: 4) {
                    ForEach(inline.indices, id: \.self) { i in ExtensionInlineButton(action: inline[i], compact: true) {} }
                    Spacer()
                    ExtensionBadges(badges: [.init(text: "idle"), .init(text: "review", tone: .warn)], compact: true)
                }
            }
            .frame(width: 320).padding(14).styled(.barPopovers, look: look).pilotTheme(look: look).background(Color(tokens.colors.canvas))
            try writeRender(asks, to: out.appendingPathComponent("asks-\(style.rawValue).png"), wait: 0.4)
        }
    }
}
}
#endif
