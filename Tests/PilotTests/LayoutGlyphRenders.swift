#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Layouts round 1 (Sven's Q234): the top bar's workspaces item, the workspace its screen shows drawing its layout's
/// glyph in place of its number, for every layout (and none, which keeps its number), in Instrument and Toybox, dark
/// and light, numbers and icons styles; then the second display, whose bar draws the glyph on the workspace it shows
/// while the other screen has the focus. The real view (TopBarWorkspacesView) on fakes, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter LayoutGlyphRenders`
extension SharedLook {
@MainActor
@Suite("Layout glyph renders")
struct LayoutGlyphRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The shown workspace's layout glyph in the top bar, each layout, both styles, dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try ClockRenders.dir("layout-glyph")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let was = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = was }

        let observers = EngineObservers()
        let windows = try AeroWindow.parse(InstrumentTopBarRenders.windows)
        let tiler = observers.tiler
        tiler.seed(focused: "2", occupied: OccupiedWorkspace.list(windows), windows: windows,
                   perMonitor: try AeroMonitorWorkspace.parse(InstrumentTopBarRenders.monitors))
        let rows: [(String, LayoutPreset?)] = LayoutPreset.cycle.map { ($0.label, $0) } + [(LayoutPreset.columns.label, .columns), (LayoutPreset.rows.label, .rows), ("No layout", nil)]
        for style in PilotStyle.allCases {
            look.style = style
            for (mode, theme) in style == .toybox ? [("dark", "toybox-night"), ("light", "toybox")] : [("dark", "garnet"), ("light", "porcelain")] {
                look.themeID = theme
                let tokens = StyleTokens.of(style, theme: look.theme)
                let item = { (preset: LayoutPreset?, bar: BarStyle, screen: String) in
                    TopBarWorkspacesView(screen: screen, tiler: tiler, style: bar, layout: { name in name == "2" ? preset : name == "4" ? .scrolling : nil })
                        .environment(\.inTopBar, true).frame(height: 30).fixedSize()
                }
                try writeRender(VStack(alignment: .leading, spacing: 8) {
                    Text("\(style.title) · \(mode) · workspace 2 shown here with the focus").font(.headline)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 16) {
                            Text(row.0).font(.caption).frame(width: 110, alignment: .leading)
                            item(row.1, .numbers, InstrumentTopBarRenders.screen)
                            item(row.1, .icons, InstrumentTopBarRenders.screen)
                        }
                    }
                    Text("The second display's bar: it shows 4 (Scrolling), the focus on 2").font(.caption)
                    item(.mainStack, .numbers, "Portrait")
                }
                .padding(14).frame(width: 760, alignment: .topLeading)
                .styled(.topBar, look: look).pilotTheme(look: look)
                .foregroundStyle(Color(tokens.colors.text)).background(Color(tokens.colors.canvas)),
                                to: dir.appendingPathComponent("glyph-\(style.rawValue)-\(mode).png"), wait: 0.5)
            }
        }
    }
}
}
#endif
