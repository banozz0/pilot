/// First-run onboarding (stories 1, 2, 40, 94, 103 and 104; SPEC.md, Onboarding; Onboarding 1.1, variant C, Q841-Q843):
/// Hyper picks the key, Access ticks itself once Accessibility is allowed, Set up runs everything or what was picked by
/// hand (SetupScript for the helpers), and Try it ticks on the first hold and the first Hyper+Space. Pure: the app fills
/// `Status`; `Row` also serves `pilot status --part onboarding` and Settings › Permissions.
public enum Onboarding {
    /// Every layer key, Caps Lock suggested (P68: Control, Option and right Command too).
    public static let hyperChoices = LayerKey.allCases

    /// A choice's line under its name: what Caps Lock keeps, or what a modifier no longer does (LayerKey.note).
    public static func hyperDetail(_ key: LayerKey) -> String {
        key == .capsLock ? "suggested · tap alone for Escape · Shift+Caps Lock still types capitals" : key.note
    }

    public struct Status: Equatable, Sendable {
        public var accessibility = false, systemEvents = false
        /// The file index's grant (card agent-bo-95422768).
        public var fullDiskAccess = false
        /// Pilot's own dictation's grant (story 194).
        public var microphone = false
        /// The grants features ask at their first use, shown on Permissions too (Sven, 2026-10-28, Q4).
        public var screenRecording = false, inputMonitoring = false, notifications = false
        public var bluetooth = false, location = false, calendars = false, reminders = false
        public var clashes = 0

        public init(accessibility: Bool = false, systemEvents: Bool = false, clashes: Int = 0) {
            self.accessibility = accessibility; self.systemEvents = systemEvents; self.clashes = clashes
        }
    }

    /// How much Pilot needs a row: Settings › Permissions' groups, in this order (Sven, 2026-10-28, Q4); Access names the
    /// recommended and optional ones for later (Onboarding 1.1).
    public enum Need: CaseIterable, Sendable {
        case required, recommended, optional, whenUsed

        public var title: String {
            switch self {
            case .required: "Needed"
            case .recommended: "Recommended"
            case .optional: "Optional"
            case .whenUsed: "Only when you use them"
            }
        }
    }

    /// Permissions' rows: every grant Pilot can use (Sven, 2026-10-28: "make sure that we have all permissions shown in
    /// the onboarding"), and the clashing shortcuts.
    public enum Row: CaseIterable, Sendable {
        case accessibility, systemEvents, fullDiskAccess, conflicts, microphone, screenRecording, inputMonitoring, notifications
        case bluetooth, location, calendars, reminders

        public var need: Need {
            switch self {
            case .accessibility: .required
            case .systemEvents, .fullDiskAccess, .conflicts: .recommended
            case .microphone, .screenRecording, .inputMonitoring, .notifications: .optional
            case .bluetooth, .location, .calendars, .reminders: .whenUsed
            }
        }

        public static func rows(_ need: Need) -> [Row] { allCases.filter { $0.need == need } }

        public var title: String {
            switch self {
            case .accessibility: "Allow Pilot to use Accessibility"
            case .systemEvents: "Allow Pilot to control System Events"
            case .fullDiskAccess: "Allow Pilot Full Disk Access"
            case .conflicts: "Turn off clashing macOS shortcuts"
            case .microphone: "Allow Pilot to use the microphone"
            case .screenRecording: "Allow Pilot to record the screen"
            case .inputMonitoring: "Allow Pilot Input Monitoring"
            case .notifications: "Allow Pilot to send notifications"
            case .bluetooth: "Allow Pilot to use Bluetooth"
            case .location: "Allow Pilot to use your location"
            case .calendars: "Allow Pilot to read your calendars"
            case .reminders: "Allow Pilot to read your reminders"
            }
        }

        public func detail(_ s: Status) -> String {
            switch self {
            case .accessibility: "so Pilot can see keys and move windows"
            case .systemEvents: "for dark mode, sleep and log out; skipped, each asks the first time"
            case .fullDiskAccess: "so the menu finds files in Desktop, Documents and Downloads; until then it lists no files"
            case .conflicts:
                "\(s.clashes) macOS shortcut\(s.clashes == 1 ? "" : "s") would fight Pilot's keys and get switched off. "
                    + "Review them or put them back any time in \(AppPlace(.conflicts).path)."
            case .microphone: "for Pilot's own dictation; skip it if you never dictate"
            case .screenRecording: "for screenshots, scrolling captures, recordings and exact menu bar items; skipped, your first capture asks"
            case .inputMonitoring: "tells a mouse's media keys from your keyboard's, in \(AppPlace(.mouse).path)"
            case .notifications: "for low-battery alerts about your mouse, keyboard and headphones"
            case .bluetooth: "lists and connects your paired devices in Setup › Bluetooth"
            case .location: "macOS hides Wi-Fi names without it, in Setup › Wi-Fi"
            case .calendars: "your events in the clock's popover, and quick events"
            case .reminders: "reminders with a due day beside your events in the clock's popover"
            }
        }
    }

    public static func isDone(_ row: Row, _ s: Status) -> Bool {
        switch row {
        case .accessibility: s.accessibility
        case .systemEvents: s.systemEvents
        case .fullDiskAccess: s.fullDiskAccess
        case .conflicts: s.clashes == 0
        case .microphone: s.microphone
        case .screenRecording: s.screenRecording
        case .inputMonitoring: s.inputMonitoring
        case .notifications: s.notifications
        case .bluetooth: s.bluetooth
        case .location: s.location
        case .calendars: s.calendars
        case .reminders: s.reminders
        }
    }

    /// Continue unlocks on Accessibility alone, the one grant Pilot needs to run (ADR 0005); every other row can be left
    /// for Settings or for the feature's first use (card agent-bo-95423043).
    public static func canContinue(_ s: Status) -> Bool { s.accessibility }

    /// Try it's two prompts, each ticked by the engine: a hold of the layer key, then Hyper+Space opening the menu. Only
    /// opens after Try it starts count, so the Install confirm step's panel during Set up never ticks it.
    public struct TryIt: Equatable, Sendable {
        public var held = false
        public private(set) var menuOpened = false
        private let menuOpensAtStart: Int

        public init(menuOpens: Int) { menuOpensAtStart = menuOpens }

        public mutating func see(menuOpens: Int) { if menuOpens > menuOpensAtStart { menuOpened = true } }
    }

    /// AEDeterminePermissionToAutomateTarget's answer for System Events: 0 is allowed; procNotFound (-600) comes whenever
    /// System Events is not running, whatever the grant, and it quits itself when idle, so the row keeps `last`.
    public static func systemEvents(answer: Int32, last: Bool) -> Bool { answer == -600 ? last : answer == 0 }
}

extension Onboarding.Row {
    /// A grant's name on Access's "Later, from Settings" panel (Onboarding 1.1, T54).
    public var short: String {
        switch self {
        case .accessibility: "Accessibility"
        case .systemEvents: "System Events"
        case .fullDiskAccess: "Full Disk Access"
        case .conflicts: "clashing shortcuts"
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording at first capture"
        case .inputMonitoring: "Input Monitoring"
        case .notifications: "Notifications"
        case .bluetooth: "Bluetooth"
        case .location: "Location"
        case .calendars: "Calendars"
        case .reminders: "Reminders"
        }
    }
}

/// Set up's one Terminal run for the helpers (Onboarding 1.1, T54): Homebrew's installer when it is missing, then each
/// formula on its own, so one failure never stops the rest; npm and cargo, which bring Node and Rust, come last. Each step
/// writes its state to `status` as it goes ("mole installing", "mole done", "mole failed exit 1"), which Pilot reads to
/// show each helper's line; "end" closes the run, "closed" means the window went before it finished, "stopped" that
/// Ctrl-C stopped it. Homebrew's
/// installer asks for the Mac's password itself, there.
public enum SetupScript {
    public struct Step: Equatable, Sendable {
        /// The item's id, as the status lines name it.
        public let id: String
        /// What installs it, run as written.
        public let command: String
        /// The command that is on the Mac once it installed (`brew`, `mo`, `cwebp`).
        public let check: String
        /// Run after it installs: Install's record of a package Pilot installed.
        public let hook: String?
        /// What the window prints before it runs; the command itself when nil. Homebrew's installer is a `$(curl …)`,
        /// which would print the whole fetched script.
        public let label: String?

        public init(id: String, command: String, check: String, hook: String? = nil, label: String? = nil) {
            self.id = id; self.command = command; self.check = check; self.hook = hook; self.label = label
        }
    }

    /// The script, as a zsh file that deletes itself once it starts. A step whose command is missing after an exit 0
    /// fails all the same (Homebrew's installer exits 0 when curl fetched nothing); a formula fails without a run while
    /// brew is missing.
    public static func script(_ steps: [Step], status: String) -> String {
        let q = VisibleRun.quoted
        let lines = steps.map { "step \(q($0.id)) \(q($0.check)) \(q($0.hook ?? "")) \(q($0.label ?? $0.command)) \($0.command)" }
        return """
        #!/bin/zsh
        rm -f -- "$0"
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        f=\(q(status))
        : > "$f"
        trap 'print -r -- closed >> "$f"; exit 129' HUP TERM
        trap 'print -r -- stopped >> "$f"; exit 130' INT
        failed=0
        step() {
          local id=$1 check=$2 hook=$3 label=$4; shift 4
          if [[ $id != homebrew ]] && ! command -v brew > /dev/null; then
            print -r -- "$id failed nobrew" >> "$f"; failed=1; return
          fi
          print -r -- "$id installing" >> "$f"
          print; print -r -- "$ $label"
          "$@"
          local s=$?
          if (( s != 0 )); then print -r -- "$id failed exit $s" >> "$f"; failed=1; return; fi
          if ! command -v "$check" > /dev/null; then print -r -- "$id failed missing" >> "$f"; failed=1; return; fi
          print -r -- "$id done" >> "$f"
          [[ -n $hook ]] && eval "$hook"
          return 0
        }
        \(lines.joined(separator: "\n"))
        print -r -- end >> "$f"
        exit $failed
        """
    }

    /// One helper's state as the run left it.
    public enum Outcome: Equatable, Sendable {
        case installing, done
        /// Why, in plain words.
        case failed(String)
    }

    /// The status file read: each id's last state, and whether the run ended or its window closed first. A step not
    /// named yet is waiting; once the window closed, a step still installing or waiting failed with that reason.
    public static func read(_ text: String, ids: [String]) -> (outcomes: [String: Outcome], finished: Bool) {
        var outcomes: [String: Outcome] = [:]
        var ended = false, closed = false, stopped = false
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ", maxSplits: 2).map(String.init)
            switch words.first {
            case "end": ended = true
            case "closed": closed = true
            case "stopped": stopped = true
            case let id? where words.count >= 2:
                switch words[1] {
                case "installing": outcomes[id] = .installing
                case "done": outcomes[id] = .done
                case "failed": outcomes[id] = .failed(reason(words.count > 2 ? words[2] : ""))
                default: break
                }
            default: break
            }
        }
        if (closed || stopped) && !ended {
            let why = stopped ? "Ctrl-C stopped the run before it finished" : "the Terminal window closed before it finished"
            for id in ids where outcomes[id] == nil || outcomes[id] == .installing { outcomes[id] = .failed(why) }
        }
        return (outcomes, ended || closed || stopped)
    }

    private static func reason(_ code: String) -> String {
        if code == "nobrew" { return "needs Homebrew, which did not install" }
        if code == "missing" { return "the install finished but its command is not on this Mac" }
        if code.hasPrefix("exit ") { return "stopped with \(code); the Terminal window says why" }
        return "stopped; the Terminal window says why"
    }
}
