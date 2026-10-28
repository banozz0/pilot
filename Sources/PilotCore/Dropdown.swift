import Foundation

/// Pilot's menu-bar dropdown in five blocks (card agent-bo-95422912; round 3's dropdown, "Menu bar changes ok", redrawn
/// in design round 4, artifact 5sh21HWjCjsWYAwWKTibcE, approved by Sven in chat 2026-10-06): Status, with any problem
/// at the top in red or amber; Workspaces; Quick switches; Now; the footer. Holding Option adds the developer rows.
public enum Dropdown {
    public enum Block: CaseIterable, Sendable {
        case status, workspaces, quickSwitches, now, developer, footer
    }

    /// The blocks in order: the developer rows, before the footer, only while Option is held.
    public static func blocks(option: Bool) -> [Block] { Block.allCases.filter { option || $0 != .developer } }

    /// The status block's headline: "Pilot is on", or how many things need fixing, which then lead the dropdown.
    public static func headline(isOn: Bool, problems: Int) -> String {
        if problems == 1 { return "Pilot needs 1 thing" }
        if problems > 1 { return "Pilot needs \(problems) things" }
        return isOn ? "Pilot is on" : "Pilot is off"
    }

    /// The line under it: what Hyper is now. Switched off (card agent-bo-95422986) it says so first: fixing a problem
    /// would not bring it back.
    public static func hyperLine(hyperOn: Bool, trusted: Bool, secureInput: Bool, held: Bool, layerKey: String, problems: Int) -> String {
        if !hyperOn { return "Hyper is off" }
        if !trusted || secureInput { return "Hyper is off until \(problems == 1 ? "it is" : "they are") fixed" }
        return held ? "Hyper held" : "Hyper is \(layerKey)"
    }

    public enum Switch: CaseIterable, Sendable {
        case hyper, tiling, topBar, keepAwake, clipboard

        /// The switches two by two under Hyper's full-width tile.
        public static let grid = allCases.filter { $0 != .hyper }

        public var title: String {
            switch self {
            case .hyper: "Hyper key"
            case .tiling: "Tiling"
            case .topBar: "Top bar"
            case .keepAwake: "Keep awake"
            case .clipboard: "Clipboard"
            }
        }

        /// The line under the title, round 3's: what the switch is doing now. Hyper off names the key macOS has back;
        /// Tiling names the tiler (card agent-bo-95423025).
        public func state(_ on: Bool, layerKeys: [LayerKey], tiler: String) -> String {
            switch self {
            case .hyper: on ? "binds on" : "\(layerKeys.label) left to macOS"
            case .tiling: on ? "\(tiler) on" : "\(tiler) paused"
            case .topBar: on ? "macOS bar hidden" : "macOS bar shown"
            case .keepAwake: on ? "kept awake" : "sleeps as usual"
            case .clipboard: on ? "recording" : "paused"
            }
        }

        /// Its SF Symbol; Hyper's is its layer key's own sign (⇪, ⌥ or ⌘).
        public func symbol(layerKeys: [LayerKey]) -> String {
            switch self {
            case .hyper: layerKeys.primary.systemImage
            case .tiling: "rectangle.split.3x1"
            case .topBar: "menubar.rectangle"
            case .keepAwake: "cup.and.saucer"
            case .clipboard: "doc.on.clipboard"
            }
        }
    }

    /// The dropdown's rows under its blocks, one list every style draws (Sven 2026-10-10: "make sure it has all the most
    /// important stuff"): what opens most first, then Pilot itself, then Quit, each group on its own rule. A row with a
    /// registered action shows that action's bind; Open Pilot and Quit keep their ⌘ keys.
    public enum Row: CaseIterable, Sendable {
        case openPilot, menu, clipboard, aiChat, updates, feedback, support, quit
        case printObservers, rescue

        /// The developer rows while Option is held.
        public static let developer: [Row] = [.printObservers, .rescue]

        public var title: String {
            switch self {
            case .openPilot: "Open Pilot"
            case .menu: "Pilot menu"
            case .clipboard: "Clipboard history"
            case .aiChat: "AI chat"
            case .updates: "Check for updates"
            case .feedback: "Send feedback"
            case .support: "Support Pilot"
            case .quit: "Quit Pilot"
            case .printObservers: "Print observers"
            case .rescue: "Rescue stranded windows"
            }
        }

        public var symbol: String {
            switch self {
            case .openPilot: "gearshape"
            case .menu: "magnifyingglass"
            case .clipboard: "list.clipboard"
            case .aiChat: "sparkles"
            case .updates: "arrow.triangle.2.circlepath"
            case .feedback: "exclamationmark.bubble"
            case .support: "heart"
            case .quit: "power"
            case .printObservers: "text.alignleft"
            case .rescue: "lifepreserver"
            }
        }

        /// The registered action the row runs, whose bind it shows.
        public var actionID: String? {
            switch self {
            case .menu: "apps.launcher"
            case .clipboard: "apps.clipboard"
            case .aiChat: "ai.chat"
            default: nil
            }
        }

        /// Its ⌘ key, which also works while the dropdown has the keyboard.
        public var command: Character? {
            switch self {
            case .openPilot: ","
            case .quit: "q"
            default: nil
            }
        }
    }

    /// The footer's groups, top to bottom; Check for updates only where there is something to check (a release's update
    /// feed, or a bundle built from a commit).
    public static func footer(canUpdate: Bool) -> [[Row]] {
        [[.openPilot, .menu, .clipboard, .aiChat], canUpdate ? [.updates, .feedback, .support] : [.feedback, .support], [.quit]]
    }

    /// A row's key as the dropdown signs it (card agent-bo-95422993, G3): the real layer key's sign and the bind's own keys,
    /// "⇪⇧ Space" or "⌥ Space"; a plain combo by its name; nil when the action has no key.
    public static func keyLabel(_ key: Key?, layerKeys: [LayerKey]) -> String? {
        guard let key else { return nil }
        guard key.hyper else { return key.label }
        return layerKeys.symbol + (BindsKeyboard.Layer(hyper: key)?.signs ?? "") + " " + KeyNames.name(for: key.keyCode)
    }

    /// The Workspaces header's keys: the layer key's sign and 1 to the highest tile, at least 4, as Home's tile says.
    public static func workspaceKeys(layerKeys: [LayerKey], count: Int) -> String { "\(layerKeys.symbol) 1–\(max(4, count))" }

    /// Every row the dropdown offered before card 912, and where it is now, so nothing goes missing.
    public static let carried: [(row: String, block: Block, now: String)] = [
        ("The workspaces with windows, a click going there", .workspaces, "a tile per workspace with its apps"),
        ("The tiler is not running: tiling and workspaces are off", .status, "the tiler problem, Workspaces dimmed"),
        ("Rescue stranded windows", .status, "under Option; the tiler problem restarts it"),
        ("Always rescue when the tiler quits", .developer, "gone with the old tiler (R3)"),
        ("Accessibility not granted", .status, "the Accessibility problem"),
        ("Finish setup…", .status, "Allow on the Accessibility problem"),
        ("A password field has the keyboard", .status, "the secure input problem"),
        ("Hyper held / Hyper is <key>", .status, "the line under the headline"),
        ("Pilot's last error", .status, "a problem"),
        ("Last: <press>", .now, "the last press row"),
        ("Recent presses", .developer, "the recent presses under Option"),
        // Pilot is the whole app, so it has no on/off here; the Hyper key does (Sven, 2026-10-07; card agent-bo-95422986).
        ("Pilot (the on/off switch)", .quickSwitches, "gone; the Hyper key switch instead"),
        // Other apps are not Pilot's to mention (Sven, C3 2026-10-10): the ticks left; the saved choice still applies.
        ("Also quit Karabiner-Elements", .developer, "gone; the saved choice still applies"),
        ("Also quit Hammerspoon", .developer, "gone; the saved choice still applies"),
        ("The switch's problem", .status, "a problem"),
        ("Print observers", .developer, "a row under Option"),
        ("Open Pilot… ⌘,", .footer, "Open Pilot"),
        ("Quit Pilot ⌘Q", .footer, "Quit Pilot"),
    ]
}
