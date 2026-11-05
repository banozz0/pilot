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
                    Text("\(s.number)").styleText(\.mono).foregroundStyle(style.color(\.canvas))
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
                 about: "Choose each helper, key and file kind. Nothing changes until you confirm.") {
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

// MARK: Pick by hand

/// Pick by hand: the same groups as ticked rows, each with what it gives, nothing ticked at first; what is on this Mac
/// says so instead of a switch.
struct SetupPickList: View {
    @Environment(\.style) private var style
    let setup: OnboardingSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(SetupGroup.allCases, id: \.self) { group in
                VStack(alignment: .leading, spacing: 0) {
                    groupHeading(group)
                    ForEach(group.items, id: \.self) { item in
                        InstrumentRule()
                        HStack(spacing: 14) {
                            SetupTitled(title: item.title, detail: item.detail)
                            Spacer(minLength: 8)
                            if setup.onMac.contains(item) {
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

/// Try it's "More, if you want", folded: the AI provider, Extensions, Recommend apps, the upscaler's Max quality, and
/// the other permissions, which live in Settings › Permissions. Never needed for Finish.
struct OnboardingMore: View {
    @Environment(\.style) private var style
    @State private var recommend = Recommendations.shared.show

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
            InstrumentRule()
            line {
                SetupTitled(title: "Recommend apps", detail: OnboardingExtras.recommendDetail)
                Spacer(minLength: 8)
                Toggle("Recommend apps", isOn: Binding(get: { recommend }, set: { recommend = $0; OnboardingExtras.recommend($0) }))
                    .labelsHidden().toggleStyle(.pilotSwitch)
            }
            InstrumentRule()
            line {
                SetupTitled(title: OnboardingExtras.upscalerTitle, detail: OnboardingExtras.upscalerDetail)
                Spacer(minLength: 8)
                if let state = OnboardingExtras.upscalerState {
                    Text(state).styleText(\.mono).foregroundStyle(style.color(\.text2)).fixedSize()
                } else {
                    SetupButton(title: "Download") { OnboardingExtras.fetchUpscaler() }
                }
            }
            InstrumentRule()
            line {
                SetupTitled(title: "Other permissions", detail: "System Events, Full Disk Access, Microphone and the rest, each with its Allow")
                Spacer(minLength: 8)
                SetupButton(title: "Open Settings") { AppWindowController.shared.open(.permissions) }
            }
        }
    }

    private func line(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 14) { content() }.padding(.horizontal, 18).padding(.vertical, 10)
    }
}
