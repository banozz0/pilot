import PilotCore
import SwiftUI

// The HUDs in Toybox (card agent-bo-95423182, batch 5): the tip and an extension's alert, each
// on the panel's pop block (PopSurface: the 2 pt ink outline and 7 pt edge, no blur). The menu's language: the Pilot
// mark speaks the tip, a candy tile and a Fredoka title head a question, keycap buttons with the sun on the one to
// press, a sunk foot under an ink rule. The same models, actions, keys and words as Instrument's.

/// A tip: the Pilot mark, one line of Nunito with tabular digits (a count ticking up never shifts it), its one button a
/// keycap as far in from the block's edge as keeps their corners concentric.
struct ToyTip: View {
    @Environment(\.style) private var style
    let model: TipModel

    var body: some View {
        HStack(spacing: 12) {
            PilotMark(size: 28)
            Text(model.text).font(Toy.nunito(800, 15)).monospacedDigit().foregroundStyle(style.color(\.text))
            if let action = model.action { Button(action.title, action: action.run).buttonStyle(.pilot) }
        }
        .padding(.leading, 10).padding(.trailing, model.action == nil ? 20 : 8)
        .frame(minHeight: 52)
    }
}

/// A HUD that asks: a candy tile and the Fredoka title over what it is about, then its buttons at the right with the one
/// to press last and sun yellow; under an ink rule, what sits at its foot on the sunk fill.
struct ToyAsk<Buttons: View, Foot: View>: View {
    @Environment(\.style) private var style
    let symbol: String
    /// The tile's candy colour, by Toy.module's order.
    let module: Int
    let title: String
    var detail: String?
    @ViewBuilder var buttons: Buttons
    @ViewBuilder var foot: Foot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ToyTile(symbol: symbol, color: Toy.module(module, style), size: 36).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).styleText(\.title).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
                    if let detail { Text(detail).styleText(\.body).foregroundStyle(style.color(\.text2)) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.top, 18)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                buttons
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 14)
            foot
        }
    }
}

/// An extension's alert: a coral bell tile, its heading, its note, then its buttons as keycaps with the sun on the primary
/// one, last.
struct ToyExtensionAlert: View {
    let alert: Extension.AlertSpec
    var extra: AnyView?
    var press: (Int?) -> Void

    var body: some View {
        ToyAsk(symbol: "bell.fill", module: 3, title: alert.text, detail: alert.note) {
            extra
            ForEach(ExtensionAlertButton.all(alert).reversed()) { button in
                if button.primary { Button(button.title) { press(button.id) }.buttonStyle(.pilotPrimary) }
                else { Button(button.title) { press(button.id) }.buttonStyle(.pilot) }
            }
        } foot: {
            EmptyView()
        }
        .frame(minWidth: 320, alignment: .leading)
    }
}

/// The hold overlay in Toybox: the layer held as keycaps (Hyper's the sun) and its name in Fredoka over an ink rule; under
/// it the page's binds in Instrument's columns (InstrumentOverlay.columns), each module's under its eyebrow with a candy
/// dot in the module's colour, every bind its keycaps then what it does. The same rows and words as OverlayView.
struct ToyOverlay: View {
    @Environment(\.style) private var style
    let title: String
    let rows: [BindsPage.Row]
    /// As InstrumentOverlay's: the binds cut and the footer's link to Binds › More › Overlay.
    var more = 0
    var edit: (() -> Void)?
    /// The layer key whose sign leads the header; the engine's, else Caps Lock.
    var layerKeys = Engine.shared?.settings.layerKeys ?? [.capsLock]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                caps(title)
                Text(title).styleText(\.title).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 16)
                if title == "Hyper" { Text("Add Shift or Ctrl for more").styleText(\.caption).foregroundStyle(style.color(\.text3)) }
            }
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18).padding(.vertical, 14)
            ToyRule()
            if rows.isEmpty {
                Text("No binds on this layer yet.").styleText(\.body).foregroundStyle(style.color(\.text3))
                    .padding(.horizontal, 18).padding(.vertical, 18)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    let columns = InstrumentOverlay.columns(rows)
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                        if index > 0 { style.color(\.line2).frame(width: 2).padding(.vertical, 16) }
                        // A grid, so each column's words start past its widest key.
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                            ForEach(Array(column.enumerated()), id: \.offset) { _, line in
                                switch line {
                                case .group(let name, let first): eyebrow(name).padding(.top, first ? 0 : 8).gridCellColumns(2)
                                case .bind(let row): bind(row)
                                }
                            }
                        }
                        .fixedSize()
                        .padding(.horizontal, 18).padding(.vertical, 16)
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            OverlayFooter(more: more, edit: edit)
        }
        .frame(minWidth: 440, alignment: .leading)
    }

    /// A bind's or the layer's keys as caps, Hyper's the sun.
    private func caps(_ label: String) -> some View {
        let caps = InstrumentBindKeys.caps(label, layerKeys: layerKeys)
        return ToyKeys(keys: caps.filter { !$0.hyper }.map(\.text), hyper: caps.contains { $0.hyper })
    }

    private func eyebrow(_ name: String) -> some View {
        HStack(spacing: 6) {
            ToyDot(color: Toy.module(BindsKeyboard.module(name == "Pilot" ? Module.engine.rawValue : name), style))
            ToyEyebrow(text: name)
        }
        .accessibilityAddTraits(.isHeader)
    }

    /// A bind: its keys, then what it does.
    private func bind(_ row: BindsPage.Row) -> some View {
        GridRow {
            Group {
                if let key = row.key { caps(key) } else { Text("—").styleText(\.key).foregroundStyle(style.color(\.text3)) }
            }
            Text(row.label).styleText(\.body).foregroundStyle(style.color(\.text2))
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// The level HUD (card agent-bo-95423314): the brightness key itself, a keycap with the sun on it in its label colour, its
/// core the sun's colour, paler and its rays shorter as the level falls; the screen's name in Nunito and the percentage
/// in Fredoka; under them the slider's chunky track (ToySliderFace) filled in the sun; without a level, the status in the
/// second text colour in its place. One width.
struct ToyLevel: View {
    @Environment(\.style) private var style
    let model: LevelModel

    var body: some View {
        let level = LevelFace.level(model)
        // A keycap's label colour (ToyKeycap's), so the sun reads on the key in the dark too.
        let ink = style.color(level == nil ? \.text3 : \.text)
        let core = style.color(\.raised).mix(with: style.color(\.accent), by: level.map { 0.3 + 0.7 * $0 } ?? 0)
        HStack(spacing: 14) {
            LevelSun(level: level, slashed: model.reading == .noControl, size: 30, weight: 2.5, fill: core, ink: ink, outlined: true, core: 0.44)
                .frame(width: 40, height: 40)
                .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
                .background(Toy.block(style, fill: style.color(\.raised), radius: style.radii.key, edge: 4))
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.screen).font(Toy.nunito(800, 15)).foregroundStyle(style.color(\.text)).lineLimit(1)
                    Spacer(minLength: 0)
                    LevelPercent(percent: model.percent, number: Toy.fredoka(20), sign: Toy.nunito(800, 13),
                                 numberColor: style.color(\.text), signColor: style.color(\.text2))
                }
                Group {
                    if let level { ToyLevelBar(level: level) }
                    else { Text(model.status ?? "").font(Toy.nunito(700, 13)).foregroundStyle(style.color(\.text2)).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
            }
        }
        .padding(.leading, 12).padding(.trailing, 20).padding(.vertical, 12)
        .frame(width: 340)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LevelFace.label(model))
    }
}

/// The slider's track without its knob: a sunk capsule in the ink outline, the level an outlined capsule of sun; none at 0.
private struct ToyLevelBar: View {
    @Environment(\.style) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let level: Double

    var body: some View {
        let height: CGFloat = 14
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(style.color(\.sunken)).overlay { Capsule().strokeBorder(style.color(\.outline), lineWidth: 2) }
                Capsule().fill(style.color(\.accent)).overlay { Capsule().strokeBorder(style.color(\.outline), lineWidth: 2) }
                    .frame(width: max(height, g.size.width * level)).opacity(level > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .animation(LevelFace.motion(reduceMotion), value: level)
    }
}
