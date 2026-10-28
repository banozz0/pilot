import OSLog
import PilotCore

let ailog = Logger(subsystem: "dev.banozz.pilot", category: "quick-ai")

/// Quick AI's actions (card agent-bo-95423050): Ask AI opens the AI chat (story 166), Fix selected text fixes the
/// selection in place with no panel (QuickFix), Ask AI about selected text opens the selection box (SelectionBox). The one-shot answer panel they once shared is parked on
/// parked/quick-ai-panel.
@MainActor
enum QuickAIActions {
    static let askID = "ai.ask", fixID = "ai.fix", selectionID = "ai.selection"
    static let keywords = "ai claude chatgpt codex ollama"

    static func register(into registry: inout ActionRegistry) {
        do {
            // Named for any provider (story 162); the keywords keep "claude" and the others finding them.
            // Opens the AI chat on its input (story 166).
            try registry.register(Action(id: askID, label: "Ask AI", module: .apps, tier: .v1, keywords: Self.keywords) { AIChatPanel.shared.show() })
            try registry.register(Action(id: fixID, label: "Fix selected text", module: .apps,
                                         defaultKey: Key("f", .ctrl), tier: .v1, keywords: Self.keywords) { QuickFix.shared.fixSelection() })
            try registry.register(Action(id: selectionID, label: "Ask AI about selected text", module: .apps, defaultKey: Key("a", .ctrl),
                                         tier: .v1, keywords: Self.keywords + " rewrite selection prompt") { SelectionBox.shared.open() })
        } catch { ailog.error("quick AI actions: \(String(describing: error), privacy: .public)") }
    }
}
