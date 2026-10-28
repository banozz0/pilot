import AppKit
import Observation
import PilotCore
import SwiftUI

// MARK: - Blocks

/// An extension's blocks (story 161, ADR 0010 amended), laid out by Pilot in the style picked through the Kit and the Ink:
/// stats side by side, a meter with its label and note, a list of rows (a click runs the first action, the ⋯ menu and a
/// right-click list them all), markdown, a row of buttons (the first primary); Surfaces v2 adds a section, a chat, an
/// input, a row's badges and inline buttons, and a run's ask, asked in its row or button row; omarchy-ideas T4 a hero (a big
/// now) and a strip (a row of days). `compact` is the bar item's popover: the same blocks, small, a list's rows plain lines,
/// a meter CodexBar's row ("Session 66% left", when it resets). On a page (`page`, 2026-10-17) a list with a reorder
/// drags its rows by their grips, ⌥↑ ⌥↓ moving the one whose grip has the focus, and a live input runs as Sven types.
struct ExtensionBlocksView: View {
    @Environment(\.ink) private var ink
    let blocks: [Extension.Block]
    var compact = false
    /// What a page hands its blocks: `change` runs a row's move and returns once the page shows the extension's answer;
    /// `typed` hands a live input's run on with its pause (nil: now). Nil in a popover, where rows never drag.
    struct PageHooks {
        let change: (Extension.Item.Action) async -> Void
        let typed: (Extension.Item.Action, Duration?) -> Void
    }
    var page: PageHooks?
    let act: (Extension.Item.Action) -> Void
    /// Where a run asks: its block, then its row (nil: the block's button row).
    private struct Slot: Equatable { let block: Int, row: Int? }
    /// The run asking now and where.
    @State private var asking: (slot: Slot, asking: Extension.Asking)?
    /// A list's rows as moved, by block, drawn until the page shows the extension's own answer to the move.
    @State private var moved: [Int: [Extension.Item]] = [:]
    /// The row a drag is over, by block, and the grip with the focus, by its row's id.
    @State private var dropping: Slot?
    @FocusState private var grip: String?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            ForEach(blocks.indices, id: \.self) { i in
                // Instrument's figures stand apart on hairlines, not on wells (Q475, the Omarchy weather look).
                if ink.isInstrument, i > 0, Self.ruled(blocks[i - 1], blocks[i]) { InstrumentRule().accessibilityHidden(true) }
                block(blocks[i], at: i)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A hairline between two blocks when either is a hero or a strip, or both are stats.
    static func ruled(_ above: Extension.Block, _ block: Extension.Block) -> Bool {
        func figures(_ b: Extension.Block) -> Bool { switch b { case .hero, .strip: true; default: false } }
        if case .stats = above, case .stats = block { return true }
        return figures(above) || figures(block)
    }

    @ViewBuilder private func block(_ block: Extension.Block, at index: Int) -> some View {
        switch block {
        case .stats(let stats): statsRow(stats)
        case .meter(let meter): meterView(meter)
        case .list(let title, let items, let reorder):
            list(title, moved[index] ?? items, reorder: compact ? nil : page.flatMap { page in reorder.map { ($0, page) } }, at: index)
        case .markdown(let text): BlockMarkdown(text: text, compact: compact).equatable()
        case .buttons(let actions):
            if let ask = ask(at: Slot(block: index, row: nil)) { ask }
            else {
                HStack(spacing: 8) {
                    ForEach(actions.indices, id: \.self) { i in
                        let run = { start(actions[i], at: Slot(block: index, row: nil)) }
                        if compact { Button(actions[i].label, action: run).barButton(primary: i == 0) }
                        else { Button(actions[i].label, action: run).buttonStyle(i == 0 ? .pilotPrimary : .pilot) }
                    }
                }
            }
        case .section(let title, let subtitle, let aside, let asideNote, let inner, let icon, let help):
            section(title, subtitle, aside, asideNote, inner, icon: icon, help: help)
        case .chat(let chat): ExtensionChatView(chat: chat, compact: compact)
        case .input(let input): ExtensionInputView(input: input, compact: compact, typed: input.live == nil ? nil : page?.typed, act: act)
        case .hero(let hero): heroView(hero)
        case .strip(let columns): stripView(columns)
        case .note(let note): noteView(note)
        case .links(let links):
            if let ask = ask(at: Slot(block: index, row: nil)) { ask }
            else { ExtensionLinksRow(links: links, compact: compact) { start($0, at: Slot(block: index, row: nil)) } }
        }
    }

    /// Runs `action` now, or asks first in place of its row when it has an ask.
    private func start(_ action: Extension.Item.Action, at slot: Slot) {
        if let asking = Extension.Asking(action) { self.asking = (slot, asking) }
        else { act(action) }
    }

    /// The ask showing at this row, if it is this one's.
    private func ask(at slot: Slot) -> ExtensionAskView? {
        guard let asking, asking.slot == slot else { return nil }
        return ExtensionAskView(asking: asking.asking, compact: compact) { answered in
            self.asking = nil
            answered.map(act)
        }
    }

    /// A section (Surfaces v2): its title and subtitle over its blocks, its aside and aside note at their right (CodexBar's
    /// account and plan), on a raised card; a page's a Tile, the asides its trailing. In a popover (Q138, design A) its head
    /// is one line: the provider's glyph, the title, the aside note as a chip, the aside at the right, its help on hover;
    /// a subtitle only when it has one (AI usage: a stale read). With no blocks it is one quiet line, no card.
    @ViewBuilder private func section(_ title: String?, _ subtitle: String?, _ aside: String?, _ asideNote: String?,
                                      _ inner: [Extension.Block], icon: Extension.Gauge.Icon?, help: String?) -> some View {
        let blocks = ExtensionBlocksView(blocks: inner, compact: compact, page: page, act: act)
        if compact && inner.isEmpty {
            HStack(spacing: 6) {
                if let icon { ProviderGlyph(icon: icon).fill(ink.muted).frame(width: 11, height: 11).accessibilityHidden(true) }
                if let title { Text(title).font(ink.ui(11.5, .medium)) }
                if let aside { Text(aside).truncationMode(.middle) }
                Spacer(minLength: 6)
                if let subtitle { Text(subtitle) }
                if help != nil { Image(systemName: "info.circle").font(.system(size: 10)).accessibilityHidden(true) }
            }
            .font(ink.ui(11)).foregroundStyle(ink.muted).lineLimit(1)
            .padding(.horizontal, 10)
            .help(help ?? "")
            .accessibilityElement(children: .combine)
            .accessibilityHint(help ?? "")
        } else if compact {
            VStack(alignment: .leading, spacing: 8) {
                if title != nil || subtitle != nil || aside != nil || asideNote != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .center, spacing: 6) {
                            if let icon { ProviderGlyph(icon: icon).fill(ink.text).frame(width: 12, height: 12).accessibilityHidden(true) }
                            if let title { Text(title).font(ink.ui(12.5, .semibold)).foregroundStyle(ink.text).layoutPriority(1) }
                            if let asideNote {
                                Text(asideNote).font(ink.ui(10, .medium)).foregroundStyle(ink.muted)
                                    .padding(.horizontal, 5).padding(.vertical, 1).overlay(Capsule().strokeBorder(ink.line2))
                            }
                            Spacer(minLength: 6)
                            if let aside { Text(aside).font(ink.ui(11)).foregroundStyle(ink.muted).truncationMode(.middle) }
                        }
                        if let subtitle { Text(subtitle).font(ink.ui(10.5)).foregroundStyle(ink.muted) }
                    }
                    .lineLimit(1)
                    .help(help ?? "")
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(help ?? "")
                }
                blocks
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background { if !ink.isInstrument { RoundedRectangle(cornerRadius: 9).fill(ink.well) } }
            .overlay { if ink.isInstrument { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(ink.line) } }
        } else {
            Tile(title: title, note: subtitle, trailing: {
                if aside != nil || asideNote != nil {
                    VStack(alignment: .trailing, spacing: 1) {
                        if let aside { Text(aside).font(ink.ui(12)) }
                        if let asideNote { Text(asideNote).font(ink.ui(11)) }
                    }
                    .fontWeight(.regular).foregroundStyle(ink.muted)
                    .help(help ?? "")
                }
            }) { blocks }
        }
    }

    /// A note (Q138): one small muted line, its icon, its text, its aside at the right, its help on hover.
    private func noteView(_ note: Extension.Block.Note) -> some View {
        HStack(spacing: 5) {
            if let symbol = note.icon.flatMap({ Extension.Item.Action.icons[$0] }) {
                Image(systemName: symbol).font(.system(size: compact ? 9.5 : 11, weight: .semibold)).accessibilityHidden(true)
            }
            Text(note.text)
            Spacer(minLength: 6)
            if let aside = note.aside { Text(aside) }
        }
        .font(ink.ui(compact ? 10.5 : 12)).foregroundStyle(ink.muted).lineLimit(1)
        .help(note.help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityHint(note.help ?? "")
    }

    private func colour(_ tone: Extension.Tone?, else plain: Color) -> Color { ink.tone(tone, else: plain) }

    @ViewBuilder private func statsRow(_ stats: [Extension.Block.Stat]) -> some View {
        if ink.isInstrument { instrumentStats(stats) } else { wellStats(stats) }
    }

    /// Instrument's stats (Q475): each label a mono eyebrow over its figure in the light mono, hairlines between them, no
    /// wells.
    private func instrumentStats(_ stats: [Extension.Block.Stat]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(stats.indices, id: \.self) { i in
                if i > 0 { InstrumentRule(vertical: true).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                    Text(stats[i].label).styleText(\.eyebrow).foregroundStyle(ink.muted).truncationMode(.tail)
                    Text(stats[i].value).font(ink.mono(compact ? 17 : 24, weight: .light)).monospacedDigit()
                        .foregroundStyle(colour(stats[i].tone, else: ink.text)).minimumScaleFactor(0.7)
                }
                .lineLimit(1)
                .padding(.leading, i == 0 ? 0 : compact ? 10 : 14).padding(.trailing, compact ? 6 : 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func wellStats(_ stats: [Extension.Block.Stat]) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            ForEach(stats.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stats[i].value).font(ink.mono(compact ? 14 : 20, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(colour(stats[i].tone, else: ink.text))
                    Text(stats[i].label).font(ink.ui(compact ? 10.5 : 11.5)).foregroundStyle(ink.muted).minimumScaleFactor(0.85)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, compact ? 8 : 12).padding(.vertical, compact ? 6 : 10)
                .background(ink.well, in: .rect(cornerRadius: compact ? 7 : 10))
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func heroView(_ hero: Extension.Block.Hero) -> some View {
        if ink.isInstrument { instrumentHero(hero) } else { toyHero(hero) }
    }

    /// Instrument's hero (Q475, the Omarchy weather look): a thin line glyph (or the emoji sent), the value in the light
    /// mono with its unit raised beside it, and at the right the place as a pinned eyebrow over its stats, each a mono
    /// eyebrow over its figure.
    private func instrumentHero(_ hero: Extension.Block.Hero) -> some View {
        let big: CGFloat = compact ? 46 : 62
        return HStack(alignment: .center, spacing: compact ? 12 : 18) {
            if let glyph = hero.glyph { ExtensionGlyph(glyph: glyph, size: compact ? 38 : 52) }
            HStack(alignment: .top, spacing: 3) {
                Text(hero.value).font(ink.mono(big, weight: .ultraLight)).tracking(-0.04 * big).monospacedDigit()
                    .foregroundStyle(colour(hero.tone, else: ink.text))
                if let unit = hero.unit {
                    Text(unit).font(ink.mono(compact ? 15 : 19, weight: .light)).foregroundStyle(ink.muted).padding(.top, big * 0.14)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
            Spacer(minLength: 8)
            if hero.place != nil || !hero.stats.isEmpty {
                VStack(alignment: .leading, spacing: compact ? 6 : 9) {
                    if let place = hero.place {
                        HStack(spacing: 5) {
                            Image(systemName: "mappin").font(.system(size: compact ? 9 : 10, weight: .medium)).accessibilityHidden(true)
                            Text(place).styleText(\.eyebrow)
                        }
                        .foregroundStyle(ink.text2)
                    }
                    if !hero.stats.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: compact ? 12 : 18, verticalSpacing: compact ? 2 : 4) {
                            GridRow {
                                ForEach(hero.stats.indices, id: \.self) { i in Text(hero.stats[i].label).styleText(\.eyebrow).foregroundStyle(ink.muted) }
                            }
                            GridRow {
                                ForEach(hero.stats.indices, id: \.self) { i in
                                    Text(hero.stats[i].value).font(ink.mono(compact ? 12.5 : 14)).monospacedDigit()
                                        .foregroundStyle(colour(hero.stats[i].tone, else: ink.text))
                                }
                            }
                        }
                    }
                }
                .lineLimit(1).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, compact ? 2 : 6)
        .accessibilityElement(children: .combine)
    }

    /// A hero: the glyph big, the value bigger with its unit, the place under them, its small stats at their right.
    private func toyHero(_ hero: Extension.Block.Hero) -> some View {
        HStack(alignment: .center, spacing: compact ? 12 : 16) {
            if let glyph = hero.glyph { ExtensionGlyph(glyph: glyph, size: compact ? 38 : 48) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(hero.value).font(ink.mono(compact ? 34 : 44, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(colour(hero.tone, else: ink.text))
                    if let unit = hero.unit { Text(unit).font(ink.ui(compact ? 15 : 18)).foregroundStyle(ink.muted) }
                }
                if let place = hero.place { Text(place).font(ink.ui(compact ? 12 : 13.5)).foregroundStyle(ink.muted) }
            }
            .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
            Spacer(minLength: 8)
            if !hero.stats.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: compact ? 3 : 5) {
                    ForEach(hero.stats.indices, id: \.self) { i in
                        GridRow {
                            Text(hero.stats[i].label).foregroundStyle(ink.muted)
                            Text(hero.stats[i].value).font(ink.mono(compact ? 12 : 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(colour(hero.stats[i].tone, else: ink.text)).gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(ink.ui(compact ? 11.5 : 12.5)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, compact ? 2 : 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func stripView(_ columns: [Extension.Block.Column]) -> some View {
        if ink.isInstrument { instrumentStrip(columns) } else { wellStrip(columns) }
    }

    /// Instrument's strip (Q475): its columns on the panel itself, no well, each its label a mono eyebrow, a thin line
    /// glyph (or the emoji sent), its high in the mono and its low muted.
    private func instrumentStrip(_ columns: [Extension.Block.Column]) -> some View {
        // A line no column fills (hours with no low) takes no room.
        let glyphs = columns.contains { $0.glyph != nil }, highs = columns.contains { $0.high != nil }, lows = columns.contains { $0.low != nil }
        return HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { i in
                let column = columns[i]
                VStack(spacing: compact ? 5 : 7) {
                    Text(column.label).styleText(\.eyebrow).foregroundStyle(ink.muted)
                    if let glyph = column.glyph { ExtensionGlyph(glyph: glyph, size: compact ? 16 : 20) }
                    else if glyphs { Color.clear.frame(height: compact ? 16 : 20) }
                    if highs { Text(column.high ?? " ").font(ink.mono(compact ? 12.5 : 13.5)).foregroundStyle(ink.text) }
                    if lows { Text(column.low ?? " ").font(ink.mono(compact ? 11 : 12)).foregroundStyle(ink.muted) }
                }
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, compact ? 2 : 4)
    }

    /// A strip: its columns side by side, each its label, glyph, high and low, on a well.
    private func wellStrip(_ columns: [Extension.Block.Column]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { i in
                let column = columns[i]
                VStack(spacing: compact ? 4 : 6) {
                    Text(column.label).font(ink.ui(compact ? 10.5 : 11.5, .semibold)).foregroundStyle(ink.muted)
                    if let glyph = column.glyph { ExtensionGlyph(glyph: glyph, size: compact ? 18 : 22) }
                    else { Text(" ").font(.system(size: compact ? 18 : 22)).accessibilityHidden(true) }
                    Text(column.high ?? " ").font(ink.mono(compact ? 12.5 : 14, weight: .semibold)).foregroundStyle(ink.text)
                    Text(column.low ?? " ").font(ink.mono(compact ? 11.5 : 12.5)).foregroundStyle(ink.muted)
                }
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, compact ? 8 : 12).padding(.horizontal, compact ? 4 : 8)
        .background(ink.well, in: .rect(cornerRadius: compact ? 7 : 10))
    }

    @ViewBuilder private func meterView(_ meter: Extension.Block.Meter) -> some View {
        let value = meter.value ?? "\(Int(meter.percent.rounded())) %"
        if compact {
            // CodexBar's row: "Session 66% left" and when it resets, the bar, one line of note.
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Text(meter.label).fontWeight(.semibold)) \(value)").font(ink.ui(12)).foregroundStyle(ink.text).layoutPriority(1)
                    Spacer(minLength: 0)
                    if let resetsAt = meter.resetsAt {
                        TimelineView(.everyMinute) { context in Text(Extension.Block.Meter.resets(at: resetsAt, now: context.date)) }
                            .font(ink.ui(10.5)).foregroundStyle(ink.muted)
                    }
                }
                .lineLimit(1)
                track(meter, height: ink.isInstrument ? 3 : 5)
                if let note = meter.note { Text(note).font(ink.ui(10.5)).foregroundStyle(ink.muted).lineLimit(1) }
            }
            .help(meter.help ?? "")
            .accessibilityElement(children: .combine)
            .accessibilityValue(value)
            .accessibilityHint(meter.help ?? "")
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(meter.label).foregroundStyle(ink.text)
                    Spacer(minLength: 8)
                    Text(value).font(ink.mono(12)).monospacedDigit().foregroundStyle(ink.text2)
                }
                .font(ink.ui(13))
                track(meter, height: ink.isInstrument ? 4 : 8)
                if let note = meter.note { Text(note).font(ink.ui(11.5)).foregroundStyle(ink.muted) }
                // Pilot ticks the countdown itself (Surfaces v2), each minute, while the view shows.
                if let resetsAt = meter.resetsAt {
                    TimelineView(.everyMinute) { context in
                        Text(Extension.Block.Meter.countdown(to: resetsAt, now: context.date)).monospacedDigit()
                    }
                    .font(ink.ui(11.5)).foregroundStyle(ink.muted)
                }
            }
            .help(meter.help ?? "")
            .accessibilityElement(children: .combine)
            .accessibilityValue(meter.value ?? "\(Int(meter.percent.rounded())) percent")
            .accessibilityHint(meter.help ?? "")
        }
    }

    /// A meter's track, filled in its tone, with its mark: a tick a little taller than the track, in the mark's tone; an
    /// alert mark (AI usage: in deficit) red in every style, since Instrument's tones are all its signal (Q138).
    private func track(_ meter: Extension.Block.Meter, height: CGFloat) -> some View {
        GeometryReader { track in
            Capsule().fill(ink.line2)
                .overlay(alignment: .leading) {
                    Capsule().fill(colour(meter.tone, else: ink.accent)).frame(width: track.size.width * meter.percent / 100)
                }
                .overlay(alignment: .leading) {
                    if let mark = meter.mark {
                        Capsule().fill(meter.markTone == .alert ? ink.destructive : colour(meter.markTone, else: ink.text))
                            .frame(width: 2, height: track.size.height + 4)
                            .offset(x: min(max(track.size.width * mark / 100 - 1, 0), track.size.width - 2))
                    }
                }
        }
        .frame(height: height)
    }

    @ViewBuilder private func list(_ title: String?, _ items: [Extension.Item], reorder: (Extension.Block.Reorder, PageHooks)?,
                                   at block: Int) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(title).font(ink.ui(11, .semibold)).foregroundStyle(ink.muted) }
                ForEach(items.indices, id: \.self) { i in row(items[i], at: block, row: i) }
            }
        } else {
            Tile(title: title) {
                if items.isEmpty { Text("Nothing here.").font(ink.ui(12.5)).foregroundStyle(ink.muted) }
                ForEach(items.indices, id: \.self) { i in
                    BlockRow(first: i == 0) {
                        if let reorder { grip(items, at: i, reorder, block: block) }
                        row(items[i], at: block, row: i)
                    }
                    .overlay(alignment: .top) {
                        if dropping == Slot(block: block, row: i) { Capsule().fill(ink.accent).frame(height: 2) }
                    }
                    .dropDestination(for: String.self) { payloads, _ in
                        guard let reorder, let key = payloads.first.flatMap({ Self.dragged($0, by: reorder.0) }) else { return false }
                        return move(items, key: key, to: i, reorder, block: block)
                    } isTargeted: { over in
                        if over { dropping = Slot(block: block, row: i) } else if dropping == Slot(block: block, row: i) { dropping = nil }
                    }
                }
            }
        }
    }

    /// A movable row's grip: dragged, it carries the row to the row it is dropped on; focused (a click or Tab), ⌥↑ and ⌥↓
    /// move the row one place. A row without an id has a blank in its place, so the titles stay in line.
    @ViewBuilder private func grip(_ items: [Extension.Item], at i: Int, _ reorder: (Extension.Block.Reorder, PageHooks), block: Int) -> some View {
        if let key = items[i].id {
            let step = { (by: Int) in move(items, key: key, to: i + by, reorder, block: block) }
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(grip == key ? ink.accent : ink.muted)
                .frame(width: 16, height: 22).contentShape(.rect)
                .focusable()
                .focused($grip, equals: key)
                .onTapGesture { grip = key }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    guard press.modifiers.contains(.option) else { return .ignored }
                    _ = step(press.key == .upArrow ? -1 : 1)
                    return .handled
                }
                .draggable(Self.payload(key, by: reorder.0))
                .help("Drag to move · ⌥↑ ⌥↓")
                .accessibilityLabel("Move \(items[i].title)")
                .accessibilityAction(named: "Move up") { _ = step(-1) }
                .accessibilityAction(named: "Move down") { _ = step(1) }
        } else {
            Color.clear.frame(width: 16, height: 22)
        }
    }

    /// Moves row `key` to `to`: drawn there at once, then run as the reorder's command; the extension's answer replaces it.
    /// False when it does not move (no such row, past either end, there already).
    private func move(_ items: [Extension.Item], key: String, to: Int, _ reorder: (Extension.Block.Reorder, PageHooks), block: Int) -> Bool {
        dropping = nil
        guard let next = Extension.Block.Reorder.moving(items, key: key, to: to) else { return false }
        moved[block] = next
        grip = key
        Task {
            await reorder.1.change(reorder.0.action(key: key, to: to))
            if moved[block] == next { moved[block] = nil }
        }
        return true
    }

    /// What a grip's drag carries: the reorder's command and the row's id, so a drop on another list, or text from
    /// elsewhere, moves nothing.
    static func payload(_ key: String, by reorder: Extension.Block.Reorder) -> String { "pilot-move\t\(reorder.command)\t\(key)" }

    /// The row id a drag carries for `reorder`; nil for any other text.
    static func dragged(_ payload: String, by reorder: Extension.Block.Reorder) -> String? {
        let parts = payload.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "pilot-move", parts[1] == reorder.command else { return nil }
        return String(parts[2])
    }

    /// A row: its picture or emoji, title, subtitle and badges, then its inline buttons; a click runs its first action, the ⋯ menu
    /// and a right-click list them all. A run that asks first asks in the row's place.
    @ViewBuilder private func row(_ item: Extension.Item, at block: Int, row index: Int) -> some View {
        if let ask = ask(at: Slot(block: block, row: index)) { ask }
        else { row(item) { start($0, at: Slot(block: block, row: index)) } }
    }

    private func row(_ item: Extension.Item, act: @escaping (Extension.Item.Action) -> Void) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            Button { item.actions.first.map(act) } label: {
                HStack(spacing: 9) {
                    if let picture = item.image.flatMap(Self.picture) {
                        let side: CGFloat = compact ? 28 : 32
                        Image(nsImage: picture).resizable().scaledToFill().frame(width: side, height: side)
                            .clipShape(.rect(cornerRadius: 5)).accessibilityHidden(true)
                    } else if let icon = item.icon { Text(icon).font(.system(size: compact ? 12 : 14)) }
                    // A popover row with badges or buttons puts its subtitle under its title, so neither is cut to nothing.
                    let stacked = compact && !(item.badges.isEmpty && item.inline.isEmpty)
                    let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 1)) : AnyLayout(HStackLayout(spacing: 9))
                    layout {
                        Text(item.title).foregroundStyle(ink.text).lineLimit(1)
                        if let subtitle = item.subtitle {
                            Text(subtitle).font(stacked ? ink.ui(10.5) : nil).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    if !item.badges.isEmpty { ExtensionBadges(badges: item.badges, compact: compact) }
                    Spacer(minLength: 0)
                    // Its word at the right, a due day (To-do B).
                    if let accessory = item.accessory { ExtensionBadges(badges: [accessory], compact: compact) }
                }
                .font(ink.ui(compact ? 12 : 13))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(item.actions.isEmpty)
            .help(item.actions.first?.label ?? "")
            ForEach(item.inline.indices, id: \.self) { i in
                ExtensionInlineButton(action: item.inline[i], compact: compact) { act(item.inline[i]) }
            }
            if item.actions.count > 1 {
                Button { BarMenu.pop(menu(item, act: act)) } label: {
                    Image(systemName: "ellipsis").frame(minWidth: 16, minHeight: 16).contentShape(.rect)
                }
                .buttonStyle(.plain).fixedSize()
                .foregroundStyle(ink.muted)
                .help("More actions")
                .accessibilityLabel("Actions for \(item.title)")
            }
        }
        // In a bar popover the panel hands the right button to the anchor (KeyPanel), so the bars' native menu shows;
        // on the page SwiftUI's own menu does.
        .background(ScreenAnchor(box: ScreenAnchor.Box(), rightClick: item.actions.isEmpty ? nil : { BarMenu.pop(menu(item, act: act)) }))
        .contextMenu { actionButtons(item, act: act) }
    }

    /// A row's picture, decoded once and kept while memory allows, so a popover asked again every few seconds decodes
    /// nothing new.
    private static let pictures = NSCache<NSData, NSImage>()
    private static func picture(_ data: Data) -> NSImage? {
        if let kept = pictures.object(forKey: data as NSData) { return kept }
        guard let made = NSImage(data: data) else { return nil }
        pictures.setObject(made, forKey: data as NSData)
        return made
    }

    /// Every action of a row as the bars' native menu: its ⋯ and, in a bar popover, its right-click.
    private func menu(_ item: Extension.Item, act: @escaping (Extension.Item.Action) -> Void) -> [(title: String, run: () -> Void)] {
        item.actions.map { action in (action.label, { act(action) }) }
    }

    /// Every action of a row, a button each: its right-click on the page.
    private func actionButtons(_ item: Extension.Item, act: @escaping (Extension.Item.Action) -> Void) -> some View {
        ForEach(item.actions.indices, id: \.self) { i in Button(item.actions[i].label) { act(item.actions[i]) } }
    }
}

/// A hero's or a strip's glyph: one of Item.Action.icons' names drawn as its thin line icon in the second text colour
/// (Q475, the Omarchy weather look), any other text (an emoji, which stays allowed) as it is.
struct ExtensionGlyph: View {
    @Environment(\.ink) private var ink
    let glyph: String, size: CGFloat

    var body: some View {
        if let symbol = Extension.Item.Action.icons[glyph] {
            Image(systemName: symbol).font(.system(size: size * 0.8, weight: size >= 30 ? .thin : .light))
                .foregroundStyle(ink.text2).frame(height: size).accessibilityLabel(glyph)
        } else {
            Text(glyph).font(.system(size: size))
        }
    }
}

/// A links row (Q138): small muted links side by side, each its toned dot, icon, title and word; a click runs its action,
/// or lists its actions when it has several; its help on hover.
struct ExtensionLinksRow: View {
    @Environment(\.ink) private var ink
    let links: [Extension.Block.Link]
    var compact = false
    let act: (Extension.Item.Action) -> Void

    var body: some View {
        HStack(spacing: compact ? 10 : 14) {
            ForEach(links.indices, id: \.self) { i in link(links[i]) }
        }
        .font(ink.ui(compact ? 11.5 : 12.5)).foregroundStyle(ink.muted)
        .lineLimit(1).fixedSize()
    }

    private func link(_ link: Extension.Block.Link) -> some View {
        Button {
            if link.actions.count == 1 { act(link.actions[0]) }
            else { BarMenu.pop(link.actions.map { action in (action.label, { act(action) }) }) }
        } label: {
            HStack(spacing: 5) {
                if let tone = link.tone { Circle().fill(ink.tone(tone, else: ink.muted)).frame(width: 6, height: 6) }
                if let symbol = link.icon.flatMap({ Extension.Item.Action.icons[$0] }) {
                    Image(systemName: symbol).font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
                }
                if let title = link.title { Text(title) }
                if let word = link.word { Text(word).foregroundStyle(ink.text) }
            }
            .frame(minHeight: compact ? 22 : 26).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(link.label)
        .accessibilityLabel([link.title, link.word].compactMap { $0 }.joined(separator: " ").isEmpty ? link.label
                            : [link.title, link.word].compactMap { $0 }.joined(separator: " "))
        .accessibilityHint(link.help ?? "")
    }
}

/// A markdown block as the detail view cuts it (DetailBlock), drawn in the style's own colours and faces; Equatable, so
/// a page redrawing for its Refresh or its time never splits and parses the same text again.
struct BlockMarkdown: View, Equatable {
    @Environment(\.ink) private var ink
    let text: String, compact: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool { a.text == b.text && a.compact == b.compact }

    var body: some View {
        let parts = DetailBlock.split(text), type = ReadingType()
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            ForEach(parts.indices, id: \.self) { i in
                switch parts[i] {
                case .heading(let level, let words):
                    Text(type.inline(words)).font(ink.ui(level <= 1 ? 17 : level == 2 ? 15 : 13.5, .semibold)).foregroundStyle(ink.text)
                        .padding(.top, i == 0 ? 0 : 6).accessibilityAddTraits(.isHeader)
                case .paragraph(let words): Text(type.inline(words)).foregroundStyle(ink.text)
                case .item(let marker, let words):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).foregroundStyle(ink.muted)
                        Text(type.inline(words)).foregroundStyle(ink.text)
                    }
                case .rule: ink.line.frame(height: 1)
                case .code(let code):
                    Text(code).font(ink.mono(compact ? 11 : 12)).foregroundStyle(ink.text2)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(ink.well, in: .rect(cornerRadius: 6))
                }
            }
        }
        .font(ink.ui(compact ? 12 : 13))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

extension Ink {
    /// An extension tone's colour: fine green, warn amber, alert red; none the plain one given.
    func tone(_ tone: Extension.Tone?, else plain: Color) -> Color {
        switch tone {
        case .fine: green
        case .warn: yellow
        case .alert: red
        case nil: plain
        }
    }
}

// MARK: - Page

/// An extension's page in the app window (story 161): its command asked as the page shows and again on its pace (10 s at
/// the most often) while the window is on screen, never while hidden; Refresh asks now. The blocks of the last answer
/// stay while a later one fails, the failure said over them.
@Observable @MainActor
final class ExtensionPageModel {
    let id: String
    private(set) var ext: Extension?
    private(set) var blocks: [Extension.Block]?
    /// Why the last ask has nothing: a required setting unset, an error, too slow; nil when it answered.
    private(set) var problem: String?
    /// A required setting is unset: the page offers the extension's settings.
    private(set) var needsSettings = false
    /// The extension is gone, or has neither a page nor a bar item to show.
    private(set) var gone = false
    private(set) var updated: Date?
    private(set) var asking = false
    /// Its last answer's own pace (Surfaces v2), over the manifest's while it lasts.
    private(set) var refresh: Int?
    /// A push to one of its no-view commands (Surfaces v2): that command's view, beside the blocks on a wide page, over
    /// them on a narrow one, with its own back stack.
    var pane: ExtensionPopoverModel?
    @ObservationIgnored private(set) var inputs: ExtensionRun.Inputs?
    /// When the extension and its settings were last read from its folder.
    @ObservationIgnored private var read: Date?
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let storage: ExtensionStorage
    @ObservationIgnored private let run: @Sendable (Extension.Surface, ExtensionRun.Inputs) async -> SurfaceOutcome
    @ObservationIgnored private let now: () -> Date
    /// The ask in flight, and whether another was asked for while it ran: a change's ask is never dropped, it runs next.
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var again = false
    /// Counted at the start and the end of each change made on the page (a row moved, a live search): an answer asked
    /// before the count moved may be from before the change, so it is dropped and the ask after the change shows instead.
    @ObservationIgnored private var changes = 0
    /// The last change asked for, which the next one waits out.
    @ObservationIgnored private var changing: Task<Void, Never>?
    /// A live input's run (2026-10-17): its pause, its quiet run and the ask after it; a newer text cancels it.
    @ObservationIgnored private var live: Task<Void, Never>?
    /// A live input's run, and its pause; a test's fakes.
    @ObservationIgnored var quiet: @Sendable (Extension.Command, JSONValue?, String?, ExtensionRun.Inputs) async -> ExtensionRun.Outcome = {
        await ExtensionRun.noView($0, context: $1, input: $2, inputs: $3)
    }
    @ObservationIgnored var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0, tolerance: $0 / 10) }

    init(id: String, folder: URL = Extension.folder, storage: ExtensionStorage = ExtensionStorage(), now: @escaping () -> Date = Date.init,
         run: @escaping @Sendable (Extension.Surface, ExtensionRun.Inputs) async -> SurfaceOutcome = { await ExtensionRun.surface($0, inputs: $1) }) {
        self.id = id; self.folder = folder; self.storage = storage; self.now = now; self.run = run
    }

    /// The page's pace in seconds: its last answer's `refresh`, else its manifest's.
    var every: Int { refresh ?? ext?.shownSurface?.every ?? Extension.Surface.pace(.page, asked: nil) }

    /// Opens `command`'s view in the pane, asked as the page is, with the push's `context`.
    func open(_ command: String, title: String?, context: JSONValue?,
              act: @escaping ExtensionActions.Act = { ExtensionActions.run($0, in: $1, inputs: $2) },
              run: @escaping @Sendable (Extension.Command, JSONValue?, ExtensionRun.Inputs) async -> SurfaceOutcome = ExtensionPopoverModel.runner(.page)) async {
        guard let ext, let inputs else { return }
        let pane = ExtensionPopoverModel(id: id, folder: folder, storage: storage, now: now, run: run)
        pane.act = act
        self.pane = pane
        await pane.start(ext, inputs: inputs, command: command, title: title, context: context)
    }

    /// Asks its page's command, off the main thread. The extension and its settings are read again from its folder first
    /// when `reread`, when they are missing, or once its manifest's pace has passed since they were read: a faster
    /// `refresh` (Surfaces v2) asks only the command. Asked while an ask runs, it asks once more after that one, and
    /// returns when the page shows the later answer.
    func refresh(reread: Bool = false) async {
        if let inFlight {
            again = true
            return await inFlight.value
        }
        asking = true
        let task = Task {
            await ask(reread: reread)
            while again {
                again = false
                await ask(reread: false)
            }
            (inFlight, asking) = (nil, false)
        }
        inFlight = task
        await task.value
    }

    private func ask(reread: Bool) async {
        let pace = Double(ext?.shownSurface?.every ?? Extension.Surface.pace(.page, asked: nil))
        if reread || inputs == nil || read.map({ now().timeIntervalSince($0) >= pace }) ?? true {
            let (folder, id) = (folder, id)
            let found = await Task.detached { Extension.find(in: folder).extensions.first { $0.id == id } }.value
            ext = found
            guard let ext = found, ext.shownSurface != nil else { gone = true; return }
            gone = false
            var why: String?, unset = false
            inputs = await ExtensionsModule.inputs(for: ext, storage: storage, hud: { why = $0 }, unset: { _ in unset = true })
            needsSettings = unset
            read = now()
            if inputs == nil { problem = why }
        }
        if let ext, let page = ext.shownSurface, let inputs {
            let asked = changes
            let outcome = await run(page, inputs)
            guard asked == changes else { return }
            switch outcome {
            case .blocks(let answer, let every): (blocks, problem, updated, refresh) = (answer, nil, now(), every)
            case .error(let why): problem = "\(ext.title) \(why)"
            case .bar: problem = "\(ext.title) \(ExtensionRun.unreadable)"
            }
        }
        if let problem { dlog.error("extension page: \(self.id, privacy: .public) \(problem, privacy: .private)") }
    }

    /// Asks on its pace until cancelled, while what shows it is on screen; an answer younger than its pace (a window shown
    /// again) waits out the rest of it first.
    func keepFresh() async {
        while !Task.isCancelled {
            let wait = updated.map { Double(every) - now().timeIntervalSince($0) } ?? 0
            if wait > 0 { guard (try? await sleep(.seconds(wait))) != nil else { return } }
            await refresh()
            guard (try? await sleep(.seconds(every))) != nil else { return }
        }
    }

    /// Runs `action`, a change Sven made on the page (a row moved, 2026-10-17), as the extension's, then asks again;
    /// returns once the page shows the extension's answer to it. Changes run one after another, so two quick moves never
    /// race in the extension's own files.
    func change(_ action: Extension.Item.Action, act: @escaping ExtensionActions.Act) async {
        let before = changing
        let task = Task {
            await before?.value
            guard let ext, let inputs else { return }
            changes += 1
            await act(action, ext, inputs)?.value
            changes += 1
            await refresh()
        }
        changing = task
        await task.value
    }

    /// A live input's text changed (2026-10-17): its run waits out `pause` (nil, its Return: none), then runs quietly and
    /// the page asks again. A newer text cancels the run waiting or running, its process tree stopped, so only the newest
    /// text's answer is drawn; nothing waits while no one types.
    func typed(_ action: Extension.Item.Action, pause: Duration?) {
        live?.cancel()
        live = Task {
            if let pause { guard (try? await sleep(pause)) != nil else { return } }
            guard !Task.isCancelled else { return }
            await runLive(action)
        }
    }

    /// The page went away: a live run waiting or running stops.
    func stopLive() {
        live?.cancel()
        live = nil
    }

    /// The newest live run has ended or been cancelled.
    func settled() async { await live?.value }

    /// The live run itself: a run per pause would HUD every keystroke, so its HUD line and its actions are left out (its
    /// answer is the page asked again) and only a failure is said.
    private func runLive(_ action: Extension.Item.Action) async {
        guard let ext, let inputs, case .run(let name, let context) = action.kind, let command = ext.noView(name) else { return }
        changes += 1
        let outcome = await quiet(command, context, action.input, inputs)
        changes += 1
        guard !Task.isCancelled else { return }
        switch outcome {
        case .hud: break
        case .actions(let actions, _): dlog.notice("extension: \(command.actionID, privacy: .public) live run left \(actions.count) actions undone")
        default: ExtensionsModule.show(outcome, of: command, in: ext, act: { _ in })
        }
        await refresh()
    }

    /// Runs `action` as the extension's: a push to one of its no-view commands goes to `push` (its name and context); a run
    /// or a Pilot action changes what it shows, so it asks again as a run ends, a Pilot action a moment later.
    func run(_ action: Extension.Item.Action, act: ExtensionActions.Act, push: (String, JSONValue?) -> Void) {
        guard let ext, let inputs else { return }
        if case .push(let name, let context) = action.kind, ext.noView(name) != nil { push(name, context); return }
        ExtensionActions.followed(act(action, ext, inputs), action) { await self.refresh() }
    }
}

struct ExtensionSurfacePage: View {
    @Environment(\.ink) private var ink
    /// The window shows: the page asks on its pace only then.
    let onScreen: Bool
    @State private var model: ExtensionPageModel
    /// Opens the extension's Installed card: its keys, settings and Uninstall stay there.
    let settings: (String) -> Void
    /// Runs one of its actions as the extension's; a test's spy.
    var act: ExtensionActions.Act = { ExtensionActions.run($0, in: $1, inputs: $2) }
    /// The page is `wide` or wider: a pushed view opens beside the blocks, else over them.
    @State private var wide = false
    static let wideFrom: CGFloat = 720, paneWidth: CGFloat = 380

    init(id: String, onScreen: Bool, model: ExtensionPageModel? = nil, settings: @escaping (String) -> Void) {
        self.onScreen = onScreen
        _model = State(initialValue: model ?? ExtensionPageModel(id: id))
        self.settings = settings
    }

    var body: some View {
        let intro = model.ext.flatMap { $0.description.isEmpty ? nil : $0.description }
        KitPage(intro: intro) {
            controls.padding(.top, 14).padding(.bottom, 10)
            if let problem = model.problem {
                Tile {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(ink.warnText).accessibilityHidden(true)
                        Text(problem).foregroundStyle(ink.text).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if model.needsSettings { Button("Open settings") { settings(model.id) }.buttonStyle(.pilotPrimary) }
                    }
                    .font(ink.ui(13))
                }
            }
            if model.gone {
                EmptyState(title: "No page", line: "\(model.id) is not installed, or no longer has a page.", action: ("Open Extensions", { settings(model.id) }))
            } else if let blocks = model.blocks {
                let main = VStack(alignment: .leading, spacing: 12) {
                    if blocks.isEmpty { Text("Nothing to show.").font(ink.ui(13)).foregroundStyle(ink.muted) }
                    ExtensionBlocksView(blocks: blocks, page: .init(change: { await model.change($0, act: act) }, typed: model.typed)) { action in run(action) }
                }
                Group {
                    if let pane = model.pane {
                        let close = { model.pane = nil }
                        if wide {
                            HStack(alignment: .top, spacing: 14) {
                                main.frame(maxWidth: .infinity, alignment: .topLeading)
                                ExtensionPaneView(model: pane, onScreen: onScreen, close: close).frame(width: Self.paneWidth)
                            }
                        } else {
                            ExtensionPaneView(model: pane, onScreen: onScreen, close: close)
                        }
                    } else {
                        main
                    }
                }
                .padding(.top, 4)
                .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideFrom } action: { wide = $0 }
            } else if model.problem == nil {
                FinePrint(text: "Asking \(model.ext?.title ?? model.id)…")
            }
        }
        // Asked as it shows, then on its pace while the window is on screen; leaving or hiding the page stops it.
        .task(id: onScreen) {
            guard onScreen else { return }
            await model.keepFresh()
        }
        .onDisappear { model.stopLive() }
    }

    /// When it was last answered and how often, then Refresh and the way to its settings.
    private var controls: some View {
        HStack(spacing: 10) {
            if let note { Text(note).font(ink.ui(12)).foregroundStyle(ink.muted) }
            Spacer(minLength: 8)
            Button("Refresh") { Task { await model.refresh(reread: true) } }.buttonStyle(.pilot).disabled(model.asking)
            AccentLink(title: "Settings", chevron: "arrow.up.right") { settings(model.id) }
        }
    }

    /// "Updated 14:02 · every 60 s".
    private var note: String? {
        guard let updated = model.updated else { return nil }
        return "Updated \(updated.formatted(date: .omitted, time: .shortened)) · every \(model.every) s"
    }

    /// Runs `action` as the extension's; a push to one of its no-view commands opens the pane (Surfaces v2).
    private func run(_ action: Extension.Item.Action) {
        model.run(action, act: act) { name, context in Task { await model.open(name, title: action.title, context: context, act: act) } }
    }
}

/// A page's pane (Surfaces v2): a pushed no-view command's view on a tile, as the popover draws its stack, with close;
/// asked again on its answer's pace only while the window shows.
struct ExtensionPaneView: View {
    @Environment(\.ink) private var ink
    let model: ExtensionPopoverModel
    let onScreen: Bool
    let close: () -> Void

    var body: some View {
        let bottom = model.stack[0]
        Tile {
            ExtensionStackView(model: model, root: bottom.title ?? bottom.command, fallback: model.top.command,
                               title: ink.ui(14, .semibold), accent: ink.accentInk, muted: ink.muted, mono: ink.mono(11)) {
                IconButton(symbol: "xmark", label: "Close", size: 20, glyph: 11, action: close)
            }
            .font(ink.ui(12.5))
        }
        .task(id: onScreen ? model.pace : nil) {
            guard onScreen else { return }
            await model.keepFresh()
        }
    }
}

// MARK: - Sidebar

/// The installed extensions for the app window: `links`, the ones that declare a page (Home's blocks, story 161), and
/// `entries`, every one, for the Extensions area's sidebar (Sven 2026-10-16: "all extensions downloaded should list
/// here"); read as the window opens and as the Extensions page reads its folder.
@Observable @MainActor
final class ExtensionPages {
    static let shared = ExtensionPages()

    struct Link: Equatable, Identifiable {
        let id: String, title: String, icon: String?
        /// It has something to show as a page: its page, else its bar item's popover. One with neither opens its card on
        /// Installed.
        var opens = true
        /// "📊 AI usage".
        var label: String { [icon, title].compactMap { $0 }.joined(separator: " ") }
    }

    private(set) var links: [Link] = []
    private(set) var entries: [Link] = []
    @ObservationIgnored private let folder: URL

    init(folder: URL = Extension.folder) { self.folder = folder }

    func reload() async {
        let folder = folder
        show(await Task.detached { Extension.find(in: folder).extensions }.value)
    }

    /// The links of `extensions`, already read.
    func show(_ extensions: [Extension]) {
        let new = Self.links(extensions), all = Self.entries(extensions)
        if new != links { links = new }
        if all != entries { entries = all }
    }

    nonisolated static func links(_ extensions: [Extension]) -> [Link] {
        extensions.filter { $0.page != nil }.map { Link(id: $0.id, title: $0.title, icon: $0.icon) }
    }

    /// Every installed extension, as the folder lists them.
    nonisolated static func entries(_ extensions: [Extension]) -> [Link] {
        extensions.map { Link(id: $0.id, title: $0.title, icon: $0.icon, opens: $0.shownSurface != nil) }
    }

    /// The entries ⌃Tab steps through: the ones that open as a page.
    var pageEntries: [Link] { entries.filter(\.opens) }
}

extension Extension {
    /// What its page in the window shows: its declared page, else its bar item's popover, its bar command asked as a
    /// popover at a page's pace (Now playing declares only a bar item); nil with neither.
    var shownSurface: Surface? {
        if let page { return page }
        return bar.map { Surface(kind: .popover, command: $0.command, every: Surface.pace(.page, asked: Double($0.every))) }
    }
}

/// The sidebar's hook (story 161): a row per installed extension under the Extensions row, drawn by the sidebar's own
/// `row`: one with a page or a bar item opens its page, one with neither its card on Installed.
struct ExtensionPageRows<Row: View>: View {
    @Bindable var model: AppWindowModel
    var pages = ExtensionPages.shared
    @ViewBuilder let row: (_ link: ExtensionPages.Link, _ on: Bool, _ open: @escaping () -> Void) -> Row

    var body: some View {
        ForEach(pages.entries) { link in
            row(link, model.extensionPage == link.id) { link.opens ? model.goExtensionPage(link.id) : model.focusExtension(link.id) }
        }
    }
}

// MARK: - Top bar

/// The top bar's Extensions item's dropdown, from its right-click's Show: each bar item placed there, as its own popover
/// shows it.
struct ExtensionBarPopover: View {
    @Environment(\.style) private var style
    let bar: ExtensionBar

    var body: some View {
        let ink = BarInk(style: style), items = bar.items.filter { bar.shows($0.id, .topBar) }
        VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                Text("Extensions").font(ink.title)
                Text(bar.items.isEmpty ? "No installed extension has a bar item." : "Every extension's item is in the macOS menu bar.")
                    .foregroundStyle(ink.muted)
                if bar.items.isEmpty {
                    Button("Browse catalogue") { AppWindowController.shared.open(AppPlace(.extensionCatalogue)) }.barButton(primary: true)
                } else {
                    Button("Bar settings") { AppWindowController.shared.open(.menuBar) }.barButton()
                }
            }
            ForEach(items) { item in
                ExtensionItemSection(item: item)
                if item.id != items.last?.id { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .barPopover(width: 300)
        .extensionGlass()
    }
}

/// An extension's own bar item's popover (Surfaces v2): ExtensionPopoverView over its last bar answer.
struct ExtensionItemPopover: View {
    let id: String
    let bar: ExtensionBar

    var body: some View {
        if let item = bar.items.first(where: { $0.id == id }) {
            ExtensionPopoverView(item: item)
        } else {
            Text("\(id) has no bar item now.").frame(maxWidth: .infinity, alignment: .leading).barPopover(width: 320).extensionGlass()
        }
    }
}

/// One bar item in a popover: its name and text, why it shows nothing, its blocks small, and Open page.
struct ExtensionItemSection: View {
    @Environment(\.style) private var style
    let item: ExtensionBar.Item

    var body: some View {
        let ink = BarInk(style: style)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(ExtensionPages.Link(id: item.id, title: item.title, icon: item.icon).label).font(ink.title)
                Spacer(minLength: 8)
                if let text = item.answer?.text, !text.isEmpty { Text(text).font(ink.mono(11)).foregroundStyle(ink.muted) }
            }
            if let problem = item.problem { Text(problem).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true) }
            else if item.answer == nil { Text("Asking…").foregroundStyle(ink.muted) }
            if let blocks = item.answer?.blocks, !blocks.isEmpty {
                ExtensionBlocksView(blocks: blocks, compact: true) { action in
                    Task { await ExtensionActions.run(action, asExtension: item.id, title: item.title) }
                }
            }
            if item.hasPage {
                Button("Open page") { AppWindowController.shared.openExtensionPage(item.id) }.barButton()
            }
        }
    }
}

/// An extension page's row in Instrument's sidebar, drawn as its page rows are: raised with the signal's tick when picked.
struct InstrumentExtensionRow: View {
    @Environment(\.style) private var style
    let link: ExtensionPages.Link, on: Bool, open: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        Button(action: open) {
            HStack(spacing: 10) {
                Text(link.icon ?? "🧩").font(.system(size: 11 * style.scale)).frame(width: 16)
                Text(link.title).styleText(\.body).foregroundStyle(style.color(on ? \.text : \.text2)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
            }
            .padding(.leading, 22).padding(.trailing, 10).frame(height: style.points(30))
            .background { if on { shape.fill(style.color(\.raised)) } }
            .overlay { if on { shape.strokeBorder(style.color(\.line)) } }
            .overlay(alignment: .leading) { if on { Capsule().fill(style.color(\.accent)).frame(width: 2, height: 14).padding(.leading, 4) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// An extension page's row in Toybox's sidebar: its emoji on a tile, the picked one a sun keycap; folded to the rail, the
/// tile alone, named by its tooltip.
struct ToyExtensionRow: View {
    @Environment(\.style) private var style
    let link: ExtensionPages.Link, on: Bool, rail: Bool, open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 11) {
                Text(link.icon ?? "🧩").font(.system(size: (rail ? 17 : 15) * style.scale)).frame(width: rail ? 32 : 28, height: rail ? 32 : 28)
                if !rail {
                    Text(link.title).font(style.toyNunito(700, 14.5)).foregroundStyle(on ? style.color(\.onAccent) : style.color(\.text)).lineLimit(1)
                    Spacer(minLength: 4)
                }
            }
            .padding(.horizontal, rail ? 0 : 10)
            .frame(width: rail ? 50 : nil, height: rail ? 46 : style.points(40))
            .frame(maxWidth: rail ? nil : .infinity, alignment: .leading)
            .background { if on { Toy.block(style, fill: style.color(\.accent), radius: 13, edge: 4) } }
            .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .help(rail ? link.title : "")
        .accessibilityLabel(link.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
