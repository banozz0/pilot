/// Whether macOS lets Pilot use something behind a privacy prompt (Bluetooth, Location): not asked yet, refused, allowed.
enum PrivacyAccess: Sendable { case notAsked, denied, allowed }

/// One macOS privacy prompt waited on: raises it only when Pilot was never asked, then returns once the framework's
/// delegate reports an answer. Bluetooth and Wi-Fi's Location share it.
@MainActor
final class PermissionAsk {
    private var waiting: CheckedContinuation<PrivacyAccess, Never>?

    func ask(current: () -> PrivacyAccess, prompt: () -> Void) async -> PrivacyAccess {
        guard current() == .notAsked, waiting == nil else { return current() }
        return await withCheckedContinuation { waiting = $0; prompt() }
    }

    /// The delegate's callback; an answer still "not asked" (the first callback, before the prompt) waits on.
    func answered(_ access: PrivacyAccess) {
        guard access != .notAsked else { return }
        waiting?.resume(returning: access)
        waiting = nil
    }
}
