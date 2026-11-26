#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Look › Themes › More's app switches (Sven, Q402, 2026-11-26: two columns, each switch beside its app's name), drawn as
/// ThemeAppSwitches with a fixed fixture: Zed, Ghostex, seven detected apps and Obsidian with two vaults of one name, one
/// app off. Then the master switch off, which dims the grid. Nothing is read from or written to any app's files. At the
/// window's page width, Instrument in a dark and a light theme. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter ThemeAppSwitchesRenders`
extension SharedLook {
@MainActor
@Suite("Theme app switches renders")
struct ThemeAppSwitchesRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let size = CGSize(width: AppWindowController.size.width - 73, height: 420)

    @Test("Themes › More's app switches, on and with the master off, in Instrument dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("theme-app-switches")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()

        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.style = .instrument
        for (scheme, theme) in [("dark", "tokyo-night"), ("light", "porcelain")] {
            look.themeID = theme
            for othersOn in [true, false] {
                let view = MonitorsGround {
                    ThemeAppSwitches(apps: Self.fixture(othersOn: othersOn), stage: { _, _ in })
                        .padding(32)
                        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
                }
                    .styled(.page(.look))
                    .pilotWindowStyles()
                    .pilotTheme(look: look)
                try MoreTabRenders.hosted(view, size: Self.size) { host in
                    let rep = try #require(snapshot(host, scale: 2))
                    try #require(rep.representation(using: .png, properties: [:]))
                        .write(to: dir.appendingPathComponent("switches-\(othersOn ? "on" : "master-off")-\(scheme).png"))
                }
            }
        }
    }

    static func fixture(othersOn: Bool) -> ThemeCoordinator.AppFollowing {
        let kinds: [ThemeAppKind] = [.vscode, .cursor, .btop, .lazygit, .neovim, .fish, .vesktop]
        return .init(zedFound: true, zedOn: true, obsidianOn: true, ghostexFound: true, ghostexOn: true, othersOn: othersOn,
                     vaults: [.init(root: "/Users/example/Notes/vault", on: true), .init(root: "/Users/example/Work/vault", on: false)],
                     apps: kinds.map { .init(kind: $0.rawValue, name: $0.name, on: $0 != .btop) })
    }
}
}
#endif
