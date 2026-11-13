#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Pilot's dock, look A (spec pilot-dock; Sven 2026-11-13, Q199, Q200; the render the coordinator's brief asks for): sample
/// pins and running apps with their dots, the front app raised, and three widgets drawn from bar parts, on Jungle. Opt-in
/// like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter DockRenders`
@MainActor
@Suite("Dock renders")
struct DockRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static func app(_ name: String, _ path: String, pinned: Bool = true, windows: Int = 0, running: Bool = true, front: Bool = false) -> DockApp {
        DockApp(bundleID: name.lowercased(), url: URL(filePath: path), name: name, pinned: pinned, pid: running ? 1 : nil, windows: windows, front: front)
    }

    @Test("The dock renders its pins, running apps, dots and three widgets", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try ClockRenders.dir("dock")
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let saved = look.themeID
        defer { look.themeID = saved }
        look.themeID = "jungle"
        let tokens = StyleTokens.of(look.style, theme: look.theme)
        let apps = [
            Self.app("Finder", "/System/Library/CoreServices/Finder.app", windows: 1),
            Self.app("Mail", "/System/Applications/Mail.app", windows: 3),
            Self.app("System Settings", "/System/Applications/System Settings.app", running: false),
            Self.app("Music", "/System/Applications/Music.app", windows: 2, front: true),
            Self.app("Notes", "/System/Applications/Notes.app", running: false),
            Self.app("Calendar", "/System/Applications/Calendar.app", windows: 1),
            Self.app("Terminal", "/System/Applications/Utilities/Terminal.app", pinned: false, windows: 2),
        ]
        let faces: [[[BarPart]]] = [
            [[.label("SESSION"), .bar(0.62), .value("62%")], [.label("WEEK"), .bar(0.41), .value("41%")]],
            [[.ring(0.5), .value("18:42"), .label("FOCUS 2 OF 4")]],
            [[.symbol("cloud.sun"), .value("24°"), .label("MIRAVEL")]],
        ]
        for size in DockSize.allCases {
            let strip = DockStrip(size: size, hasWidgets: true) {
                ForEach(Array(apps.enumerated()), id: \.offset) { _, app in DockAppIcon(app: app, size: size) }
            } widgets: {
                ForEach(Array(faces.enumerated()), id: \.offset) { _, face in
                    DockWidget(size: size) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(face.enumerated()), id: \.offset) { _, line in BarPartsView(items: [line]) }
                        }
                    }
                }
            }
                .environment(\.inTopBar, true)
                .background(RoundedRectangle(cornerRadius: DockPill.radius, style: .continuous).fill(Color(tokens.colors.panel).opacity(0.82)))
                .styled(.topBar, look: look).pilotTheme(look: look)
                .padding(28)
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.10), Color(red: 0.42, green: 0.48, blue: 0.20)],
                                           startPoint: .top, endPoint: .bottom))
            try writeRender(strip, to: dir.appendingPathComponent("dock-\(size.rawValue).png"), wait: 1.2)
        }
    }
}
}
#endif
