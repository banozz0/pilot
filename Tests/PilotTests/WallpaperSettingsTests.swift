import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Story 160: Look › Wallpaper keeps the folders and images that cycle, the order, the screens and the interval; the timer
/// runs only while an interval is set and the screen is seen. The block drawn offscreen in each style and read back;
/// PILOT_RENDER_DIR keeps the PNGs.
@MainActor
@Suite("Wallpaper settings")
struct WallpaperSettingsTests {
    static func defaults() -> UserDefaults { UserDefaults(suiteName: testSuite())! }

    @Test("Starts on ~/Pictures/Wallpapers by name on the screen in front, never on its own; every change is kept")
    func kept() {
        let store = Self.defaults()
        let settings = WallpaperSettings(defaults: store)
        #expect(settings.sources == [WallpaperCycle.standardFolder.path] && settings.isStandard)
        #expect(settings.order == .name && settings.scope == .focusedScreen && settings.interval == 0 && !settings.isScheduled)
        settings.add([URL(filePath: "/Volumes/Art/walls"), URL(filePath: "/Users/ada/Desktop/one.jpg"), URL(filePath: "/Volumes/Art/walls/")])
        settings.remove(WallpaperCycle.standardFolder.path)
        settings.order = .shuffle
        settings.scope = .everyScreen
        let seed = settings.seed
        settings.shuffleAgain()
        #expect(settings.seed != seed)
        let again = WallpaperSettings(defaults: store)
        #expect(again.sources == ["/Volumes/Art/walls", "/Users/ada/Desktop/one.jpg"])
        #expect(again.order == .shuffle && again.scope == .everyScreen && again.seed == settings.seed)
        again.remove("/Volumes/Art/walls")
        again.remove("/Users/ada/Desktop/one.jpg")
        #expect(again.urls == [WallpaperCycle.standardFolder], "none left falls back to ~/Pictures/Wallpapers")
        again.reset()
        #expect(again.isStandard)
    }

    @Test("Settings saved before folders per screen read back unchanged: shared folders, every screen on them")
    func migrates() {
        let store = Self.defaults()
        // The five keys as a build before 2026-10-17 left them, and nothing else.
        store.set(["/Users/ada/Pictures/Wallpapers/1440p-ultrawide"], forKey: "wallpaper.sources")
        store.set("shuffle", forKey: "wallpaper.order")
        store.set("12345", forKey: "wallpaper.seed")
        store.set("everyScreen", forKey: "wallpaper.scope")
        store.set(30, forKey: "wallpaper.interval")
        let settings = WallpaperSettings(defaults: store)
        #expect(settings.sources == ["/Users/ada/Pictures/Wallpapers/1440p-ultrawide"] && settings.order == .shuffle && settings.seed == 12345)
        #expect(settings.scope == .everyScreen && settings.interval == 30)
        #expect(settings.folders == .shared && settings.screenSources.isEmpty)
        #expect(settings.urls(for: "37D8832A-2D66-02CA-B9F7-8F30A301B230") == settings.urls && settings.urls(for: nil) == settings.urls)
    }

    @Test("Each screen its own: a screen's folders are kept by its display UUID, one without takes the shared ones, shared mode ignores them")
    func perScreen() {
        let store = Self.defaults()
        let settings = WallpaperSettings(defaults: store)
        let main = "37D8832A-2D66-02CA-B9F7-8F30A301B230", second = "9A1B6E0C-4F55-4C2B-8D11-5E6F7A8B9C0D"
        settings.add([URL(filePath: "/Volumes/Art/ultrawide")])
        settings.add([URL(filePath: "/Volumes/Art/portrait"), URL(filePath: "/Volumes/Art/portrait/")], display: second)
        #expect(settings.ownSources(second) == ["/Volumes/Art/portrait"] && settings.ownSources(main).isEmpty)
        #expect(settings.sources == [WallpaperCycle.standardFolder.path, "/Volumes/Art/ultrawide"], "a screen's add leaves the shared ones")
        #expect(settings.urls(for: second) == settings.urls, "shared mode cycles the shared folders on every screen")
        settings.folders = .perScreen
        #expect(settings.urls(for: second) == [URL(filePath: "/Volumes/Art/portrait")] && settings.urls(for: main) == settings.urls)
        let again = WallpaperSettings(defaults: store)
        #expect(again.folders == .perScreen && again.ownSources(second) == ["/Volumes/Art/portrait"])
        again.remove("/Volumes/Art/portrait", display: second)
        #expect(again.screenSources.isEmpty && again.urls(for: second) == again.urls, "none left takes the shared ones")
        again.add([URL(filePath: "/Volumes/Art/one.jpg")], display: main)
        again.reset(display: main)
        #expect(again.ownSources(main).isEmpty && again.sources == [WallpaperCycle.standardFolder.path, "/Volumes/Art/ultrawide"])
        #expect(WallpaperSettings.imageLists([[], [], again.urls], order: .name, seed: 1).count == 2, "a list two screens share is listed once")
    }

    @Test("An interval starts the timer, Never stops it; a locked screen pauses it and an unlock starts it again; a stray value reads Never")
    func timer() {
        let store = Self.defaults()
        let settings = WallpaperSettings(defaults: store)
        settings.interval = 15
        #expect(settings.isScheduled)
        settings.pause()
        #expect(!settings.isScheduled)
        settings.resume()
        #expect(settings.isScheduled)
        #expect(WallpaperSettings(defaults: store).interval == 15)
        settings.interval = 0
        #expect(!settings.isScheduled)
        store.set(7, forKey: "wallpaper.interval")
        #expect(WallpaperSettings(defaults: store).interval == 0)
    }

    @Test("The block shows each screen's wallpaper, the one Next gives dimmed beside it, and its place, the folders and images as chips, order, screens and interval; each screen its own folders under its row",
          arguments: WallpaperCycle.Folders.allCases)
    func renders(_ folders: WallpaperCycle.Folders) throws {
        let settings = WallpaperSettings(defaults: Self.defaults())
        settings.add([URL(filePath: NSHomeDirectory() + "/Pictures/Omarchy"), URL(filePath: "/Users/ada/Desktop/dunes.jpg")])
        settings.add([URL(filePath: NSHomeDirectory() + "/Pictures/Portraits")], display: "LG")
        settings.order = .shuffle
        settings.interval = 60
        settings.folders = folders
        // Each screen its own renders the workspace rows too (Q333): one with its own folder, one on its screen's.
        if folders == .perScreen {
            settings.workspaces = .perWorkspace
            settings.add([URL(filePath: NSHomeDirectory() + "/Pictures/Forest")], workspace: "2")
        }
        defer { settings.interval = 0 }
        let screens = [
            WallpaperScreen(id: 1, name: "LG HDR WQHD", portrait: false, detail: "kanagawa.png · 3 of 12", thumb: Self.picture(.systemTeal),
                            next: Self.picture(.systemBlue), nextName: "lantern", displayUUID: "LG"),
            WallpaperScreen(id: 2, name: "DELL U2723QE", portrait: true, detail: "mountain.jpg · not in the cycle", thumb: Self.picture(.systemOrange),
                            next: Self.picture(.systemGreen), nextName: "fallen", displayUUID: "DELL"),
        ]
        let look = try LookPageTests().look().0
        for style in PilotStyle.allCases {
            let name = "\(style.rawValue)-\(folders.rawValue)"
            look.style = style
            let view = WallpaperBlock(settings: settings, screens: screens, count: 12, workspaces: ["1", "2"]).padding(10).frame(width: 760)
                .styled(.page(.look)).background(Theme.background).pilotTheme(look: look)
            var text = ""
            let height: CGFloat = folders == .perScreen ? 820 : 640
            try LookPageTests().hosted(view.frame(width: 1000, height: height), height: height) { host in
                let rep = try #require(snapshot(host, scale: 2))
                if let dir = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] {
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "wallpaper-\(name).png"))
                }
                text = try recognisedText(in: rep).map(\.text).joined(separator: "\n")
            }
            // "12 ima": OCR reads the muted count as "12 imaaes" once the next pictures show; the render has it whole.
            let own = folders == .perScreen ? ["Shared folders", "Pictures/Portraits", "The shared folders", "Workspace 2", "Pictures/Forest",
                                               "screen's folders"] : ["Images from"]
            for line in ["Wallpaper", "LG HDR WQHD", "3 of 12", "not in the cycle", "12 ima", "Pictures/Omarchy", "dunes.jpg", "Shuffle again",
                         "Every screen", "Every hour", "Same for every screen", "Each screen its own", "Same as global", "Per workspace"] + own {
                #expect(text.localizedCaseInsensitiveContains(line), "\(name): \(line) missing, read: \(text)")
            }
            if folders == .shared { #expect(!text.contains("Portraits"), "\(name): a screen's own folders show only while each has its own") }
        }
    }

    static func picture(_ colour: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 160, height: 90), flipped: false) { rect in
            colour.setFill()
            rect.fill()
            return true
        }
    }
}
