import Foundation

/// The Power item's popover (Sven 2026-10-10): lock, sleep and sleep the displays at once; restart, shut down and log
/// out only once confirmed in the popover, as an extension's ask confirms an action that ends something.
public enum PowerAction: String, CaseIterable, Sendable {
    case lock, sleep, sleepDisplays, restart, shutDown, logOut

    public var title: String {
        switch self {
        case .lock: "Lock screen"
        case .sleep: "Sleep"
        case .sleepDisplays: "Sleep displays"
        case .restart: "Restart…"
        case .shutDown: "Shut down…"
        case .logOut: "Log out…"
        }
    }

    public var symbol: String {
        switch self {
        case .lock: "lock"
        case .sleep: "moon"
        case .sleepDisplays: "display"
        case .restart: "arrow.triangle.2.circlepath"
        case .shutDown: "power"
        case .logOut: "rectangle.portrait.and.arrow.right"
        }
    }

    /// Ends the session: its question and the red button's word, asked in the popover first; nil runs at once.
    public var confirmation: (question: String, yes: String)? {
        switch self {
        case .restart: ("Restart this Mac? Open apps are asked to quit.", "Restart")
        case .shutDown: ("Shut down this Mac? Open apps are asked to quit.", "Shut down")
        case .logOut: ("Log out? Open apps are asked to quit.", "Log out")
        default: nil
        }
    }
    public var confirms: Bool { confirmation != nil }

    /// What runs it: pmset to sleep the Mac or its displays, System Events (the one automation target, in a child
    /// osascript) to end the session, and the login framework's lock call; never a posted key.
    public var command: PowerCommand {
        switch self {
        case .lock: .lockScreen
        case .sleep: .process("/usr/bin/pmset", ["sleepnow"])
        case .sleepDisplays: .process("/usr/bin/pmset", ["displaysleepnow"])
        case .restart: .systemEvents("restart")
        case .shutDown: .systemEvents("shut down")
        case .logOut: .systemEvents("log out")
        }
    }
}

public enum PowerCommand: Equatable, Sendable {
    /// SACLockScreenImmediate, the call the lock screen item uses.
    case lockScreen
    /// `tell application "System Events" to <verb>`.
    case systemEvents(String)
    case process(String, [String])
}

/// Runs a power command: the Mac's own in the app, a fake in tests, so no test locks, sleeps or restarts anything.
@MainActor public protocol PowerRunning {
    func run(_ command: PowerCommand)
}

/// The popover's confirm: the action asking, if any.
public struct PowerAsk: Equatable, Sendable {
    public private(set) var asking: PowerAction?

    public init() {}

    /// A pick: one that ends the session waits for its confirm, the rest run now. True when something ran.
    @MainActor @discardableResult
    public mutating func pick(_ action: PowerAction, on runner: some PowerRunning) -> Bool {
        guard !action.confirms else {
            asking = action
            return false
        }
        asking = nil
        runner.run(action.command)
        return true
    }

    /// The red button: runs the action asking. True when something ran.
    @MainActor @discardableResult
    public mutating func confirm(on runner: some PowerRunning) -> Bool {
        guard let action = asking else { return false }
        asking = nil
        runner.run(action.command)
        return true
    }

    public mutating func cancel() { asking = nil }
}
