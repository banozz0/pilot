import AppKit
import PilotCore
import SwiftUI

// The chips at the right of the menu's line (launcher ideas, 2026-10-18): Emoji's category picker on ⌘P (P39), and
// Translate's From, swap and To (P40). A chip opens its list (ChipMenu) over the menu's top right; while that is open it
// takes every key the panel sees (PilotMenu.handle), so the search field and the list under it wait.

extension MenuModel {
    /// The open branch's chips in Line's line, Emoji's and Translate's, with the grid and the panes under them; none in a
    /// picker, another layout (which lists their rows as before) or anywhere else.
    var hasLineChips: Bool { layout == .line && !nav.isList && (nav.branch == .emoji || nav.branch == .translate) }

    /// The search's words where a branch says what to type.
    var branchPrompt: String? {
        switch nav.branch {
        case .emoji: "Search emoji…"
        case .translate: "Type or paste text…"
        default: nil
        }
    }

    /// A key while a chip's list is open, every one taken: ↑ ↓ move, Return picks, Escape (or the key that opened it)
    /// closes, Tab closes and steps on; a list that filters takes letters and Delete.
    func chipKey(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ characters: String?) -> Bool {
        guard var chip else { return false }
        let command = flags.contains(.command)
        switch PilotMenu.key(code, flags) {
        case .up?, .down?:
            chip.move(code == 126 ? -1 : 1)
            self.chip = chip
        case .return?: commitChip()
        case .escape?: self.chip = nil
        case .tab?, .backTab?:
            self.chip = nil
            if chip.purpose != .emojiCategory { stepChip(flags.contains(.shift) ? -1 : 1) }
        case .left?, .right?: break
        default:
            // ⌘P closes the list it opened; a list that filters takes Delete and what is typed.
            if code == 35, command {
                self.chip = nil
            } else if chip.filters, code == 51 {
                chip.query = String(chip.query.dropLast())
                self.chip = chip
            } else if chip.filters, !command, !flags.contains(.control), let typed = characters,
                      typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                chip.query += typed
                self.chip = chip
            }
        }
        return true
    }

    /// Return on the list, or a click on row `index`: the list closes and its row is picked.
    func commitChip(at index: Int? = nil) {
        guard var chip else { return }
        if let index { chip.select(index) }
        self.chip = nil
        if let row = chip.selected { pick(row, in: chip.purpose) }
    }

    /// The pointer over a list's row selects it.
    func pointChip(at index: Int) { chip?.select(index) }

    private func pick(_ row: ChipMenu.Row, in purpose: ChipMenu.Purpose) {
        switch purpose {
        case .emojiCategory:
            emojiCategory = row.value.isEmpty ? nil : row.value
            mlog.notice("menu: emoji shows \(self.emojiCategory ?? "all categories", privacy: .public)")
            onQuery?(nav.query)
        case .translateFrom, .translateTo:
            pickLanguage(row, from: purpose == .translateFrom)
        }
    }
}

/// A chip in the line: its words, a language's code before them or Auto's globe, and the chevron; ringed in the accent
/// while Tab is on it or its list is open.
struct LineChip: View {
    @Environment(\.style) private var style
    let title: String
    var code: String?
    var symbol: String?
    var focused = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(style.font(\.caption)).foregroundStyle(style.color(\.text2)) }
            if let code {
                Text(code.uppercased()).styleText(\.mono).foregroundStyle(style.color(\.text2))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(style.color(\.panel), in: .rect(cornerRadius: 3))
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(style.color(\.line2)) }
            }
            Text(title).styleText(\.caption).foregroundStyle(style.color(\.text))
            Image(systemName: "chevron.down").font(.system(size: 9 / style.scale, weight: .semibold)).foregroundStyle(style.color(\.text3))
        }
        .lineLimit(1).fixedSize()
        .padding(.leading, 10).padding(.trailing, 9).frame(height: 30)
        .background(style.color(\.raised), in: shape)
        .overlay { shape.strokeBorder(style.color(focused ? \.accent : \.line2)) }
        .background { if focused { shape.inset(by: -3).fill(style.color(\.accentSoft)) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The line's right in Emoji and Translate: the category chip and ⌘P, or From, the swap and To.
struct LineChips: View {
    @Bindable var model: MenuModel

    var body: some View {
        if model.nav.branch == .emoji {
            HStack(spacing: 10) {
                Button { model.openEmojiCategories?() } label: {
                    LineChip(title: model.emojiCategory ?? "All categories", focused: model.chip?.purpose == .emojiCategory)
                }
                .buttonStyle(.plain).focusable(false)
                InstrumentKeys(caps: ["⌘", "P"], hyper: false)
            }
        } else {
            TranslateChips(model: model)
        }
    }
}

/// A chip's list over the menu's top right: a filter line when it filters, its rows under their headings, the one in
/// force checked, the selected one raised, a rule where a row asks for one.
struct ChipMenuView: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel
    let chip: ChipMenu
    let pointer: PointerTrack

    var body: some View {
        let pointing = PointerList(track: pointer, name: "chip", selection: { model.chip?.selection }, hover: { model.pointChip(at: $0) },
                                   click: { model.commitChip(at: $0) })
        VStack(alignment: .leading, spacing: 0) {
            if chip.filters {
                HStack(spacing: 0) {
                    Text(chip.query.isEmpty ? "Type to filter" : chip.query).styleText(\.row)
                        .foregroundStyle(style.color(chip.query.isEmpty ? \.text3 : \.text))
                    Rectangle().fill(style.color(\.accent)).frame(width: 2, height: 16).padding(.leading, 1)
                }
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
                .overlay(alignment: .bottom) { InstrumentRule() }
                .padding(.horizontal, -6).padding(.top, -6).padding(.bottom, 6)
            }
            let headings = chip.visible.indices.count(where: chip.startsSection)
            let rules = chip.visible.count(where: \.ruleAfter)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(chip.visible.enumerated()), id: \.offset) { i, row in
                            if let section = row.section, chip.startsSection(i) {
                                InstrumentEyebrow(text: section).padding(.horizontal, 10).padding(.top, i == 0 ? 2 : 8).padding(.bottom, 4)
                            }
                            line(row, on: i == chip.selection).id(i).pointerRow(pointing, i)
                            if row.ruleAfter { InstrumentRule().padding(.horizontal, 6).padding(.vertical, 5) }
                        }
                        if chip.visible.isEmpty {
                            Text("Nothing matches.").styleText(\.caption).foregroundStyle(style.color(\.text3)).padding(10)
                        }
                    }
                }
                .scrollIndicators(.never)
                .scrollsToSelection(pointing) { _, new in if let new { proxy.scrollTo(new) } }
                // As tall as its rows, headings and rules, scrolling past 380.
                .frame(height: min(CGFloat(max(chip.visible.count, 1)) * 30 + CGFloat(headings) * 26 + CGFloat(rules) * 11, 380))
            }
        }
        .padding(6)
        .frame(width: 258)
        .styleSurface(\.pop, fill: \.panel, radius: \.card)
    }

    private func line(_ row: ChipMenu.Row, on: Bool) -> some View {
        HStack(spacing: 8) {
            Text(row.title).styleText(\.row).foregroundStyle(style.color(\.text)).lineLimit(1)
            Spacer(minLength: 8)
            if let detail = row.detail { Text(detail).styleText(\.mono).foregroundStyle(style.color(\.text3)) }
            if row.checked {
                Image(systemName: "checkmark").font(style.font(\.small)).foregroundStyle(style.color(\.accentText))
            } else if row.section == TranslateLanguages.download {
                Image(systemName: "arrow.down.circle").font(style.font(\.small)).foregroundStyle(style.color(\.text3))
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .instrumentPicked(on)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
