import PilotCore
import SwiftUI

/// The bind editor in Toybox, design A (spec bind-editor T6; Binds' sheet, drawn in `.page(.binds)`'s style): the same
/// state, search, plan and kind forms as Instrument's (InstrumentBindEditor, BindEditorSearch, BindEditorKinds), in
/// Toybox's parts. The keys as big keycaps (Hyper's the sun) on a card with Record and Choose key, one caption line, a
/// taken key's or a plain combo's warning on a coral-dotted well; then the one search in a keycap well, its kinds while it
/// is empty, its rows under their eyebrows with scope chips once typed, the lit row on a sun keycap; a pick folds the list
/// to one card, a keyed action's move warned under it; the foot's sentence, then Cancel and the sun's Save. No popup
/// menus; 560 pt wide, at most the window's height less 60. The kind forms are BindEditorKinds' own. Suggest with AI
/// (spec ai-binds T3) spins on its row while it asks, and its card says it came from the AI.
/// Drawn in BindEditor's own body, so its state redraws it as it does Instrument's sheet.
extension BindEditor {
    var toybox: some View {
        let plan = plan
        let stage = stage
        // One search per draw: the list, its chips and the foot's "↵ picks" all read it.
        let store = engine.binds.store
        let listing: (lines: [BindFinder.Line], chips: [BindFinder.Chip]) = stage == .list ? finder.listing { store.trigger(for: $0) } : ([], [])
        return VStack(alignment: .leading, spacing: 14) {
            if let mouse { toyMouseStrip(mouse, plan: plan) } else { toyStrip(plan) }
            Group {
                switch stage {
                case .list: toySearch(listing.lines, chips: listing.chips)
                case .form(let kind): kindForm(kind)
                case .card: toyCard(plan)
                }
            }
            toyFoot(plan, stage: stage, lines: listing.lines)
        }
        .font(style.toyNunito(700, 13.5))
        .foregroundStyle(style.color(\.text))
        .tint(style.color(\.accentText))
        .padding(22)
        .frame(width: 560, alignment: .leading)
        .frame(maxHeight: windowHeight - 60, alignment: .top)
        .background(style.color(\.canvas))
        .background {
            // Esc stages (Record, the search, the token, then Cancel); Cmd+Return saves from anywhere.
            Group {
                Button("", action: escape).keyboardShortcut(.cancelAction)
                Button("") { key.map(save) }.keyboardShortcut(.return, modifiers: .command).disabled(!plan.enabled)
            }
            .accessibilityHidden(true)
        }
        .onChange(of: finder.query) { finder.highlighted = 0 }
        // Cancel or Save while the AI is asked stops it, its child with it.
        .onDisappear { finder.stopAsking() }
        // After the body's onAppear has read the apps and the bind: the search's sources, then Record or the search.
        .task { open() }
    }

    // MARK: the trigger strip

    private func toyStrip(_ plan: BindPlan) -> some View {
        ToyBlock(title: nil, trailing: { EmptyView() }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button { choosingKey = true } label: { toyCaps }.buttonStyle(.plain).help("Choose key")
                    Spacer(minLength: 8)
                    Button(recording ? "Stop" : "Record") { recording ? escape() : record() }.buttonStyle(.pilot)
                    Button("Choose key") { choosingKey = true }.buttonStyle(.pilot)
                        .popover(isPresented: $choosingKey, arrowEdge: .bottom) { toyKeyChooser }
                }
                Text(keyCaption(plan)).font(style.toyNunito(700, 12.5)).foregroundStyle(style.color(\.text3))
                    .fixedSize(horizontal: false, vertical: true)
                if let taken = plan.taken {
                    toyAttention(taken) { Button("Use another key") { record() }.buttonStyle(.pilot) }
                }
                if let plain, let warning = PlainComboShadow.warning(for: plain) { toyAttention(.init(lead: warning, rest: "")) }
            }
        }
    }

    /// A mouse button's strip: its name as a big keycap (Hyper's sun before it) and what it sends, Click or Hold on the
    /// right, the caption line, and Other button…'s note.
    private func toyMouseStrip(_ mouse: MouseTrigger, plan: BindPlan) -> some View {
        ToyBlock(title: nil, trailing: { EmptyView() }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if mouse.hyper { ToyKeycap(label: "Hyper", hyper: true, large: true); Text("+").foregroundStyle(style.color(\.text3)) }
                    ToyKeycap(label: mouse.name, large: true)
                    if let detail = mouse.detail { Text("· \(detail)").font(style.toyNunito(700, 12.5)).foregroundStyle(style.color(\.text3)) }
                    Spacer(minLength: 8)
                    if mouse.holds {
                        ForEach([false, true], id: \.self) { hold in
                            Button(hold ? "Hold" : "Click") { pickTrigger(hold: hold) }.buttonStyle(mouseHolds == hold ? .pilotPrimary : .pilot)
                        }
                    }
                }
                Text(keyCaption(plan)).font(style.toyNunito(700, 12.5)).foregroundStyle(style.color(\.text3))
                    .fixedSize(horizontal: false, vertical: true)
                if let note = mouse.note { toyAttention(.init(lead: note, rest: "")) }
            }
        }
    }

    /// The keys as big caps, Hyper's the sun; "press a key" while Record listens, a dash cap while none is picked.
    private var toyCaps: some View {
        Group {
            if recording { ToyKeycap(label: "press a key", large: true) } else if let key { ToyBind(key: key, large: true) } else { ToyKeycap(label: "—", large: true) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recording ? "Listening for keys" : key?.label ?? "No keys")
    }

    /// Choose key: the Hyper layers, then the keys, for keys Record cannot catch. A plain combo is recorded.
    private var toyKeyChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToySegments(selection: $sublayer, options: BindsPage.Sublayer.allCases.map { ($0, $0 == .hyper ? "Hyper" : BindsPage.Tab.layer($0).shortTitle) },
                        label: "Layer")
            Text("A plain combo needs its own keys held: Record it.").font(style.toyNunito(700, 12.5)).foregroundStyle(style.color(\.text3))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                    ForEach(BindEditor.keys, id: \.key) { k in
                        Button(k.value) { choose(key: k.key, layer: sublayer) }
                            .buttonStyle(keyCode == k.key && plain == nil ? .pilotPrimary : .pilot)
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(14).frame(width: 440)
        .background(style.color(\.canvas))
    }

    // MARK: the search

    private func toySearch(_ lines: [BindFinder.Line], chips: [BindFinder.Chip]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            toySearchField(lines)
            if !chips.isEmpty { toyChips(chips) }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                            if let heading = line.heading {
                                ToyEyebrow(text: heading).padding(.top, i == 0 ? 2 : 10).padding(.bottom, 4).padding(.leading, 6)
                            }
                            toyLine(line, lit: i == finder.highlighted).id(line.id)
                        }
                        if lines.isEmpty {
                            Text(finder.scope == .menu ? "No app matches." : "Nothing matches.").font(style.toyNunito(700, 12.5))
                                .foregroundStyle(style.color(\.text3)).padding(.top, 4)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                // Its rows for the window; it gives up to two rows' height when a warning above needs the room.
                .frame(minHeight: Self.toyRowHeight * 2, idealHeight: toyListHeight, maxHeight: toyListHeight)
                .onChange(of: finder.highlighted) { _, i in if lines.indices.contains(i) { scroll.scrollTo(lines[i].id) } }
            }
        }
    }

    /// A row with its sun keycap's room.
    private static let toyRowHeight: CGFloat = 42

    private var toyListHeight: CGFloat { CGFloat(Self.listRows(windowHeight: windowHeight)) * Self.toyRowHeight + 24 }

    private func toySearchField(_ lines: [BindFinder.Line]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .bold)).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
            if let kind = finder.scope {
                Button { scope(nil) } label: {
                    HStack(spacing: 4) { Text(kind.title); Image(systemName: "xmark").font(.system(size: 9, weight: .heavy)) }
                }
                .buttonStyle(.pilot).help("Search everything")
            }
            TextField("Search", text: $finder.query, prompt: Text(toySearchPrompt).foregroundStyle(style.color(\.text3)))
                .textFieldStyle(.plain).font(style.toyNunito(700, 14)).focused($searchFocused)
                .onSubmit { if lines.indices.contains(finder.highlighted) { choose(lines[finder.highlighted].pick) } }
                .onKeyPress(.downArrow) { finder.highlighted = min(finder.highlighted + 1, max(lines.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { finder.highlighted = max(finder.highlighted - 1, 0); return .handled }
        }
        .padding(.horizontal, 12).frame(height: 38)
        .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
        .background(Toy.block(style, fill: style.color(\.panel), radius: style.radii.control, edge: 4))
    }

    private var toySearchPrompt: String {
        if finder.scope == .menu { return "Which app's menu?" }
        return "What should \(triggerName ?? "it") do? An app, an action, a URL, a command"
    }

    /// The scope chips, All picked (they show only while nothing is scoped), each with its count.
    private func toyChips(_ chips: [BindFinder.Chip]) -> some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                ToyChip(on: chip.kind == nil, pick: { if let kind = chip.kind { scope(kind) } }) {
                    HStack(spacing: 5) {
                        Text(chip.title)
                        if let count = chip.count { Text("\(count)").opacity(0.6) }
                    }
                    .font(style.toyNunito(800, 13))
                }
            }
        }
    }

    private func toyLine(_ line: BindFinder.Line, lit: Bool) -> some View {
        let dim = style.color(lit ? \.onAccent : \.text3)
        return HStack(spacing: 10) {
            if line.busy { ProgressView().controlSize(.small).tint(dim).frame(width: 24, height: 24) } else { toyIcon(line.pick) }
            Text(line.title).font(style.toyNunito(800, 13.5)).lineLimit(1).layoutPriority(1)
            Text(line.detail).font(style.toyNunito(700, 12.5)).foregroundStyle(dim).lineLimit(1)
            Spacer(minLength: 8)
            if let count = line.count { Text(count).font(style.toyNunito(700, 12.5)).foregroundStyle(dim) }
            if case .row(let row) = line.pick, let key = row.key { ToyBind(key: key, small: true) }
            if lit { Image(systemName: "return").font(.system(size: 11, weight: .bold)).accessibilityHidden(true) }
        }
        .foregroundStyle(style.color(lit ? \.onAccent : \.text))
        .padding(.horizontal, 10).frame(height: Self.toyRowHeight - 6)
        .toySunRow(lit, radius: 12, style: style)
        .contentShape(.rect)
        .onTapGesture { choose(line.pick) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func toyIcon(_ pick: BindFinder.Pick) -> some View {
        switch pick {
        case .kinds(let kinds): glyph(Self.symbol(kinds.count > 1 ? nil : kinds.first))
        case .row(let row):
            if let bundle = row.bundle { AppIcon(name: row.title, bundle: bundle, size: 24) } else { glyph(Self.symbol(row.id)) }
        }
    }

    // MARK: the picked card

    private func toyCard(_ plan: BindPlan) -> some View {
        let id = target ?? ""
        let name = plan.name ?? id
        return VStack(alignment: .leading, spacing: 12) {
            ToyBlock(title: nil, trailing: { EmptyView() }) {
                HStack(spacing: 14) {
                    if let bundle = Self.bundle(of: id) { AppIcon(name: name, bundle: bundle, size: 36) } else { glyph(Self.symbol(id), size: 36) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(style.toyFredoka(19)).lineLimit(1)
                        Text(Abilities.what(id, label: name)).font(style.toyNunito(700, 12.5)).foregroundStyle(style.color(\.text2)).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button("Change") { change() }.buttonStyle(.pilot)
                }
            }
            if let moving = plan.moving { toyAttention(moving) }
            if finder.suggested {
                Label("Suggested by AI · check it, then Save", systemImage: "sparkles").font(style.toyNunito(700, 12.5))
                    .foregroundStyle(style.color(\.text3))
            }
            if mouse == nil, engine.settings.overlayMode == .pick {
                HStack {
                    Text("List it in the Hold-Hyper overlay").foregroundStyle(style.color(\.text2))
                    Spacer(minLength: 8)
                    Toggle("List it in the Hold-Hyper overlay", isOn: $inOverlay).labelsHidden().toggleStyle(.pilotSwitch)
                }
            }
        }
    }

    /// A conflict where it happens: a coral dot, the bold lead, the rest, an optional way out, on a sunk well.
    private func toyAttention(_ warning: BindPlan.Warning, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ToyDot(color: style.color(\.problem))
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Text(warning.lead).font(style.toyNunito(800, 13)).foregroundStyle(style.color(\.text)))\(warning.rest.isEmpty ? "" : " " + warning.rest)")
                    .font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                action()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .toyWell(radius: 14)
    }

    // MARK: the foot

    private func toyFoot(_ plan: BindPlan, stage: Stage, lines: [BindFinder.Line]) -> some View {
        HStack(spacing: 10) {
            if let removal {
                Button(removal.title, action: removal.run).buttonStyle(PilotButtonStyle(destructive: true, ghost: true))
                    // In the search or a form's field Cmd+Delete deletes to the line's start; it removes the key only outside them.
                    .keyboardShortcut(searchFocused || formField != nil ? nil : KeyboardShortcut(.delete, modifiers: .command))
                if let action, engine.binds.store.isCustom(action) {
                    Button("Reset") { reset() }.buttonStyle(PilotButtonStyle(ghost: true))
                }
            }
            if let refusal {
                toyFootNote(Text(refusal))
            } else if removal == nil {
                toySentence(plan, lines: stage == .list && !finder.query.isEmpty ? lines : [])
            }
            Spacer(minLength: 8)
            Button("Cancel") { dismiss() }.buttonStyle(.pilot)
            Button(plan.verb.rawValue) { key.map(save) }.buttonStyle(.pilotPrimary).disabled(!plan.enabled)
                // While a list shows, Return picks its row, and in the shell's command it starts a line; else it saves.
                .keyboardShortcut(returnSaves(stage) ? .defaultAction : nil)
        }
        .padding(.top, 2)
    }

    /// The foot's sentence: what Save does, its keys and pick in the ink, a freed key in coral; while a typed search lists
    /// rows, what Return picks.
    private func toySentence(_ plan: BindPlan, lines: [BindFinder.Line]) -> some View {
        let ink = style.color(\.text)
        if lines.indices.contains(finder.highlighted) {
            return toyFootNote(Text("↵ picks \(Text(lines[finder.highlighted].title).foregroundStyle(ink)). ↑↓ moves."))
        }
        guard let keys = plan.keys, let name = plan.name else { return toyFootNote(Text(plan.sentence)) }
        let holder = plan.holder.map { ", not \($0)" } ?? ""
        let freed = plan.freed.map { Text(" \($0) goes free.").foregroundStyle(style.color(\.problem)) } ?? Text("")
        return toyFootNote(Text("\(Text(keys).foregroundStyle(ink)) \(plan.opens ? "opens" : "runs") \(Text(name).foregroundStyle(ink))\(holder).\(freed)"))
    }

    private func toyFootNote(_ text: Text) -> some View {
        text.font(style.toyNunito(700, 12.5)).foregroundStyle(style.color(\.text2)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
}
