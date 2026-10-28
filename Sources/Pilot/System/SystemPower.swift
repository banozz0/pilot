import Foundation
import PilotCore

/// The Power item's commands on this Mac: the System branch's own lock and System Events calls (SystemModule), and
/// pmset as a child process. Nothing posts a key.
struct SystemPower: PowerRunning {
    func run(_ command: PowerCommand) {
        slog.notice("power: \(String(describing: command), privacy: .public)")
        switch command {
        case .lockScreen: SystemModule.lock()
        case .systemEvents(let verb): SystemModule.systemEvents(verb)
        case .process(let cli, let arguments):
            Task {
                do { _ = try await ChildProcess.run(cli, arguments, timeout: .seconds(10)) }
                catch { slog.error("power \(cli, privacy: .public): \(String(describing: error), privacy: .public)") }
            }
        }
    }
}
