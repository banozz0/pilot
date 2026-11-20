import Foundation

/// The Pilot menu (card agent-bo-95422912, design round 4, approved by Sven in chat 2026-10-06), one fixed menu since
/// 2026-11-20 (Sven: "pilot menu page shouldnt exist anymore either pilot menu should be simple"; pilot-ui-redesign T20,
/// S4 B): any problem at the top, the four switches, the workspaces, then Check for updates, Open Pilot and Quit. Holding
/// Option adds the developer rows and the recent presses. Nothing in it is arranged.
public enum Dropdown {
    /// The launcher's action (Hyper+Space): the one bind Key binds off keeps (spec pilot-ui-redesign T4).
    public static let launcherAction = "apps.launcher"

    /// The status block's headline: "Pilot is on", or how many things need fixing, which then lead the dropdown.
    public static func headline(isOn: Bool, problems: Int) -> String {
        if problems == 1 { return "Pilot needs 1 thing" }
        if problems > 1 { return "Pilot needs \(problems) things" }
        return isOn ? "Pilot is on" : "Pilot is off"
    }

    /// The line under it: what Hyper is now. `hyperOn` is the Key binds switch (`switch.on`), `launcherOn` the Launcher's
    /// (`launcher.on`). Both off (card agent-bo-95422986) it says so first: fixing a problem would not bring it back. Key
    /// binds off with the launcher on, Hyper+Space still works (spec pilot-ui-redesign T4's Open question 4, T20).
    public static func hyperLine(hyperOn: Bool, launcherOn: Bool = true, trusted: Bool, secureInput: Bool, held: Bool, layerKey: String,
                                 problems: Int) -> String {
        if !hyperOn, !launcherOn { return "Hyper is off" }
        if !trusted || secureInput { return "Hyper is off until \(problems == 1 ? "it is" : "they are") fixed" }
        if !hyperOn { return "Key binds are off: only Hyper+Space works" }
        return held ? "Hyper held" : "Hyper is \(layerKey)"
    }

    /// The quick switches. The first four (`four`) are Home's and the Pilot menu's (spec pilot-ui-redesign T4, S4 B):
    /// the launcher, the key binds, tiling and the clipboard; each is one saved setting.
    public enum Switch: String, CaseIterable, Codable, Sendable {
        case launcher, hyper = "keybinds", tiling, topBar = "topbar", keepAwake = "keepawake", clipboard, dictation

        /// Home's and the Pilot menu's four, in the order drawn (round 2's "Home's four switches are the same set").
        public static let four: [Switch] = [.launcher, .hyper, .tiling, .clipboard]
        /// Their group in `pilot schema`.
        public static let group = "switches"

        /// The setting `pilot get` reads it by; the four's only. Key binds is Pilot's on/off switch (`switch.on`, the
        /// binds armed), no longer the session-only Hyper key (`hyper.on`).
        public var settingKey: String? {
            switch self {
            case .launcher: "launcher.on"
            case .hyper: "switch.on"
            case .tiling: "tiling.on"
            case .clipboard: "clipboard.recording"
            case .topBar, .keepAwake, .dictation: nil
            }
        }

        public var title: String {
            switch self {
            case .launcher: "Launcher"
            case .hyper: "Key binds"
            case .tiling: "Tiling"
            case .topBar: "Top bar"
            case .keepAwake: "Keep awake"
            case .clipboard: "Clipboard"
            case .dictation: "Dictation key"
            }
        }

        /// Its word under the glyph in the compact menu's row (spec pilot-1-1 T29).
        public var short: String {
            switch self {
            case .hyper: "Binds"
            case .keepAwake: "Awake"
            case .dictation: "Dictation"
            default: title
            }
        }

        /// The tile's tooltip: its title and what it is doing now.
        public func tooltip(_ on: Bool, layerKeys: [LayerKey], tiler: String) -> String {
            "\(title): \(state(on, layerKeys: layerKeys, tiler: tiler))"
        }

        /// What the switch is doing now, round 3's line. Key binds off keeps only the launcher's key (Open question 4);
        /// Tiling names the tiler (card agent-bo-95423025).
        public func state(_ on: Bool, layerKeys: [LayerKey], tiler: String) -> String {
            switch self {
            case .launcher: on ? "opens on its key" : "its key does nothing"
            case .hyper: on ? "binds on" : "only the launcher's key"
            case .tiling: on ? "\(tiler) on" : "\(tiler) paused"
            case .topBar: on ? "macOS bar hidden" : "macOS bar shown"
            case .keepAwake: on ? "kept awake" : "sleeps as usual"
            case .clipboard: on ? "recording" : "paused"
            case .dictation: on ? "a tap dictates" : "no dictation key"
            }
        }

        /// Its SF Symbol; Key binds' is its layer key's own sign (⇪, ⌥ or ⌘).
        public func symbol(layerKeys: [LayerKey]) -> String {
            switch self {
            case .launcher: "magnifyingglass"
            case .hyper: layerKeys.primary.systemImage
            case .tiling: "rectangle.split.3x1"
            case .topBar: "menubar.rectangle"
            case .keepAwake: "moon"
            case .clipboard: "doc.on.clipboard"
            case .dictation: "mic"
            }
        }
    }

    /// The menu's rows: the footer's line, and the developer rows while Option is held. Settings and Quit keep their ⌘
    /// keys. (The command rows, row set A of Q683, went with the tall menu, 2026-11-20.)
    public enum Row: CaseIterable, Sendable {
        case updates, settings, quit
        case printObservers, rescue

        /// The developer rows while Option is held.
        public static let developer: [Row] = [.printObservers, .rescue]

        public var title: String {
            switch self {
            case .updates: "Check for updates"
            case .settings: "Settings"
            case .quit: "Quit"
            case .printObservers: "Print observers"
            case .rescue: "Rescue stranded windows"
            }
        }

        public var symbol: String {
            switch self {
            case .updates: "arrow.triangle.2.circlepath"
            case .settings: "gearshape"
            case .quit: "power"
            case .printObservers: "text.alignleft"
            case .rescue: "lifepreserver"
            }
        }

        /// Its ⌘ key, which also works while the dropdown has the keyboard.
        public var command: Character? {
            switch self {
            case .settings: ","
            case .quit: "q"
            default: nil
            }
        }
    }

    /// The footer's one line; Check for updates only where there is something to check (a release's update feed, or a
    /// bundle built from a commit).
    public static func footer(canUpdate: Bool) -> [Row] { canUpdate ? [.updates, .settings, .quit] : [.settings, .quit] }

    /// A row's key as the dropdown signs it (card agent-bo-95422993, G3): the real layer key's sign and the bind's own keys,
    /// "⇪⇧ Space" or "⌥ Space"; a plain combo by its name; nil when the action has no key.
    public static func keyLabel(_ key: Key?, layerKeys: [LayerKey]) -> String? {
        guard let key else { return nil }
        guard key.hyper else { return key.label }
        return layerKeys.symbol + (BindsKeyboard.Layer(hyper: key)?.signs ?? "") + " " + KeyNames.name(for: key.keyCode)
    }

    /// The Workspaces header's keys: the layer key's sign and 1 to the highest tile, at least 4, as Home's tile says.
    public static func workspaceKeys(layerKeys: [LayerKey], count: Int) -> String { "\(layerKeys.symbol) 1–\(max(4, count))" }

}
