#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Offscreen renders of Workspaces (and its Tiling tab), Install (Catalogue and Web apps) and Defaults (card
/// agent-bo-95422897) for Moody beside the approved artifact 5sh21HWjCjsWYAwWKTibcE: the whole window in Tokyo Night and
/// Folio, on an engine in a moved home with app rules, floats, layouts seeded; Defaults
/// again with All kinds open. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter RestyledRenders`
extension SharedLook {
@MainActor
@Suite("Restyled renders")
struct RestyledRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Workspaces, Install and Defaults render in Tokyo Night and Folio", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("restyled")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        // Seeded in the moved home's defaults and files before the engine reads them; nothing reaches the tiler.
        var block = PilotBlock()
        block.rules = [.init(appId: "com.mitchellh.ghostty", workspace: "1"), .init(appId: "app.zen-browser.zen", workspace: "2"),
                       .init(appId: "md.obsidian", workspace: "3"), .init(appId: "com.spotify.client", workspace: "4")]
        block.floatApps = ["Finder", "System Settings"]
        block.floatTitles = ["Preferences"]
        block.gaps = .init(inner: 10, outer: 14)
        UserDefaults.standard.set(try JSONEncoder().encode(block), forKey: "pilotBlock")
        WorkspaceLayout.save(["1": .init(preset: .mainStack, auto: true), "2": .init(preset: .scrolling, auto: false)], to: .standard)
        let engine = Engine()
        engine.observers.tiler.seed(focused: "2", occupied: [OccupiedWorkspace(name: "1", apps: ["Ghostty"]), OccupiedWorkspace(name: "2", apps: ["Zen"])])
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.restyled")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        let frame = try #require(window.contentView?.superview)
        let places = [AppPlace(.workspaces), AppPlace(.tiling), AppPlace(.install, .catalogue), AppPlace(.install, .webApps), AppPlace(.openWith)]
        for theme in ["tokyo-night", "folio"] {
            Look.shared.themeID = theme
            for place in places {
                model.go(place)
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                frame.layoutSubtreeIfNeeded()
                let name = place.section.map { "\(place.page.rawValue)-\($0.rawValue)" } ?? place.page.rawValue
                let png = try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:]))
                try png.write(to: dir.appendingPathComponent("\(theme)-\(name).png"))
            }
            // Install's front: its search and What Pilot lists.
            try writeRender(CataloguePage().frame(width: 900, height: 900).pilotTheme(look: .shared).background(Theme.background),
                            to: dir.appendingPathComponent("\(theme)-install.png"))
            // Open with's All kinds open, the page alone at the window's page width.
            let page = OpenWithPage(allKinds: true).environment(engine).frame(width: 900, height: 1100).pilotTheme(look: .shared).background(Theme.background)
            try writeRender(page, to: dir.appendingPathComponent("\(theme)-defaults-allkinds.png"))
        }
        Look.shared.themeID = PilotTheme.defaultID
        window.close()
    }

    /// Open with with All kinds folded out (Sven 2026-11-12, "open with isnt well aligned"): the page alone beside the
    /// window's sidebar at the first window width (1000) and a wide one (1440), in Instrument, on fake defaults
    /// that pick QuickTime Player for video, the longest app name the cards show. Output: `open-with/<style>-<width>.png`.
    @Test("Open with renders with All kinds open in Instrument", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderOpenWith() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("open-with")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let engine = Engine()
        let suite = "pilot.renders.open-with"
        UserDefaults().removePersistentDomain(forName: suite)
        let editor = EditorChoice(defaults: UserDefaults(suiteName: suite)!, installed: { _ in true }, handler: { _ in "com.microsoft.VSCode" })
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.themeID = "nightwatch"
        for style in [PilotStyle.instrument] {
            look.style = style
            for width in [1000, 1440] {
                let page = OpenWithPage(allKinds: true, kinds: DefaultAppsModel(system: RenderDefaultApps(), forget: { _ in }), editor: editor)
                    .environment(engine).frame(width: CGFloat(width - 207), height: 2400).pilotTheme(look: look).background(Theme.background)
                try Self.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("\(style.rawValue)-\(width).png"))
            }
        }
    }

    /// `rep` cut 16 pt under the last row whose pixels right of `x` (in points) differ from the bottom row's: the page's end.
    /// A page that reaches the bottom was cut by the render's height, which fails.
    static func writeTrimmed(_ rep: NSBitmapImageRep, from x: Int, to url: URL) throws {
        let scale = rep.pixelsWide / max(1, Int(rep.size.width))
        let data = try #require(rep.bitmapData), row = rep.bytesPerRow, start = x * scale * rep.bitsPerPixel / 8, bottom = rep.pixelsHigh - 1
        let last = stride(from: bottom, through: 0, by: -1).first { memcmp(data + $0 * row + start, data + bottom * row + start, row - start) != 0 } ?? bottom
        try #require(last < bottom - 16 * scale, "the page is taller than the render: \(url.lastPathComponent)")
        let image = try #require(rep.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: last + 16 * scale)))
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }
}

/// Mockup D's defaults: web links in Google Chrome, plain text and Markdown in Visual Studio Code. Never LaunchServices.
@MainActor
private struct RenderDefaultApps: DefaultAppsSystem {
    func current(_ handler: DefaultHandler) -> String? {
        switch handler {
        case .url(let url): url.hasPrefix("mailto") ? "com.apple.mail" : "com.google.Chrome"
        case .contentType(let id):
            ["image", "png", "jpeg", "heic", "gif", "webp", "pdf"].contains(where: id.contains) ? "com.apple.Preview"
                : ["mpeg-4", "quicktime"].contains(where: id.contains) && !id.contains("audio") ? "com.apple.QuickTimePlayerX"
                : ["mp3", "audio", "flac"].contains(where: id.contains) ? "com.apple.Music"
                : id.contains("archive") ? "com.apple.archiveutility" : "com.microsoft.VSCode"
        }
    }
    func choices(_ handlers: [DefaultHandler]) -> [(name: String, bundle: String)] {
        [("Visual Studio Code", "com.microsoft.VSCode"), ("TextEdit", "com.apple.TextEdit"), ("Google Chrome", "com.google.Chrome"), ("Preview", "com.apple.Preview"),
         ("QuickTime Player", "com.apple.QuickTimePlayerX"), ("Music", "com.apple.Music"), ("Archive Utility", "com.apple.archiveutility"), ("Mail", "com.apple.mail")]
    }
    func name(_ bundle: String) -> String { bundle }
    func setDefault(_ bundle: String, for handler: DefaultHandler) async throws {}
}
}
#endif
