#if DEBUG
import AppKit
import Clipboard
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Every page card agent-bo-95423004 fills (Home, Stats, Install's Catalogue and Web apps, Defaults, Setup in each part,
/// Look, Clipboard, Pilot; Files › Folders with three dressed folders, P43), the whole window at a fixed size the way Sven sees it (1440 × 1100, 1000 × 800, 760 × 620),
/// untrimmed so an empty half shows, in Lagoon. Seeded as Home's renders seed it; Setup reads fakes.
/// Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-fill PILOT_RENDER_DIR=/tmp/pilot-renders-fill PILOT_RESOURCES=Packaging swift test --filter PageFillRenders`
extension SharedLook {
@MainActor
@Suite("Page fill renders")
struct PageFillRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let sizes: [(Int, Int)] = [(1440, 1100), (1000, 800), (760, 620)]

    /// The places, by file name.
    static let places: [(String, AppPlace, SetupSection?)] = [
        ("home", AppPlace(.home), nil), ("stats", AppPlace(.stats), nil), ("menubar", AppPlace(.menuBar), nil),
        ("install-catalogue", AppPlace(.install, .catalogue), nil), ("install-webapps", AppPlace(.install, .webApps), nil),
        ("openwith", AppPlace(.openWith), nil), ("look", AppPlace(.look), nil), ("clipboard", AppPlace(.clipboard), nil),
        ("general", AppPlace(.general), nil), ("files-folders", AppPlace(.files, .folders), nil),
    ] + SetupPage.front.map { ("system-\($0.rawValue)", AppPlace(.system), $0) }

    /// A clipboard history with copies from apps on this Mac, so Recent shows real icons (in the render home).
    static func seedClips(home: URL) throws -> ClipboardStore {
        let path = home.appendingPathComponent("render-clips.sqlite")
        try? FileManager.default.removeItem(at: path)
        let store = try ClipboardStore(path: path)
        let now = Date()
        let copies: [(String, String, Double)] = [
            ("git rebase -i origin/main --autosquash", "com.mitchellh.ghostty", 9_000),
            ("https://github.com/nikitabobko/AeroSpace/releases", "com.apple.Safari", 7_200),
            ("Meeting moved to Thursday 14:00, same room.", "com.apple.mail", 5_400),
            ("let column = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)", "com.microsoft.VSCode", 3_600),
            ("Alex Rivera\nValletta, Malta", "com.apple.Notes", 2_400),
            ("#7AA2F7", "com.figma.Desktop", 1_200),
            ("brew install --cask ghostty", "com.mitchellh.ghostty", 600),
            ("The tap owns the binds. Never post or rewrite key events to trigger another app's hotkey.", "com.apple.TextEdit", 240),
            ("https://omarchy.org/manual", "com.apple.Safari", 60),
            ("Pilot makes a Mac feel as close to Omarchy as macOS allows: one native app with its own tiler.", "com.apple.Notes", 30),
            ("aerospace list-windows --workspace focused --format '%{app-name}'", "com.mitchellh.ghostty", 20),
            ("Order #4417 shipped, arriving Friday", "com.apple.mail", 12_000),
            ("pilot://open?page=setup&section=wifi", "com.apple.TextEdit", 14_000),
            ("swift test --filter FillRenders", "com.microsoft.VSCode", 16_000),
            ("Hola, ¿cómo estás? Muy bien, gracias.", "com.apple.Notes", 20_000),
            ("https://ui.shadcn.com/docs/components", "com.apple.Safari", 26_000),
            ("0xFF7AA2F7", "com.figma.Desktop", 30_000),
            ("ssh web-1 'systemctl status nginx'", "com.mitchellh.ghostty", 40_000),
            ("Thanks! I'll take a look tonight and send notes.", "com.apple.mail", 50_000),
            ("struct CardGrid: Layout { var minimum: CGFloat = 220 }", "com.microsoft.VSCode", 60_000),
        ]
        for (text, app, ago) in copies { _ = try store.add(.plainText(text, sourceApp: app), at: now.addingTimeInterval(-ago)) }
        return store
    }

    @Test("Every filled page renders at 1440, 1000 and 760", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("fill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }
        try HomeRenders.seedPresets()
        try Self.seedConfigs(home: URL(fileURLWithPath: home))

        let engine = try HomeRenders.engine()
        SharedLook.StatsRenders.seed(SystemSampler.shared)
        SharedLook.StatsRenders.pickMockup(BarItemsStore.shared)
        let made = SetupDevices.make
        // Wi-Fi and Bluetooth as on a Mac that has shown them once, Location allowed, so the renders list networks and devices.
        SetupDevices.make = {
            let wifi = SetupWiFiTests.FakeWiFi()
            wifi.location = .allowed
            // As many networks and devices as a flat in a town sees and a desk holds.
            wifi.nearby += [WiFiNetwork(name: "Vodafone-5G-2F1A", signal: -66, secured: true), WiFiNetwork(name: "GO-Fibre-8812", signal: -74, secured: true),
                            WiFiNetwork(name: "Melita_Home", signal: -77, secured: true), WiFiNetwork(name: "DIRECT-HP-Printer", signal: -83, secured: true),
                            WiFiNetwork(name: "Airport Guest", signal: -86, secured: false), WiFiNetwork(name: "iPhone de Sofía", signal: -88, secured: true)]
            let bluetooth = SetupBluetoothTests.FakeBluetooth()
            bluetooth.devices += [BluetoothDevice(address: "aa-04", name: "Magic Trackpad", connected: true),
                                  BluetoothDevice(address: "aa-05", name: "Sony WH-1000XM5", connected: false),
                                  BluetoothDevice(address: "aa-06", name: "Apple Watch", connected: false)]
            bluetooth.reached.insert("aa-04")
            let defaults = SetupBluetoothTests.defaults(shown: true)
            defaults.set(true, forKey: SetupWiFi.shownKey)
            return SetupDevices(audio: SetupSoundTests.FakeAudio(), bluetooth: bluetooth, wifi: wifi,
                                displays: SetupDisplays(system: SetupDisplaysTests.FakeDisplays()),
                                look: Look(inputSources: SetupKeepAwakeTests.FakeSources()), defaults: defaults,
                                pointer: PointerSpeed(system: SharedLook.PointerSpeedRenders.FakePointer()))
        }
        defer { SetupDevices.make = made }

        let clips = try Self.seedClips(home: URL(fileURLWithPath: home))
        ClipboardHistory.shared.useStore(clips)
        defer { ClipboardHistory.shared.useStore(nil) }

        // Files › Folders (P43): three folders in the moved home dressed through Pilot's own store, one a git repository;
        // three of Your designs (P55), cut-out folders drawn here, the first worn by Projects.
        let pack = URL(fileURLWithPath: home).appending(path: "Pack", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        for (name, colour) in [("Ocean", NSColor.systemTeal), ("Moss", .systemGreen), ("Ember", .systemOrange)] {
            let art = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { _ in
                colour.blended(withFraction: 0.25, of: .black)?.setFill()
                NSBezierPath(roundedRect: NSRect(x: 20, y: 150, width: 100, height: 60), xRadius: 14, yRadius: 14).fill()
                colour.setFill()
                NSBezierPath(roundedRect: NSRect(x: 20, y: 40, width: 216, height: 160), xRadius: 18, yRadius: 18).fill()
                return true
            }
            let rep = try #require(art.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try #require(rep.representation(using: .png, properties: [:])).write(to: pack.appending(path: "\(name).png"))
        }
        YourFolderDesigns.standard.add([pack])
        let yours = try #require(YourFolderDesigns.standard.list().first)
        let dressed = [("Projects", yours.design.id), ("Documents/Design", "lagoon"), ("code/pilot", "terminal")]
            .map { (URL(fileURLWithPath: home).appending(path: $0, directoryHint: .isDirectory), $1) }
        for (folder, design) in dressed {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if design == "terminal" { try FileManager.default.createDirectory(at: folder.appending(path: ".git"), withIntermediateDirectories: true) }
            let icon = try #require(design == yours.design.id ? FolderDesigns.icon(.yours(yours.design, yours.file)) : FolderDesigns.art(design))
            try FolderDesigns.looks.apply(icon, design: design, to: folder)
        }
        defer { for (folder, _) in dressed { _ = try? FolderDesigns.looks.reset(folder) } }

        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map(name.contains) ?? true }
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.fill")!)
        model.onScreen = true
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        Look.shared.themeID = "lagoon"
        defer { Look.shared.themeID = PilotTheme.defaultID }
        for (width, height) in Self.sizes {
            window.setContentSize(NSSize(width: CGFloat(width), height: CGFloat(height)))
            for (name, place, section) in Self.places where wanted("\(name)-\(width)") {
                model.go(AppPlace(.binds))
                try await Task.sleep(for: .milliseconds(100))
                if let section { model.setupSection = section }
                model.go(place)
                // A sleep, not a run loop spin: the test runs on the main actor, so a page's own main-actor tasks (Setup
                // starting its Wi-Fi and Bluetooth) run only once the test yields.
                try await Task.sleep(for: .milliseconds(800))
                frame.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(frame, scale: 1))
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: dir.appendingPathComponent("\(name)-\(width).png"))
                // Stats and Menu bar fill the window (card agent-bo-95423024): no blank run a third of it tall.
                if ["stats", "menubar"].contains(name) {
                    let blank = FillPagesTests.longestBlank(FillPagesTests.inked(rep, columns: 0.3..<1))
                    #expect(blank < 1.0 / 3, "\(name)-\(width): \(blank)")
                }
            }
        }
    }

    /// The Hyper+Space branches whose icons the card gives meaning: Remove on apps that are on every Mac plus a formula, a
    /// font, a cask without an app and a web app; Install and two of its categories on the shipped catalogue; Update;
    /// Clean's preview; Learn's keybindings, Trigger and System on the registry's own actions.
    @Test("The menu's branches render with their icons", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderMenu() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("menu")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        var remove = [RemoveRow]()
        RemoveList.addApps(&remove, paths: ["/System/Applications/Calculator.app", "/System/Applications/Calendar.app", "/System/Applications/Music.app",
                                            "/System/Applications/Notes.app", "/Applications/Safari.app", "/System/Applications/TextEdit.app"], skipping: [])
        remove += [RemoveRow(source: .package(Package(.formula, "lazygit")!), name: "lazygit"),
                   RemoveRow(source: .package(Package(.formula, "ripgrep")!), name: "ripgrep"),
                   RemoveRow(source: .package(Package(.cask, "font-jetbrains-mono")!), name: "JetBrains Mono"),
                   RemoveRow(source: .package(Package(.cask, "karabiner-elements")!), name: "Karabiner-Elements"),
                   RemoveRow(source: .package(Package(.uv, "llm")!), name: "llm"),
                   RemoveRow(source: .webApp(bundleID: "dev.banozz.pilot.webapp.chatgpt"), name: "ChatGPT")]
        let removeRows = RemoveList.entries(RemoveList.sorted(remove, .name))
        let catalogue = try InstallCatalogue.parse(Data(contentsOf: RestyledPagesTests.shipped))
        let install = MenuEntries.install(catalogue, installed: [])
        let updates = UpdateList.entries([UpdateRow(item: .package(Package(.formula, "lazygit")!), from: "0.55", to: "0.56"),
                                          UpdateRow(item: .package(Package(.cask, "zed")!), from: "0.205", to: "0.206"),
                                          UpdateRow(item: .appStore(id: "497799835", name: "Xcode"), from: "26.0", to: "26.1"),
                                          UpdateRow(item: .npm("@openai/codex", prefix: "/opt/homebrew"), from: "0.40", to: "0.41"),
                                          UpdateRow(item: .macOS(label: "macOS 26.1", title: "macOS Tahoe 26.1", restart: true), from: "", to: "26.1")],
                                         includeSelfUpdating: false, masInstalled: false)
        let preview = CleanPreview.parse("""
        ➤ Browsers
        → Chrome cache · 1.73GB dry
        → Safari cache · 312MB dry
        ➤ Developer tools
        → Xcode DerivedData · 4.2GB dry
        → npm cache · 820MB dry
        ➤ User essentials
        → User app logs · 96MB dry
        → Trash · 1.1GB dry
        → Downloads leftovers · 40MB dry
        ➤ Applications
        → Slack cache · 210MB dry
        → Spotify cache · 1.4GB dry
        Potential space: 9.9GB | 10 items
        """)
        let clean = CleanMenu.entries(preview, mole: true)
        let engine = Engine()
        let built = MenuEntries.build(apps: [("Finder", "com.apple.finder"), ("TextEdit", "com.apple.TextEdit")], actions: engine.bindActions,
                                      store: engine.binds.store, roleApps: [:], menu: AppsModule.menuID, openID: AppsModule.openID(bundle:),
                                      running: [], extras: [:], switches: [:])
        let panels: [(String, MenuNavigator)] = [
            ("remove", MenuNavigator(entries: removeRows, branch: .remove)), ("install", MenuNavigator(entries: install, branch: .install)),
            ("install-fonts", MenuNavigator(entries: install, branch: .category("Fonts"))),
            ("install-cli", MenuNavigator(entries: install, branch: .category("Command-line tools"))),
            ("update", MenuNavigator(entries: updates, branch: .update)), ("clean", MenuNavigator(entries: clean, branch: .clean)),
            ("clean-previewing", MenuNavigator(entries: [], branch: .clean)),
            ("learn", MenuNavigator(entries: built, branch: .keybindings)), ("trigger", MenuNavigator(entries: built, branch: .trigger)),
            ("system", MenuNavigator(entries: built, branch: .system)),
        ]
        Look.shared.themeID = "lagoon"
        defer { Look.shared.themeID = PilotTheme.defaultID }
        for (name, nav) in panels {
            let panel = HUD.makePanel(MenuView(model: MenuModel(nav: nav)))
            defer { panel.close() }
            let content = try #require(panel.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            content.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(content, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    /// A few configs in the moved home with lines like a Mac with dotfiles has, so Defaults' cards show real glimpses.
    static func seedConfigs(home: URL) throws {
        let files = [
            ".config/ghostty/config": "# Ghostty\nfont-family = JetBrains Mono\nfont-size = 14\ntheme = pilot\nwindow-padding-x = 10\nmacos-titlebar-style = hidden\nconfirm-close-surface = false\n",
            ".zshrc": "# zsh\nexport EDITOR=code\nexport PATH=\"$HOME/.local/bin:$PATH\"\neval \"$(starship init zsh)\"\nalias g=lazygit\nsetopt HIST_IGNORE_DUPS\n",
            ".gitconfig": "[user]\n\tname = Alex\n[init]\n\tdefaultBranch = main\n[pull]\n\trebase = true\n[push]\n\tautoSetupRemote = true\n",
            ".config/nvim/init.lua": "-- Neovim\nvim.g.mapleader = \" \"\nvim.opt.number = true\nvim.opt.relativenumber = true\nvim.opt.tabstop = 4\nrequire(\"config.lazy\")\n",
            ".config/starship.toml": "# Starship\nadd_newline = false\nformat = \"$directory$git_branch$character\"\n[character]\nsuccess_symbol = \"[❯](green)\"\n[directory]\ntruncation_length = 3\n",
        ]
        for (file, text) in files {
            let url = home.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        // The engine's file: the lines a hand-written one starts with, once, ahead of the block Pilot writes.
        let toml = home.appendingPathComponent(".aerospace.toml")
        if (try? Data(contentsOf: toml))?.isEmpty ?? true {
            try Data("# AeroSpace\nstart-at-login = true\nenable-normalization-flatten-containers = true\ndefault-root-container-layout = 'tiles'\naccordion-padding = 30\n".utf8).write(to: toml)
        }
    }
}
}
#endif
