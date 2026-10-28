import AppKit
import Foundation
import PilotCore
import Synchronization
import SwiftUI
import Testing
@testable import Pilot

/// A page's edits (2026-10-17, Markets): a row's move runs its list's reorder command with `{key, to}` and the page asks
/// again; a live input waits out its pause, a newer text cancels the run waiting or in flight, and an answer asked
/// before a change never shows over the one asked after it. The clock and the runs are fakes.
@MainActor
@Suite("Page edits")
struct PageEditsTests {
    nonisolated static let manifest = #"{"id": "markets", "title": "Markets", "icon": "📈", "surfaces": {"page": {"command": "page", "every": 120}}, "commands": [{"name": "page", "title": "Page", "mode": "no-view", "hidden": true, "run": "run"}, {"name": "find", "title": "Find", "mode": "no-view", "hidden": true, "run": "run"}, {"name": "move", "title": "Move", "mode": "no-view", "hidden": true, "run": "run"}]}"#

    nonisolated static let reorder = Extension.Block.Reorder(command: "move")
    nonisolated static let find = Extension.Item.Action(kind: .run(command: "find", context: nil), title: "Search")

    nonisolated static func rows(_ ids: [String]) -> Extension.Block {
        .list(title: nil, items: ids.map { Extension.Item(id: $0, title: $0, actions: [.open("https://example.com/\($0)")]) }, reorder: reorder)
    }

    /// A temporary folder with the Markets-like extension, its storage, and the page asked once.
    static func page(_ run: @escaping @Sendable (Extension.Surface, ExtensionRun.Inputs) async -> SurfaceOutcome) async throws
        -> (dir: URL, model: ExtensionPageModel) {
        let dir = try ExtensionSurfaceTests.folder(), exts = dir.appending(path: "Extensions")
        try ExtensionCatalogueModelTests.write(manifest, as: "markets", in: exts)
        let model = ExtensionPageModel(id: "markets", folder: exts, storage: ExtensionSurfaceTests.storage(dir), run: run)
        await model.refresh()
        return (dir, model)
    }

    /// Page asks counted, each held until the test lets it answer when `held` says so.
    final class Asks: Sendable {
        private let state = Mutex<(count: Int, waiting: [Int: CheckedContinuation<Void, Never>], open: Set<Int>)>((0, [:], []))
        var count: Int { state.withLock { $0.count } }

        /// Counts an ask and returns its number, from 1.
        func next() -> Int { state.withLock { $0.count += 1; return $0.count } }

        func hold(_ ask: Int) async {
            await withCheckedContinuation { c in
                let now = state.withLock { s -> Bool in
                    if s.open.contains(ask) { return true }
                    s.waiting[ask] = c
                    return false
                }
                if now { c.resume() }
            }
        }

        func open(_ ask: Int) {
            state.withLock { s in s.open.insert(ask); return s.waiting.removeValue(forKey: ask) }?.resume()
        }
    }

    /// A fake clock: each pause waits until `open`, and says how long it was asked to be.
    @MainActor final class Pauses {
        private(set) var asked: [Duration] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var count: Int { waiting.count }

        func sleep(_ pause: Duration) async {
            asked.append(pause)
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            let all = waiting
            waiting = []
            all.forEach { $0.resume() }
        }
    }

    @Test("A move runs the reorder's command with the row's id as key and its new place as to, then the page asks again and shows that answer")
    func move() async throws {
        let asks = Asks()
        let (dir, model) = try await Self.page { _, _ in
            asks.next() == 1 ? .blocks([Self.rows(["SPY", "BTC", "ETH"])]) : .blocks([Self.rows(["BTC", "ETH", "SPY"])])
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        var ran: [Extension.Item.Action] = []
        await model.change(Self.reorder.action(key: "SPY", to: 2), act: { action, ext, _ in
            ran.append(action)
            #expect(ext.id == "markets")
            return Task {}
        })
        #expect(ran.map(\.kind) == [.run(command: "move", context: .object(["key": .string("SPY"), "to": .number(2)]))])
        #expect(asks.count == 2 && model.blocks == [Self.rows(["BTC", "ETH", "SPY"])], "asked again once the move ran, its answer drawn")
    }

    @Test("Two quick moves run one after the other, never at once, in the order made")
    func movesInTurn() async throws {
        let (dir, model) = try await Self.page { _, _ in .blocks([]) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Mutex<[String]>([])
        func act(_ action: Extension.Item.Action, _: Extension, _: ExtensionRun.Inputs) -> Task<Void, Never>? {
            guard case .run(_, .object(let context)?) = action.kind, case .string(let key)? = context["key"] else { return nil }
            return Task.detached {
                log.withLock { $0.append("start \(key)") }
                try? await Task.sleep(for: .milliseconds(40))
                log.withLock { $0.append("end \(key)") }
            }
        }
        let first = Task { await model.change(Self.reorder.action(key: "SPY", to: 1), act: act) }
        let second = Task { await model.change(Self.reorder.action(key: "BTC", to: 0), act: act) }
        await first.value
        await second.value
        let order = log.withLock { $0 }
        #expect(order == ["start SPY", "end SPY", "start BTC", "end BTC"] || order == ["start BTC", "end BTC", "start SPY", "end SPY"], "\(order)")
    }

    @Test("A grip's drag carries its reorder's command and the row's id; a drop of other text, or another list's row, moves nothing")
    func dragPayload() {
        let payload = ExtensionBlocksView.payload("NASDAQ:AAPL", by: Self.reorder)
        #expect(ExtensionBlocksView.dragged(payload, by: Self.reorder) == "NASDAQ:AAPL")
        #expect(ExtensionBlocksView.dragged(payload, by: .init(command: "sort")) == nil)
        #expect(ExtensionBlocksView.dragged("SPY", by: Self.reorder) == nil && ExtensionBlocksView.dragged("pilot-move\tmove", by: Self.reorder) == nil)
        #expect(ExtensionBlocksView.dragged("pilot-move\tmove\ta\tb", by: Self.reorder) == "a\tb", "an id may hold a tab")
    }

    @Test("Typing waits out the pause: three quick changes run once, with the last text, after one 250 ms pause each; nothing waits before the first")
    func debounce() async throws {
        let asks = Asks()
        let (dir, model) = try await Self.page { _, _ in _ = asks.next(); return .blocks([]) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let pauses = Pauses(), ran = Mutex<[String?]>([])
        model.sleep = { await pauses.sleep($0) }
        model.quiet = { _, _, input, _ in ran.withLock { $0.append(input) }; return .hud("Markets: 3 found") }
        let input = Extension.Block.Input(action: Self.find, live: .milliseconds(250))
        #expect(pauses.count == 0, "idle: nothing waits")
        for text in ["b", "bt", " btc "] { model.typed(input.typed(text), pause: input.live) }
        #expect(try await SystemSamplerTests.wait(seconds: 5) { pauses.count == 3 })
        #expect(ran.withLock { $0 }.isEmpty, "nothing runs before the pause ends")
        pauses.open()
        await model.settled()
        #expect(ran.withLock { $0 } == ["btc"] && pauses.asked == Array(repeating: .milliseconds(250), count: 3))
        #expect(asks.count == 2, "the page asked once after the run")
    }

    @Test("A newer text cancels the run in flight: its answer is never drawn and it says nothing; the newer run's is")
    func cancelsInFlight() async throws {
        let asks = Asks()
        let (dir, model) = try await Self.page { _, _ in _ = asks.next(); return .blocks([]) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let ran = Mutex<[String]>([]), cancelled = Mutex<[String]>([])
        model.quiet = { _, _, input, _ in
            let text = input ?? ""
            ran.withLock { $0.append(text) }
            guard text == "ap" else { return .hud(nil) }
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { cancelled.withLock { $0.append(text) } }
            return .failed("cancelled")
        }
        model.typed(Self.find.answered("ap"), pause: nil)
        #expect(try await SystemSamplerTests.wait(seconds: 5) { ran.withLock { $0 } == ["ap"] })
        model.typed(Self.find.answered("app"), pause: nil)
        await model.settled()
        #expect(try await SystemSamplerTests.wait(seconds: 5) { cancelled.withLock { $0 } == ["ap"] }, "the run in flight was cancelled")
        #expect(ran.withLock { $0 } == ["ap", "app"] && asks.count == 2, "one ask after the newer run, none after the cancelled one")
        #expect(model.problem == nil)
    }

    @Test("An ask in flight when a live run changes the page is dropped, never drawn, and the page asks again after the run and draws that")
    func staleAnswer() async throws {
        let asks = Asks()
        let (dir, model) = try await Self.page { _, _ in
            let ask = asks.next()
            if ask > 1 { await asks.hold(ask) }
            return .blocks([.markdown(["v0", "old", "new"][min(ask, 3) - 1])])
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        model.quiet = { _, _, _, _ in .hud(nil) }
        let periodic = Task { await model.refresh() }
        #expect(try await SystemSamplerTests.wait(seconds: 5) { asks.count == 2 })
        model.typed(Self.find.answered("btc"), pause: nil)
        try await Task.sleep(for: .milliseconds(50))
        asks.open(2)
        #expect(try await SystemSamplerTests.wait(seconds: 5) { asks.count == 3 }, "asked again after the live run")
        #expect(model.blocks == [.markdown("v0")], "the answer asked before the run is never drawn")
        asks.open(3)
        await model.settled()
        await periodic.value
        #expect(model.blocks == [.markdown("new")] && asks.count == 3)
    }
}

#if DEBUG
extension SharedLook {
/// The page edits drawn: Markets' page with its live search box and its watchlist, each row's grip at its left (a row
/// without an id has none), in Instrument and Toybox. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter PageEditsRenders`
@MainActor
@Suite("Page edits renders")
struct PageEditsRenders {
    @Test("A page with a live search box and a reorderable list renders in every style",
          .enabled(if: SurfacesV2Renders.env["PILOT_RENDER_DIR"] != nil && SurfacesV2Renders.env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let out = try ExtensionSurfaceRenders.out("page-edits")
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        look.glass = false
        defer { (look.themeID, look.style, look.glass) = saved }
        let row = { (id: String?, title: String, subtitle: String, badge: String, tone: Extension.Tone) in
            Extension.Item(id: id, title: title, subtitle: subtitle, icon: "📈", actions: [.open("https://www.tradingview.com")],
                           badges: [.init(text: badge, tone: tone)],
                           inline: [Extension.Item.Action(kind: .run(command: "remove", context: nil), title: "Remove", icon: "xmark", destructive: true)])
        }
        let blocks: [Extension.Block] = [
            .input(.init(placeholder: "Search TradingView: BTC, AAPL, EURUSD, SPX…", action: PageEditsTests.find, live: .milliseconds(250))),
            .list(title: nil, items: [
                row("SPY", "SPY · €603.12", "▁▂▃▄▅▆▇ SPDR S&P 500 ETF", "▲0.28%", .fine),
                row("BTC", "BTC · €94,210", "▇▆▅▄▃▂▁ Bitcoin", "▼1.40%", .alert),
                row("ETH", "ETH · €3,321", "▃▄▃▄▅▄▅ Ethereum", "▲0.92%", .fine),
                row(nil, "No id · not movable", "a row without an id keeps its place", "–", .warn),
            ], reorder: PageEditsTests.reorder),
            .note(.init(text: "Updated 14:05 · US market open", aside: "TradingView", icon: "chart")),
        ]
        let dir = try ExtensionSurfaceTests.folder(), exts = dir.appending(path: "Extensions")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ExtensionCatalogueModelTests.write(PageEditsTests.manifest, as: "markets", in: exts)
        for (style, theme) in SurfacesV2Renders.styles {
            (look.themeID, look.style) = (theme, style)
            let model = ExtensionPageModel(id: "markets", folder: exts, storage: ExtensionSurfaceTests.storage(dir), run: { _, _ in .blocks(blocks) })
            await model.refresh()
            let view = SurfaceGround { ExtensionSurfacePage(id: "markets", onScreen: false, model: model) { _ in }.frame(width: 760, height: 520) }
                .styled(.page(.extensions), look: look).pilotTheme(look: look)
            try writeRender(view, to: out.appendingPathComponent("page-edits-\(style.rawValue).png"), wait: 0.6)
        }
    }
}
}
#endif
