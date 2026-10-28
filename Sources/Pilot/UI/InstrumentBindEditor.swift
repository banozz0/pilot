import PilotCore
import SwiftUI

/// The bind editor in Instrument, design A (spec bind-editor, Sven 2026-10-12; Binds' sheet, drawn in `.page(.binds)`'s
/// style): the trigger strip (the keys as big caps, Hyper's in the signal colour, Record and Choose key, one caption line,
/// a taken key's or a plain combo's warning); then one search over everything a key can run, its kinds listed while it is
/// empty, its rows under their groups with scope chips once typed; a pick folds the list to one card, an already keyed
/// action's move warned under it; the foot says in one sentence what Save does, or why it is off. Solid, no glass, no
/// popup menus; 560 pt wide, at most the window's height less 60, the list scrolling in a fixed area.
/// Drawn in BindEditor's own body, so its state redraws it as it does Toybox's sheet.
extension BindEditor {
    var instrument: some View {
        let plan = plan
        let stage = stage
        // One search per draw: the list, its chips and the foot's "↵ picks" all read it.
        let store = engine.binds.store
        let listing: (lines: [BindFinder.Line], chips: [BindFinder.Chip]) = stage == .list ? finder.listing { store.trigger(for: $0) } : ([], [])
        return VStack(alignment: .leading, spacing: 0) {
            if let mouse { mouseStrip(mouse, plan: plan) } else { instrumentStrip(plan) }
            InstrumentRule()
            Group {
                switch stage {
                case .list: instrumentSearch(listing.lines, chips: listing.chips)
                case .form(let kind): kindForm(kind)
                case .card: instrumentCard(plan)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            InstrumentRule()
            instrumentFoot(plan, stage: stage, lines: listing.lines)
        }
        .styleText(\.body)
        .foregroundStyle(style.color(\.text))
        .tint(style.color(\.accent))
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
    }

    // MARK: the trigger strip

    private func instrumentStrip(_ plan: BindPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Button { choosingKey = true } label: { caps }.buttonStyle(.plain).help("Choose key")
                Spacer(minLength: 8)
                Button { recording ? escape() : record() } label: {
                    if recording { HStack(spacing: 7) { Text("Stop"); InstrumentKey(text: "esc") } } else { Label("Record", systemImage: "circle.fill").labelStyle(RecordLabel()) }
                }
                .buttonStyle(InstrumentButtonStyle(kind: recording ? .raised : .ghost))
                Button("Choose key") { choosingKey = true }.buttonStyle(InstrumentButtonStyle(kind: .ghost))
                    .popover(isPresented: $choosingKey, arrowEdge: .bottom) { keyChooser }
            }
            Text(keyCaption(plan)).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
            // The Where row (per-app binds, parked) goes here as the strip's third line; the height budget holds its 28 pt.
            if let taken = plan.taken {
                attention(taken) { Button("Use another key") { record() }.buttonStyle(InstrumentButtonStyle(kind: .raised)) }
            }
            if let plain, let warning = PlainComboShadow.warning(for: plain) { attention(.init(lead: warning, rest: "")) }
        }
        .padding(22)
    }

    /// A mouse button's strip: its name as a big cap (Hyper's before it) and what it sends, Click or Hold on the right,
    /// the caption line, and Other button…'s note.
    private func mouseStrip(_ mouse: MouseTrigger, plan: BindPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                if mouse.hyper {
                    bigCap("\(engine.settings.layerKeys.symbol) Hyper", lit: true)
                    Text("+").styleText(\.caption).foregroundStyle(style.color(\.text3))
                }
                bigCap(mouse.name, lit: false)
                if let detail = mouse.detail { Text("· \(detail)").styleText(\.caption).foregroundStyle(style.color(\.text3)) }
                Spacer(minLength: 8)
                if mouse.holds {
                    ForEach([false, true], id: \.self) { hold in
                        Button(hold ? "Hold" : "Click") { pickTrigger(hold: hold) }
                            .buttonStyle(InstrumentButtonStyle(kind: mouseHolds == hold ? .raised : .ghost))
                            .accessibilityAddTraits(mouseHolds == hold ? .isSelected : [])
                    }
                }
            }
            .accessibilityElement(children: .contain)
            Text(keyCaption(plan)).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
            if let note = mouse.note { attention(.init(lead: note, rest: "")) }
        }
        .padding(22)
    }

    /// The keys as big caps joined by "+": the layer key's filled in the signal colour; "press a key" while Record listens.
    private var caps: some View {
        HStack(spacing: 8) {
            if recording {
                bigCap("press a key", lit: false, listening: true)
            } else if let key {
                let parts = key.hyper ? ["\(engine.settings.layerKeys.symbol) Hyper"] + HomeKeys.caps(key, space: "Space")
                    : key.label.components(separatedBy: "+")
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    if i > 0 { Text("+").styleText(\.caption).foregroundStyle(style.color(\.text3)) }
                    bigCap(part, lit: key.hyper && i == 0)
                }
            } else {
                bigCap("—", lit: false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recording ? "Listening for keys" : key?.label ?? "No keys")
    }

    private func bigCap(_ text: String, lit: Bool, listening: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.key, style: .continuous)
        return Text(text).font(.system(size: 16, weight: .medium, design: .monospaced)).lineLimit(1).fixedSize()
            .foregroundStyle(style.color(lit ? \.onHyper : listening ? \.accent : \.text))
            .padding(.horizontal, 14).frame(minWidth: 40, minHeight: 40)
            .background(style.color(lit ? \.hyper : listening ? \.canvas : \.raised), in: shape)
            .overlay { shape.strokeBorder(style.color(lit ? \.accentLine : listening ? \.accent : \.line2), lineWidth: listening ? 1.5 : 1) }
    }

    /// Choose key: the Hyper layers, then the keys, for keys Record cannot catch. A plain combo is recorded.
    private var keyChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(BindsPage.Sublayer.allCases, id: \.self) { layer in
                    Button(layer == .hyper ? "Hyper" : BindsPage.Tab.layer(layer).shortTitle) { sublayer = layer; plain = nil }
                        .buttonStyle(InstrumentButtonStyle(kind: sublayer == layer && plain == nil ? .primary : .raised))
                }
            }
            Text("A plain combo needs its own keys held: Record it.").styleText(\.caption).foregroundStyle(style.color(\.text3))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                    ForEach(BindEditor.keys, id: \.key) { k in
                        Button(k.value) { choose(key: k.key, layer: sublayer) }
                            .buttonStyle(InstrumentButtonStyle(kind: keyCode == k.key && plain == nil ? .primary : .raised))
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(14).frame(width: 420)
        .background(style.color(\.canvas))
    }

    // MARK: the search

    private func instrumentSearch(_ lines: [BindFinder.Line], chips: [BindFinder.Chip]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField(lines)
            if !chips.isEmpty { chipRow(chips) }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                            if let heading = line.heading {
                                Text(heading).styleText(\.eyebrow).foregroundStyle(style.color(\.text3))
                                    .padding(.top, i == 0 ? 2 : 10).padding(.bottom, 4).padding(.leading, 4)
                            }
                            lineRow(line, lit: i == finder.highlighted).id(line.id)
                        }
                        if lines.isEmpty {
                            Text(finder.scope == .menu ? "No app matches." : "Nothing matches.").styleText(\.caption)
                                .foregroundStyle(style.color(\.text3)).padding(.top, 4)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                // Its rows for the window; it gives up to two rows' height when a warning above needs the room.
                .frame(minHeight: Self.rowHeight * 2, idealHeight: listHeight, maxHeight: listHeight)
                .onChange(of: finder.highlighted) { _, i in if lines.indices.contains(i) { scroll.scrollTo(lines[i].id) } }
            }
        }
    }

    static let rowHeight: CGFloat = 36

    /// The rows for the window under the first group's heading.
    private var listHeight: CGFloat { CGFloat(Self.listRows(windowHeight: windowHeight)) * Self.rowHeight + 24 }

    private func searchField(_ lines: [BindFinder.Line]) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
            if let kind = finder.scope {
                Button { scope(nil) } label: {
                    HStack(spacing: 4) { Text(kind.title); Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                }
                .buttonStyle(InstrumentButtonStyle(kind: .raised)).help("Search everything")
            }
            TextField("Search", text: $finder.query, prompt: Text(searchPrompt).foregroundStyle(style.color(\.text3)))
                .textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { if lines.indices.contains(finder.highlighted) { choose(lines[finder.highlighted].pick) } }
                .onKeyPress(.downArrow) { finder.highlighted = min(finder.highlighted + 1, max(lines.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { finder.highlighted = max(finder.highlighted - 1, 0); return .handled }
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(style.color(\.sunken), in: shape)
        .overlay { shape.strokeBorder(style.color(searchFocused ? \.accent : \.line2), lineWidth: searchFocused ? 1.5 : 1) }
    }

    private var searchPrompt: String {
        if finder.scope == .menu { return "Which app's menu?" }
        return "What should \(triggerName ?? "it") do? An app, an action, a URL, a command"
    }

    private func chipRow(_ chips: [BindFinder.Chip]) -> some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                Button { if let kind = chip.kind { scope(kind) } } label: {
                    HStack(spacing: 5) {
                        Text(chip.title)
                        if let count = chip.count { Text("\(count)").foregroundStyle(style.color(\.text3)) }
                    }
                }
                .buttonStyle(InstrumentButtonStyle(kind: chip.kind == nil ? .primary : .raised))
            }
        }
    }

    private func lineRow(_ line: BindFinder.Line, lit: Bool) -> some View {
        HStack(spacing: 10) {
            if line.busy { ProgressView().controlSize(.small).frame(width: 24, height: 24) } else { lineIcon(line.pick) }
            Text(line.title).lineLimit(1).layoutPriority(1)
            Text(line.detail).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1)
            Spacer(minLength: 8)
            if let count = line.count { Text(count).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
            if case .row(let row) = line.pick, let key = row.key { InstrumentKeys(trigger: key) }
            if lit { Image(systemName: "return").font(.system(size: 11)).foregroundStyle(style.color(\.accent)).accessibilityHidden(true) }
        }
        .padding(.horizontal, 10).frame(height: Self.rowHeight)
        .background { if lit { RoundedRectangle(cornerRadius: style.radii.control).fill(style.color(\.accentSoft)) } }
        .overlay(alignment: .leading) { if lit { Capsule().fill(style.color(\.accent)).frame(width: 2, height: 20) } }
        .contentShape(.rect)
        .onTapGesture { choose(line.pick) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func lineIcon(_ pick: BindFinder.Pick) -> some View {
        switch pick {
        case .kinds(let kinds): glyph(Self.symbol(kinds.count > 1 ? nil : kinds.first))
        case .row(let row):
            if let bundle = row.bundle { AppIcon(name: row.title, bundle: bundle, size: 24) } else { glyph(Self.symbol(row.id)) }
        }
    }

    func glyph(_ symbol: String, size: CGFloat = 24) -> some View {
        Image(systemName: symbol).font(.system(size: size * 0.5)).foregroundStyle(style.color(\.text2))
            .frame(width: size, height: size)
            .background(style.color(\.raised), in: .rect(cornerRadius: size * 0.25))
            .overlay { RoundedRectangle(cornerRadius: size * 0.25).strokeBorder(style.color(\.line2)) }
            .accessibilityHidden(true)
    }

    /// A kind's glyph; More's an ellipsis.
    static func symbol(_ kind: BindSearch.Kind?) -> String {
        switch kind {
        case .app?: "macwindow"
        case .action?: "sparkles"
        case .web?, .appURL?: "globe"
        case .shell?: "apple.terminal"
        case .menu?: "filemenu.and.selection"
        case .keys?: "keyboard"
        case .shortcut?: "square.2.layers.3d"
        case .picker?: "list.bullet"
        case nil: "ellipsis"
        }
    }

    /// An action's glyph where it wears no app's icon: the menu's, else its kind's.
    static func symbol(_ id: String) -> String {
        if let symbol = MenuEntry.actionSymbol(id) { return symbol }
        switch DriveRoute(id: id) {
        case .shell?: return "apple.terminal"
        case .url?: return "globe"
        case .keystroke?: return "keyboard"
        case .shortcut?: return "square.2.layers.3d"
        case .picker?: return "list.bullet"
        case .menu?: return "filemenu.and.selection"
        case nil: return AppLink(id: id) == nil ? "sparkles" : "globe"
        }
    }

    // MARK: the picked card

    private func instrumentCard(_ plan: BindPlan) -> some View {
        let id = target ?? ""
        let name = plan.name ?? id
        let shape = RoundedRectangle(cornerRadius: style.radii.card, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                if let bundle = Self.bundle(of: id) { AppIcon(name: name, bundle: bundle, size: 34) } else { glyph(Self.symbol(id), size: 34) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).styleText(\.strong).lineLimit(1)
                    Text(Abilities.what(id, label: name)).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Change") { change() }.buttonStyle(InstrumentButtonStyle(kind: .ghost))
            }
            .padding(14)
            .background(style.color(\.panel), in: shape)
            .overlay { shape.strokeBorder(style.color(\.line2)) }
            if let moving = plan.moving { attention(moving) }
            if finder.suggested { suggestedCaption }
            if mouse == nil, engine.settings.overlayMode == .pick {
                Toggle("List it in the Hold-Hyper overlay", isOn: $inOverlay).toggleStyle(.checkbox).foregroundStyle(style.color(\.text2))
            }
        }
    }

    /// A conflict where it happens: the signal's triangle, the bold lead, the rest, an optional way out.
    private func attention(_ warning: BindPlan.Warning, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.card, style: .continuous)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(style.color(\.accent)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Text(warning.lead).fontWeight(.semibold).foregroundStyle(style.color(\.text)))\(warning.rest.isEmpty ? "" : " " + warning.rest)")
                    .foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                action()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(style.color(\.accentSoft), in: shape)
        .overlay { shape.strokeBorder(style.color(\.accentLine)) }
    }

    // MARK: the foot

    private func instrumentFoot(_ plan: BindPlan, stage: Stage, lines: [BindFinder.Line]) -> some View {
        HStack(spacing: 8) {
            if let removal {
                Button { removal.run() } label: { HStack(spacing: 7) { Label(removal.title, systemImage: "xmark"); InstrumentKey(text: "⌘⌫") } }
                    .buttonStyle(InstrumentButtonStyle(kind: .ghost))
                    // In the search or a form's field Cmd+Delete deletes to the line's start; it removes the key only outside them.
                    .keyboardShortcut(searchFocused || formField != nil ? nil : KeyboardShortcut(.delete, modifiers: .command))
                if let action, engine.binds.store.isCustom(action) {
                    Button { reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }.buttonStyle(InstrumentButtonStyle(kind: .ghost))
                }
                if let refusal { Text(refusal).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(2) }
            } else if let refusal {
                Text(refusal).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(2)
            } else {
                footSentence(plan, lines: stage == .list && !finder.query.isEmpty ? lines : [])
            }
            Spacer(minLength: 8)
            Button { dismiss() } label: { HStack(spacing: 7) { Text("Cancel"); InstrumentKey(text: "esc") } }.buttonStyle(InstrumentButtonStyle(kind: .raised))
            Button { key.map(save) } label: { HStack(spacing: 7) { Text(plan.verb.rawValue); InstrumentKey(text: "↵") } }
                .buttonStyle(InstrumentButtonStyle(kind: .primary)).disabled(!plan.enabled)
                // While a list shows, Return picks its row, and in the shell's command it starts a line; else it saves.
                .keyboardShortcut(returnSaves(stage) ? .defaultAction : nil)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    /// The foot's sentence: what Save does, its keys and pick in the strong face, a freed key in the signal colour; while a
    /// typed search lists rows, what Return picks.
    @ViewBuilder private func footSentence(_ plan: BindPlan, lines: [BindFinder.Line]) -> some View {
        Group {
            if lines.indices.contains(finder.highlighted) {
                Text("↵ picks \(Text(lines[finder.highlighted].title).foregroundStyle(style.color(\.text))). ↑↓ moves.")
            } else if let keys = plan.keys, let name = plan.name {
                let holder = plan.holder.map { ", not \($0)" } ?? ""
                let freed = plan.freed.map { Text(" \($0) goes free.").foregroundStyle(style.color(\.accent)) } ?? Text("")
                Text("\(Text(keys).foregroundStyle(style.color(\.text))) \(plan.opens ? "opens" : "runs") \(Text(name).foregroundStyle(style.color(\.text)))\(holder).\(freed)")
            } else {
                Text(plan.sentence)
            }
        }
        .styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }

}

/// Record's dot before its word.
private struct RecordLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.icon.font(.system(size: 6)); configuration.title }
    }
}
