import PilotCore
import SwiftUI

/// Onboarding in Instrument (card agent-bo-95423181, ADR 0008; Onboarding 1.1, variant C, Q841-Q843): the step rail over
/// each screen, its title in the display face, rows in InstrumentPanels under a hairline header, every state said in
/// words, and one primary button a screen, at the foot. The same model, parts and words as Toybox's OnboardingSteps;
/// only the drawing is Instrument's.
struct InstrumentOnboarding: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    @Bindable var model: OnboardingModel
    @Binding var confirming: LayerKeyChange?
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingRail(step: model.step, allDone: model.step == .tryIt && model.demoDone(engine))
            switch model.step {
            case .welcome: welcome
            case .permissions: access
            case .extras: setUp
            case .tryIt: tryIt
            }
        }
        .padding(28)
        .frame(width: 560, alignment: .leading)
        .foregroundStyle(style.color(\.text))
    }

    /// The screen's title and what it is about.
    private func heading(_ title: String, @ViewBuilder about: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).styleText(\.display).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
            about().padding(.top, 10)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 22)
    }

    /// The foot: what to know in the third text colour, then the screen's one primary button with Return's chip.
    private func foot(_ note: String?, _ title: String, enabled: Bool = true, @ViewBuilder extra: () -> some View = { EmptyView() },
                      action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            if let note { Text(note).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            extra()
            Button(action: action) { InstrumentKeyedLabel(title: title, symbol: nil, trigger: nil) }
                .keyboardShortcut(.defaultAction).buttonStyle(InstrumentButtonStyle(kind: .primary)).disabled(!enabled)
        }
        .padding(.top, 20)
    }

    // MARK: Hyper

    private var welcome: some View {
        @Bindable var settings = engine.settings
        return VStack(alignment: .leading, spacing: 0) {
            heading(OnboardingModel.welcomeTitle) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(OnboardingModel.welcomeLine).styleText(\.strong).foregroundStyle(style.color(\.text))
                    Text(OnboardingModel.hyperAbout)
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
                            VStack(alignment: .leading, spacing: 6) {
                                let breaks = model.hyperBreaks(key, engine)
                                titled(key.label, breaks == nil ? Onboarding.hyperDetail(key) : nil)
                                if let breaks { HyperBreaks(text: breaks) }
                            }
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

    // MARK: Access

    /// Accessibility, the one grant Pilot waits for; the recommended and optional grants named for later, no buttons.
    private var access: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Allow Accessibility") {
                Text(OnboardingModel.accessAbout).styleText(\.body).lineSpacing(3).foregroundStyle(style.color(\.text2))
            }
            .padding(.bottom, -14)
            AccessPanel(model: model)
            foot(OnboardingModel.ticksItself, "Continue", enabled: Onboarding.canContinue(model.status)) { model.go(.extras) }
        }
    }

    // MARK: Set up

    /// The fork, Pick by hand, or the run in its place.
    private var setUp: some View {
        let setup = model.setup
        return VStack(alignment: .leading, spacing: 0) {
            switch setup.phase {
            case .fork:
                heading("How should Pilot set up?")
                SetupFork(setup: setup)
                HStack(spacing: 16) {
                    Text(setup.asksForMacLogin ? OnboardingModel.passwordNote : OnboardingModel.undoAfter)
                        .styleText(\.caption).foregroundStyle(style.color(\.text3))
                    Spacer(minLength: 0)
                    Button("Skip setup") { model.startTryIt() }.buttonStyle(InstrumentButtonStyle(kind: .ghost))
                }
                .padding(.top, 20)
            case .pick:
                heading("Pick by hand") {
                    Text(OnboardingModel.pickNote).styleText(\.body).foregroundStyle(style.color(\.text2))
                }
                ScrollView { SetupPickList(setup: setup) }.frame(height: OnboardingView.scrollHeight)
                foot(setup.picked.contains(.homebrew) ? OnboardingModel.passwordNote : nil, "Set up these", enabled: !setup.picked.isEmpty) {
                    Button("Back") { setup.phase = .fork }.buttonStyle(InstrumentButtonStyle(kind: .ghost))
                } action: {
                    setup.start(Array(setup.picked))
                }
            case .run:
                heading(setup.title)
                ScrollView { SetupRunList(setup: setup) }.frame(maxHeight: OnboardingView.scrollHeight)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = setup.problem { InstrumentAttention(text: problem).padding(.top, 14) }
                foot(OnboardingModel.undoNote, "Continue") { model.startTryIt() }
            }
        }
        .onAppear { if setup.phase != .run { setup.load() } }
        .task { await setup.loadThemes() }
    }

    // MARK: Try it

    private var tryIt: some View {
        let key = engine.settings.layerKeys
        return VStack(alignment: .leading, spacing: 14) {
            heading("Try it").padding(.bottom, -14)
            TryItScroll(showsMore: model.showsMore) { tryItPanels(key) }
            foot("Pilot is in the menu bar", "Finish", action: finish)
        }
    }

    private func tryItPanels(_ key: [LayerKey]) -> some View {
        let demoDone = model.demoDone(engine)
        return VStack(alignment: .leading, spacing: 14) {
            InstrumentPanel(title: "The Hyper key", note: key.label) {
                if demoDone {
                    line { DemoDone(line: model.demoLine(engine)); Spacer(minLength: 0) }
                } else {
                prompt("Hold \(key.label)", "your binds appear while you hold it", caps: [], done: model.tryIt.held)
                if let files = model.filesKey(engine) {
                    InstrumentRule()
                    prompt("Press \(key.label) + \(files)", "Pilot Files opens: the key you just set", caps: [files], done: model.filesOpened)
                }
                InstrumentRule()
                prompt("Press \(key.label) + Space", "the Pilot menu", caps: ["Space"], done: model.tryIt.menuOpened)
                }
            }
            InstrumentPanel(title: "The other permissions") {
                GrantWalkPanel(walk: model.walk).padding(.horizontal, 18).padding(.vertical, 12)
            }
            InstrumentPanel(title: "More, if you want") {
                Button(model.showsMore ? "Hide" : "Show") { model.showsMore.toggle() }.buttonStyle(InstrumentButtonStyle(kind: .ghost))
            } content: {
                if model.showsMore { OnboardingMore() }
            }
            .id(OnboardingModel.moreID)
        }
    }

    /// A prompt: the layer key's chip lit and the key after it, what to do, and whether Pilot saw it.
    private func prompt(_ title: String, _ detail: String, caps: [String], done: Bool) -> some View {
        HStack(spacing: 14) {
            // One column for every prompt's keys, so their words line up.
            InstrumentKeys(caps: caps).frame(width: 84, alignment: .leading)
            titled(title, detail)
            Spacer(minLength: 8)
            state(done ? "Done" : "Waiting", live: !done)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    // MARK: Parts

    private func line(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 14) { content() }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func titled(_ title: String, _ detail: String?) -> some View { SetupTitled(title: title, detail: detail) }

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
