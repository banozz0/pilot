import AppKit
import PilotCore
import SwiftUI

/// What the AI page reads, a seam the renders fill as Home's does: the provider settings and the chat (the panel's, so the
/// page and Ask AI show one conversation).
struct AIPageSources: Sendable {
    var settings: @MainActor @Sendable () -> AISettings = { .shared }
    var chat: @MainActor @Sendable () -> AIChatModel = { AIChatPanel.shared.model }
    var send: @MainActor @Sendable () -> Void = { AIChatPanel.shared.send() }
}

extension EnvironmentValues {
    @Entry var aiPageSources = AIPageSources()
}

/// AI › Chat (C3, Sven 2026-10-10; any provider, story 159; subscriptions, story 162; the chat owns the page, T13, Sven
/// 2026-10-11; Q177, Sven 2026-10-16; two tabs, page map, Sven 2026-10-17): one block, Chat, filling the page, the same
/// conversation as Ask AI's panel. Its input holds the Skills bubble (P29; /extension only where it runs, AskPilotSkills);
/// the empty chat says what Pilot may change (AskPilotStart). Its header's menu holds the model, the effort and Providers…, which opens AI › Setup (AISetupPage),
/// where every setting is; while the picked provider cannot answer, one line says so with a button there.
struct AIPage: View {
    @Environment(\.aiPageSources) private var sources
    private let given: AISettings?
    private let test: Test?

    enum Test: Equatable { case running, passed, failed(QuickAI.Failure) }
    enum Listing: Equatable { case running, listed(Int), failed(QuickAI.Failure) }

    /// `settings` and `test` are the renders' seams; the app's page reads AISettings.shared.
    init(settings: AISettings? = nil, test: Test? = nil) {
        given = settings
        self.test = test
    }

    /// Sven 2026-10-16, Q177: the page is for talking to Pilot about Pilot.
    static let intro = "Talk to Pilot about Pilot: your keys, workspaces, settings and extensions. It reads your setup with the pilot command, "
        + "proposes its changes as one plan, and makes them once you Allow. Ask AI opens the same chat under the top bar."

    /// Whether `provider` writes extensions: /extension runs Claude Code alone (T17).
    static func makes(_ provider: AIProvider) -> Bool { provider == .claudeCode }

    /// The skills `provider` can take, in the Skills list (P29): /extension only where it runs.
    static func skills(for provider: AIProvider, from skills: [AISkill] = AISkills.all) -> [AISkill] {
        makes(provider) ? skills : AISkills.guides(skills)
    }

    /// What the agent may touch, as three short columns on the empty chat (the `pilot` command's Allow gate, ADR 0013).
    static let reach: [(title: String, text: String)] = [
        ("One Allow for every change", "Binds, workspaces, layouts, settings, menu bar, quicklinks and snippets wait as one plan, then read back"),
        ("Asks on its own", "Key presses, quitting apps, installs, extensions"),
        ("Can't", "Run any other program, or anything pilot has no verb for"),
    ]

    /// The input's words: every provider changes Pilot, Claude Code and codex through their agents (AgentRunner's agent(),
    /// codex since Q203), an API key through Pilot's loop (Q193), each with the skills.
    static func placeholder(ready: Bool) -> String { ready ? "Tell Pilot what to change, or pick a skill" : "Ask anything" }

    var body: some View {
        AIPageBody(settings: given ?? sources.settings(), chat: sources.chat(), send: sources.send, test: test)
    }

    /// The picked provider can answer. A subscription still being checked counts as ready, so the Chat's unready line
    /// never flashes up while the page opens.
    static func ready(_ settings: AISettings) -> Bool {
        if settings.provider.command != nil, case .checking = settings.status(settings.provider) { return true }
        return settings.ready(settings.provider)
    }

    /// Asks the commands whether they are signed in, as each tab does when it opens: every one while any is unchecked,
    /// else the picked one's.
    static func refresh(_ settings: AISettings) async {
        if AIProvider.allCases.contains(where: { $0.command != nil && settings.status($0) == .checking }) {
            await settings.refreshCLIs()
        } else if settings.provider.command != nil {
            await settings.refreshCLI(settings.provider)
        }
    }

    /// The providers in Setup's two columns: the ones that sign in or run on this Mac, then the ones that take a key.
    static let columns: [[AIProvider]] = [[.claudeCode, .codex, .ollama], [.anthropicAPI, .openAI, .openAICompatible]]

    /// A provider's name on its line: an API says so, beside the subscription of the same company.
    static func lineName(_ route: AIProvider) -> String {
        switch route {
        case .anthropicAPI: "Anthropic API"
        case .openAI: "OpenAI API"
        case .openAICompatible: "OpenAI-compatible"
        default: route.name
        }
    }

    /// Each provider's picture from Install's catalogue icons, already in the app (CatalogueIcons); nil for an endpoint,
    /// which has none of its own.
    static func icon(_ route: AIProvider) -> String? {
        switch route {
        case .claudeCode, .anthropicAPI: "claude"
        case .codex, .openAI: "chatgpt"
        case .ollama: "ollama"
        case .openAICompatible: nil
        }
    }

    /// The provider's picture, or a plain tile where it has none.
    static func mark(_ route: AIProvider, size: CGFloat = 18) -> some View {
        IconTile(icon: MenuIcon(symbol: "point.3.connected.trianglepath.dotted", tint: .neutral, bundled: icon(route)), size: size)
    }

    /// Where the page measures the chat's top, to give it the rest of the window.
    static let space = "ai.page"
    /// The two columns need this much of the window; narrower, one column.
    static let twoColumns: CGFloat = 860
}

private struct AIPageBody: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    @Bindable var settings: AISettings
    let chat: AIChatModel
    let send: () -> Void
    let test: AIPage.Test?
    /// The chat card's top in the page, measured, so it reaches the window's foot whatever sits above it.
    @State private var chatTop: CGFloat = 0
    /// The transcript's height, measured: the Skills list rises over it and no further (P47).
    @State private var above: CGFloat = 430
    /// The Skills list is open: the empty chat hides behind it, none of its words peeking out beside it.
    @State private var skillsOpen = false
    @State private var problem: String?
    @FocusState private var typing: Bool

    private var provider: AIProvider { settings.provider }
    private var ready: Bool { AIPage.ready(settings) }
    /// codex not yet signed in to Pilot's own Codex home, on an empty chat: its Sign in to Codex is the one call there.
    private var codexSignIn: Bool {
        guard provider == .codex, chat.turns.isEmpty, case .signedOut = settings.status(.codex) else { return false }
        return true
    }

    var body: some View {
        GeometryReader { g in
            KitPage(intro: AIPage.intro) {
                chatBlock
                    .frame(height: max(320, g.size.height - chatTop - foot))
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(AIPage.space)).minY } action: { chatTop = $0 }
            }
        }
        .coordinateSpace(.named(AIPage.space))
        .task(id: provider) {
            problem = nil
            chat.route = settings.routeName
            await AIPage.refresh(settings)
        }
    }

    /// The page's bottom inset under the chat card, as the style's page leaves it.
    private var foot: CGFloat { style.kind == .toybox ? 32 : style.density.page }

    /// codex's sign-in to Pilot's own Codex home, from the empty chat (CodexSignIn).
    private func connect(_ route: AIProvider) {
        problem = nil
        Task {
            guard let why = await settings.connect(route), why != .cancelled else { return }
            problem = why.message
        }
    }

    // MARK: Chat

    /// The chat as the page's one block. Its header names who answers and whether it may change Pilot, and its menu
    /// holds the model, the effort and Providers…, which opens AI › Setup (page map, Sven 2026-10-17).
    private var chatBlock: some View {
        KitBlock(title: "Chat", symbol: "sparkles", fill: true, trailing: {
            HStack(spacing: 6) {
                AIRouteMenu(settings: settings, provider: provider, providers: { AppWindowController.shared.open(.aiSetup) })
                if ready { reachMark }
                IconButton(symbol: "square.and.pencil", label: "New chat") { chat.clear() }
                    .disabled(chat.turns.isEmpty && !chat.running)
            }
        }) {
            VStack(spacing: 10) {
                if !ready && !codexSignIn { unready }
                AIChatTranscript(model: chat, inset: EdgeInsets(top: 12, leading: 4, bottom: 12, trailing: 4), column: 720, centresEmpty: true) { empty }
                    .frame(maxHeight: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { above = $0 }
                AIChatInput(model: chat, send: send, boxed: true, placeholder: AIPage.placeholder(ready: ready), focus: $typing,
                            skills: ready && !codexSignIn ? AIPage.skills(for: provider) : [], room: above,
                            listOpen: $skillsOpen)
                    .frame(maxWidth: 720)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 4)
        }
    }

    /// The picked provider cannot answer yet: one line, and the way to AI › Setup, in place of the provider list
    /// (page map, Sven 2026-10-17). codex's own sign-in waits in the empty chat instead.
    private var unready: some View {
        BlockRow(first: true) {
            AIPage.mark(provider)
            Text("\(AIPage.lineName(provider)) is not set up yet").font(ink.ui(13, .medium)).foregroundStyle(ink.text).lineLimit(1)
            InfoMark(text: "AI answers once its provider is signed in, has its key or its address; Setup takes you through it.")
            Spacer(minLength: 0)
            Button("Set up…") { AppWindowController.shared.open(.aiSetup) }.buttonStyle(.pilotPrimary)
        }
    }

    /// That the picked provider may change Pilot: every one does.
    private var reachMark: some View {
        HStack(spacing: 5) {
            Circle().fill(ink.green).frame(width: 6, height: 6)
            Text("Can change Pilot").font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1).fixedSize()
        }
        .padding(.trailing, 4)
        .accessibilityElement(children: .combine)
    }

    /// Before the first turn: codex's sign-in to Pilot's own Codex home, what another provider still lacks, else what
    /// Pilot may change.
    @ViewBuilder private var empty: some View {
        if provider == .codex, case .signedOut = settings.status(.codex) {
            CodexSignIn(waiting: settings.connecting(.codex), problem: problem, signIn: { connect(.codex) }, cancel: { settings.cancelConnect(.codex) })
        } else if !ready {
            VStack(spacing: 10) {
                AIPage.mark(provider, size: 36)
                Text("Set up \(AIPage.lineName(provider)) to chat").font(ink.ui(15, .semibold)).foregroundStyle(ink.text)
            }
            .multilineTextAlignment(.center)
            .padding(.bottom, 24)
        } else {
            AskPilotStart(provider: provider).opacity(skillsOpen ? 0 : 1).accessibilityHidden(skillsOpen)
        }
    }
}

/// A provider's set-up: its sign-in, Connect or Install, key and address, then its model with Refresh where the API lists
/// them, its effort, and a Test that asks one tiny question (the picked provider's; another is picked first). On AI ›
/// Setup the picked provider's is a block of its own (`inline`, page map, Sven 2026-10-17); another's is the popover
/// its line's button opens.
struct AIProviderSetup: View {
    @Environment(\.ink) private var ink
    let route: AIProvider
    @Bindable var settings: AISettings
    @State private var draft = ""
    @State private var replacing = false
    @State private var test: AIPage.Test?
    @State private var listing: AIPage.Listing?
    @State private var problem: String?
    @State private var address = ""
    @State private var typedModel = ""
    @State private var signingIn = false
    /// In a block of the page, which names the provider: no header, no popover frame.
    private let inline: Bool

    init(route: AIProvider, settings: AISettings, test: AIPage.Test? = nil, inline: Bool = false) {
        self.route = route
        self.settings = settings
        self.inline = inline
        _test = State(initialValue: test)
    }

    private var provider: AIProvider { route }

    var body: some View {
        framed
            .task(id: provider) {
                address = settings.address(for: provider)
                typedModel = provider.typesModel ? settings.model(for: provider)?.id ?? "" : ""
                if provider.command != nil { await settings.refreshCLI(provider) }
                // codex's own catalog fills its picker by itself once per launch, as soon as codex is connected.
                if provider == .codex, settings.ready(.codex), !settings.asked.contains(.codex) { await list(.codex) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard signingIn else { return }
                signingIn = false
                let route = provider
                Task { await settings.refreshCLI(route) }
            }
    }

    @ViewBuilder private var framed: some View {
        if inline {
            rows
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    AIPage.mark(route, size: 24)
                    TitledText(title: route.title, detail: route.detail)
                }
                .padding(.bottom, 10)
                rows
            }
            .frame(width: 480).padding(16)
            .floating()
        }
    }

    @ViewBuilder private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch provider {
            case .claudeCode: cliRow
            case .codex: planRow
            default:
                if provider.editsBaseURL { addressRow }
                if provider.key != .none { keyRow }
            }
            modelRow
            effortRow
            BlockRow { testRow }
            if let problem { BlockRow { FinePrint(text: problem, color: ink.red) } }
        }
    }

    // MARK: Claude subscription

    @ViewBuilder private var cliRow: some View {
        BlockRow(first: true) {
            switch settings.cli {
            case .checking:
                TitledText(title: "Claude Code", detail: "Looking for the claude command…").padding(.vertical, 4)
                InfoMark(text: Self.cliInfo)
                Spacer()
            case .missing:
                TitledText(title: "Claude Code not found",
                           detail: "Install Claude Code (Install in Hyper+Space finds it), then sign in.").padding(.vertical, 4)
                InfoMark(text: Self.cliInfo)
                Spacer()
                Chip(text: "missing", color: ink.red)
            case .signedOut(let path):
                TitledText(title: "claude CLI not signed in", detail: AppConfigs.tilde(path, home: NSHomeDirectory())).padding(.vertical, 4)
                InfoMark(text: Self.cliInfo)
                Spacer()
                Button("Sign in…") { signIn(path) }.buttonStyle(.pilotPrimary)
            case .signedIn(let path):
                TitledText(title: "Signed in", detail: AppConfigs.tilde(path, home: NSHomeDirectory())).padding(.vertical, 4)
                InfoMark(text: Self.cliInfo)
                Spacer()
                Chip(text: "ready", color: ink.green)
            }
        }
    }

    /// The Claude subscription's ⓘ.
    static let cliInfo = "Pilot asks your Claude plan through the claude command, signed in on this Mac; Pilot keeps no login of its own."

    private func signIn(_ path: String) {
        signingIn = true
        VisibleTerminal.run("\(VisibleRun.quoted(path)) auth login", title: "Sign in to Claude", onSuccess: "true")
    }

    // MARK: ChatGPT subscription

    /// codex: Install when missing, Connect when signed out, the browser wait with Cancel, Reconnect when set.
    @ViewBuilder private var planRow: some View {
        let account = provider.account ?? provider.name
        BlockRow(first: true) {
            if settings.connecting(provider) {
                ProgressView().controlSize(.small)
                TitledText(title: "Finish signing in in your browser",
                           detail: "\(account)'s sign-in page is open; this turns ready once it takes.").padding(.vertical, 4)
                InfoMark(text: planInfo)
                Spacer()
                Button("Cancel") { settings.cancelConnect(provider) }.buttonStyle(.pilot)
            } else {
                switch settings.status(provider) {
                case .checking:
                    TitledText(title: provider.name, detail: "Looking for the \(provider.command ?? "") command…").padding(.vertical, 4)
                    InfoMark(text: planInfo)
                    Spacer()
                case .missing:
                    TitledText(title: "\(provider.name) not found",
                               detail: "Install it with Homebrew, then connect your \(account) account.").padding(.vertical, 4)
                    InfoMark(text: planInfo)
                    Spacer()
                    Button("Install…") { install() }.buttonStyle(.pilotPrimary)
                case .signedOut(let path):
                    TitledText(title: "Not connected", detail: AppConfigs.tilde(path, home: NSHomeDirectory())).padding(.vertical, 4)
                    InfoMark(text: planInfo)
                    Spacer()
                    Button("Connect…") { connect() }.buttonStyle(.pilotPrimary)
                case .signedIn(let path):
                    TitledText(title: "Connected", detail: AppConfigs.tilde(path, home: NSHomeDirectory())).padding(.vertical, 4)
                    InfoMark(text: planInfo)
                    Spacer()
                    Button("Reconnect…") { connect() }.buttonStyle(.pilot)
                }
            }
        }
        BlockRow {
            FinePrint(text: "Connect opens \(account)'s sign-in in your browser through the \(provider.command ?? "") command. "
                + "The login stays with that command; Pilot never reads or keeps it.")
        }
    }

    /// The ChatGPT subscription's ⓘ.
    private var planInfo: String { "Pilot asks your \(provider.account ?? provider.name) plan through the \(provider.command ?? "") command, with a sign-in of its own." }

    private func install() {
        guard let package = provider.installPackage else { return }
        signingIn = true
        InstallModule.pick(package)
    }

    private func connect() {
        problem = nil
        test = nil
        let route = provider
        Task {
            guard let why = await settings.connect(route), why != .cancelled else { return }
            problem = why.message
        }
    }

    // MARK: Key and address

    @ViewBuilder private var keyRow: some View {
        let optional = provider.key == .optional
        let first = !provider.editsBaseURL
        if settings.hasKey(provider) && !replacing {
            BlockRow(first: first) {
                TitledText(title: "API key", detail: "Saved in your Keychain; Pilot never shows or logs it").padding(.vertical, 4)
                InfoMark(text: keyInfo)
                Spacer()
                Button("Replace…") { replacing = true }.buttonStyle(.pilot)
                Button("Remove") { save(nil) }.buttonStyle(.pilot)
            }
        } else {
            BlockRow(first: first) {
                Text(optional ? "API key, if it needs one" : "API key")
                InfoMark(text: keyInfo)
                SecureField("API key", text: $draft, prompt: Text(verbatim: "Paste your key").foregroundStyle(ink.muted))
                    .labelsHidden().pilotField().onSubmit { save(draft) }
                Button("Save") { save(draft) }.buttonStyle(.pilotPrimary)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if replacing { Button("Cancel") { replacing = false; draft = "" }.buttonStyle(.pilot) }
            }
            BlockRow {
                FinePrint(text: "It stays in your Keychain, never in a file.")
                Spacer()
                if let page = provider.keyPage {
                    AccentLink(title: "Make one at \(page.host ?? "")") { NSWorkspace.shared.open(page) }
                }
            }
        }
    }

    private var keyInfo: String { "Your own \(AIPage.lineName(provider)) key, billed to your account; Replace or Remove changes it." }

    private func save(_ key: String?) {
        do {
            try settings.setKey(key, for: provider)
            problem = nil
            replacing = false
            test = nil
        } catch {
            problem = "The Keychain did not take the key (\(error))."
        }
        draft = ""
    }

    @ViewBuilder private var addressRow: some View {
        BlockRow(first: true) {
            Text("Address")
            InfoMark(text: "Where Pilot sends your questions for \(AIPage.lineName(provider)); Save keeps a new one.")
            TextField("Address", text: $address, prompt: Text(verbatim: provider.addressExample).foregroundStyle(ink.muted))
                .labelsHidden().font(ink.mono(12)).pilotField().onSubmit(saveAddress)
            Button("Save", action: saveAddress).buttonStyle(.pilot).disabled(address == settings.address(for: provider))
        }
        BlockRow {
            FinePrint(text: provider == .ollama
                ? "Ollama on this Mac answers here. Install it, then ollama pull a model (llama3.2, say), and press Refresh."
                : "The API's base, the part before /chat/completions: OpenRouter's, or LM Studio's http://localhost:1234/v1.")
        }
    }

    private func saveAddress() {
        settings.setAddress(address, for: provider)
        address = settings.address(for: provider)
    }

    // MARK: Model

    /// A list to refresh, or more than the CLI's default to pick from.
    private var picksModel: Bool { provider.refreshesModels || settings.models(for: provider).count > 1 }

    @ViewBuilder private var modelRow: some View {
        let models = settings.models(for: provider)
        if picksModel {
            BlockRow {
                Text("Answers with")
                InfoMark(text: provider.refreshesModels ? "The model that answers; Refresh asks \(provider.name) for the ones it has."
                         : "The model that answers the chat, Ask AI and Fix selected text.")
                Spacer()
                if !provider.refreshesModels {
                    DropdownField(label: "Model", options: models.map { ($0.id ?? "", $0.title) }, picked: settings.model(for: provider)?.id ?? "") {
                        settings.setModel($0, for: provider)
                    }
                    .frame(maxWidth: 220)
                } else {
                    if provider.typesModel {
                        TextField("Model id", text: $typedModel, prompt: Text(verbatim: "Model id").foregroundStyle(ink.muted))
                            .labelsHidden().font(ink.mono(12)).pilotField().frame(maxWidth: 200)
                            .onChange(of: typedModel) { settings.setModel(typedModel, for: provider) }
                    }
                    if !models.isEmpty {
                        DropdownField(label: "Model", options: models.map { ($0.id ?? "", $0.title) }, picked: settings.model(for: provider)?.id ?? "") {
                            settings.setModel($0, for: provider)
                            typedModel = $0
                        }
                        .frame(maxWidth: 200)
                    }
                    Button("Refresh") { refresh() }.buttonStyle(.pilot).disabled(listing == .running)
                }
            }
        }
        if provider.refreshesModels, let listing {
            BlockRow {
                switch listing {
                case .running: ProgressView().controlSize(.small); FinePrint(text: "Asking \(provider.name) for its models…")
                case .listed(let count): FinePrint(text: "\(provider.name) lists \(count) \(count == 1 ? "model" : "models").")
                case .failed(let why): Chip(text: why.title, color: ink.red); why.hint.map { FinePrint(text: $0, color: ink.red) }
                }
                Spacer()
            }
        }
    }

    /// How hard the model thinks: low answers fastest, high thinks longest.
    @ViewBuilder private var effortRow: some View {
        if settings.takesEffort(provider) {
            BlockRow {
                Text("Effort")
                InfoMark(text: "How long the model thinks before it answers: low answers fastest, high thinks longest.")
                Spacer()
                Segments(selection: Binding(get: { settings.effort(for: provider) }, set: { settings.setEffort($0, for: provider) }),
                         options: AIEffort.allCases.map { ($0, $0.title) }, label: "Effort")
            }
        }
    }

    private func refresh() {
        let route = provider
        Task { await list(route) }
    }

    private func list(_ route: AIProvider) async {
        listing = .running
        let failed = await settings.refreshModels(for: route)
        listing = failed.map(AIPage.Listing.failed) ?? .listed(settings.models(for: route).count)
    }

    // MARK: Test

    /// Test asks the picked provider, so another one is picked first.
    @ViewBuilder private var testRow: some View {
        if provider != settings.provider {
            FinePrint(text: "AI uses \(AIPage.lineName(settings.provider)).")
            InfoMark(text: "Test asks the picked provider, so Use picks this one first.")
            Spacer()
            Button("Use \(AIPage.lineName(provider))") { settings.provider = provider; test = nil }.buttonStyle(.pilot)
        } else {
            Button("Test") {
                test = .running
                Task { test = await settings.test().map(AIPage.Test.failed) ?? .passed }
            }
            .buttonStyle(.pilot).disabled(test == .running)
            InfoMark(text: "Asks \(provider.name) one tiny question, the way AI will, to show it answers.")
            switch test {
            case nil: FinePrint(text: "Asks one tiny question the way AI will")
            case .running: ProgressView().controlSize(.small); FinePrint(text: "Asking…")
            case .passed: Chip(text: "works", color: ink.green); FinePrint(text: "\(provider.name) answered")
            case .failed(let why): Chip(text: why.title, color: ink.red); why.hint.map { FinePrint(text: $0, color: ink.red) }
            }
            Spacer()
        }
    }
}

/// Onboarding's optional AI step (task N10; "AI", page map, Sven 2026-10-17): the provider alone, skipped by leaving it; the key, sign-in, address,
/// model and Test wait on the AI page.
struct AIProviderPick: View {
    @Bindable var settings = AISettings.shared

    static let title = "AI"
    static let detail = "How Ask AI and Fix selected text reach a model: your Claude or ChatGPT subscription, "
        + "your own Anthropic or OpenAI key, Ollama on this Mac, or any OpenAI-compatible server. Connect, add the key "
        + "or change it any time on the AI page."

    var body: some View {
        DropdownField(label: "AI uses", options: AIProvider.allCases.map { ($0, $0.title) }, picked: settings.provider) {
            settings.provider = $0
        }
        .frame(width: 220)
    }
}

/// The picked provider, its model and its effort, as one menu (none when there is nothing to pick). Its pickers take the
/// system switch style back (menuRows), or the window's greys every row (Sven on build 42).
struct AIRouteMenu: View {
    @Environment(\.ink) private var ink
    let settings: AISettings
    let provider: AIProvider
    /// Providers…, the menu's last item, on the AI page once the picked provider can answer; it makes the label a menu.
    var providers: (() -> Void)?

    var body: some View {
        let models = settings.models(for: provider)
        let effort = settings.takesEffort(provider)
        let model = settings.model(for: provider)
        let label = HStack(spacing: 5) {
            Text(AIPage.lineName(provider)).foregroundStyle(ink.text2)
            if let model, model.id != nil { Text("· \(model.title)") }
            if effort { Text("· \(settings.effort(for: provider).title)") }
            if models.count > 1 || effort || providers != nil { Image(systemName: "chevron.up.chevron.down").font(ink.ui(9, .semibold)) }
        }
        .font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1).fixedSize()
        if models.count > 1 || effort || providers != nil {
            Menu {
                if models.count > 1 {
                    Picker("Model", selection: Binding(get: { settings.model(for: provider)?.id }, set: { settings.setModel($0, for: provider) })) {
                        ForEach(models.indices, id: \.self) { Text(models[$0].title).tag(models[$0].id) }
                    }
                    .pickerStyle(.inline).menuRows()
                }
                if effort {
                    Picker("Effort", selection: Binding(get: { settings.effort(for: provider) }, set: { settings.setEffort($0, for: provider) })) {
                        ForEach(AIEffort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline).menuRows()
                }
                if let providers {
                    Divider()
                    Button("Providers…", action: providers)
                }
            } label: { label }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(providers == nil ? "Model and effort" : "Provider, model and effort")
        } else {
            label
        }
    }
}

/// The apps where Hyper+drag shows no selection pill (Sven Q215), the terminals until changed: a chip each with its ×, and
/// Add app… to pick another.
struct SelectionSkipRow: View {
    /// The skipped apps' bundle ids and names, read when the row shows.
    @State private var apps: [(id: String, name: String)] = []

    var body: some View {
        BlockRow {
            TitledText(title: "No pill in").padding(.vertical, 4).fixedSize()
            InfoMark(text: "Hyper+drag shows no selection pill in these apps; the terminals until you change them.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(apps, id: \.id) { app in
                        Chip(text: app.name, remove: { save(apps.map(\.id).filter { $0 != app.id }) }).help(app.id)
                    }
                }
            }
            Button { add() } label: { Chip(text: "Add app", symbol: "plus") }.buttonStyle(.kitPress)
        }
        .task { load() }
    }

    private func load() { apps = SelectionTools.shared.skipped.map { ($0, AppsModule.displayName($0)) } }

    private func save(_ next: [String]) {
        SelectionTools.shared.skipped = next
        load()
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "No pill in this app"
        guard panel.runModal() == .OK, let id = panel.url.flatMap(Bundle.init(url:))?.bundleIdentifier else { return }
        save(apps.map(\.id) + [id])
    }
}
