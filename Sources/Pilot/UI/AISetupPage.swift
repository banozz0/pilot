import AppKit
import PilotCore
import SwiftUI

/// AI › Setup (page map, Sven 2026-10-17, Q210): every AI setting, which until then hid in the chat's popovers. Every
/// provider on one line (name, state, one button), two columns where the window has the room; a line's click picks the
/// provider AI uses, and another line's button signs in, connects or installs at once, or opens that provider's set-up in
/// a popover. The picked provider's set-up (sign-in, key, address, model, effort, Test) is a block of its own. AI's More
/// (simplify-pages T19) holds the fallback, the AI keys and when a new chat starts. A new provider is a new AIProvider
/// case: it lists itself here.
struct AISetupPage: View {
    @Environment(\.aiPageSources) private var sources
    private let given: AISettings?
    private let test: AIPage.Test?
    /// AI's More tab rather than Setup.
    private let more: Bool

    /// `settings` and `test` are the renders' seams; the app's page reads AISettings.shared.
    init(settings: AISettings? = nil, test: AIPage.Test? = nil, more: Bool = false) {
        given = settings
        self.test = test
        self.more = more
    }

    static let intro = "Which AI answers, and how it signs in."
    static let introInfo = "It answers the chat, Ask AI and Fix selected text; the keys that open them, the fallback and a new chat are on More."

    /// More's index. A row added to or moved off a block changes its count here.
    static let entries = [
        MoreEntry(id: .aiFallback, symbol: "arrow.triangle.branch", controls: 1),
        MoreEntry(id: .aiKeys, symbol: "keyboard", controls: 6),
        MoreEntry(id: .aiNewChat, symbol: "bubble.left.and.bubble.right", controls: 1),
    ]

    var body: some View {
        if more { AIMoreBody(settings: given ?? sources.settings()) } else { AISetupBody(settings: given ?? sources.settings(), test: test) }
    }
}

private struct AISetupBody: View {
    @Environment(\.ink) private var ink
    @Bindable var settings: AISettings
    let test: AIPage.Test?
    /// The provider whose set-up popover is open.
    @State private var settingUp: AIProvider?
    @State private var problem: String?
    /// Sign in… or Install… opened a terminal: the line asks again once Pilot is back in front.
    @State private var signingIn: AIProvider?

    private var provider: AIProvider { settings.provider }

    var body: some View {
        GeometryReader { g in
            KitPage(intro: AISetupPage.intro, info: AISetupPage.introInfo) {
                providers(width: g.size.width)
                KitBlock(title: AIPage.lineName(provider), symbol: "slider.horizontal.3", note: provider.detail) {
                    AIProviderSetup(route: provider, settings: settings, test: test, inline: true).id(provider)
                }
            }
        }
        .task(id: provider) {
            // A popover's Use picked its provider and took its line's button away: none opens again by itself.
            settingUp = nil
            problem = nil
            await AIPage.refresh(settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard let route = signingIn else { return }
            signingIn = nil
            Task { await settings.refreshCLI(route) }
        }
    }

    // MARK: Providers

    private func providers(width: CGFloat) -> some View {
        KitBlock(title: "Providers", symbol: "point.3.connected.trianglepath.dotted", trailing: {
            Text("Click one to use it")
        }) {
            if width >= AIPage.twoColumns {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(AIPage.columns.indices, id: \.self) { c in column(AIPage.columns[c]) }
                }
            } else {
                column(AIPage.columns.flatMap(\.self))
            }
            if let problem { BlockRow { FinePrint(text: problem, color: ink.red) } }
        }
    }

    private func column(_ routes: [AIProvider]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(routes.enumerated()), id: \.element) { i, route in BlockRow(first: i == 0) { line(route) } }
        }
        .frame(maxWidth: .infinity)
    }

    /// One provider on one line: picked by a click, its name, its ⓘ (outside the pick, which would take its click) and
    /// state, and its one button. The picked line has none: its set-up is the block under the list.
    private func line(_ route: AIProvider) -> some View {
        let on = route == provider
        let (words, ready) = state(route)
        return HStack(spacing: 10) {
            Button { settings.provider = route } label: {
                HStack(spacing: 10) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle").font(ink.ui(14)).foregroundStyle(on ? ink.accent : ink.muted)
                    AIPage.mark(route)
                    Text(AIPage.lineName(route)).font(ink.ui(13, on ? .semibold : .medium)).foregroundStyle(ink.text).lineLimit(1)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(AIPage.lineName(route)), \(words)")
            .accessibilityAddTraits(on ? .isSelected : [])
            InfoMark(text: route.detail)
            HStack(spacing: 5) {
                Circle().fill(ready ? ink.green : .clear).strokeBorder(ready ? .clear : ink.muted, lineWidth: 1).frame(width: 6, height: 6)
                Text(words).font(ink.ui(12)).foregroundStyle(ready ? ink.text2 : ink.muted).lineLimit(1)
            }
            .layoutPriority(-1)
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            if !on { button(route, ready: ready) }
        }
    }

    /// What a provider's line says: signed in, key set or ready when it can answer, else what it lacks.
    private func state(_ route: AIProvider) -> (String, Bool) {
        if settings.connecting(route) { return ("Signing in…", false) }
        switch route {
        case .claudeCode, .codex:
            switch settings.status(route) {
            case .checking: return ("Checking…", false)
            case .missing: return ("Not installed", false)
            case .signedOut: return (route.isPlan ? "Not connected" : "Signed out", false)
            case .signedIn: return ("Signed in", true)
            }
        case .anthropicAPI, .openAI: return settings.hasKey(route) ? ("Key set", true) : ("Not set up", false)
        case .ollama, .openAICompatible: return settings.ready(route) ? ("Ready", true) : ("Not set up", false)
        }
    }

    /// Another line's one button: Sign in, Connect or Install run at once; a key, an address or a model opens the
    /// set-up; a ready provider's Manage opens it too, words only, so the lines that still need something carry the weight.
    @ViewBuilder private func button(_ route: AIProvider, ready: Bool) -> some View {
        if settings.connecting(route) {
            Button("Cancel") { settings.cancelConnect(route) }.buttonStyle(.pilot)
        } else {
            switch (route, settings.status(route)) {
            case (.claudeCode, .signedOut(let path)):
                Button("Sign in…") { signIn(path) }.buttonStyle(.pilot)
            case (.codex, .missing):
                Button("Install…") { install(route) }.buttonStyle(.pilot)
            case (.codex, .signedOut):
                Button("Connect…") { connect(route) }.buttonStyle(.pilot)
            default:
                Button(ready ? "Manage…" : route.key == .required ? "Add key…" : "Set up…") { settingUp = route }
                    .buttonStyle(PilotButtonStyle(ghost: ready))
                    .popover(isPresented: Binding(get: { settingUp == route }, set: { if !$0 { settingUp = nil } }), arrowEdge: .bottom) {
                        AIProviderSetup(route: route, settings: settings)
                    }
            }
        }
    }

    /// `claude auth login` in a terminal the person sees; the line asks again when Pilot is back in front.
    private func signIn(_ path: String) {
        signingIn = .claudeCode
        VisibleTerminal.run("\(VisibleRun.quoted(path)) auth login", title: "Sign in to Claude", onSuccess: "true")
    }

    /// Install's confirm step for the command's Homebrew package; nothing runs until Install is picked there.
    private func install(_ route: AIProvider) {
        guard let package = route.installPackage else { return }
        signingIn = route
        InstallModule.pick(package)
    }

    private func connect(_ route: AIProvider) {
        problem = nil
        Task {
            guard let why = await settings.connect(route), why != .cancelled else { return }
            problem = why.message
        }
    }
}

/// AI's More (simplify-pages T19): the fallback, the AI's keys and when a chat starts over, each a place. The fallback's
/// choices are the providers ready to answer, so it reads their state as Setup does.
private struct AIMoreBody: View {
    @Environment(\.ink) private var ink
    @Bindable var settings: AISettings

    private var provider: AIProvider { settings.provider }

    var body: some View {
        KitMore(entries: AISetupPage.entries) {
            fallback.moreBlock(.aiFallback)
            keys.moreBlock(.aiKeys)
            chat.moreBlock(.aiNewChat)
        }
        .task(id: provider) { await AIPage.refresh(settings) }
    }

    /// The AI that answers a request once when the picked one fails (on More, simplify-pages T19).
    private var fallback: some View {
        KitBlock(title: AppSection.aiFallback.title, symbol: "arrow.triangle.branch") {
            BlockRow(first: true) {
                Text("Fallback")
                InfoMark(text: "If \(provider.name) \(AIFallback.when), this AI answers that request once, on its own model, and says so. Anything else shows as an error.")
                Spacer()
                DropdownField(label: "Fallback", options: [(AIProvider?.none, "None")] + settings.fallbackChoices.map { (Optional($0), $0.title) },
                              picked: settings.fallbackInUse) { settings.fallback = $0 }
                    .frame(width: 220)
            }
        }
    }

    // MARK: Keys and chat

    /// The AI's keys, the chat's popover's until the page map: Ask AI, the chat, the two on selected text, and the
    /// selection pill's key and the apps it skips.
    private var keys: some View {
        KitBlock(title: AppSection.aiKeys.title, symbol: "keyboard") {
            key("Ask AI", "Opens the AI chat; or Hyper+Space, then type ask and your question.", QuickAIActions.askID, first: true)
            key("Open AI chat", "Opens or closes the chat under the top bar, as you left it.", AIChatPanel.chatID)
            key("Fix selected text", "Rewrites the text you selected, in place; also Fix with Pilot in the right-click menu.", QuickAIActions.fixID)
            key("Ask AI about selected text", "A chat bubble on the text you selected; also Ask Pilot AI in the right-click menu.",
                QuickAIActions.selectionID)
            BlockRow {
                // Hyper+drag selects text only while windows move with another modifier (MouseDragTap takes the drag).
                let blocked = Engine.shared?.settings.dragModifier == .hyper
                TitledText(title: "Selection tools", detail: blocked ? SelectionPill.blocked : nil).padding(.vertical, 4)
                InfoMark(text: "Hyper+drag over text shows Ask AI, Read aloud, Copy and Translate, and Summarise with that extension; this key shows them at the pointer.")
                Spacer()
                BindKey(action: SelectionTools.id)
            }
            SelectionSkipRow()
        }
    }

    private func key(_ title: String, _ info: String, _ action: String, first: Bool = false) -> some View {
        BlockRow(first: first) {
            Text(title)
            InfoMark(text: info)
            Spacer()
            BindKey(action: action)
        }
    }

    private var chat: some View {
        KitBlock(title: AppSection.aiNewChat.title, symbol: "bubble.left.and.bubble.right") {
            BlockRow(first: true) {
                Text("Start a new chat after")
                InfoMark(text: "Left this long unused, the chat opens empty.")
                Spacer()
                Segments(selection: Binding(get: { settings.chatReset }, set: { settings.chatReset = $0 }),
                         options: AIChat.Reset.allCases.map { ($0, $0.title) }, label: "Start a new chat after")
            }
        }
    }
}
