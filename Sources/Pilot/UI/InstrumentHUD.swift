import PilotCore
import SwiftUI

// The HUDs in Instrument (mockup A, card agent-bo-95423181, ADR 0008): the tip, the window-rescue prompt and an
// extension's alert, each on the panel's pop face (PopSurface). The same models, actions, keys and words as
// Toybox's; only the drawing is Instrument's.

/// A tip: one line of Geist with tabular digits, so a count ticking up never shifts it; its one button raised, as far in
/// from the face's edge as keeps its corners concentric with the face's. 44 pt high with a button or without.
struct InstrumentTip: View {
    @Environment(\.style) private var style
    let model: TipModel

    var body: some View {
        let inset = style.radii.pop - style.radii.control
        HStack(spacing: 14) {
            Text(model.text).monospacedDigit().styleText(\.strong).foregroundStyle(style.color(\.text))
            if let action = model.action {
                Button(action.title, action: action.run).buttonStyle(InstrumentButtonStyle(kind: .raised))
            }
        }
        .padding(.leading, 18).padding(.trailing, model.action == nil ? 18 : inset)
        .frame(height: style.density.control + 2 * inset)
    }
}

/// A HUD that asks: its title, what it is about in the second text colour, then its buttons at the right, the one
/// primary last; under a hairline, what sits at its foot.
private struct InstrumentAsk<Buttons: View, Foot: View>: View {
    @Environment(\.style) private var style
    let title: String
    var detail: String?
    @ViewBuilder var buttons: Buttons
    @ViewBuilder var foot: Foot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).styleText(\.title).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
                if let detail { Text(detail).styleText(\.body).foregroundStyle(style.color(\.text2)) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18).padding(.top, 16)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                buttons
            }
            .padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 14)
            foot
        }
    }
}

/// An extension's alert: its heading, its note, then its buttons raised with the primary one last, at the right.
struct InstrumentExtensionAlert: View {
    let alert: Extension.AlertSpec
    var extra: AnyView?
    var press: (Int?) -> Void

    var body: some View {
        InstrumentAsk(title: alert.text, detail: alert.note) {
            extra
            ForEach(ExtensionAlertButton.all(alert).reversed()) { button in
                Button(button.title) { press(button.id) }.buttonStyle(InstrumentButtonStyle(kind: button.primary ? .primary : .raised))
            }
        } foot: {
            EmptyView()
        }
        .frame(minWidth: 300, alignment: .leading)
    }
}

/// The level HUD (card agent-bo-95423314): Lucide's line sun on a tile, its rays growing with the level; the screen's name in
/// Geist and the percentage in Geist Mono; under them a meter of the sixteen steps a held key takes, lit in the signal
/// colour; without a level, the status in the second text colour in its place. One width.
struct InstrumentLevel: View {
    @Environment(\.style) private var style
    let model: LevelModel

    var body: some View {
        let level = LevelFace.level(model)
        let ink = style.color(level == nil ? \.text3 : \.text2)
        HStack(spacing: 14) {
            LevelSun(level: level, slashed: model.reading == .noControl, size: 22, weight: 1.5, fill: .clear, ink: ink, outlined: true)
                .opacity(level.map { 0.55 + 0.45 * $0 } ?? 1)
                .instrumentTile(36)
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.screen).styleText(\.strong).foregroundStyle(style.color(\.text)).lineLimit(1)
                    Spacer(minLength: 0)
                    LevelPercent(percent: model.percent, number: style.font(\.key, size: 13), sign: style.font(\.key, size: 11),
                                 numberColor: style.color(\.text), signColor: style.color(\.text3))
                }
                Group {
                    if let level { InstrumentLevelMeter(level: level) }
                    else { Text(model.status ?? "").styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, minHeight: 15, maxHeight: 15, alignment: .leading)
            }
        }
        .padding(.leading, 14).padding(.trailing, 18).padding(.vertical, 14)
        .frame(width: 320)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LevelFace.label(model))
    }
}

/// The level as the sixteen steps, each a 4 pt capsule on the track's line, lit in the signal colour up to the level (a
/// part-lit step for a level between steps).
private struct InstrumentLevelMeter: View {
    @Environment(\.style) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let level: Double

    var body: some View {
        steps(\.line2)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    steps(\.accent).mask(alignment: .leading) { Rectangle().frame(width: g.size.width * level) }
                }
            }
            .frame(height: 4)
            .animation(LevelFace.motion(reduceMotion), value: level)
    }

    private func steps(_ colour: KeyPath<StyleColors, Paint>) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<LevelFace.steps, id: \.self) { _ in Capsule().fill(style.color(colour)) }
        }
    }
}
