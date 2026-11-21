import AppKit
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Mac › Update & Clean with its Reports under the Update and Clean block (story 153; Sven, 2026-11-16), drawn offscreen
/// from a store seeded in a temporary folder, never Pilot's own: an Update all that went through, an Update that failed, a
/// Clean that freed space and one whose window was closed; Mole missing. Beside it Mac › Login & Background on seeded
/// items, never this Mac's. Instrument; its text is read back. PILOT_RENDER_DIR keeps the PNGs.
@MainActor
@Suite("Update & Clean and Login & Background renders")
struct ReportsPageRenders {
    static func seed(_ folder: URL) throws -> ReportStore {
        let store = ReportStore(folder: folder)
        let now = Date.now
        func run(_ report: RunReport, exit: Int32?, output: String) throws {
            let dir = try store.begin(report)
            try output.write(to: dir.appending(path: "output"), atomically: true, encoding: .utf8)
            try "99999".write(to: dir.appending(path: "pid"), atomically: true, encoding: .utf8)
            if let exit { try "\(exit)".write(to: dir.appending(path: "status"), atomically: true, encoding: .utf8) }
        }
        let rows = [UpdateRow(item: .package(Package(.cask, "zed")!), from: "0.205.4", to: "0.206.1"),
                    UpdateRow(item: .package(Package(.formula, "git")!), from: "2.51.0", to: "2.51.1"),
                    UpdateRow(item: .package(Package(.uv, "ruff")!), from: "0.13.2", to: "0.13.3")]
        let all = RunReport(kind: .update, title: "Update all", command: "brew upgrade --formula git && brew upgrade --cask zed && uv tool upgrade ruff",
                            started: now - 60, items: RunReport.update("", command: "", rows: rows, home: "/Users/ada").items)
        try run(all, exit: 0, output: "\u{1B}[34m==>\u{1B}[0m Upgrading 1 outdated package:\ngit 2.51.0 -> 2.51.1\n==> Pouring git--2.51.1.arm64_tahoe.bottle.tar.gz\n🍺  /opt/homebrew/Cellar/git/2.51.1: 1,710 files, 55.3MB\n==> Upgrading zed\nUpdated 1 tool: ruff 0.13.3")
        let failed = RunReport(kind: .update, title: "Update node", command: "brew upgrade --formula node", started: now - 3600 * 3,
                               items: [RunReport.Item(name: "node", from: "24.9.0", to: "24.10.0", detail: "formula")])
        try run(failed, exit: 1, output: "Error: node: Failed to download resource \"node\"\nDownload failed: https://ghcr.io/v2/homebrew/core/node/blobs/sha256:…")
        let preview = CleanPreview.parse("➤ Browsers\n  → Chrome cache · 1.73GB dry\n➤ Developer tools\n  → Xcode DerivedData · 4.20GB dry\n\nPotential space: 6.05GB | Items: 2")
        let clean = RunReport(kind: .clean, title: "Clean", command: "mo clean", started: now - 3600 * 26,
                              items: RunReport.clean(command: "", preview: preview).items, estimate: preview.total)
        try run(clean, exit: 0, output: "➤ Browsers\n  ✓ Chrome cache\n➤ Developer tools\n  ✓ Xcode DerivedData\n\nTracked cleanup: 5.91GB | Items cleaned: 2\nFree space: 182GB (+5.9GB)")
        let closed = RunReport(kind: .clean, title: "Clean", command: "mo clean", started: now - 3600 * 50, items: [], estimate: "28.75GB")
        try run(closed, exit: nil, output: "➤ System caches\nPassword:")
        return store
    }

    @Test("Update & Clean has Update and Clean, each with its last run and Open report, Clean offering Install Mole when it is missing, and under them every run newest first, the newest open to its command, versions and output")
    func upkeep() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-render-upkeep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try Self.seed(folder)
        #expect(store.list().map(\.end) == [.done, .failed(1), .done, .cancelled(nil)])
        let dir = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"].map { URL(filePath: $0) }
        let look = LookPageTests().look().0
        var text = ""
        for style in PilotStyle.allCases {
            look.style = style
            // The front, then More with Reports (the feature trim, 2026-11-19).
            for more in [false, true] {
                let page = ReportsGround { UpkeepPage(store: store, mole: false, homebrew: true, more: more) }.styled(.page(.upkeep), look: look).frame(width: 1000, height: 1500).pilotTheme(look: look)
                try LookPageTests().hosted(page, height: 1500) { host in
                    let rep = try #require(snapshot(host, scale: 2))
                    if let dir { try rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "upkeep-\(style.rawValue)\(more ? "-more" : "").png")) }
                    if style == .instrument { text += try recognisedText(in: rep).map(\.text).joined(separator: "\n") + "\n" }
                }
            }
        }
        for line in ["Update and Clean", "Clean runs through Mole", "Install Mole", "Open report", "Last run", "Reports",
                     "Update all", "Update node", "failed", "exit 1", "5.91GB freed", "cancelled", "brew upgrade", "0.205.4", "0.206.1",
                     "Upgrading 1 outdated package", "Copy output", "Show in Finder"] {
            #expect(text.contains(line), "\(line) missing, read: \(text)")
        }
        #expect(!text.contains("[34m"), "colours stripped, read: \(text)")
        // Login and background items left for a page of their own (Sven, 2026-11-16).
        #expect(!text.contains("Login and background"), "read: \(text)")
        // W89: Clean's ticked list in Instrument, parts closed as it opens; Mole there and its list kept.
        look.style = .instrument
        let list = CleanList(rows: [
            CleanList.Row(path: "/Users/me/Library/Caches/com.example.FakeApp", part: "App caches", bytes: 2_500_000, count: 2),
            CleanList.Row(path: "/Users/me/Library/Caches/com.example.OtherApp", part: "App caches", bytes: 1_200_000),
            CleanList.Row(path: "/Users/me/Library/Logs/FakeApp", part: "Logs", bytes: 300_000),
            CleanList.Row(path: "/Users/me/Library/Caches/Homebrew/downloads", part: "Developer tools", bytes: 3_500_000),
        ])
        let ticks = ReportsGround {
            UpkeepPage(store: store, mole: true, homebrew: true, cleanList: list)
        }.styled(.page(.upkeep), look: look).frame(width: 1000, height: 1500).pilotTheme(look: look)
        try LookPageTests().hosted(ticks, height: 1500) { host in
            let rep = try #require(snapshot(host, scale: 2))
            if let dir { try rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "upkeep-clean-ticks.png")) }
            let read = try recognisedText(in: rep).map(\.text).joined(separator: "\n")
            for line in ["What Clean would remove", "App caches", "Logs", "Developer tools", "Move ticked to Trash", "Clean all"] {
                #expect(read.contains(line), "\(line) missing, read: \(read)")
            }
        }
        for query in ["update", "clean", "upgrade", "free space"] { #expect(AppPlace.search(query).first == AppPlace(.upkeep), "\(query)") }
        #expect(AppPlace.search("report").first == AppPlace(.reports))
    }
}

/// The page on its style's ground, as the window's frame lays it.
private struct ReportsGround<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.background(ink.background) }
}
