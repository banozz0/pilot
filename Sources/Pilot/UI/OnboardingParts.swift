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
    /// What it breaks, a risky Hyper choice's (Sven, 2026-11-19): a small alert icon after the title, the words only as
    /// the row's tooltip, which the row sets.
    var alert: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).styleText(\.strong).foregroundStyle(style.color(\.text))
                if let alert {
                    Image(systemName: "exclamationmark.triangle.fill").imageScale(.small).foregroundStyle(style.color(\.warn))
                        .accessibilityLabel(alert)
                }
            }
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
                }
            } button: {
                SetupButton(title: "Set up everything", primary: true, wide: true) { setup.start(setup.everything) }
                    .disabled(setup.everything.isEmpty)
            }
            card(eyebrow: "Your way", title: "Pick by hand",
                 about: "Choose each key, setting and feature. Nothing changes until you confirm.") {
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

/// Pick by hand: the same groups as ticked rows, each with what it gives, then the features and the helpers each needs
/// (SetupFeature), nothing ticked at first; what is on this Mac says so instead of a switch.
struct SetupPickList: View {
    @Environment(\.style) private var style
    let setup: OnboardingSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(SetupGroup.allCases.filter { !$0.offered.isEmpty }, id: \.self) { group in
                VStack(alignment: .leading, spacing: 0) {
                    groupHeading(group.title, symbol: group.symbol)
                    ForEach(group.offered, id: \.self) { item in
                        row(item.title, item.detail, held: setup.held(item),
                            isOn: Binding(get: { setup.picked.contains(item) }, set: { setup.set(item, $0) }))
                    }
                }
                .styleSurface(\.card)
            }
            // The features, each ticking the helpers it needs (Sven, 2026-11-19).
            VStack(alignment: .leading, spacing: 0) {
                groupHeading("Features", symbol: SetupGroup.helpers.symbol)
                ForEach(SetupFeature.allCases, id: \.self) { feature in
                    row(feature.title, setup.detail(feature), held: setup.held(feature),
                        isOn: Binding(get: { setup.picked(feature) }, set: { setup.set(feature, $0) }))
                }
            }
            .styleSurface(\.card)
        }
    }

    /// A row: its switch, or in its place what holds it, on this Mac or in the last run's record (never offered twice).
    private func row(_ title: String, _ detail: String, held: OnboardingSetup.Held?, isOn: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            InstrumentRule()
            HStack(spacing: 14) {
                SetupTitled(title: title, detail: detail)
                Spacer(minLength: 8)
                switch held {
                case .onMac?:
                    Text("On this Mac").styleText(\.mono).foregroundStyle(style.color(\.text2)).fixedSize()
                case .ran(let words)?:
                    Text(words).styleText(\.mono).foregroundStyle(style.color(\.text3)).lineLimit(2).frame(maxWidth: 200, alignment: .trailing)
                case nil:
                    Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.pilotSwitch)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
    }

    private func groupHeading(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
            Text(title).styleText(\.title).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
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

// MARK: Keys

/// Keys' three presets side by side (pilot-ui-redesign T13; Q264's Set up B, drawn in T9, widened to 780 by Q4): each
/// card names its preset, a few of its keys and how many more it has (Sven's one change to the drawing), then its count.
/// A card's press, or its number key, picks it; the pick is `setup.keys`, applied by Continue (T12). With no pick, the
/// active preset (Classic or the user's own) is kept.
struct KeysPresetCards: View {
    @Environment(\.style) private var style
    let setup: OnboardingSetup

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(Self.cards.enumerated()), id: \.element.preset) { index, card in
                let picked = setup.keys == card.preset
                Button { setup.keys = card.preset } label: { face(card, number: index + 1, picked: picked) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                    .accessibilityLabel("\(card.name), \(card.about) \(card.foot)")
                    .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func face(_ card: Card, number: Int, picked: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.card, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(number)").styleText(\.mono).foregroundStyle(style.color(picked ? \.canvas : \.text3))
                    .frame(width: 20, height: 20)
                    .background { if picked { RoundedRectangle(cornerRadius: style.radii.chip, style: .continuous).fill(style.color(\.accent)) } }
                    .overlay { if !picked { RoundedRectangle(cornerRadius: style.radii.chip, style: .continuous).strokeBorder(style.color(\.line2)) } }
                Text(card.name).styleText(\.title).foregroundStyle(style.color(\.text)).fixedSize().layoutPriority(1)
                if card.preset == .easy { Spacer(minLength: 4); InstrumentEyebrow(text: "Recommended") }
            }
            Text(card.about).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(card.lines, id: \.label) { line in
                    row { ForEach(line.caps, id: \.self) { PresetCap(text: $0, lit: picked) } } label: {
                        Text(line.label).styleText(\.body).foregroundStyle(style.color(\.text2))
                    }
                }
                if card.more > 0 {
                    row { PresetCap(text: "+\(card.more)", lit: picked, dashed: true) } label: {
                        Text("and \(card.more) more").styleText(\.body).foregroundStyle(style.color(\.text3))
                    }
                }
                if card.lines.isEmpty {
                    row { PresetCap(text: "?", lit: false, dashed: true) } label: {
                        Text("Your first key").styleText(\.body).foregroundStyle(style.color(\.text3))
                    }
                }
            }
            .padding(.top, 14)
            Spacer(minLength: 14)
            InstrumentRule()
            Text(card.foot).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .styleSurface(\.card)
        // The pick in the signal colour, its one meaning here: what is selected (DESIGN.md).
        .overlay { if picked { shape.strokeBorder(style.color(\.accentLine), lineWidth: 1.5) } }
        .contentShape(shape)
    }

    /// A key line: one column for every card's keys, so the words line up down the card.
    private func row(@ViewBuilder caps: () -> some View, @ViewBuilder label: () -> some View) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) { caps() }.frame(width: 62, alignment: .leading)
            label()
        }
    }

    /// A card: its preset, the line under its name, a few of its keys with the actions each covers, and its foot.
    struct Card {
        struct Line { let caps: [String], label: String, actions: [String] }
        let preset: Onboarding.Keys
        let name: String, about: String
        let lines: [Line]
        /// Every key the preset has, from its table (pilot-key-presets' rules: Easy 32, Complex 110, Scratch 0).
        let total: Int
        let foot: String
        /// "And N more": the preset's keys less the actions its lines cover (Easy 25, Complex 81).
        var more: Int { lines.isEmpty ? 0 : total - Set(lines.flatMap(\.actions)).count }
    }

    /// The three cards, as T9 drew them (pilot-key-presets.notes.md, "The rules").
    static let cards: [Card] = {
        let workspaces = Workspaces.all
        let easy = PilotDefault.easy.count, complex = PilotDefault.complex.count
        return [
            Card(preset: .easy, name: "Easy", about: "Letters you can guess.", lines: [
                Line(caps: ["Space"], label: "Pilot menu", actions: ["apps.launcher"]),
                Line(caps: ["B"], label: "Browser", actions: ["apps.browser"]),
                Line(caps: ["Return"], label: "Terminal", actions: ["apps.terminal"]),
                Line(caps: ["V"], label: "Clipboard history", actions: ["apps.clipboard"]),
                Line(caps: ["S"], label: "Capture area", actions: ["captures.area"]),
                Line(caps: ["←", "→"], label: "Focus a window", actions: ["windows.focusLeft", "windows.focusRight"]),
            ], total: easy, foot: "\(easy) keys, all in Complex too."),
            Card(preset: .complex, name: "Complex", about: "Easy, plus every window move.", lines: [
                Line(caps: ["⇧←↑↓→"], label: "Swap windows", actions: ["Up", "Down", "Left", "Right"].map { "windows.swap\($0)" }),
                Line(caps: ["⌃←↑↓→"], label: "Nudge a window", actions: ["Up", "Down", "Left", "Right"].map { "windows.nudge\($0)" }),
                Line(caps: ["1–9"], label: "Go to workspace", actions: workspaces.map { "workspaces.go:\($0)" }),
                Line(caps: ["⇧1–9"], label: "Send window", actions: workspaces.map { "workspaces.move:\($0)" }),
                Line(caps: ["[", "]"], label: "First ¾, last ¼", actions: ["windows.firstThreeQuarters", "windows.lastQuarter"]),
                Line(caps: ["Z"], label: "Capture scrolling", actions: ["captures.scrolling"]),
            ], total: complex, foot: "\(complex) keys. None for apps a Mac may lack."),
            Card(preset: .scratch, name: "Scratch", about: "No keys. Build your own.", lines: [], total: 0,
                 foot: "0 keys. The menu bar icon still opens Pilot."),
        ]
    }()
    private typealias Line = Card.Line

    // The step's words, the same in both looks.
    static let title = "Which keys should Pilot start with?"
    static func about(hyper: String) -> String { "Hyper is \(hyper). You can change any key later in Keys." }
    static let hint = "Press 1, 2 or 3"
    /// The primary button: the pick's words, or Keep my keys with no pick.
    static func button(_ pick: Onboarding.Keys?) -> String {
        switch pick {
        case .easy?: "Use Easy keys"
        case .complex?: "Use Complex keys"
        case .scratch?: "Start with no keys"
        case nil: "Keep my keys"
        }
    }
    /// The foot's note while the active preset is none of the three: what Keep keeps.
    static func keeping(_ name: String) -> String { "Keeping your preset, \(name). Press 1, 2 or 3 to switch." }
}

/// One key chip on a preset card: each key sign as its line icon (the mono face lacks them), the words between in the
/// key face; lit in the signal colour on the picked card, dashed for a count or an empty slot.
private struct PresetCap: View {
    @Environment(\.style) private var style
    let text: String
    let lit: Bool
    var dashed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.chip, style: .continuous)
        HStack(spacing: 1) {
            ForEach(Array(Self.runs(text).enumerated()), id: \.offset) { InstrumentLegend(text: $1) }
        }
        .foregroundStyle(style.color(lit ? \.accent : dashed ? \.text3 : \.text2))
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 5).frame(minWidth: style.points(19), minHeight: style.points(19))
        .background { if !dashed { shape.fill(style.color(\.raised)) } }
        .overlay {
            shape.strokeBorder(style.color(lit ? \.accentLine : \.line2), style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
        }
        .accessibilityLabel(text)
    }

    /// The text cut into its key signs and the words between them: "⇧1–9" is ⇧ then "1–9".
    static func runs(_ text: String) -> [String] {
        var runs: [String] = [], word = ""
        for c in text.map(String.init) {
            if InstrumentKey.symbols[c] != nil {
                if !word.isEmpty { runs.append(word); word = "" }
                runs.append(c)
            } else {
                word += c
            }
        }
        if !word.isEmpty { runs.append(word) }
        return runs
    }
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
                // Settings › Permissions has each but Screen Recording, which it shows only once Menu bar › Other apps asks
                // for it (ADR 0012).
                let pilot = walk.skipped.filter { $0 != .screenRecording }
                if !pilot.isEmpty {
                    Text("Skipped: \(pilot.map(GrantWalk.name).joined(separator: ", ")). Each is in \(AppPlace(.permissions).path).")
                        .styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                }
                if walk.skipped.contains(.screenRecording) {
                    Text("Screen Recording: \(AppPlace(.menuBar).path) › Other apps, or System Settings › Privacy & Security › Screen Recording.")
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
                                detail: granted ? "Pilot reads the Hyper key now." : PermissionDragPanel.List.line)
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
/// critique, 2026-11-18). The rest live where they are used: Pilot's terminal downloading on Hyper+T's first press, the
/// other permissions in Allow the rest just above and Settings › Permissions. Never needed for Finish.
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
