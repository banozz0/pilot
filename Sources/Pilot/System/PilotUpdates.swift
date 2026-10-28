import AppKit
import Foundation
import PilotCore
import Sparkle

/// General's update state, by one of two routes (SH6). A release bundle carries a real EdDSA key (`SUPublicEDKey`, which the
/// release step sets; Packaging/Info.plist holds a placeholder): Sparkle 2 checks the appcast at `SUFeedURL`, once a day
/// after the user says yes to its question on the second launch, and Check for updates shows Sparkle's window. A debug
/// build alone has the checkout route (Sven, Q331): Scripts/build-app.sh writes the checkout it came from into Info.plist,
/// and Check for updates counts the commits on that checkout's main since this build, which git-sync keeps current. A
/// release never contains that route or runs git; without the key it has nothing to check, as a bare binary has not.
@MainActor @Observable
final class PilotUpdates {
    static let shared = PilotUpdates()

    enum State: Equatable {
        case unknown, checking, current, behind(Int), failed
    }

    enum Route: String {
        case sparkle, none
        #if DEBUG
        case checkout
        #endif
    }

    private(set) var state: State = .unknown
    let commit: String?
    /// The checkout a debug build counts from; nil in a release, which never reads `PilotSource`.
    let source: String?
    /// The appcast Sparkle reads: Info.plist's SUFeedURL, the one place it is written.
    let feed: String?
    let route: Route
    /// Sparkle's updater, made by `start()` on the Sparkle route alone.
    private var sparkle: SPUStandardUpdaterController?
    private let reminders = GentleReminders()

    init(info: [String: Any]? = Bundle.main.infoDictionary) {
        commit = info?["PilotCommit"] as? String
        feed = info?["SUFeedURL"] as? String
        let keyed = Self.isKey(info?["SUPublicEDKey"] as? String) && feed != nil
        #if DEBUG
        source = info?["PilotSource"] as? String
        route = keyed ? .sparkle : commit != nil && source != nil ? .checkout : .none
        #else
        source = nil
        route = keyed ? .sparkle : .none
        #endif
    }

    /// An Ed25519 public key as `generate_keys` prints it: base64 of 32 bytes. The placeholder is not one.
    nonisolated static func isKey(_ text: String?) -> Bool {
        text.flatMap { Data(base64Encoded: $0) }?.count == 32
    }

    /// Starts Sparkle's schedule at launch; off the Sparkle route nothing starts.
    func start() {
        guard route == .sparkle, sparkle == nil else { return }
        sparkle = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: reminders)
    }

    /// A bundle with something to check: Sparkle's feed, or a debug build's commit and checkout to count from.
    var canCheck: Bool { route != .none }

    /// A debug build's checkout count: General shows its chip and `status --check` waits for it.
    var counts: Bool {
        #if DEBUG
        route == .checkout
        #else
        false
        #endif
    }

    /// Why `status --check` has nothing to count on this route; nil when it counts.
    var checkRefusal: String? {
        switch route {
        case .none: "this build has no update feed, so there is nothing to check"
        case .sparkle: "Sparkle checks on its own schedule; Check for updates on General shows its window"
        #if DEBUG
        case .checkout: nil
        #endif
        }
    }

    /// When Sparkle last looked at the feed, scheduled or asked; nil off the Sparkle route and before its first check.
    var lastChecked: Date? { sparkle?.updater.lastUpdateCheckDate }

    /// Sparkle checks once a day on the user's yes; nil off the Sparkle route.
    var automaticChecks: Bool? { sparkle?.updater.automaticallyChecksForUpdates }

    /// A scheduled check found an update Sparkle showed behind other windows: `label` says so until it is dealt with.
    var updateWaiting: Bool { reminders.waiting }

    /// What Check for updates does on this route, for its tooltip.
    var checkHelp: String {
        switch route {
        case .sparkle: "Look for a new version of Pilot"
        case .none: "This build has no update feed"
        #if DEBUG
        case .checkout: "Count the commits on main since this build"
        #endif
        }
    }

    /// The commit's first seven, for the version line.
    var shortCommit: String? { commit.map { String($0.prefix(7)) } }

    /// Check for updates: Sparkle's window in front of the app Sven was in (WindowFocus, as Settings opens from the menu
    /// bar), or a debug build's count.
    func check() {
        switch route {
        case .none: return
        case .sparkle:
            start()
            sparkle?.checkForUpdates(nil)
            WindowFocus.bringForward()
        #if DEBUG
        case .checkout: count()
        #endif
        }
    }

    /// The checkout's count on a page's first show; Sparkle keeps its own schedule and never opens a window unasked here.
    func countOnce() {
        #if DEBUG
        if route == .checkout, state == .unknown { count() }
        #endif
    }

    #if DEBUG
    private func count() {
        guard let commit, let source, state != .checking else { return }
        state = .checking
        Task {
            let answer = try? await ChildProcess.run("/usr/bin/git", ["-C", source, "rev-list", "--count", "\(commit)..main"], timeout: .seconds(10))
            state = Self.state(count: answer)
            log.notice("updates: \(String(describing: self.state), privacy: .public)")
        }
    }

    /// `git rev-list --count`'s answer: none since is current, else behind by that many; no answer is a failed check.
    nonisolated static func state(count: String?) -> State {
        guard let n = count.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return .failed }
        return n == 0 ? .current : .behind(n)
    }
    #endif

    var label: String {
        if updateWaiting { return "Update available" }
        return switch state {
        case .unknown: lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named)))" }
            ?? (commit == nil ? "Development build" : "Not checked yet")
        case .checking: "Checking…"
        case .current: "Up to date"
        case .behind(let n): "\(n) \(n == 1 ? "change" : "changes") on main since this build"
        case .failed: "Couldn't read the checkout"
        }
    }
}

/// Sparkle's gentle reminders for a menu-bar app: a scheduled update shows behind other windows rather than stealing focus,
/// and `waiting` holds until its session ends.
@MainActor @Observable
private final class GentleReminders: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    var waiting = false

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !state.userInitiated { waiting = true }
    }

    func standardUserDriverWillFinishUpdateSession() { waiting = false }
}
