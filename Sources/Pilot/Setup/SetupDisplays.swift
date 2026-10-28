import AppKit
import CoreGraphics
import Foundation
import Observation

/// Setup › Displays (card agent-bo-95422804): every screen with its resolution, refresh rate, rotation and place. A new
/// resolution applies for the session and goes back by itself after 15 s unless kept, as macOS's own Displays settings
/// do, so a mode the screen cannot show never strands Sven; only Keep makes it permanent. A rotation is the other way
/// round: it stays, and a tip offers Revert for 15 s (Sven 2026-10-24), since a turned screen still shows. One model for
/// the app, so the way back runs even when the page or the window is closed in the meantime.
@Observable @MainActor
final class SetupDisplays {
    static let shared = SetupDisplays(system: CoreGraphicsDisplays(), connections: .shared, offersRevert: true, defaults: .pilot())
    static let keepWindow: TimeInterval = 15

    struct Pending: Equatable {
        let display: CGDirectDisplayID
        let old: DisplayMode, new: DisplayMode
        let until: Date

        /// Whole seconds until the way back, rounded up, for the countdown.
        func secondsLeft(at now: Date) -> Int { max(0, Int(until.timeIntervalSince(now).rounded(.up))) }
    }

    /// A rotation that stays (Sven 2026-10-24): for 15 s a tip offers Revert wherever it came from, the bar, the action
    /// or `pilot`; ignored, it is kept.
    struct Turn: Equatable {
        let display: CGDirectDisplayID
        let old: Int, new: Int
        let until: Date

        func secondsLeft(at now: Date) -> Int { max(0, Int(until.timeIntervalSince(now).rounded(.up))) }
    }

    private(set) var displays: [DisplayInfo] = []
    /// One change waits at a time: a mode or a rotation picked while the other waits sends that one back first.
    private(set) var pending: Pending?
    private(set) var turning: Turn?
    private(set) var problem: String?
    @ObservationIgnored private var modesByDisplay: [CGDirectDisplayID: [DisplayMode]] = [:]
    @ObservationIgnored private var rotatable: Set<CGDirectDisplayID> = []
    /// The app's model offers Revert in a tip; the tests' models do not.
    @ObservationIgnored private let offersRevert: Bool
    @ObservationIgnored private var revertTip: TipModel?
    /// Each screen's rotation by display UUID, as last seen while the same screens stayed connected, and that set of
    /// screens: what `settleRotations` puts back once the set changes. Saved, so a launch onto another set restores
    /// too; the tests' models keep them in memory.
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var rotations: [String: Int] = [:]
    @ObservationIgnored private var screenSet: Set<String>?
    @ObservationIgnored private var restoreUntil = Date.distantPast
    @ObservationIgnored private var settling: Watch?
    @ObservationIgnored private var screensChanged: NSObjectProtocol?
    @ObservationIgnored private let system: DisplaySystem
    /// Display membership is owned separately from mode picking, but Setup keeps the one live controller for its rows.
    let connections: DisplayConnections?
    let nicknames: DisplayNicknames
    @ObservationIgnored private let after: Watch.After
    @ObservationIgnored private var timer: Watch?

    init(system: DisplaySystem, after: @escaping Watch.After = Watch.after, connections: DisplayConnections? = nil,
         nicknames: DisplayNicknames = .shared, offersRevert: Bool = false, defaults: UserDefaults? = nil) {
        self.system = system
        self.offersRevert = offersRevert
        self.defaults = defaults
        rotations = defaults?.object(forKey: Self.rotationsKey) as? [String: Int] ?? [:]
        screenSet = (defaults?.stringArray(forKey: Self.screenSetKey)).map(Set.init)
        self.after = after
        self.connections = connections
        self.nicknames = nicknames
    }

    func start() {
        displays = system.displays()
        modesByDisplay = Dictionary(displays.map { ($0.id, system.modes($0.id)) }, uniquingKeysWith: { a, _ in a })
        rotatable = Set(displays.map(\.id).filter(system.canRotate))
    }

    /// Whether the screen offers Rotate: macOS's private rotation call is there and lets this screen turn.
    func canRotate(_ display: CGDirectDisplayID) -> Bool { rotatable.contains(display) }

    func modes(for display: CGDirectDisplayID) -> [DisplayMode] { modesByDisplay[display] ?? [] }

    /// The screen's Pilot name: its nickname when its UUID names only it, else macOS's name.
    func label(_ display: DisplayInfo) -> String {
        let unique = displays.filter { $0.displayUUID == display.displayUUID }.count == 1
        return nicknames.label(systemName: display.name, displayUUID: unique ? display.displayUUID : nil)
    }

    func offersPicker(_ display: CGDirectDisplayID) -> Bool { modes(for: display).count > 1 }

    /// Each size once (HiDPI apart), at the refresh rate in use when the size has it, else its highest: the size picker.
    func sizes(for display: CGDirectDisplayID) -> [DisplayMode] {
        let rate = current(display)?.refresh
        var bySize: [DisplayMode.Size: DisplayMode] = [:], order: [DisplayMode.Size] = []
        for mode in modes(for: display) {
            if let kept = bySize[mode.size] {
                if kept.refresh != rate, mode.refresh == rate || mode.refresh > kept.refresh { bySize[mode.size] = mode }
            } else {
                bySize[mode.size] = mode
                order.append(mode.size)
            }
        }
        return order.compactMap { bySize[$0] }
    }

    /// The size picker's choice for the mode in use.
    func selectedSize(for display: CGDirectDisplayID) -> DisplayMode? {
        guard let now = current(display) else { return nil }
        return sizes(for: display).first { $0.size == now.size } ?? now
    }

    /// The rate picker's choice for the mode in use, matched by rate, since the list keeps one encoding per rate and the
    /// mode in use may be another.
    func selectedRate(for display: CGDirectDisplayID) -> DisplayMode? {
        guard let now = current(display) else { return nil }
        return rates(for: display).first { $0.refresh == now.refresh } ?? now
    }

    /// The refresh rates the size in use offers: the rate picker.
    func rates(for display: CGDirectDisplayID) -> [DisplayMode] {
        guard let now = current(display) else { return [] }
        return modes(for: display).filter { $0.size == now.size }
    }

    private func current(_ display: CGDirectDisplayID) -> DisplayMode? { displays.first { $0.id == display }?.mode }

    /// Applies `mode` for the session and starts the 15 s count back to the old one; a pick while one waits keeps the
    /// first old mode to go back to.
    func pick(_ mode: DisplayMode, for display: CGDirectDisplayID) {
        guard let current = current(display), mode != current else { return }
        // A pick while another screen waits sends that one back first; on the same screen the first old mode stays. A
        // rotation offering Revert is kept.
        if turning != nil { keep() }
        if let pending, pending.display != display { revert() }
        let old = pending?.old ?? current
        guard change(mode, display, permanently: false) else { return }
        timer?.cancel()
        pending = Pending(display: display, old: old, new: mode, until: Date().addingTimeInterval(Self.keepWindow))
        timer = after(Self.keepWindow) { [weak self] in self?.revert() }
    }

    /// Turns the screen to `degrees` for good and offers Revert for 15 s; a second turn of the same screen keeps the
    /// first rotation to go back to.
    func rotate(_ display: CGDirectDisplayID, to degrees: Int) {
        guard let now = displays.first(where: { $0.id == display })?.rotation, degrees != now else { return }
        if pending != nil { revert() }
        if let turning, turning.display != display { keep() }
        let old = turning?.old ?? now
        guard turn(display, degrees) else { return }
        timer?.cancel()
        let turn = Turn(display: display, old: old, new: degrees, until: Date().addingTimeInterval(Self.keepWindow))
        turning = turn
        timer = after(Self.keepWindow) { [weak self] in self?.keep() }
        if offersRevert { offerRevert(turn) }
    }

    func keep() {
        if let turning {
            stopWaiting()
            return slog.notice("display \(turning.display, privacy: .public) rotation \(turning.new, privacy: .public) kept")
        }
        guard let pending else { return }
        stopWaiting()
        _ = change(pending.new, pending.display, permanently: true)
    }

    func revert() {
        if let turning {
            stopWaiting()
            _ = turn(turning.display, turning.old)
            return
        }
        guard let pending else { return }
        stopWaiting()
        _ = change(pending.old, pending.display, permanently: false)
    }

    private func stopWaiting() {
        timer?.cancel()
        timer = nil
        pending = nil
        turning = nil
        if let revertTip, HUD.tipModel === revertTip { HUD.dismissTip() }
        revertTip = nil
    }

    /// "24G1WG4 turned to 90°" with Revert, fading with the 15 s; closing it any other way keeps the rotation.
    private func offerRevert(_ turn: Turn) {
        let name = displays.first { $0.id == turn.display }.map(label) ?? "Display"
        HUD.tip("\(name) turned to \(turn.new)°", seconds: Self.keepWindow, action: .init(title: "Revert") { [weak self] in self?.revert() })
        revertTip = HUD.tipModel
    }

    /// Puts each screen's rotation back when the screens connected change (Sven 2026-10-24): macOS keeps a layout per
    /// set of screens and applies that set's own, the vertical screen unrotated, when the main one goes off or comes
    /// back. Once, from launch; the change settles for 1 s first, as a reconfiguration comes in a burst.
    func followRotations() {
        guard screensChanged == nil else { return }
        settleRotations()
        screensChanged = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settling?.cancel()
                self.settling = self.after(1) { [weak self] in self?.settleRotations() }
            }
        }
    }

    /// The same screens: each one's rotation is the one to keep, so a turn in System Settings counts. Other screens, or
    /// within 5 s of them (macOS may turn a screen in a later burst): each screen still here goes back to its kept one.
    func settleRotations() {
        let now = system.displays()
        let set = Set(now.compactMap(\.displayUUID))
        if let screenSet, screenSet != set { restoreUntil = Date().addingTimeInterval(5) }
        screenSet = set
        let restoring = Date() < restoreUntil
        for screen in now {
            guard let uuid = screen.displayUUID else { continue }
            if restoring, let kept = rotations[uuid], kept != screen.rotation {
                slog.notice("display \(screen.id, privacy: .public) back to its kept rotation \(kept, privacy: .public)° after the screens changed")
                _ = turn(screen.id, kept)
            } else {
                rotations[uuid] = screen.rotation
            }
        }
        saveRotations()
    }

    private static let rotationsKey = "displays.rotations", screenSetKey = "displays.screenSet"

    private func saveRotations() {
        defaults?.set(rotations, forKey: Self.rotationsKey)
        defaults?.set(screenSet.map { $0.sorted() }, forKey: Self.screenSetKey)
    }

    private func turn(_ display: CGDirectDisplayID, _ degrees: Int) -> Bool {
        do {
            try system.rotate(display, to: degrees)
            problem = nil
            slog.notice("display \(display, privacy: .public) rotated to \(degrees, privacy: .public)°")
            start()
            if let uuid = displays.first(where: { $0.id == display })?.displayUUID {
                rotations[uuid] = degrees
                saveRotations()
            }
            return true
        } catch {
            problem = String(describing: error)
            slog.error("display \(display, privacy: .public) rotation: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func change(_ mode: DisplayMode, _ display: CGDirectDisplayID, permanently: Bool) -> Bool {
        do {
            try system.apply(mode, to: display, permanently: permanently)
            problem = nil
            slog.notice("display \(display, privacy: .public) \(mode.label, privacy: .public)\(permanently ? " kept" : "", privacy: .public)")
            displays = system.displays()
            return true
        } catch {
            problem = String(describing: error)
            slog.error("display \(display, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
