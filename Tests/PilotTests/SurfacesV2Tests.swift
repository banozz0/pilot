import AppKit
import Foundation
import PilotCore
import SwiftUI
import Synchronization
import Testing
@testable import Pilot

/// Surfaces v2 in Pilot (SPEC story 165): each extension's bar item its own macOS menu-bar item with its gauges, placed
/// in Bar settings; the fixture extension in Tests/Fixtures/surfaces-demo answers every new block. Runs are fakes unless a test
/// names the fixture, which is a real python3 program.
@MainActor
@Suite("Surfaces v2")
struct SurfacesV2Tests {
    /// The fixture extension's folder, in the repo.
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/surfaces-demo")

    /// A temporary Extensions folder holding a copy of the fixture, with its storage.
    static func fixtureFolder() throws -> (dir: URL, exts: URL, storage: ExtensionStorage) {
        let dir = try ExtensionSurfaceTests.folder(), exts = dir.appending(path: "Extensions")
        try FileManager.default.copyItem(at: fixture, to: exts.appending(path: "surfaces-demo"))
        return (dir, exts, ExtensionSurfaceTests.storage(dir))
    }

    nonisolated static let gauges: [Extension.Gauge] = [.init(label: "C", meters: [34, 25]), .init(label: "X", meters: [0, 67], tone: .warn)]

    // MARK: P1

    @Test("The fixture reads as one extension whose bar line carries two gauges; its section blocks are skipped by a bar that does not know them")
    func fixtureBar() async throws {
        let (dir, exts, storage) = try Self.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try #require(Extension.find(in: exts).extensions.first)
        #expect(ext.id == "surfaces-demo" && ext.bar?.command.name == "bar" && ext.page?.command.name == "page")
        let inputs = try #require(await ExtensionsModule.inputs(for: ext, storage: storage, hud: { _ in }))
        guard case .bar(let answer) = await ExtensionRun.surface(try #require(ext.bar), inputs: inputs, timeout: .seconds(10)) else {
            Issue.record("no bar answer"); return
        }
        #expect(answer.text == "2" && answer.tone == .warn && answer.gauges == Self.gauges)
    }

    @Test("Each extension's bar item is its own menu-bar item after Pilot's; placed in the top bar it leaves; a click opens its own popover")
    func ownItems() async throws {
        let store = BarItemsStore(defaults: try MenuBarStatusItemsTests.defaults()) { [:] }
        let dir = try ExtensionSurfaceTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions")
        try ExtensionSurfaceTests.write("ai", title: "AI usage", in: exts)
        try ExtensionSurfaceTests.write("git", title: "Git", in: exts)
        let asked = Mutex<[String]>([])
        let bar = ExtensionBar(folder: exts, storage: ExtensionSurfaceTests.storage(dir), run: { surface, _ in
            asked.withLock { $0.append(surface.command.id.extension) }
            return .bar(surface.command.id.extension == "ai" ? Extension.BarAnswer(text: "", gauges: Self.gauges) : Extension.BarAnswer(text: "2", tone: .warn))
        })
        bar.shows = { store.shows(extension: $0, in: $1) }
        let host = MenuBarStatusItemsTests.Host(), items = MenuBarStatusItems(store: store, host: host)
        items.start(MenuBarStatusItemsTests.sources(SystemSamplerTests.sampler(SystemSamplerTests.Counter()), extensionBar: bar))
        #expect(try await SystemSamplerTests.wait { host.shown.last?.compactMap(\.extensionID) == ["ai", "git"] })
        let ai = try #require(host.shown.last?.first { $0.extensionID == "ai" })
        #expect(ai.key == "extensions.ai" && ai.kinds == [.extensions] && ai.tooltip == "AI usage · C 34% 25% · X 0% 67%")
        #expect(host.shown.last?.first?.kinds == [.pilot], "Pilot's own icon stays first")
        items.click(ai)
        #expect(host.presentedExtensions == ["ai"] && host.presented.isEmpty)
        // Git moves to the top bar only: the menu bar loses it, and a round asks only what is placed somewhere.
        store.settings.toggle(extension: "git", in: .topBar)
        store.settings.toggle(extension: "git", in: .menuBar)
        #expect(try await SystemSamplerTests.wait { host.shown.last?.compactMap(\.extensionID) == ["ai"] })
        store.settings.set(extension: "git", on: false, placement: .topBar)
        asked.withLock { $0 = [] }
        await bar.round()
        #expect(asked.withLock { $0 }.allSatisfy { $0 != "git" }, "an item placed nowhere is not asked")
        items.stop()
    }

    @Test("The gauge icon: a template without tones, coloured with one, wider with each gauge and the text; nothing draws nothing")
    func gaugeIcon() throws {
        let plain = ExtensionBarFace(id: "a", title: "A", answer: Extension.BarAnswer(text: "", gauges: [.init(label: "C", meters: [34, 25])]))
        let toned = ExtensionBarFace(id: "a", title: "A", answer: Extension.BarAnswer(text: "2", gauges: Self.gauges))
        let one = try #require(ExtensionGaugeIcon.image(plain)), two = try #require(ExtensionGaugeIcon.image(toned))
        #expect(one.isTemplate && !two.isTemplate)
        #expect(one.size.height == 18 && two.size.width > one.size.width + ExtensionGaugeIcon.meterWidth)
        #expect(ExtensionGaugeIcon.image(ExtensionBarFace(id: "a", title: "A", answer: Extension.BarAnswer(text: ""))) == nil)
        // It draws: some pixel of the meters is ink.
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(two.size.width) * 2, pixelsHigh: 36, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = two.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        two.draw(in: NSRect(origin: .zero, size: two.size))
        NSGraphicsContext.restoreGraphicsState()
        let inked = (0..<bitmap.pixelsWide).contains { x in (0..<bitmap.pixelsHigh).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 } }
        #expect(inked)
    }

    nonisolated static let providers: [Extension.Gauge] = [.init(icon: .claude, text: "66%"), .init(icon: .openai, text: "15%")]

    @Test("Provider gauges: each glyph 14 pt and its text, 8 pt apart, a template untoned; both glyphs stay inside their square")
    func providerIcon() throws {
        let face = ExtensionBarFace(id: "ai", title: "AI usage", answer: Extension.BarAnswer(text: "", gauges: Self.providers))
        let image = try #require(ExtensionGaugeIcon.image(face))
        #expect(image.isTemplate && image.size.height == 18)
        let texts = ["66%", "15%"].map { NSAttributedString(string: $0, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]).size().width.rounded(.up) }
        #expect(ExtensionGaugeIcon.width(face) == 2 * (ExtensionGaugeIcon.glyphSize + ExtensionGaugeIcon.partGap) + texts.reduce(0, +) + ExtensionGaugeIcon.gaugeGap)
        let toned = ExtensionBarFace(id: "ai", title: "AI usage", answer: Extension.BarAnswer(text: "", gauges: [.init(tone: .alert, icon: .claude, text: "2%")]))
        #expect(try #require(ExtensionGaugeIcon.image(toned)).isTemplate == false)
        let square = CGRect(x: 3, y: 2, width: 14, height: 14)
        for icon in [Extension.Gauge.Icon.claude, .openai] {
            let drawn = ExtensionGaugeIcon.glyph(icon, in: square).boundingRect
            #expect(square.insetBy(dx: -0.01, dy: -0.01).contains(drawn) && drawn.width > 12 && drawn.height > 12, "\(icon) \(drawn)")
        }
    }

    // MARK: P2

    /// A popover model over `exts` whose runs are `answer`, each asked command and context noted.
    static func popover(_ exts: URL, storage: ExtensionStorage, shown: [Extension.Block]? = nil,
                        answer: @escaping @Sendable (String, JSONValue?) async -> SurfaceOutcome) -> ExtensionPopoverModel {
        ExtensionPopoverModel(id: "surfaces-demo", shown: shown, folder: exts, storage: storage, run: { command, context, _ in await answer(command.name, context) })
    }

    @Test("The popover shows the bar's last blocks until its own answer comes, asked with the bar command; a push stays in it with its context, back returns")
    func popoverStack() async throws {
        let (dir, exts, storage) = try Self.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asked = Mutex<[String]>([])
        let model = Self.popover(exts, storage: storage, shown: [.markdown("last bar")]) { command, context in
            asked.withLock { $0.append("\(command) \(context.map { "\($0)" } ?? "-")") }
            return command == "bar" ? .blocks([.markdown("popover")]) : .blocks([.markdown("chat")])
        }
        var acted: [String] = []
        model.act = { action, _, _ in acted.append(action.label); return nil }
        #expect(model.top.blocks == [.markdown("last bar")] && !model.canGoBack)
        await model.open()
        #expect(model.top.blocks == [.markdown("popover")] && model.top.updated != nil && asked.withLock { $0 } == ["bar -"])
        model.perform(Extension.Item.Action(kind: .push(command: "chat", context: .object(["ref": .string("s1")])), title: "Reply"))
        #expect(try await SystemSamplerTests.wait { model.top.blocks == [.markdown("chat")] })
        #expect(model.canGoBack && model.top.title == "Reply" && asked.withLock { $0 }.last == #"chat object(["ref": PilotCore.JSONValue.string("s1")])"#)
        model.back()
        #expect(!model.canGoBack && model.top.blocks == [.markdown("popover")])
        // A push to a command that is not a no-view one, and a copy, run as the extension's: nothing is pushed.
        model.perform(Extension.Item.Action(kind: .push(command: "nowhere", context: nil), title: "Elsewhere"))
        model.perform(.copy("x"))
        #expect(acted == ["Elsewhere", "Copy"] && !model.canGoBack)
    }

    @Test("A run from the popover asks its view again as the run ends, not 1.5 s later (Sven on build 23: to-do felt slow)")
    func popoverRunEnds() async throws {
        let (dir, exts, storage) = try Self.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Mutex<[String]>([])
        let model = Self.popover(exts, storage: storage) { _, _ in log.withLock { $0.append("asked") }; return .blocks([.markdown("ok")]) }
        // A run longer than the old fixed 1.5 s: asked again after it, never before it ends.
        model.act = { _, _, _ in Task { try? await Task.sleep(for: .seconds(2)); log.withLock { $0.append("ran") } } }
        await model.open()
        model.perform(Extension.Item.Action(kind: .run(command: "send", context: nil), title: "Send"))
        // The order is the promise; no 10 s deadline: a main thread held by another suite's test outlasted it (Build 65).
        #expect(try await SystemSamplerTests.wait { log.withLock { $0.count } == 3 })
        #expect(log.withLock { $0 } == ["asked", "ran", "asked"], "asked again as the run ended")
    }

    @Test("A failed ask keeps the blocks showing with the failure said; an answer for a view no longer on top is dropped")
    func popoverFailure() async throws {
        let (dir, exts, storage) = try Self.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fail = Mutex(false)
        let model = Self.popover(exts, storage: storage) { command, _ in
            if command == "slow" { try? await Task.sleep(for: .milliseconds(300)); return .blocks([.markdown("late")]) }
            return fail.withLock { $0 } ? .error("did not answer in 5 s") : .blocks([.markdown("ok")])
        }
        await model.open()
        fail.withLock { $0 = true }
        await model.refresh()
        #expect(model.top.blocks == [.markdown("ok")] && model.top.problem == "Surfaces demo did not answer in 5 s")
        let pushing = Task { await model.push("slow", title: nil, context: nil) }
        try await Task.sleep(for: .milliseconds(50))
        model.back()
        await pushing.value
        #expect(!model.canGoBack && model.top.blocks == [.markdown("ok")])
    }

    @Test("The fixture's popover answers sections with countdown meters, a list and a push button")
    func fixturePopover() async throws {
        let (dir, exts, storage) = try Self.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try #require(Extension.find(in: exts).extensions.first)
        let inputs = try #require(await ExtensionsModule.inputs(for: ext, storage: storage, hud: { _ in }))
        let outcome = await ExtensionRun.blocks(try #require(ext.noView("bar")), surface: .popover, inputs: inputs, timeout: .seconds(10))
        guard case .blocks(let blocks, _) = outcome else { Issue.record("\(outcome)"); return }
        guard case .section(let title, _, _, _, let inner, _, _) = blocks.first, case .meter(let meter) = inner.first else { Issue.record("no section"); return }
        #expect(title == "Claude" && meter.resetsAt != nil && blocks.count == 4)
        if case .buttons(let actions) = blocks.last { #expect(actions.first?.kind == .push(command: "chat", context: .object(["ref": .string("s1")]))) }
        else { Issue.record("no buttons") }
    }
}

