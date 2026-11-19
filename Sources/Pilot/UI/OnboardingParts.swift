import PilotCore
import SwiftUI

// Onboarding 1.1's parts both looks draw (T54, variant C): the step rail, Set up's fork, Pick by hand's list, the run's
// groups with their Undo, and Try it's optional panel. Every colour, face, button and switch comes from the style, so
// Toybox and Instrument each draw them in their own look.

/// The step rail over every screen: numbered nodes joined by a line that fills as each step finishes. A done node shows
/// a tick, the current one the accent, the rest stay hairline.
struct OnboardingRail: View {
    @Environment(\.style) private var style
    let step: OnboardingModel.Step
    /// The current step is finished too (Try it's demo done): its node shows a tick.
    var allDone = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { s in
                if s != .welcome {
                    (s.number <= step.number ? style.color(\.text3) : style.color(\.line2))
                        .frame(height: 1).frame(minWidth: 10, maxWidth: .infinity)
                }
                node(s)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.number) of \(OnboardingModel.Step.allCases.count), \(step.title)")
        .padding(.bottom, 22)
    }

    private func node(_ s: OnboardingModel.Step) -> some View {
        let current = s == step, done = s.number < step.number
        return HStack(spacing: 8) {
            ZStack {
                if current {
                    Circle().fill(style.color(\.accent))
                    if allDone {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(style.color(\.canvas))
                    } else {
                        Text("\(s.number)").styleText(\.mono).foregroundStyle(style.color(\.canvas))
                    }
                } else {
                    Circle().strokeBorder(style.color(done ? \.line3 : \.line2), lineWidth: 1)
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(style.color(\.text2))
                    } else {
                        Text("\(s.number)").styleText(\.mono).foregroundStyle(style.color(\.text3))
                    }
                }
            }
            .frame(width: 22, height: 22)
            Text(s.title.uppercased()).styleText(\.eyebrow).foregroundStyle(style.color(current ? \.text : \.text3)).lineLimit(1).fixedSize()
        }
    }
}

/// A row's title, strong, over its detail in the third text colour, whole.
struct SetupTitled: View {
    @Environment(\.style) private var style
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).styleText(\.strong).foregroundStyle(style.color(\.text))
            if let detail { Text(detail).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A button in the style's own face; `wide` fills its card.
private struct SetupButton: View {
    let title: String
    var primary = false
    var wide = false
    /// What VoiceOver reads when the title alone is not enough ("Undo Helpers").
    var label: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title).frame(maxWidth: wide ? .infinity : nil) }.buttonStyle(PilotButtonStyle(primary: primary))
            .accessibilityLabel(label ?? title)
    }
}

// MARK: Set up's fork

/// Set up's two paths side by side: Set up everything, marked Recommended, with the primary button, and Pick by hand.
struct SetupFork: View {
    @Environment(\.style) private var style
    let setup: OnboardingSetup

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            card(eyebrow: "Recommended", title: "Set up everything", about: "One run. " + OnboardingModel.undoAfter) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(SetupGroup.allCases, id: \.self) { group in
                        let n = group.items.count(where: setup.everything.contains)
                        if n > 0 {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(n)").styleText(\.mono).foregroundStyle(style.color(\.text3)).frame(width: 14, alignment: .leading)
                                Text(group.line).styleText(\.caption).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    // The theme is the user's own pick (Sven, 2026-11-19): kept as it is until one is picked here.
                    VStack(alignment: .leading, spacing: 4) {
                        SetupThemePicker(setup: setup)
                        if setup.themePick != nil {
                            Text(setup.themeNote).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(setup.forkCount).styleText(\.mono).foregroundStyle(style.color(\.text3)).padding(.top, 2)
                    if !setup.noAppBefore.isEmpty {
                        // Said before the run (reviewer, T54): Undo cannot put "no app" back.
                        Text("\(setup.noAppBefore.map { $0 == .txt ? ".txt" : ".md" }.joined(separator: " and ")): no app opens it now, so its Undo can't go back to none.")
                            .styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } button: {
                SetupButton(title: "Set up everything", primary: true, wide: true) { setup.start(setup.everything) }
                    .disabled(setup.everything.isEmpty)
            }
            card(eyebrow: "Your way", title: "Pick by hand",
                 about: "Choose each key and setting. Nothing changes until you confirm.") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("· starts with nothing ticked").styleText(\.caption).foregroundStyle(style.color(\.text2))
                    Text("· each row says what it gives").styleText(\.caption).foregroundStyle(style.color(\.text2))
                }
            } button: {
                SetupButton(title: "Pick by hand", wide: true) { setup.phase = .pick }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card(eyebrow: String, title: String, about: String, @ViewBuilder content: () -> some View,
                      @ViewBuilder button: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InstrumentEyebrow(text: eyebrow)
            Text(title).styleText(\.title).foregroundStyle(style.color(\.text))
            Text(about).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
            content().padding(.top, 4)
            Spacer(minLength: 12)
            button()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .styleSurface(\.card)
    }
}

/// Set up's theme menu: Keep the current look (the default), or a theme of the style in use.
struct SetupThemePicker: View {
    @Bindable var setup: OnboardingSetup

    var body: some View {
        Picker("Theme", selection: $setup.themePick) {
            Text("Theme: keep the current look").tag(String?.none)
            ForEach(setup.themes, id: \.id) { theme in Text("Theme: \(theme.title)").tag(Optional(theme.id)) }
        }
        .labelsHidden().fixedSize()
    }
}

// MARK: Pick by hand

/// Pick by hand: the same groups as ticked rows, each with what it gives, nothing ticked at first; what is on this Mac
/// says so instead of a switch.
struct SetupPickList: View {
    @Environment(\.style) private var style
    let setup: OnboardingSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(SetupGroup.allCases.filter { !$0.offered.isEmpty }, id: \.self) { group in
                VStack(alignment: .leading, spacing: 0) {
                    groupHeading(group)
                    ForEach(group.offered, id: \.self) { item in
                        InstrumentRule()
                        HStack(spacing: 14) {
                            SetupTitled(title: item.title, detail: item == .theme && setup.themePick != nil ? setup.themeNote : item.detail)
                            Spacer(minLength: 8)
                            if item == .theme && setup.ledger[item] == nil {
                                // Picking one ticks it; Keep the current look unticks it.
                                SetupThemePicker(setup: setup)
                            } else if setup.onMac.contains(item) {
                                Text("On this Mac").styleText(\.mono).foregroundStyle(style.color(\.text2)).fixedSize()
                            } else if let state = setup.ledger[item]?.state {
                                // Held by the last run's record: said, never offered twice.
                                Text(state.words).styleText(\.mono).foregroundStyle(style.color(\.text3)).lineLimit(2)
                                    .frame(maxWidth: 200, alignment: .trailing)
                            } else {
                                toggle(item)
                            }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 10)
                    }
                }
                .styleSurface(\.card)
            }
        }
    }

    private func toggle(_ item: SetupItem) -> some View {
        Toggle(item.title, isOn: Binding(get: { setup.picked.contains(item) }, set: { setup.set(item, $0) })).labelsHidden().toggleStyle(.pilotSwitch)
    }

    private func groupHeading(_ group: SetupGroup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: group.symbol).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
            Text(group.title).styleText(\.title).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.horizontal, 18).frame(height: 40)
    }
}

// MARK: The run

/// The run, in place of the fork, and Try it's Review: one row per group with its count, a thin bar, a line naming each
/// change with its state, and Undo for the whole group; opening a group lists its lines, each with its own Undo.
/// Homebrew's undo asks first.
struct SetupRunList: View {
    @Environment(\.style) private var style
    let setup: OnboardingSetup
    @State private var open: Set<SetupGroup> = []
    @State private var asking: [SetupItem]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(SetupGroup.allCases.filter { setup.share($0) != nil }.enumerated()), id: \.element) { index, group in
                if index > 0 { InstrumentRule() }
                row(group)
            }
        }
        .styleSurface(\.card)
        // Looks again each time it shows: at launch's resume and in Try it's Review, a quiet mark may have settled since.
        .onAppear { setup.refresh() }
        .confirmationDialog("Remove Homebrew?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            Button("Remove Homebrew", role: .destructive) { if let asking { setup.undo(asking) }; asking = nil }
            Button("Cancel", role: .cancel) { asking = nil }
        } message: {
            Text(OnboardingSetup.homebrewWarning)
        }
    }

    private func row(_ group: SetupGroup) -> some View {
        let share = setup.share(group) ?? (0, 0, 0), undo = setup.undoable(group), live = share.settled < share.total
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { if open.contains(group) { open.remove(group) } else { open.insert(group) } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: group.symbol).foregroundStyle(style.color(\.text2)).frame(width: 26, height: 26)
                            .background(style.color(\.raised), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityHidden(true)
                        Text(group.title).styleText(\.strong).foregroundStyle(style.color(\.text))
                        Image(systemName: open.contains(group) ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
                        Spacer(minLength: 8)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.title), \(open.contains(group) ? "close" : "open") its lines")
                // While it runs, what settled; after, what is done, so a failure shows as a gap.
                Text("\(live ? share.settled : share.done) of \(share.total)").styleText(\.mono).foregroundStyle(style.color(live ? \.accent : \.text2)).fixedSize()
                if !undo.isEmpty { SetupButton(title: "Undo", label: "Undo \(group.title)") { ask(undo) } }
            }
            // The accent while the group runs, the second text colour once it settled.
            InstrumentMeter(share: share.total == 0 ? 0 : Double(share.settled) / Double(share.total), fill: live ? \.accent : \.text2)
                .padding(.leading, 38)
            Text(setup.line(group)).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 38)
            if open.contains(group) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.items.filter { setup.ledger[$0] != nil }, id: \.self) { item in
                        HStack(spacing: 10) {
                            Text(item.short).styleText(\.body).foregroundStyle(style.color(\.text))
                            Spacer(minLength: 8)
                            Text(setup.ledger[item]?.state.words ?? "").styleText(\.mono).foregroundStyle(style.color(\.text3))
                                .lineLimit(2).multilineTextAlignment(.trailing)
                            if undo.contains(item) { SetupButton(title: "Undo", label: "Undo \(item.short)") { ask([item]) } }
                        }
                    }
                }
                .padding(.leading, 38).padding(.top, 2)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    /// Homebrew's undo asks first: removing it removes everything installed through it.
    private func ask(_ items: [SetupItem]) { if items.contains(.homebrew) { asking = items } else { setup.undo(items) } }
}

// MARK: Try it

/// Try it's Allow the rest (T58): the grants Access left for later, walked one after another (GrantWalk), with
/// "Done: N of M", the step it waits on, Skip and Stop; at the end, what was skipped and where it is.
struct GrantWalkPanel: View {
    @Environment(\.style) private var style
    let walk: GrantWalk

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch walk.phase {
            case .ready:
                HStack(spacing: 14) {
                    Text(GrantWalk.steps.map(GrantWalk.name).joined(separator: " · ") + ": one after another, each where macOS asks.")
                        .styleText(\.caption).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    SetupButton(title: "Allow the rest") { walk.start() }
                }
            case .asking(let row):
                Text(walk.done).styleText(\.mono).foregroundStyle(style.color(\.text3))
                HStack(spacing: 14) {
                    SetupTitled(title: "Now: \(GrantWalk.name(row))", detail: GrantWalk.hint(row))
                    Spacer(minLength: 8)
                    SetupButton(title: "Skip", label: "Skip \(GrantWalk.name(row))") { walk.skip() }
                    SetupButton(title: "Stop") { walk.stop() }
                }
            case .finished:
                Text(walk.done).styleText(\.mono).foregroundStyle(style.color(\.text2))
                // Settings › Permissions has each but Notifications, which only System Settings has, and Screen Recording,
                // which it shows only once Menu bar › Other apps asks for it (ADR 0012).
                let pilot = walk.skipped.filter { $0 != .notifications && $0 != .screenRecording }
                if !pilot.isEmpty {
                    Text("Skipped: \(pilot.map(GrantWalk.name).joined(separator: ", ")). Each is in \(AppPlace(.permissions).path).")
                        .styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                }
                if walk.skipped.contains(.screenRecording) {
                    Text("Screen Recording: \(AppPlace(.menuBar).path) › Other apps, or System Settings › Privacy & Security › Screen Recording.")
                        .styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                }
                if walk.skipped.contains(.notifications) {
                    Text("Notifications: System Settings › Notifications › Pilot.")
                        .styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension Engine {
    /// The label of the Hyper bind on `key`, nil when none: the action a Hyper choice's everyday shortcut would run.
    func boundLabel(_ key: Key) -> String? { binds.store.action(for: key).flatMap { action($0)?.label } }
}

/// Access in both styles (Sven, 2026-11-19: mockup C, with A's drag strip and B's plain words): what Accessibility lets
/// Pilot do and the one thing it never sees; Pilot's icon to drag into the list from this window, no floating helper,
/// with three steps that follow the real state (Settings running, then the grant); the later grants in one line.
struct AccessPanel: View {
    @Environment(\.style) private var style
    let model: OnboardingModel

    var body: some View {
        let granted = model.status.accessibility, open = model.settingsOpen || granted
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("With it, Pilot can").styleText(\.title).foregroundStyle(style.color(\.text))
                ForEach(OnboardingModel.accessCan, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(style.color(\.accent)).accessibilityHidden(true)
                        Text(line).styleText(\.body).foregroundStyle(style.color(\.text2))
                    }
                }
                Text(OnboardingModel.accessNever).styleText(\.caption).foregroundStyle(style.color(\.text3)).padding(.top, 4)
            }
            .padding(.horizontal, 18).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading).styleSurface(\.card)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    DraggableApp().frame(width: 48, height: 48).help("Drag Pilot into the list")
                    SetupTitled(title: granted ? "Accessibility is on" : "Drag Pilot into the list",
                                detail: granted ? "Pilot reads the Hyper key now." : "Then switch it on. An old Pilot listed? Remove it with − first.")
                    Spacer(minLength: 8)
                    if granted {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(style.color(\.accent)).accessibilityLabel("Allowed")
                    } else {
                        SetupButton(title: model.accessAsked ? "Open again" : "Allow", primary: !model.accessAsked) { model.allowAccessibility() }
                    }
                }
                HStack(spacing: 8) {
                    step("1 · Settings open", "beside this window", done: open, live: !open && model.accessAsked)
                    step("2 · Drag Pilot in", "or + and pick it", done: granted, live: open && !granted)
                    step("3 · Switch it on", "Pilot sees it at once", done: granted, live: false)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14).styleSurface(\.card)
            Text(OnboardingModel.laterLine).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ title: String, _ detail: String, done: Bool, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).styleText(\.small).foregroundStyle(style.color(done ? \.accent : live ? \.text : \.text3))
            Text(detail).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style.color(done ? \.accentLine : \.line2), lineWidth: 1))
    }
}

/// Try it's demo, done: one line for the whole tab in place of its prompts (Sven, 2026-11-19).
struct DemoDone: View {
    @Environment(\.style) private var style
    let line: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(style.color(\.accent)).accessibilityHidden(true)
            SetupTitled(title: "Demo done", detail: line)
        }
    }
}

/// What a Hyper key choice breaks, under its name in both styles: an alert icon and Onboarding.hyperBreaks' line (Sven's
/// critique, 2026-11-18).
struct HyperBreaks: View {
    @Environment(\.style) private var style
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(style.color(\.warn)).accessibilityLabel("Breaks")
            Text(text).styleText(\.caption).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Try it's panels in both styles, scrolling inside Set up's height, so More opening never grows the window past the
/// screen (a tester's grew too tall to reach Finish, 2026-11-18); opening More scrolls to it, tagged `OnboardingModel.moreID`.
struct TryItScroll<Content: View>: View {
    let showsMore: Bool
    @ViewBuilder let content: Content

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView { content }
                .onChange(of: showsMore) { if showsMore { withAnimation { scroll.scrollTo(OnboardingModel.moreID, anchor: .top) } } }
        }
        .frame(maxHeight: OnboardingView.scrollHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Try it's "More, if you want", folded: only the extras that matter on day one, the AI provider and Extensions (Sven's
/// critique, 2026-11-18). The rest live where they are used: Recommend apps on Install's search, the upscaler's Max
/// quality in Upscale's Model, Pilot's terminal downloading on Hyper+T's first press, the other permissions in Allow the
/// rest just above and Settings › Permissions. Never needed for Finish.
struct OnboardingMore: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line {
                VStack(alignment: .leading, spacing: 8) {
                    SetupTitled(title: AIProviderPick.title, detail: AIProviderPick.detail)
                    AIProviderPick()
                }
            }
            InstrumentRule()
            line {
                SetupTitled(title: "Extensions", detail: OnboardingExtras.extensionsDetail)
                Spacer(minLength: 8)
                SetupButton(title: "Browse…") { OnboardingExtras.browseExtensions() }
            }
        }
    }

    private func line(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 14) { content() }.padding(.horizontal, 18).padding(.vertical, 10)
    }
}
