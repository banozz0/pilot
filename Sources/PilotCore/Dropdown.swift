import Foundation

/// Pilot's menu-bar dropdown (card agent-bo-95422912; round 3's dropdown, "Menu bar changes ok", redrawn in design round
/// 4, artifact 5sh21HWjCjsWYAwWKTibcE, approved by Sven in chat 2026-10-06), compact since spec pilot-1-1 T29 (Q644 A,
/// row set A of Q683), tall since spec desktop-controls T3 (Sven's pick A, each block its card): Status, with any problem
/// at the top; the workspaces; the quick switches; what is running, only while something runs; the rows with their keys; Check
/// for updates, Settings and Quit on one line. Holding Option adds the developer rows and the recent presses.
public enum Dropdown {
    /// The launcher's action (Hyper+Space): the one bind Key binds off keeps, and the Menu row's (spec pilot-ui-redesign T4).
    public static let launcherAction = "apps.launcher"

    /// A block by the name `pilot set dropdown.*` takes (spec desktop-controls T4). Extensions, sound, connections,
    /// display, media and stats are the tall menu's optional blocks, off until shown; the developer rows and the footer are
    /// fixed.
    public enum Block: String, CaseIterable, Codable, Sendable {
        case status, workspaces, quickSwitches = "switches", extensions, now = "running"
        case sound, connections, display, media, stats
        case rows = "commands", developer, footer
    }

    /// Today's compact blocks in order: the developer rows, before the footer, only while Option is
    /// held. Now draws only while something runs (a recording, a focus timer, a download), and reads that itself, so a
    /// countdown redraws only it. The optional blocks are the tall menu's alone.
    public static func blocks(option: Bool) -> [Block] {
        [.status, .workspaces, .quickSwitches, .now, .rows, .developer, .footer].filter { option || $0 != .developer }
    }

    /// The tall menu's arrangement (spec desktop-controls T4, Launcher › Your menu's pattern): the order of the blocks
    /// that move, which are hidden and which are pinned above the scroll, and which quick switches the Switches block
    /// shows. Status hidden still leads while a problem waits (`shown(problems:)`); the developer rows and the footer stay
    /// where they are.
    public struct Layout: Codable, Equatable, Sendable {
        public var order: [Block]
        public var hidden: Set<Block>
        public var pinned: Set<Block>
        /// The extensions' ids whose bar items the Extensions card lists, in order (Sven, 2026-11-11, Q74 A, Q75: its own
        /// list, not the pill's).
        public var extensions: [String]
        /// The quick switches the Switches block shows, drawn in `Switch.allCases` order (spec pilot-ui-redesign T20).
        public var switches: Set<Switch>

        /// The blocks that can move, in their first order.
        public static let arrangeable: [Block] = [.status, .workspaces, .quickSwitches, .extensions, .now, .sound, .connections, .display,
                                                  .media, .stats, .rows]
        /// Off until shown (Sven's "yes", 2026-11-08; Extensions, 2026-11-11).
        public static let optional: Set<Block> = [.extensions, .sound, .connections, .display, .media, .stats]
        /// The tall menu, an install from before's arrangement while it has none saved: every block but the optional ones,
        /// all seven switches.
        public static let standard = Layout(order: arrangeable, hidden: optional, pinned: [])
        /// The one Pilot menu, a new install's arrangement (spec pilot-ui-redesign T20, S4 B, shot 4b; Open question 6,
        /// Sven 2026-11-19): the four switches, then the workspaces, then the footer's Open Pilot and Quit. Every other
        /// block and the other three switches are hidden, there to turn back on from Desktop › Pilot menu. Status is
        /// first but hidden, so it shows only while a problem waits.
        public static let pilotMenu: Layout = {
            let lead: [Block] = [.status, .quickSwitches, .workspaces]
            return Layout(order: lead + arrangeable.filter { !lead.contains($0) },
                          hidden: Set(arrangeable).subtracting([.quickSwitches, .workspaces]), pinned: [], switches: Set(Switch.four))
        }()

        public init(order: [Block], hidden: Set<Block>, pinned: Set<Block>, extensions: [String] = [], switches: Set<Switch> = Set(Switch.allCases)) {
            self.order = order; self.hidden = hidden; self.pinned = pinned; self.extensions = extensions; self.switches = switches
        }

        /// A layout saved before the Extensions card has no `extensions`: it reads as none. One saved before T20 has no
        /// `switches`: it reads as all seven, as that menu showed them.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            order = try c.decode([Block].self, forKey: .order)
            hidden = try c.decode(Set<Block>.self, forKey: .hidden)
            pinned = try c.decode(Set<Block>.self, forKey: .pinned)
            extensions = (try? c.decodeIfPresent([String].self, forKey: .extensions)) ?? []
            switches = (try? c.decodeIfPresent(Set<Switch>.self, forKey: .switches)) ?? Set(Switch.allCases)
        }

        /// The extensions asked on the menu's account while it is open: its own, only while the Extensions card shows.
        public var asked: [String] { shown.contains(.extensions) ? extensions : [] }

        /// The blocks that show, in order.
        public var shown: [Block] { order.filter { !hidden.contains($0) } }

        /// The blocks the menu draws: `shown`, with a hidden Status back in its place while any problem waits, so a
        /// problem always leads the menu it is hidden from.
        public func shown(problems: Bool) -> [Block] { order.filter { !hidden.contains($0) || (problems && $0 == .status) } }

        /// The switches the Switches block draws, in their order.
        public var shownSwitches: [Switch] { Switch.allCases.filter(switches.contains) }

        /// `given` first, then the rest in their first order; refuses a fixed block or one named twice.
        public static func order(_ given: [Block]) throws(ControlError) -> [Block] {
            if let fixed = given.first(where: { !arrangeable.contains($0) }) {
                throw ControlError(.badValue, "\(fixed.rawValue) stays where it is; the blocks that move are \(names(arrangeable))")
            }
            guard Set(given).count == given.count else { throw ControlError(.badValue, "a block is named twice in \(names(given))") }
            return given + arrangeable.filter { !given.contains($0) }
        }

        /// Refuses hiding a fixed block. Status may hide since T20: a problem still brings it back (`shown(problems:)`).
        public static func hide(_ given: Set<Block>) throws(ControlError) -> Set<Block> {
            if let fixed = given.first(where: { !arrangeable.contains($0) }) { throw ControlError(.badValue, "\(fixed.rawValue) can't be hidden") }
            return given
        }

        public static func pin(_ given: Set<Block>) throws(ControlError) -> Set<Block> {
            if let fixed = given.first(where: { !arrangeable.contains($0) }) { throw ControlError(.badValue, "\(fixed.rawValue) can't be pinned") }
            return given
        }

        /// `block` moved to `index` in the order (the edit list's arrows and drag), the others keeping theirs.
        public mutating func move(_ block: Block, to index: Int) {
            guard let from = order.firstIndex(of: block), order.indices.contains(index) else { return }
            order.insert(order.remove(at: from), at: index)
        }

        public static func names(_ blocks: [Block]) -> String { blocks.map(\.rawValue).joined(separator: ",") }
    }

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
    /// Each one's raw value is its name in `pilot set dropdown.switches` and in a saved layout.
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

    /// The dropdown's rows (row set A, Q683; Sven 2026-10-10: "make sure it has all the most important stuff"): what opens
    /// by key, listed as a reminder and for mouse moments; capture and voice; the ways into Pilot that have no key; then
    /// the footer's line. A row with a registered action shows that action's bind; Settings and Quit keep their ⌘ keys.
    /// Send feedback and Support are on General's About (Settings).
    public enum Row: CaseIterable, Sendable {
        case menu, clipboard, aiChat, quickNotes, dictate, captureArea, screenRecording, keysMap, extensions, updates, settings, quit
        case printObservers, rescue

        /// The developer rows while Option is held.
        public static let developer: [Row] = [.printObservers, .rescue]

        public var title: String {
            switch self {
            case .menu: "Pilot menu"
            case .clipboard: "Clipboard history"
            case .aiChat: "AI chat"
            case .quickNotes: "Quick notes"
            case .dictate: "Dictate"
            case .captureArea: "Capture area"
            case .screenRecording: "Screen recording"
            case .keysMap: "Keys map"
            case .extensions: "Extensions"
            case .updates: "Check for updates"
            case .settings: "Settings"
            case .quit: "Quit"
            case .printObservers: "Print observers"
            case .rescue: "Rescue stranded windows"
            }
        }

        public var symbol: String {
            switch self {
            case .menu: "magnifyingglass"
            case .clipboard: "list.clipboard"
            case .aiChat: "sparkles"
            case .quickNotes: "pencil"
            case .dictate: "mic"
            case .captureArea: "crop"
            case .screenRecording: "video"
            case .keysMap: "keyboard"
            case .extensions: "puzzlepiece.extension"
            case .updates: "arrow.triangle.2.circlepath"
            case .settings: "gearshape"
            case .quit: "power"
            case .printObservers: "text.alignleft"
            case .rescue: "lifepreserver"
            }
        }

        /// The registered action the row runs, whose bind it shows.
        public var actionID: String? {
            switch self {
            case .menu: Dropdown.launcherAction
            case .clipboard: "apps.clipboard"
            case .aiChat: "ai.chat"
            case .quickNotes: "notes.toggle"
            case .dictate: "dictation.toggle"
            case .captureArea: "captures.area"
            case .screenRecording: "captures.screenRecording"
            default: nil
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

    /// The rows' groups under the switches and Now, each with its heading. Widgets joins Pilot's once it has a page
    /// (spec pilot-1-1 T17 to T24).
    public static let groups: [(title: String, rows: [Row])] = [
        ("Open", [.menu, .clipboard, .aiChat, .quickNotes, .dictate]),
        ("Capture", [.captureArea, .screenRecording]),
        ("Pilot", [.keysMap, .extensions]),
    ]

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

    /// Every row the dropdown offered before card 912 or dropped since, and where it is now, so nothing goes missing.
    public static let carried: [(row: String, block: Block, now: String)] = [
        ("The workspaces with windows, a click going there", .workspaces, "a tile per workspace with its apps"),
        ("The tiler is not running: tiling and workspaces are off", .status, "the tiler problem with Restart; Workspaces back once it runs"),
        ("Rescue stranded windows", .status, "a command under Option; the tiler problem restarts it"),
        ("Always rescue when the tiler quits", .developer, "gone with the old tiler (R3)"),
        ("Accessibility not granted", .status, "the Accessibility problem"),
        ("Finish setup…", .status, "Allow on the Accessibility problem"),
        ("A password field has the keyboard", .status, "the secure input problem"),
        ("Hyper held / Hyper is <key>", .status, "the line under the headline"),
        ("Pilot's last error", .status, "a problem"),
        // Now shows only what runs (spec pilot-1-1 T29): the last press went to Option's rows.
        ("Last: <press>", .developer, "the recent presses, commands under Option"),
        ("Recent presses", .developer, "the recent presses, commands under Option"),
        // Pilot is the whole app, so it has no on/off here; the Hyper key does (Sven, 2026-10-07; card agent-bo-95422986).
        ("Pilot (the on/off switch)", .quickSwitches, "the Key binds switch"),
        // Other apps are not Pilot's to mention (Sven, C3 2026-10-10): the ticks left; the saved choice still applies.
        ("Also quit Karabiner-Elements", .developer, "gone; the saved choice still applies"),
        ("Also quit Hammerspoon", .developer, "gone; the saved choice still applies"),
        ("The switch's problem", .status, "a problem"),
        ("Print observers", .developer, "a command under Option"),
        ("Open Pilot… ⌘,", .footer, "Settings ⌘,"),
        ("Quit Pilot ⌘Q", .footer, "Quit ⌘Q"),
        // Spec pilot-1-1 T29: both are on General's About, which Settings opens.
        ("Send feedback", .footer, "Settings, then About"),
        ("Support Pilot", .footer, "Settings, then General's Support"),
    ]
}
