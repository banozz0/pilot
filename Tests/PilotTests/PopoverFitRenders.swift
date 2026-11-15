#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Bar dropdowns round 4 (Sven, 2026-11-15, on build 2564: "ai usage still looks like cutout"): AI usage's calm popover as
/// he had it, three accounts and both status pages degraded ("Claude minor", "Codex minor" beside Open page), drawn
/// offscreen at its own size on Solid (glass draws nothing offscreen), with every line Vision reads and its right edge.
/// The popover is cut when a line ends past the face's inset or a line is missing.
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter PopoverFitRenders`
@MainActor
@Suite("Popover fit renders")
struct PopoverFitRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    nonisolated static func open(_ url: String) -> Extension.Item.Action { .init(kind: .open(url)) }

    /// The calm popover's blocks for three accounts on a day both status pages say minor.
    nonisolated static let aiUsage: [Extension.Block] = {
        let soon = Date(timeIntervalSinceNow: 3 * 3600)
        func meter(_ label: String, _ left: Double) -> Extension.Block {
            .meter(.init(label: label, percent: left, tone: .fine, resetsAt: soon, mark: 60, value: "\(Int(left))% left"))
        }
        let credit = Extension.Block.note(.init(text: "1 reset credit", aside: "next expires 12 Dec", icon: "reset"))
        let redeem = Extension.Block.buttons([.init(kind: .run(command: "redeem-reset", context: nil), title: "Redeem reset…")])
        return [
            .section(title: "Claude", subtitle: nil, aside: "someaccount7", asideNote: "Max 5x",
                     blocks: [meter("Session", 88), meter("Weekly", 50)], icon: .claude),
            .section(title: "Codex", subtitle: nil, aside: "someaccount7", asideNote: "Plus",
                     blocks: [meter("Session", 100), meter("Weekly", 15), credit, redeem], icon: .openai),
            .section(title: "Codex", subtitle: nil, aside: "example.dev", asideNote: "Plus",
                     blocks: [meter("Session", 100), meter("Weekly", 39), credit, redeem], icon: .openai),
            .section(title: "Codex", subtitle: "signed out", aside: "~/.codex-pro", blocks: [], icon: .openai),
            .links([Extension.Block.Link(title: "Claude", tone: .warn, word: "minor", actions: [open("https://status.claude.com/")]),
                    Extension.Block.Link(title: "Codex", tone: .warn, word: "minor", actions: [open("https://status.openai.com/")]),
                    Extension.Block.Link(icon: "chart", help: "Usage dashboards", actions: [open("https://claude.ai"), open("https://chatgpt.com")]),
                    Extension.Block.Link(icon: "plus", help: "Add Codex account…", actions: [.init(kind: .run(command: "add-account", context: nil))])]
                .compactMap { $0 }),
        ]
    }()

    @Test("AI usage's popover with both status words fits its face: no line runs past the inset",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func aiUsageFits() async throws {
        let dir = try ClockRenders.dir("popover-fit")
        let look = Look.shared
        let was = (look.style, look.themeID, look.glass)
        defer { (look.style, look.themeID, look.glass) = was }
        (look.style, look.themeID, look.glass) = (.instrument, "dracula", false)
        let (folder, exts, storage) = try SurfacesV2Tests.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = SurfacesV2Tests.popover(exts, storage: storage) { _, _ in .blocks(Self.aiUsage) }
        await model.open()
        let item = ExtensionBar.Item(id: "surfaces-demo", title: "AI usage", icon: "📊", hasPage: true, answer: nil, problem: nil)
        let view = ExtensionPopoverView(item: item, model: model).styled(.barPopovers, look: look).pilotTheme(look: look).fixedSize()
        testApp()
        let rep = try rendered(view, wait: 1)
        try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("ai-usage.png"))
        let width = CGFloat(rep.pixelsWide) / 2, face = ExtensionPopoverView.width
        let lines = try recognisedText(in: rep).map { (text: $0.text, right: ($0.box.maxX * width).rounded()) }
        for line in lines { print("popover-fit: \(line.right) \(line.text)") }
        print("popover-fit: drawn \(width) wide, face \(face), inset \(PopoverMetrics.inset)")
        #expect(width == face, "the popover keeps its width")
        let read = lines.map(\.text).joined(separator: " ")
        for words in ["someaccount7", "example.dev", "next expires 12 Dec", "Open page", "Claude", "minor"] {
            #expect(read.contains(words), "\(words) is drawn whole")
        }
        // Vision boxes sit a point or two outside the glyphs; a cut line ends at the face's edge.
        for line in lines { #expect(line.right <= face - PopoverMetrics.inset + 3, "\(line.text) ends at \(line.right) of \(face)") }
    }
}
}
#endif
