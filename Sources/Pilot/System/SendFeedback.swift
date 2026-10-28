import AppKit
import PilotCore

/// Send feedback (story 136, card agent-bo-95423195): the browser on a new issue on Pilot's repo, prefilled with this
/// Mac's facts (PilotCore's Feedback). NSWorkspace opens it, so no automation target and no new permission.
@MainActor
enum SendFeedback {
    static func open(_ kind: Feedback.Kind, layerKeys: [LayerKey]) {
        let url = Feedback.url(kind, facts: facts(layerKeys: layerKeys))
        slog.notice("feedback: \(kind.rawValue, privacy: .public) opens a new issue")
        NSWorkspace.shared.open(url)
    }

    /// The dropdown's one row: the menu's picker offers both kinds.
    static func choose(layerKeys: [LayerKey]) {
        let rows = Feedback.Kind.allCases.map { MenuEntry(title: $0.label, target: .action($0.actionID)) }
        PilotMenu.shared.pick(rows, title: "Send feedback") { row in
            open(row.target == .action(Feedback.Kind.bug.actionID) ? .bug : .idea, layerKeys: layerKeys)
        }
    }

    static func facts(layerKeys: [LayerKey]) -> Feedback.Facts {
        Feedback.Facts(version: GeneralPage.version, macOS: SystemReader.machine.macOS, model: SystemReader.machine.model,
                       layerKey: layerKeys.label, look: "\(Look.shared.style.title) · \(Look.shared.theme.name)",
                       tiler: "Pilot's own")
    }
}
