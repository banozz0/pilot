import AppKit
import Foundation

import SwiftUI
import Testing
@testable import Pilot
@testable import PilotCore

/// Workspaces' icons style (card agent-bo-95423019, design JJPiA9o30SA direction B's left island): each workspace's number
/// then its apps as their icons, each once in the tiler's order, at most 3 then +N; the current workspace's icons at full
/// strength on its raised pill, the others' at 55 percent. Seeded through TilerService.seed; with PILOT_RENDER_DIR set
/// the bars are also written there as PNGs.
@MainActor
@Suite("Workspace app icons", .serialized)
struct WorkspaceIconsTests {
    /// Ghostty in 1, Zen then Ghostex in 2 (twice each: two windows), the focus on `focused`.
    static func tiler(focused: String = "2") -> TilerService {
        let tiler = EngineObservers().tiler
        let windows = [("Ghostty", "com.mitchellh.ghostty", "1"), ("Zen", "app.zen-browser.zen", "2"), ("Ghostex", "com.madda.ghostex.host", "2"),
                       ("Zen", "app.zen-browser.zen", "2"), ("Ghostex", "com.madda.ghostex.host", "2")].enumerated().map { i, w in
            AeroWindow(id: i, appName: w.0, bundleId: w.1, pid: 100 + Int32(i), workspace: w.2, monitorId: 1, layout: "h_tiles", title: "")
        }
        tiler.seed(focused: focused, occupied: OccupiedWorkspace.list(windows), windows: windows)
        return tiler
    }

    @Test("Seeded with Ghostty in 1 and Zen plus Ghostex in 2, the icons style draws 1 with Ghostty and 2 with Zen then Ghostex, each once, by their own bundles (card agent-bo-95423019, AC 1)")
    func appsPerWorkspace() throws {
        let occupied = Self.tiler().occupied
        #expect(occupied.map(\.name) == ["1", "2"])
        #expect(TopBarWorkspaces.Icons(occupied[0].apps) == .init(apps: ["Ghostty"], more: 0))
        #expect(TopBarWorkspaces.Icons(occupied[1].apps) == .init(apps: ["Zen", "Ghostex"], more: 0))
        #expect(occupied[1].bundles == ["Zen": "app.zen-browser.zen", "Ghostex": "com.madda.ghostex.host"])
        // Drawn: 1 holds one icon, 2 two: runs of ink columns 4 pt apart, each about an icon wide.
        let one = try StripStyleTests.alone(WorkspaceAppIcons(workspace: occupied[0], lit: true).fixedSize(), width: 80)
        let two = try StripStyleTests.alone(WorkspaceAppIcons(workspace: occupied[1], lit: true).fixedSize(), width: 80)
        #expect(Self.icons(one).count == 1 && Self.icons(two).count == 2, "workspace 1 draws runs \(Self.icons(one)), 2 draws \(Self.icons(two))")
        #expect((Self.icons(one) + Self.icons(two)).allSatisfy { (24...30).contains($0) }, "a run is not one 15 pt icon wide")
    }

    /// The widths, in pixels, of the runs of columns off the ground, apart by at least 3 pixels: one per icon drawn.
    static func icons(_ rep: NSBitmapImageRep) -> [Int] {
        let ground = StripStyleTests.ground()
        let columns = (0..<rep.pixelsWide).filter { x in (0..<rep.pixelsHigh).contains { !StripStyleTests.near(StripStyleTests.pixel(rep, x, $0), ground, 6) } }
        var runs: [Int] = [], start = columns.first, last = columns.first
        for x in columns.dropFirst() {
            if x - last! > 3 { runs.append(last! - start! + 1); start = x }
            last = x
        }
        if let start, let last { runs.append(last - start + 1) }
        return runs
    }

    @Test("With 5 apps in a workspace it draws 3 icons and +2 (card agent-bo-95423019, AC 2)")
    func capsAtThree() {
        let shown = TopBarWorkspaces.Icons(["Ghostty", "Zen", "Ghostex", "Finder", "Mail"])
        #expect(shown == .init(apps: ["Ghostty", "Zen", "Ghostex"], more: 2))
        #expect(shown.moreLabel == "+2")
        #expect(TopBarWorkspaces.Icons(["Ghostty", "Zen", "Ghostex"]) == .init(apps: ["Ghostty", "Zen", "Ghostex"], more: 0))
    }

    @Test("Only the current workspace's icons draw at full strength; the others' at 55 percent (card agent-bo-95423019, AC 3)")
    func dimsTheOthers() throws {
        let pair = OccupiedWorkspace(name: "2", apps: ["Ghostty", "Zen"], bundles: ["Ghostty": "com.mitchellh.ghostty", "Zen": "app.zen-browser.zen"])
        let full = try StripStyleTests.alone(WorkspaceAppIcons(workspace: pair, lit: true), width: 60)
        let dim = try StripStyleTests.alone(WorkspaceAppIcons(workspace: pair, lit: false), width: 60)
        let (median, channels) = StripStyleTests.strength(dim, of: full)
        #expect(channels > 200, "\(channels) strong channels: no icons drawn")
        #expect(abs(median - 0.55) < 0.04, "another workspace's icons draw at \(median) of the current's strength, not 55 percent")
    }

    @Test("In the bar the icons style shows each workspace's number and its icons, the current one on its pill and wider than with numbers alone (card agent-bo-95423019, renders)")
    func inTheBar() async throws {
        let (store, sources, timer) = try StripStyleTests.svensBar()
        defer { timer.stop() }
        let ws = Self.tiler()
        sources.observers.tiler.seed(focused: ws.focused, occupied: ws.occupied, windows: ws.windows)
        var widths: [BarStyle: CGFloat] = [:]
        for style in [BarStyle.numbers, .icons] {
            store.settings.set(.workspaces, style: style)
            let frames = StripStyleTests.Frames()
            let rep = try rendered(StripStyleTests.strip(store, sources, width: 1440, frames: frames), wait: 0.3)
            try StripStyleTests.write(rep, "workspace-icons/strip-\(style.rawValue)")
            widths[style] = try #require(frames.placed["Workspaces"]).width
        }
        // Two workspaces' numbers plus three icons of 15 pt each and their gaps: well over 45 pt more.
        #expect(widths[.icons]! > widths[.numbers]! + 45, "the icons style is \(widths[.icons]!) wide, numbers \(widths[.numbers]!)")
    }

    @Test("The icons style is Workspaces' last style and not its default; the macOS menu bar draws it as the numbers (card agent-bo-95423019, AC 4 as the card's Islands went)")
    func style() {
        #expect(BarKind.workspaces.styles == [.numbers, .dots, .current, .withApp, .icons])
        var i = BarInputs()
        i.workspaces = ["1", "2"]
        i.focusedWorkspace = "2"
        #expect(BarParts.parts(BarEntry(.workspaces, on: true, style: .icons), i) == [.workspaces(["1", "2"], current: "2", app: nil)])
    }
}
