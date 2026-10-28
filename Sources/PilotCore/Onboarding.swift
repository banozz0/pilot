/// First-run onboarding (stories 1, 2, 40, 94, 103 and 104; SPEC.md, Onboarding; wireframe zu046xD_ceo): Welcome picks
/// the Hyper key, Permissions' rows tick themselves from what Pilot sees, Extras picks what to download (Sven,
/// 2026-10-28), and Try it ticks on the first hold and the first Hyper+Space. Pure: the app fills `Status` once a second
/// while Permissions shows.
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
        public var bluetooth = false, location = false, calendars = false
        public var clashes = 0

        public init(accessibility: Bool = false, systemEvents: Bool = false, clashes: Int = 0) {
            self.accessibility = accessibility; self.systemEvents = systemEvents; self.clashes = clashes
        }
    }

    /// How much Pilot needs a row: Permissions' groups, in this order; `whenUsed` starts folded (Sven, 2026-10-28, Q4).
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
        case bluetooth, location, calendars

        public var need: Need {
            switch self {
            case .accessibility: .required
            case .systemEvents, .fullDiskAccess, .conflicts: .recommended
            case .microphone, .screenRecording, .inputMonitoring, .notifications: .optional
            case .bluetooth, .location, .calendars: .whenUsed
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
            case .inputMonitoring: "tells a mouse's media keys from your keyboard's, in Binds › Mouse"
            case .notifications: "for low-battery alerts about your mouse, keyboard and headphones"
            case .bluetooth: "lists and connects your paired devices in Setup › Bluetooth"
            case .location: "macOS hides Wi-Fi names without it, in Setup › Wi-Fi"
            case .calendars: "your events in the clock's popover, and quick events"
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
        }
    }

    /// Continue unlocks on Accessibility alone, the one grant Pilot needs to run (ADR 0005); every other row can be left
    /// for Settings or for the feature's first use (card agent-bo-95423043).
    public static func canContinue(_ s: Status) -> Bool { s.accessibility }

    /// Permissions' foot: General lists some grants, and every feature asks its own at its first use.
    public static let continueNote = "Continue unlocks once Accessibility is allowed. The rest can wait: each feature asks at its first use."

    /// Try it's two prompts, each ticked by the engine: a hold of the layer key, then Hyper+Space opening the menu. Only
    /// opens after Try it starts count, so the Install confirm step's panel during Extras never ticks it.
    public struct TryIt: Equatable, Sendable {
        public var held = false
        public private(set) var menuOpened = false
        private let menuOpensAtStart: Int

        public init(menuOpens: Int) { menuOpensAtStart = menuOpens }

        public mutating func see(menuOpens: Int) { if menuOpens > menuOpensAtStart { menuOpened = true } }
    }

    /// Extras' one Terminal run (Sven, 2026-10-28, Q7): Homebrew's installer when it is missing, then `brew install` of
    /// the formulas picked; nil when there is nothing to run. Homebrew's installer asks for the Mac's password itself.
    public static func brewCommand(installer: String?, formulas: [String]) -> String? {
        let parts = [installer, formulas.isEmpty ? nil : "brew install \(formulas.joined(separator: " "))"].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " && ")
    }

    /// AEDeterminePermissionToAutomateTarget's answer for System Events: 0 is allowed; procNotFound (-600) comes whenever
    /// System Events is not running, whatever the grant, and it quits itself when idle, so the row keeps `last`.
    public static func systemEvents(answer: Int32, last: Bool) -> Bool { answer == -600 ? last : answer == 0 }
}
