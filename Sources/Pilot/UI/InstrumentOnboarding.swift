import PilotCore
import SwiftUI

/// Onboarding in Instrument (card agent-bo-95423181, ADR 0008), Home's language in mockup A: the step in mono capitals
/// over its title, its rows in an InstrumentPanel under a hairline header, each permission's state said in words, the
/// layer key's chip lit in the signal colour, and one primary button a step, at the foot. The same model, actions, keys
/// and words as OnboardingView's; only the drawing is Instrument's.
struct InstrumentOnboarding: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    @Bindable var model: OnboardingModel
    @Binding var confirming: LayerKeyChange?
    let finish: () -> Void
    /// Permissions' folded group, open.
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.step {
            case .welcome: welcome
            case .permissions: permissions
            case .extras: extras
            case .tryIt: tryIt
            }
        }
        .padding(28)
        .frame(width: 560, alignment: .leading)
        .foregroundStyle(style.color(\.text))
    }

    /// The step's mono capitals, its title, and what it is about.
    private func heading(_ step: Int, _ title: String, @ViewBuilder about: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            InstrumentEyebrow(text: "Step \(step) of \(OnboardingModel.Step.allCases.count)")
            Text(title).styleText(\.display).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader).padding(.top, 10)
            about().padding(.top, 10)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 22)
    }

    /// The foot: what to know in the third text colour, then the step's one primary button with Return's chip.
    private func foot(_ note: String?, _ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            if let note { Text(note).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            Button(action: action) { InstrumentKeyedLabel(title: title, symbol: nil, trigger: nil) }
                .keyboardShortcut(.defaultAction).buttonStyle(InstrumentButtonStyle(kind: .primary)).disabled(!enabled)
        }
        .padding(.top, 20)
    }

    // MARK: Welcome

    private var welcome: some View {
        @Bindable var settings = engine.settings
        return VStack(alignment: .leading, spacing: 0) {
            heading(OnboardingModel.Step.welcome.number, "Welcome to Pilot") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pilot makes this Mac work like Omarchy.").styleText(\.strong).foregroundStyle(style.color(\.text))
                    Text("Pilot runs on one key, called Hyper. Holding it is like pressing a combination of modifier keys at once, so every Hyper shortcut is free of clashes. Pick which key is Hyper.")
                        .styleText(\.body).lineSpacing(3).foregroundStyle(style.color(\.text2))
                }
            }
            InstrumentPanel(title: "Hyper key", note: settings.layerKeys.label) {
                ForEach(Array(Onboarding.hyperChoices.enumerated()), id: \.element) { index, key in
                    let on = settings.layerKeys.contains(key)
                    if index > 0 { InstrumentRule() }
                    Button { LayerKeyConfirm.pick([key], settings, from: .onboarding, asking: $confirming) } label: {
                        HStack(spacing: 12) {
                            InstrumentRadio(on: on)
                            titled(key.label, Onboarding.hyperDetail(key))
                            Spacer(minLength: 8)
                            InstrumentKey(text: key.symbol, hyper: on)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12).frame(minHeight: 52)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .layerKeyConfirm($confirming, settings: settings, from: .onboarding)
            foot(nil, "Continue") { model.go(.permissions) }
        }
    }

    // MARK: Permissions

    private var permissions: some View {
        let rows = Onboarding.Row.allCases
        let done = rows.count { Onboarding.isDone($0, model.status) }
        return VStack(alignment: .leading, spacing: 0) {
            heading(OnboardingModel.Step.permissions.number, "Permissions") {
                Text("\(done) of \(rows.count) done").styleText(\.mono).foregroundStyle(style.color(\.text3))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Onboarding.Need.allCases, id: \.self) { need in
                        let group = Onboarding.Row.rows(need)
                        InstrumentPanel(title: need.title, note: need == .whenUsed ? "\(group.count)" : nil) {
                            if need == .whenUsed {
                                Button(showAll ? "Hide" : "Show") { showAll.toggle() }.buttonStyle(InstrumentButtonStyle(kind: .ghost))
                            }
                        } content: {
                            if need != .whenUsed || showAll {
                                ForEach(Array(group.enumerated()), id: \.element) { index, row in
                                    if index > 0 { InstrumentRule() }
                                    grant(row)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: OnboardingView.scrollHeight)
            if let problem = model.problem {
                InstrumentAttention(text: problem).padding(.top, 14)
            }
            foot(Onboarding.continueNote, "Continue",
                 enabled: Onboarding.canContinue(model.status)) { model.go(.extras) }
        }
    }

    private func grant(_ row: Onboarding.Row) -> some View {
        HStack(spacing: 14) {
            titled(row.title, row.detail(model.status))
            Spacer(minLength: 8)
            if Onboarding.isDone(row, model.status) {
                state(row == .conflicts ? "Done" : "Allowed")
            } else {
                Button(model.button(row)) { model.act(row) }.buttonStyle(InstrumentButtonStyle(kind: .raised))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    // MARK: Extras

    private var extras: some View {
        let extras = model.extras
        return VStack(alignment: .leading, spacing: 0) {
            heading(OnboardingModel.Step.extras.number, "Extras") {
                Text("All optional. The common ones are ticked; nothing starts before Continue.").styleText(\.body).foregroundStyle(style.color(\.text2))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Update and Clean first, each with the helpers it runs (Q555); Homebrew's one Terminal run after Clean.
                    ForEach(OnboardingExtras.Feature.allCases, id: \.self) { feature in
                        InstrumentPanel(title: feature.title, note: feature.short) {
                            if let line = feature.line {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(line).styleText(\.body).foregroundStyle(style.color(\.text))
                                    if let later = extras.later(feature) { Text(later).styleText(\.caption).foregroundStyle(style.color(\.accent)) }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                            }
                            ForEach(Array(feature.items.enumerated()), id: \.element) { index, extra in
                                if index > 0 || feature.line != nil { InstrumentRule() }
                                item(extra)
                            }
                            if feature == .clean, let command = extras.brewCommand {
                                InstrumentRule()
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(OnboardingExtras.terminalNote).styleText(\.caption).foregroundStyle(style.color(\.text2))
                                    Text(command).styleText(\.mono).foregroundStyle(style.color(\.text3)).textSelection(.enabled)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                            }
                        }
                    }
                    InstrumentPanel(title: "Voice") {
                        if let on = extras.speechOnMac {
                            line { titled("Dictation model", "\(on.name) is on this Mac"); Spacer(minLength: 8); state("Done") }
                        } else {
                            ForEach(Array(OnboardingExtras.speechChoices.enumerated()), id: \.element) { index, choice in
                                if index > 0 { InstrumentRule() }
                                speech(choice)
                            }
                        }
                        InstrumentRule()
                        item(.voices)
                    }
                    InstrumentPanel(title: "AI and agents") {
                        VStack(alignment: .leading, spacing: 10) {
                            titled(AIProviderPick.title, AIProviderPick.detail)
                            AIProviderPick()
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        InstrumentRule()
                        item(.command)
                    }
                    InstrumentPanel(title: "Images") { item(.upscaler) }
                    InstrumentPanel(title: "Pilot") {
                        line {
                            titled("Extensions", OnboardingExtras.extensionsDetail)
                            Spacer(minLength: 8)
                            Button("Browse…") { OnboardingExtras.browseExtensions() }.buttonStyle(InstrumentButtonStyle(kind: .raised))
                        }
                        InstrumentRule()
                        item(.recommendApps)
                        InstrumentRule()
                        item(.launchAtLogin)
                    }
                }
            }
            .frame(height: OnboardingView.scrollHeight)
            .onAppear { extras.load() }
            HStack(spacing: 16) {
                Text(extras.footNote).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Skip all") { model.startTryIt(extras: false) }.buttonStyle(InstrumentButtonStyle(kind: .ghost))
                Button { model.startTryIt() } label: { InstrumentKeyedLabel(title: "Continue", symbol: nil, trigger: nil) }
                    .keyboardShortcut(.defaultAction).buttonStyle(InstrumentButtonStyle(kind: .primary))
            }
            .padding(.top, 20)
        }
    }

    /// A dictation model to pick, or Skip.
    private func speech(_ choice: SpeechChoice?) -> some View {
        let on = model.extras.speech == choice
        return Button { model.extras.speech = choice } label: {
            line {
                InstrumentRadio(on: on)
                titled(OnboardingExtras.speechTitle(choice), OnboardingExtras.speechDetail(choice))
                Spacer(minLength: 8)
                if choice == OnboardingExtras.recommendedSpeech { tag("Recommended") }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// An extra: its switch, or that it is on this Mac already.
    private func item(_ item: OnboardingExtras.Item) -> some View {
        line {
            titled(item.title, item.detail)
            Spacer(minLength: 8)
            if model.extras.onMac.contains(item) {
                state("On this Mac")
            } else {
                if let chip = item.chip { tag(chip.capitalized) }
                Toggle(item.title, isOn: model.extras.binding(item))
                    .labelsHidden().toggleStyle(InstrumentSwitchStyle(lit: false))
            }
        }
    }

    private func line(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 14) { content() }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func tag(_ text: String) -> some View {
        Text(text).styleText(\.mono).foregroundStyle(style.color(\.accent)).fixedSize()
    }

    // MARK: Try it

    private var tryIt: some View {
        let key = engine.settings.layerKeys
        let lines = model.extras.progress
        return VStack(alignment: .leading, spacing: 0) {
            heading(OnboardingModel.Step.tryIt.number, "Try it")
            InstrumentPanel(title: "The Hyper key", note: key.label) {
                prompt("Hold \(key.label) for a moment", "your binds appear while you hold it", caps: [], done: model.tryIt.held)
                InstrumentRule()
                prompt("Now press \(key.label) + Space", "opens the Pilot menu: apps, files, windows, install", caps: ["Space"],
                       done: model.tryIt.menuOpened)
            }
            if !lines.isEmpty {
                InstrumentPanel(title: "In the background") {
                    ForEach(Array(lines.enumerated()), id: \.element.title) { index, entry in
                        if index > 0 { InstrumentRule() }
                        line { Text(entry.title).styleText(\.strong); Spacer(minLength: 8); Text(entry.state).styleText(\.mono).foregroundStyle(style.color(\.text3)) }
                    }
                }
                .padding(.top, 14)
            }
            foot("Pilot is in the menu bar, showing the workspace number", "Finish", action: finish)
        }
    }

    /// A prompt: the layer key's chip lit and the key after it, what to do, and whether Pilot saw it.
    private func prompt(_ title: String, _ detail: String, caps: [String], done: Bool) -> some View {
        HStack(spacing: 14) {
            // One column for both prompts' keys, so their words line up.
            InstrumentKeys(caps: caps).frame(width: 84, alignment: .leading)
            titled(title, detail)
            Spacer(minLength: 8)
            state(done ? "Done" : "Waiting", live: !done)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    // MARK: Parts

    /// A row's title, strong, over its detail in the third text colour, whole.
    private func titled(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).styleText(\.strong).foregroundStyle(style.color(\.text))
            if let detail { Text(detail).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A state in words, in mono: done with a check in the second text colour; what Pilot waits for after the signal's
    /// dot (the live thing).
    private func state(_ words: String, live: Bool = false) -> some View {
        HStack(spacing: 6) {
            if live {
                Circle().fill(style.color(\.accent)).frame(width: 6, height: 6)
            } else {
                Image(systemName: "checkmark").font(style.font(\.small)).foregroundStyle(style.color(\.text2))
            }
            Text(words).styleText(\.mono).foregroundStyle(style.color(live ? \.text3 : \.text2))
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// A radio's face: a hairline ring, the picked one's centre in the signal colour.
private struct InstrumentRadio: View {
    @Environment(\.style) private var style
    let on: Bool

    var body: some View {
        Circle().strokeBorder(style.color(on ? \.accentLine : \.line3), lineWidth: 1.25)
            .overlay { if on { Circle().fill(style.color(\.accent)).padding(4) } }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}
