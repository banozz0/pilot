import Foundation
import PilotCore

/// Clean through Mole (story 117, card agent-bo-95422881): Mole's read-only preview off the main thread, kept for 15
/// minutes and showing its progress, and the clean itself only after the confirm step, in the visible terminal Install uses.
/// Since W89 the preview's file list is ticked rows too, and Pilot moves only the ticked ones to the Trash (`trash`).
@MainActor
enum CleanModule {
    /// A stand-in Mac for Clean (Sandbox E2E's PILOT_SANDBOX_CLEAN): its Mole, and the home that Mole lists and its file
    /// list is read from. Nil on a real Mac; set before the first preview. The Trash is FileOps', a throwaway folder there.
    nonisolated(unsafe) static var standIn: (mole: String, home: String)?

    nonisolated static var mole: String? { standIn?.mole ?? Helper.mole.path() }
    /// The home Mole runs in and lists.
    nonisolated static var home: String { standIn?.home ?? NSHomeDirectory() }

    static let previewer: CleanPreviewer = {
        let previewer = CleanPreviewer(list: { started in readList(since: started) }) { lines in
            guard let mole else { return nil }
            ilog.notice("clean: previewing, mo \(Mole.preview.joined(separator: " "), privacy: .public)")
            var environment = ProcessInfo.processInfo.environment
            environment["NO_COLOR"] = "1"
            environment["HOME"] = home
            do { return try await ChildProcess.run(mole, Mole.preview, environment: environment, timeout: .seconds(900), lines: lines) } catch {
                ilog.error("clean: preview failed, \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        // The run ends whether or not a menu waits (card agent-bo-95423002): logged only. With Clean closed it says nothing,
        // so it never reads as a scan Pilot started by itself; the kept preview shows when Clean opens next (Sven, Q246).
        previewer.onStart = { caller in ilog.notice("clean: preview started by \(caller, privacy: .public)") }
        previewer.onFinish = { preview in
            if let preview {
                ilog.notice("clean: preview ready, \(preview.items.count) items, \(preview.list.rows.count) paths, \(preview.total ?? "no total", privacy: .public)")
            }
        }
        return previewer
    }()

    /// Mole's file list for the run that started at `since` (`~/.config/mole/clean-list.txt`); nil when that run wrote
    /// none, so an older run's list is never offered as this one's.
    nonisolated static func readList(since: Date) -> CleanList? {
        let file = URL(filePath: home).appending(path: ".config/mole/clean-list.txt")
        guard let written = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              written >= since.addingTimeInterval(-2), let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return CleanList.parse(text, home: home)
    }

    /// Moves the ticked rows of the kept list to the Trash (FileOps', which asks for an administrator for an item root
    /// owns, as Finder does), off the main thread, one at a time (a row that fails says why; the rest go on), keeps the
    /// run in `store` for Reports, and takes the moved rows off the kept list. Only rows the kept list holds can go: nil
    /// when no list is kept.
    static func trash(_ ids: some Collection<String>, from previewer: CleanPreviewer = previewer, store: ReportStore) async -> CleanOutcome? {
        guard let list = previewer.ready?.list else { return nil }
        let rows = list.rows(ids), home = home
        ilog.notice("clean: moving \(rows.count) ticked paths to the Trash")
        var outcome = await Task.detached { await CleanList.move(rows, home: home) { _ = try await FileOps.systemTrash($0) } }.value
        previewer.cleaned(Set(outcome.moved.map(\.id)))
        let report = RunReport.trash(outcome, home: home)
        do {
            try store.finished(report, output: outcome.text(home: home))
            outcome.report = report.id
        } catch { ilog.error("clean: report not kept, \(String(describing: error), privacy: .public)") }
        ilog.notice("clean: \(outcome.summary, privacy: .public)")
        return outcome
    }

    /// Return on a Clean row: the clean asks with its exact command and stays open when done, so Mole's summary is read;
    /// Disk usage opens Mole's explorer; Install Mole is Install's own confirm step, with Homebrew's installer before it
    /// when Homebrew is missing too (Q557); an item or a note only says how
    /// Mole cleans; Reports opens Update & Clean at its Reports, where every clean is kept (story 153).
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
            if Helper.homebrew.path() == nil { InstallModule.installWithHomebrew(.mole) } else { InstallModule.install(.mole) }
        case .note:
            HUD.tip("Mole cleans these together; Clean asks first")
        case .reports:
            AppWindowController.shared.open(AppPlace(.reports))
        }
    }
}
