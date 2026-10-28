import AppKit
import PilotCore
import SwiftUI

/// Hyper+Space › About (Sven 2026-10-24, Q443, Q445): Omarchy's About in Pilot's look, in the list's place. Pilot's mark
/// on the left, as tall as the three cards beside it and in the theme's accent (Q447): the app icon's four tiles, the
/// first lit. On the right, Hardware, Software, and Age / Uptime / Update, each on the style's raised card as Stats' are.
/// Read once as it shows (AboutFacts), never again while it shows; Escape closes the menu.
struct MenuAboutScreen: View {
    @Environment(\.style) private var style
    @State private var facts: AboutFacts? = AboutFacts.seed
    /// How many displays Hardware lists, which sets the height before the facts are read.
    let displays: Int

    static let inset: CGFloat = 10, gap: CGFloat = 8, row: CGFloat = 20, logoWidth: CGFloat = 200, tileGap: CGFloat = 12
    /// Software's rows: the five read, then Theme and Font; Age / Uptime / Update's.
    static let softwareRows = 7, ageRows = 3

    /// A card's height with `rows` rows: its eyebrow, the rows, its padding.
    static func card(_ rows: Int) -> CGFloat { 12 + 14 + 6 + CGFloat(rows) * row + 12 }

    /// The three cards stacked, which the mark matches.
    static func cards(displays: Int) -> CGFloat {
        card(AboutFacts.hardwareRows(displays: displays)) + card(softwareRows) + card(ageRows) + 2 * gap
    }

    /// What the screen takes in the list's place, which the panel's sizers add (MenuModel's).
    static func height(displays: Int) -> CGFloat { cards(displays: displays) + 2 * inset + foot }
    /// Room under the cards, so the panel's corner never meets the last card.
    static let foot: CGFloat = 6

    var body: some View {
        let tall = Self.cards(displays: displays)
        HStack(alignment: .center, spacing: 18) {
            mark.frame(width: Self.logoWidth, height: tall)
            VStack(spacing: Self.gap) {
                card("Hardware", rows: facts?.hardware ?? [], count: AboutFacts.hardwareRows(displays: displays))
                card("Software", rows: (facts?.software ?? []) + (facts == nil ? [] : [theme, font]), count: Self.softwareRows)
                card("Age / Uptime / Update", rows: facts?.age ?? [], count: Self.ageRows)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(Self.inset).padding(.bottom, Self.foot)
        .frame(maxWidth: .infinity, alignment: .top)
        .task {
            guard facts == nil else { return }
            facts = await AboutFacts.read()
        }
    }

    /// The app icon's four tiles, the first in the accent and the others in the text colour, stretched to the cards' height.
    private var mark: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return Grid(horizontalSpacing: Self.tileGap, verticalSpacing: Self.tileGap) {
            GridRow { shape.fill(style.color(\.accent)); shape.fill(style.color(\.text)) }
            GridRow { shape.fill(style.color(\.text)); shape.fill(style.color(\.text)) }
        }
        .accessibilityLabel("Pilot")
    }

    /// The theme by name, its colours as dots, and the style it is drawn in.
    private var theme: AboutFacts.Row {
        AboutFacts.Row(label: "Theme", value: Look.shared.theme.name, note: Look.shared.style.title)
    }

    /// The style's text face and its numbers' face.
    private var font: AboutFacts.Row {
        func family(_ role: TypeRole) -> String { if case .bundled(let face) = role.face { face.family } else { "System" } }
        return AboutFacts.Row(label: "Font", value: family(style.type.body), note: family(style.type.mono))
    }

    private func card(_ title: String, rows: [AboutFacts.Row], count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).lineLimit(1)
                .frame(height: 14, alignment: .leading).padding(.bottom, 6)
            ForEach(rows) { line($0) }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.card(count), alignment: .top)
        .modifier(MenuStatsCardFace())
        .accessibilityElement(children: .combine)
    }

    private func line(_ row: AboutFacts.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(row.label).font(style.font(\.caption)).foregroundStyle(style.color(\.text3))
                .frame(width: 76, alignment: .leading)
            Group {
                if row.mono { Text(row.value).font(style.font(\.mono, size: 12)) } else { Text(row.value).styleText(\.body) }
            }
            .foregroundStyle(style.color(\.text)).layoutPriority(1)
            if let share = row.share {
                Text("\(Int((share * 100).rounded()))%").font(style.font(\.mono, size: 12)).foregroundStyle(style.color(\.accent))
                    .padding(.leading, 6)
            }
            if row.label == "Theme" { dots.padding(.leading, 8) }
            if let note = row.note {
                Text(note).font(style.font(\.caption)).foregroundStyle(style.color(\.text3)).padding(.leading, 8)
            }
        }
        .monospacedDigit().lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: .infinity, minHeight: Self.row, maxHeight: Self.row, alignment: .leading)
    }

    /// The theme's colours: its text, accent, second and third, then good, amber and problem.
    private var dots: some View {
        let t = Look.shared.theme
        return HStack(spacing: 4) {
            ForEach(Array([t.text, t.accent, t.second, t.third, t.good, t.amber, t.problem].enumerated()), id: \.offset) {
                Circle().fill(Color(Paint($0.element))).overlay { Circle().strokeBorder(style.color(\.line2)) }.frame(width: 10, height: 10)
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        .accessibilityHidden(true)
    }
}
