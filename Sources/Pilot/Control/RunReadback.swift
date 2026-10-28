import Foundation
import PilotCore

/// What `pilot run` answers besides the id (ADR 0013): the tips an action raised in about a second. Actions return
/// nothing and most finish later, so the run watches the HUD's tip for `wait` after the action starts. An error an action
/// only logs is not read back: a read of Pilot's own log store took 2 to 6 s (OSLogStore, probe 2026-10-11).
@MainActor
struct RunReadback {
    var wait: Duration = .seconds(1)
    var every: Duration = .milliseconds(50)
    /// The tip up now: which one, so a tip shown before the run is told from a new one, and its words.
    var tip: @MainActor () -> (id: ObjectIdentifier, text: String)? = { HUD.tipModel.map { (ObjectIdentifier($0), $0.text) } }

    /// Why running `id` is not watched, nil when it is: an extension command runs with its password preferences, so one
    /// that showed its token would hand it to the caller. A tip another extension raises in the background while some
    /// other run is watched still comes back: tips do not say who raised them.
    static func withheld(_ id: String) -> String? {
        id.hasPrefix(Extension.prefix) ? "an extension command's tips are not read back: it runs with its password preferences, so what it shows may hold one" : nil
    }

    /// Runs `body`, then watches for `wait`: the words of every tip it raised, in the order they showed.
    func watch(_ body: () -> Void) async -> [String] {
        let before = tip()
        body()
        var seen: [String] = []
        let end = ContinuousClock.now + wait
        while true {
            if let now = tip(), now.id != before?.id || now.text != before?.text, seen.last != now.text { seen.append(now.text) }
            guard ContinuousClock.now < end else { return seen }
            try? await Task.sleep(for: every)
        }
    }
}
