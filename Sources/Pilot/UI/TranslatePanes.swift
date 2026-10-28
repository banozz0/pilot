import AppKit
import PilotCore
import SwiftUI

// Trigger › Translate (P40; design launcher-ideas-2026-10-18, frames 1 to 3): From (Auto first), a swap and To at the
// line's right, Tab stepping them; the text and its translation side by side, each with its count, the engine named.
// Return copies the translation, ⌘Return pastes it into the app in front, ⌘S swaps; each pick is saved as the pair.

extension MenuModel {
    /// What the To chip and the translation pane show.
    var translateTarget: String { translatePair.shownTarget(source: translateSource) }

    /// Tab and Shift+Tab in Translate's line: the text, From, the swap, To, and round again.
    func stepChip(_ by: Int) {
        let next = ((chipFocus ?? -1) + 1 + by + 4) % 4 - 1
        chipFocus = next < 0 ? nil : next
    }

    /// Return on the chip Tab is on: a list opens, or the swap swaps.
    func pressChip() {
        switch chipFocus {
        case 0: openLanguages(from: true)
        case 1: swapLanguages()
        case 2: openLanguages(from: false)
        default: break
        }
    }

    /// From's or To's list, the languages already on this Mac first; asked of the system off the line, so it opens a
    /// moment after the key.
    func openLanguages(from: Bool) {
        chipFocus = from ? 0 : 2
        let other = from ? translateTarget : translateSource ?? translatePair.other
        let shown = from ? translateFrom : translateTarget
        Task { [weak self] in
            let installed = await AppleTranslator.installed(TranslatePair.languages, with: other, from: from)
            guard let self, nav.branch == .translate, nav.actions == nil else { return }
            chip = TranslateLanguages.menu(from: from, shown: shown, installed: installed)
        }
    }

    /// From and To change places; a translation shown becomes the text, as Google's swap does.
    func swapLanguages() {
        let swapped: String? = if case .copy(let text)? = nav.rows.first?.target { text } else { nil }
        changePair(translatePair.swapped(source: translateSource), explicit: translateFrom != nil, text: swapped)
        mlog.notice("menu: translate swapped to \(self.translatePair.other, privacy: .public) → \(self.translatePair.home, privacy: .public)")
    }

    /// A row of From's or To's list: a language not on this Mac opens Language & Region, as Translate's Download row does.
    func pickLanguage(_ row: ChipMenu.Row, from: Bool) {
        if row.section == TranslateLanguages.download {
            let download = MenuEntry(title: "Download \(row.title) for translation", target: .action("system.translationLanguages"),
                                     home: .translate, isAnswer: true)
            onClick?(.run(download), nav.branch)
            return
        }
        if from, row.value.isEmpty {
            translateFrom = nil
            onQuery?(nav.query)
        } else if from {
            changePair(translatePair.picking(from: row.value, source: translateSource), explicit: true)
        } else {
            changePair(translatePair.picking(to: row.value, source: translateSource), explicit: translateFrom != nil)
        }
        mlog.notice("menu: translate \(self.translateFrom ?? "auto", privacy: .public) → \(self.translateTarget, privacy: .public)")
    }

    /// The new pair shown and saved as the setting (TranslatePair, the last pick), From kept on its side when it was
    /// picked, and the text (or `text` in its place) translated again.
    private func changePair(_ pair: TranslatePair, explicit: Bool, text: String? = nil) {
        translatePair = pair
        if explicit { translateFrom = pair.other }
        Engine.shared?.settings.translatePair = pair
        if let text, text != nav.query { nav.query = text } else { onQuery?(nav.query) }
    }
}

/// From, the swap and To in Translate's line; a click does what Return on it does.
struct TranslateChips: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel

    var body: some View {
        let open = model.chip?.purpose, focus = model.chipFocus
        HStack(spacing: 8) {
            Button { model.openLanguages(from: true) } label: {
                LineChip(title: model.translateFrom.map(Translate.name) ?? "Auto", code: model.translateFrom,
                         symbol: model.translateFrom == nil ? "globe" : nil, focused: focus == 0 || open == .translateFrom)
            }
            .accessibilityLabel("From \(model.translateFrom.map(Translate.name) ?? "Auto")")
            Button { model.swapLanguages() } label: {
                Image(systemName: "arrow.left.arrow.right").font(style.font(\.caption)).foregroundStyle(style.color(\.text2))
                    .frame(width: 30, height: 30)
                    .overlay { Circle().strokeBorder(style.color(focus == 1 ? \.accent : \.line2)) }
                    .background { if focus == 1 { Circle().inset(by: -3).fill(style.color(\.accentSoft)) } }
                    .contentShape(.circle)
            }
            .accessibilityLabel("Swap languages")
            Button { model.openLanguages(from: false) } label: {
                LineChip(title: Translate.name(model.translateTarget), code: model.translateTarget, focused: focus == 2 || open == .translateTo)
            }
            .accessibilityLabel("To \(Translate.name(model.translateTarget))")
        }
        .buttonStyle(.plain).focusable(false)
    }
}

/// The text and its translation as two panes on the raised card, the arrow's disc on the hairline between: each pane's
/// eyebrow and language, its words at 17 pt, its count (and the engine) in the pane's foot. The card is the answer row:
/// Return copies it, a click runs it, a missing language's row says so in the translation's pane.
struct TranslatePanes: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel

    /// The card's room under the line: its panes and their insets.
    static let height: CGFloat = 224

    var body: some View {
        let nav = model.nav, row = nav.rows.first, typed = nav.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated: String? = if case .copy(let text)? = row?.target { text } else { nil }
        let on = row != nil && nav.selection == 0
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 0) {
            pane("Input", language: inputLanguage(typed), text: typed.isEmpty ? nil : typed, placeholder: "Type in any language.",
                 foot: "\(typed.count) characters")
            Rectangle().fill(style.color(\.line2)).frame(width: 1)
            pane("Translation", language: Translate.name(model.translateTarget), text: translated ?? row?.title,
                 placeholder: model.reading ? "Translating…" : "The translation shows here as you type.",
                 muted: translated == nil, foot: (translated.map { "\($0.count) characters · " } ?? "") + "Apple on-device")
        }
        .overlay {
            Image(systemName: "arrow.right").font(style.font(\.small)).foregroundStyle(style.color(\.text2))
                .frame(width: 34, height: 34)
                .background(style.color(\.panel), in: .circle)
                .overlay { Circle().strokeBorder(style.color(\.line2)) }
        }
        .frame(height: 200)
        .background(style.color(\.raised), in: shape)
        .overlay { shape.strokeBorder(style.color(on ? \.accentLine : \.line2)) }
        .overlay(alignment: .leading) { if on { InstrumentTick().padding(.leading, 4) } }
        .contentShape(.rect)
        .onTapGesture { if row != nil { model.click(at: 0) } }
        .padding(.horizontal, 10).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(nav.actions == nil && model.chip == nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint(translated.map { "Return copies \($0)" } ?? "")
    }

    /// "Auto-detect" before text, "English · detected" once read, the picked language's name when From is set.
    private func inputLanguage(_ typed: String) -> String {
        if let from = model.translateFrom { return Translate.name(from) }
        guard typed.count >= MenuNavigator.minimumQuery, let source = model.translateSource else { return "Auto-detect" }
        return "\(Translate.name(source)) · detected"
    }

    private func pane(_ title: String, language: String, text: String?, placeholder: String, muted: Bool = false, foot: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                InstrumentEyebrow(text: title)
                Spacer(minLength: 8)
                Text(language).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1)
            }
            .padding(.bottom, 10)
            Group {
                if let text {
                    Text(text).font(style.font(\.row, size: 17 / style.scale)).foregroundStyle(style.color(muted ? \.text2 : \.text))
                } else {
                    Text(placeholder).font(style.font(\.row, size: 14 / style.scale)).foregroundStyle(style.color(\.text3))
                }
            }
            .lineSpacing(3).lineLimit(5).truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text(foot).styleText(\.mono).foregroundStyle(style.color(\.text3)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .overlay(alignment: .top) { InstrumentRule() }
                .padding(.horizontal, -18)
        }
        .padding(.horizontal, 18).padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
