import AppKit
import PilotCore
import SwiftUI

/// What Line draws as Classic did (menu Rail and Classic T8; Classic Shell since Q139, Line's root since Q165): the root as a
/// terminal pane's list, JetBrains Mono in every role, rule headings and a cursorline. Classic itself, a look of its own,
/// went in the feature trim (2026-11-19); Line is the one Instrument menu.
enum ClassicMenu {
    /// `tokens` with every role in JetBrains Mono (notes › Classic: Face), regular with keys and titles a weight up: the search
    /// at 18, a row at 16 (the root's) or 15, meta at 12.5; headings in lowercase, as Omarchy's. The sizes are as drawn: the mockups' are already a step up. Line
    /// icons stay the system's symbols.
    static func face(_ tokens: StyleTokens) -> StyleTokens {
        func mono(_ size: Double, _ weight: Int = 400, tracking: Double = 0) -> TypeRole {
            TypeRole(face: .bundled(StyleTokens.jetBrainsMono(weight)), size: size, tracking: tracking)
        }
        var type = tokens.type
        type.body = mono(13.5)
        type.strong = mono(13.5, 600)
        type.caption = mono(12.5)
        type.small = mono(11.5)
        type.title = mono(14, 600)
        type.pageTitle = mono(16, 600)
        type.display = mono(type.display.size, 500)
        type.mono = mono(12.5)
        type.eyebrow = mono(12.5)
        type.key = mono(11.5, 500)
        type.search = mono(18)
        type.row = mono(15, 500)
        type.keyName = mono(11.5, 500)
        type.barLabel = mono(11, 500)
        type.barStrong = mono(12.5, 600)
        type.barTime = mono(12.5, 500)
        return tokens.retyped(type)
    }

    /// The root's row face: 16 pt, a step over a list's.
    static let rootRow: Double = 16
}

// MARK: - Kinds

/// The kinds Tab steps through, as Classic's status line and Line's foot count them.
enum ClassicKinds {
    /// A kind's count (Menu.count(of:)): All's is what the typed search found; blank where the navigator counts nothing
    /// (files under All, files and packages before a search).
    @MainActor static func count(of kind: MenuEntry.Kind?, _ model: MenuModel) -> String? {
        guard let kind else {
            guard !model.nav.query.isEmpty else { return nil }
            return String(model.nav.rows.count { !$0.isOffer })
        }
        return model.nav.count(of: kind).map(String.init)
    }

    /// A kind at zero: the third text where it reads at 4.5:1 on the panel, else the second.
    static func quiet(_ style: StyleTokens) -> KeyPath<StyleColors, Paint> {
        Contrast.ratio(style.colors.text3.rgb, style.colors.panel.rgb) >= 4.5 ? \.text3 : \.text2
    }
}

// MARK: - Root

/// The root (frame D1): under `── go to`, the root's rows, the navigator's own, so the arrows, Return and → walk them;
/// no recents or pins over them (Sven 2026-10-20: a simple menu). Update and Clean say what waits in them. Line draws it
/// at its 36 pt rows (`row`).
struct ClassicRoot: View {
    @Bindable var model: MenuModel
    let pointer: PointerTrack
    var row: CGFloat = MenuPanelSize.classicRow

    var body: some View {
        let nav = model.nav, pointing = model.pointedRows(pointer)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ClassicHeading(title: "go to", height: MenuPanelSize.classicRootHeading)
                    ForEach(Array(nav.rows.enumerated()), id: \.element.id) { index, entry in
                        ClassicRootRow(row: entry, on: index == nav.selection, right: waiting(entry), height: row)
                            .pointerRow(pointing, index)
                            .id(entry.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .scrollsToSelection(pointing) { _, _ in if let id = nav.selected?.id { proxy.scrollTo(id) } }
        }
        .allowsHitTesting(nav.actions == nil)
    }

    /// What waits in a branch: Update's count, Clean's size (MenuModel.waiting).
    private func waiting(_ row: MenuEntry) -> String? {
        guard let detail = model.waiting.first(where: { $0.target == row.target })?.detail else { return nil }
        return row.target == .branch(.update) ? "\(detail) waiting" : detail
    }
}

/// A root row, 38 pt (Line's 36): its icon or glyph, its name at 16 pt, at its right `right`, in the accent when it is a
/// row's keys (`keyed`), else quiet (what waits in a branch, a window's workspace); current, the cursorline with its
/// glyph in the accent.
private struct ClassicRootRow: View {
    @Environment(\.style) private var style
    let row: MenuEntry
    let on: Bool
    let right: String?
    var keyed = false
    var height: CGFloat = MenuPanelSize.classicRow

    var body: some View {
        HStack(spacing: 12) {
            ClassicIcon(row: row, on: on)
            Text(row.shownTitle).font(style.font(\.row, size: ClassicMenu.rootRow / style.scale)).foregroundStyle(style.color(\.text))
            Spacer(minLength: 8)
            if let right {
                Text(right).styleText(\.caption).foregroundStyle(style.color(keyed ? \.accentText : \.text3))
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .cursorline(on)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A heading as a rule with its name in it, `── windows ─────────`: lowercase, in the quiet colour, a terminal's way of
/// dividing a list (Classic Shell, Q139).
struct ClassicHeading: View {
    @Environment(\.style) private var style
    let title: String
    var height: CGFloat = MenuPanelSize.instrumentHeading

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(style.color(\.line2)).frame(width: 12, height: 1)
            Text(title.lowercased()).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1).fixedSize()
            Rectangle().fill(style.color(\.line)).frame(height: 1)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Classic's current row: a flat band edge to edge in the raised colour with a 3 pt accent bar in the gutter, no corner,
    /// no inset: a terminal's current line, not a launcher's pill (Q139).
    func cursorline(_ on: Bool) -> some View { modifier(ClassicCursorline(on: on)) }
}

private struct ClassicCursorline: ViewModifier {
    @Environment(\.style) private var style
    let on: Bool

    func body(content: Content) -> some View {
        content
            .background(on ? style.color(\.raised) : .clear)
            .overlay(alignment: .leading) { if on { Rectangle().fill(style.color(\.accent)).frame(width: 3) } }
    }
}

/// A row's icon: an app's own, a window's tile, an emoji, or its line glyph in the accent while it is current.
private struct ClassicIcon: View {
    @Environment(\.style) private var style
    let row: MenuEntry
    let on: Bool
    var tile: CGRect?

    var body: some View {
        if case .branch(let branch) = row.target, row.icon == nil {
            Image(systemName: InstrumentRowIcon.glyph(of: branch)).font(style.font(\.icon))
                .foregroundStyle(style.color(on ? \.accentText : \.text2))
                .frame(width: 22, height: 22).accessibilityHidden(true)
        } else {
            InstrumentRowIcon(row: row, on: on, tile: tile)
        }
    }
}
