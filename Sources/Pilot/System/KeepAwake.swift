import Foundation
import IOKit.pwr_mgt
import Observation

/// Power assertions: IOKit's is the real one; the tests use a fake, so no test keeps the Mac awake.
@MainActor
protocol PowerAssertions: AnyObject {
    /// An assertion of `type` named `name`; nil when macOS refuses.
    func hold(_ type: String, _ name: String) -> UInt32?
    func release(_ id: UInt32)
}

final class IOPowerAssertions: PowerAssertions {
    func hold(_ type: String, _ name: String) -> UInt32? {
        var id = IOPMAssertionID(0)
        let made = IOPMAssertionCreateWithName(type as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        return made == kIOReturnSuccess ? id : nil
    }

    func release(_ id: UInt32) { IOPMAssertionRelease(id) }
}

/// Setup › Keep awake (card agent-bo-95422801), and the menu's Keep awake action: the display and the Mac stay awake for
/// an hour, four hours or until turned off. Never restored at launch, so it never starts by itself; macOS drops the
/// assertion when Pilot quits, which ends it too.
@Observable @MainActor
final class KeepAwake {
    enum Length: CaseIterable {
        case hour, fourHours, untilOff

        var seconds: TimeInterval? {
            switch self {
            case .hour: 3600
            case .fourHours: 4 * 3600
            case .untilOff: nil
            }
        }

        var title: String {
            switch self {
            case .hour: "1 hour"
            case .fourHours: "4 hours"
            case .untilOff: "Until off"
            }
        }

        /// "for 1 hour", "until you turn it off": the HUD's and the log's words.
        var phrase: String { self == .untilOff ? "until you turn it off" : "for \(title)" }
    }

    static let shared = KeepAwake()
    /// What `pmset -g assertions` lists while it is on.
    static let assertionName = "Pilot keep-awake"
    /// Keeps the display, and so the Mac, from sleeping while idle.
    static let assertionType = kIOPMAssertionTypePreventUserIdleDisplaySleep as String

    private(set) var isOn = false
    /// When it ends; nil while off or on until turned off.
    private(set) var until: Date?
    /// The length the switch and the menu action turn it on for.
    private(set) var length = Length.hour
    private(set) var problem: String?
    @ObservationIgnored private let power: PowerAssertions
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let after: Watch.After
    @ObservationIgnored private var assertion: UInt32?
    @ObservationIgnored private var timer: Watch?

    init(power: PowerAssertions = IOPowerAssertions(), now: @escaping () -> Date = Date.init, after: @escaping Watch.After = Watch.after) {
        self.power = power
        self.now = now
        self.after = after
    }

    /// On for `length` from now; already on, the new length counts from now. The switch's own length is `select`'s, so
    /// lock when idle's until-off (card agent-bo-95422972) leaves it alone.
    func turnOn(_ length: Length) {
        guard let id = assertion ?? power.hold(Self.assertionType, Self.assertionName) else {
            problem = "macOS refused to keep the Mac awake"
            return slog.error("keep awake refused")
        }
        assertion = id
        problem = nil
        isOn = true
        timer?.cancel()
        if let seconds = length.seconds {
            until = now() + seconds
            timer = after(seconds) { [weak self] in self?.turnOff() }
        } else {
            until = nil
            timer = nil
        }
        slog.notice("keep awake on \(length.phrase, privacy: .public)")
    }

    func turnOff() {
        timer?.cancel()
        timer = nil
        if let assertion { power.release(assertion) }
        assertion = nil
        if isOn { slog.notice("keep awake off") }
        (isOn, until) = (false, nil)
    }

    func toggle() { isOn ? turnOff() : turnOn(length) }

    /// A length picked on the page: while on it counts from now, while off the next turn on uses it.
    func select(_ length: Length) {
        self.length = length
        if isOn { turnOn(length) }
    }

    /// Setup's line: "On until 15:42 · 47 min left", "On until you turn it off", "Off: the Mac sleeps as usual".
    func state(at now: Date) -> String {
        guard isOn else { return "Off: the Mac sleeps as usual" }
        guard let until else { return "On \(Length.untilOff.phrase)" }
        // Whole minutes, rounded up, so the last minute reads 1 min rather than 0.
        let left = Duration.seconds((max(0, until.timeIntervalSince(now)) / 60).rounded(.up) * 60)
        return "On until \(until.formatted(date: .omitted, time: .shortened)) · \(left.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left"
    }

    /// Omarchy's Super+Ctrl+I idle-lock switch (card agent-bo-95422972): lock when idle is on while keep-awake is off,
    /// and off holds keep-awake until turned off. macOS's own "require password" setting is left alone: changing it
    /// asks for an admin password. Returns the tip to show.
    func toggleIdleLock() -> String {
        if isOn {
            turnOff()
            return "Lock when idle on"
        }
        turnOn(.untilOff)
        return "Lock when idle off: the screen stays awake until you turn it back on"
    }
}
