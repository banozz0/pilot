import Foundation
import PilotCore

/// Clean through Mole (story 117, card agent-bo-95422881): Mole's read-only preview off the main thread, kept for 15
/// minutes and showing its progress, and the clean itself only after the confirm step, in the visible terminal Install uses.
@MainActor
enum CleanModule {
    nonisolated static var mole: String? { Helper.mole.path() }

    static let previewer: CleanPreviewer = {
        let previewer = CleanPreviewer { lines in
            guard let mole else { return nil }
            ilog.notice("clean: previewing, mo \(Mole.preview.joined(separator: " "), privacy: .public)")
            var environment = ProcessInfo.processInfo.environment
            environment["NO_COLOR"] = "1"
            do { return try await ChildProcess.run(mole, Mole.preview, environment: environment, timeout: .seconds(900), lines: lines) } catch {
                ilog.error("clean: preview failed, \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        // The run ends whether or not a menu waits (card agent-bo-95423002): logged, and a tip when Clean is not on screen.
        previewer.onFinish = { preview in
            if let preview { ilog.notice("clean: preview ready, \(preview.items.count) items, \(preview.total ?? "no total", privacy: .public)") }
            if let tip = CleanMenu.tip(preview, showing: PilotMenu.shared.branch == .clean) { HUD.tip(tip, seconds: 6) }
        }
        return previewer
    }()

    /// Return on a Clean row: the clean asks with its exact command and stays open when done, so Mole's summary is read;
    /// Disk usage opens Mole's explorer; Install Mole is Install's own confirm step; an item or a note only says how
    /// Mole cleans; Reports opens Install › Reports, where every clean is kept (story 153).
    static func pick(_ pick: CleanMenu.Pick) {
        switch pick {
        case .run:
            InstallModule.confirm("Clean", Mole.clean) {
                // The report keeps what the preview listed, before the clean drops it.
                let report = RunReport.clean(command: Mole.clean, preview: previewer.ready)
                previewer.drop()
                VisibleTerminal.run(Mole.clean, title: "Clean", onSuccess: VisibleRun.waitForReturn, report: report)
            }
        case .analyze:
            VisibleTerminal.run(Mole.analyze, title: "Disk usage", onSuccess: "true")
        case .install:
            InstallModule.install(.mole)
        case .note:
            HUD.tip("Mole cleans these together; Clean asks first")
        case .reports:
            AppWindowController.shared.open(AppPlace(.reports))
        }
    }
}
