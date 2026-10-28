import AppKit
import PilotCore
import SwiftUI

/// Open with › Apps for keys (story 160; on Defaults until C3): the app each role key opens, each a picker of the known
/// apps on this Mac with Automatic first, then the role's websites (Q463), and Other app… for any; Agent picks a coding
/// agent's command instead (Q462). Self-contained, so the layout rework can move it.
struct AppRolesBlock: View {
    @Bindable var picks: AppRolePicks
    /// What Automatic gives per role; a render passes its own.
    private let automatic: @MainActor (AppRole) -> String

    init(picks: AppRolePicks = .shared,
         automatic: @escaping @MainActor (AppRole) -> String = AppsModule.automatic) {
        self.picks = picks
        self.automatic = automatic
    }

    static let note = "The app or site each key opens. Automatic takes the first of the known apps you have, then macOS's own. The editor is under Opens with."

    var body: some View {
        KitBlock(title: "Apps for keys", symbol: "square.grid.2x2", note: Self.note) {
            ForEach(Array(AppRolePicks.roles.enumerated()), id: \.element) { i, role in
                BlockRow(first: i == 0) { row(role) }
            }
        }
    }

    private func row(_ role: AppRole) -> some View {
        let auto = automatic(role), pick = picks.app(role), shown = pick ?? auto
        let name = { AppRolePicks.name($0, appName: AppsModule.appName) }
        // A website or a command has no app icon: a globe or a terminal glyph stands in.
        let app = { (value: String) -> String? in if case .app = role.target(value) { value } else { nil } }
        let symbol = switch role.target(shown) { case .web: "globe"; case .command: "terminal"; case .app: "questionmark" }
        return HStack(spacing: 10) {
            HStack(spacing: 6) { Text(role.label); InfoMark(text: Self.info(role)) }.frame(maxWidth: .infinity, alignment: .leading)
            BindKey(action: "apps.\(role.rawValue)")
            AppPickerField(bundle: app(shown), name: pick.map(name) ?? "Automatic (\(name(auto)))", label: role.label, compact: true,
                           symbol: symbol) {
                Picker(role.label, selection: Binding(get: { pick }, set: { picks.set(role, $0) })) {
                    Text("Automatic (\(name(auto)))").tag(String?.none)
                    ForEach(picks.choices(role), id: \.self) { AppMenuItem(name: name($0), bundle: app($0)).tag(String?.some($0)) }
                }
                .pickerStyle(.inline).labelsHidden()
                if role != .agent {
                    Divider()
                    Button("Other app…") { other(role) }
                }
            }
            .frame(width: 240)
        }
    }

    /// Each role's ⓘ: what Automatic finds first, or Notes' own choice (page map ⓘ sweep, Sven 2026-10-17).
    static func info(_ role: AppRole) -> String {
        switch role {
        case .terminal: "Automatic takes Ghostty, then iTerm2, then macOS's Terminal."
        case .agent: "Opens a coding agent in a new window of the Terminal key's app. Automatic takes Claude Code, then Codex, Gemini CLI and opencode."
        case .browser: "Automatic follows macOS's default browser, set under Opens with."
        case .messages: "Automatic is macOS's Messages; pick Discord, Slack, WhatsApp or Discord's website here."
        case .ai: "Automatic takes the Claude app, then ChatGPT's, then claude.ai in your browser."
        case .mail: "Automatic follows macOS's default mail app; Gmail opens in your browser."
        case .notes: "Pilot quick notes makes the key open Pilot's own notes panel instead of an app."
        case .passwords: "Automatic takes 1Password, then Bitwarden, then macOS's Passwords."
        case .music: "Automatic is macOS's Music; pick Spotify, its website or YouTube Music's here."
        default: "Automatic takes macOS's own app for it."
        }
    }

    private func other(_ role: AppRole) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Use"
        panel.message = "The app the \(role.label) key opens."
        guard panel.runModal() == .OK, let id = panel.url.flatMap({ Bundle(url: $0)?.bundleIdentifier }) else { return }
        picks.set(role, id)
    }
}
