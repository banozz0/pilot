import AppKit
import PilotCore
import SwiftUI

// The menu's answer cards (menu Rail and Classic T7, frames B4–B6; SuperCmd's expression → result cards, Sven): the first
// answer row of a sum, money, a time, a date, a translation or a colour, drawn as a card in the list's top slot. The card
// is that row: it is what Return copies, the arrows leave it for the Ask AI row under it, a click runs it. Only the
// drawing changes; every word on it comes from the row and what was typed.

/// What an answer card shows, read from the answer row and the search: what was typed on the left, the result on the
/// right, each with a chip saying what it is; a colour's card draws the colour instead.
struct MenuAnswer: Equatable {
    enum Kind: Equatable { case calculation, translation, colour(UInt32) }

    let kind: Kind
    /// The left side: what was asked (the sum, the text to translate).
    let expression: String
    let expressionChip: String
    /// The right side: the result as Return copies it, its unit apart (13.67017384 · mi).
    let value: String
    let unit: String?
    let resultChip: String
    /// What the row says besides the result (the rates' day, a time's place), under the card; nil when it only repeats
    /// the expression.
    let note: String?

    /// The eyebrow over the card.
    var eyebrow: String {
        switch kind {
        case .calculation: "Calculator"
        case .translation: "Translation"
        case .colour: "Colour"
        }
    }

    /// The card for `row`, or nil when the row is no answer that copies a result: a reminder, a quicklink, a script, an
    /// extension's answer, ask …, a translation's Download row.
    init?(_ row: MenuEntry, query: String, branch: MenuBranch?) {
        guard row.isAnswer, case .copy(let copied) = row.target else { return nil }
        let typed = query.trimmingCharacters(in: .whitespaces)
        // "Spanish → English · Return copies", "= 22 km to mi · Return copies", "= 40 EUR · rates from 2026-10-14 · …".
        let parts = (row.detail ?? "").components(separatedBy: " · ").filter { !$0.isEmpty && $0 != "Return copies" }
        if row.home == .translate {
            let pair = parts.first?.components(separatedBy: " → ") ?? []
            kind = .translation
            expression = Translate.query(for: query, in: branch) ?? typed
            expressionChip = pair.count == 2 ? "\(pair[0]) · detected" : "Detected"
            (value, unit) = (copied, nil)
            resultChip = pair.count == 2 ? pair[1] : "Translation"
            note = nil
        } else if copied.hasPrefix("#"), let colour = ColourAnswer.value(copied) {
            kind = .colour(colour)
            (expression, expressionChip) = (typed, "Colour")
            (value, unit) = (copied, nil)
            resultChip = "Hex"
            note = nil
        } else {
            kind = .calculation
            if let first = parts.first, first.hasPrefix("= ") {
                expression = String(first.dropFirst(2))
                note = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil
            } else {
                expression = typed
                note = parts.isEmpty ? nil : parts.joined(separator: " · ")
            }
            expressionChip = "Expression"
            (value, unit) = Self.split(copied)
            resultChip = Self.chip(value: value, unit: unit)
        }
    }

    /// "13.67017384 mi" as its number and its unit; a result with no unit ("87", "14:30", "Fri 13 Nov 2026") stays whole.
    static func split(_ result: String) -> (String, String?) {
        guard let m = result.wholeMatch(of: /(-?[\d.,]+) ([^\s\d]+)/) else { return (result, nil) }
        return (String(m.1), String(m.2))
    }

    /// The result's chip: Money for a currency's code, Time for a clock's time, else Result. A unit's quantity (Length,
    /// Mass) is the calculator's own table, private to PilotCore, so a conversion reads Result.
    static func chip(value: String, unit: String?) -> String {
        if let unit, unit.wholeMatch(of: /[A-Z]{3}/) != nil { return "Money" }
        if value.wholeMatch(of: /\d{1,2}:\d{2}/) != nil { return "Time" }
        return "Result"
    }
}

extension MenuModel {
    /// The card the list draws in place of row `index`: the first row when it is an answer that copies a result, in the
    /// Rail and in Classic (at Classic's 6 pt corner, T8).
    func answerCard(_ row: MenuEntry, at index: Int) -> MenuAnswer? {
        // Define's rows copy text too, but its pane draws them (DefinePane).
        guard index == 0, row.home != .define else { return nil }
        return MenuAnswer(row, query: nav.query, branch: nav.branch)
    }
}

/// The card: what was asked and its chip on the left, a 34 pt arrow disc on the hairline between, the result on the right
/// in mono at 30 pt with its unit at 22 and its chip; a colour's swatch, ramp and formats instead. On the raised surface,
/// at least 158 pt tall; the current row's tick at its edge while it is the selection.
struct AnswerCard: View {
    @Environment(\.style) private var style
    let answer: MenuAnswer
    let on: Bool
    /// 12 in the Rail; Classic's is 6 (notes › Answer cards).
    var radius: CGFloat = 12

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if case .colour(let colour) = answer.kind {
                    ColourCard(colour: colour, formats: ColourAnswer.formats(colour))
                } else {
                    sides
                }
            }
            .background(style.color(\.raised), in: shape)
            .overlay { shape.strokeBorder(style.color(on ? \.accentLine : \.line2)) }
            .overlay(alignment: .leading) { if on { InstrumentTick().padding(.leading, 4) } }
            if let note = answer.note {
                Text(note).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 6)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint("Return copies \(answer.value)\(answer.unit.map { " \($0)" } ?? "")")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private var label: String {
        if case .colour = answer.kind { return "Colour \(answer.value)" }
        return "\(answer.expression), \(answer.expressionChip), is \(answer.value)\(answer.unit.map { " \($0)" } ?? ""), \(answer.resultChip)"
    }

    /// Points as the mockup draws them: the menu's faces grow by its scale (C3), and the mockup's sizes are already a
    /// step up.
    private func pt(_ size: Double) -> Double { size / style.scale }

    private var sides: some View {
        let translation = answer.kind == .translation
        return HStack(spacing: 0) {
            side(chip: answer.expressionChip) {
                Text(answer.expression).font(style.font(\.strong, size: pt(27))).tracking(-0.5)
                    .foregroundStyle(style.color(\.text))
            }
            Rectangle().fill(style.color(\.line2)).frame(width: 1)
                .overlay {
                    Image(systemName: "arrow.right").font(style.font(\.small)).foregroundStyle(style.color(\.text2))
                        .frame(width: 34, height: 34)
                        .background(style.color(\.panel), in: .circle)
                        .overlay { Circle().strokeBorder(style.color(\.line2)) }
                }
                .frame(width: 44)
            side(chip: answer.resultChip) {
                if translation {
                    Text(answer.value).font(style.font(\.strong, size: pt(27))).tracking(-0.5).foregroundStyle(style.color(\.text))
                } else {
                    let number = Text(answer.value).font(style.font(\.mono, size: pt(30))).foregroundStyle(style.color(\.text))
                    let unit = Text(answer.unit.map { " \($0)" } ?? "").font(style.font(\.mono, size: pt(22))).foregroundStyle(style.color(\.text2))
                    Text("\(number)\(unit)").monospacedDigit().tracking(-0.6)
                }
            }
        }
        .frame(minHeight: 158)
    }

    /// One side: its words over its chip, centred.
    private func side(chip: String, @ViewBuilder _ text: () -> some View) -> some View {
        VStack(spacing: 10) {
            text().lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.5)
            Text(chip).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(style.color(\.sunken), in: .capsule)
                .overlay { Capsule().strokeBorder(style.color(\.line)) }
        }
        .padding(.horizontal, 16).padding(.vertical, 22)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Colour

/// A colour's card (frame B6): a 230 pt column with the swatch, the hex and rgb on it, and the colour's 7-step ramp under
/// it; beside it the five formats. The clipboard's preview (T10) composes the same swatch, ramp and formats at its width.
struct ColourCard: View {
    let colour: UInt32
    let formats: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 8) {
                ColourSwatch(colour: colour, hex: formats.first ?? ColourAnswer.hex(colour), rgb: formats.dropFirst().first, height: 118)
                ColourRamp(colour: colour)
            }
            .frame(width: 230)
            ColourFormats(formats: formats)
        }
        .padding(12)
    }
}

/// The colour itself with its hex and rgb on it, in whichever of a dark or a light ink of the colour reads better.
struct ColourSwatch: View {
    @Environment(\.style) private var style
    let colour: UInt32
    let hex: String
    var rgb: String?
    var height: CGFloat

    var body: some View {
        let ink = Color(rgb: AnswerInk.ink(on: colour))
        VStack(alignment: .leading, spacing: 2) {
            Text(hex).font(style.font(\.mono, size: 20 / style.scale)).tracking(-0.4)
            if let rgb { Text(rgb).font(style.font(\.mono, size: 12 / style.scale)).opacity(0.8) }
        }
        .foregroundStyle(ink)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .bottomLeading)
        .background(Color(rgb: colour), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.08)) }
        .accessibilityElement(children: .combine)
    }
}

/// Seven steps of the colour, lightest to darkest, the colour itself in the middle.
struct ColourRamp: View {
    let colour: UInt32

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(AnswerInk.ramp(colour).enumerated()), id: \.offset) { _, step in
                RoundedRectangle(cornerRadius: 4).fill(Color(rgb: step)).frame(height: 16)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The five formats as a key–value list, each on a hairline: HEX, RGB, HSL, HSB, SWIFTUI.
struct ColourFormats: View {
    @Environment(\.style) private var style
    let formats: [String]

    static let names = ["Hex", "RGB", "HSL", "HSB", "SwiftUI"]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
            ForEach(Array(zip(Self.names, formats)), id: \.0) { name, value in
                GridRow {
                    Text(name.uppercased()).font(style.font(\.mono, size: 11.3 / style.scale)).tracking(0.7)
                        .foregroundStyle(style.color(\.text3))
                    Text(value).font(style.font(\.mono, size: 12.4 / style.scale)).foregroundStyle(style.color(\.text2))
                        .lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                // One hairline under the whole row, across the gap between its name and its value.
                GridRow { Rectangle().fill(style.color(\.line)).frame(height: 1).gridCellColumns(2) }
            }
        }
    }
}

enum AnswerInk {
    /// Lightest to darkest: the colour toward white at 80, 55 and 25 %, itself, then toward black at 33, 56 and 77 % (the
    /// design page's ramp for #2BC4F0).
    static func ramp(_ colour: UInt32) -> [UInt32] {
        let c = Contrast.rgb(colour), white: [Double] = [255, 255, 255], black: [Double] = [0, 0, 0]
        return [0.8, 0.55, 0.25].map { Contrast.hex(Contrast.mix(white, c, $0)) } + [colour & 0xFFFFFF]
            + [0.33, 0.56, 0.77].map { Contrast.hex(Contrast.mix(black, c, $0)) }
    }

    /// The words on a swatch: the colour taken almost to black, or almost to white, whichever reads better on it.
    static func ink(on colour: UInt32) -> UInt32 {
        let c = Contrast.rgb(colour)
        let dark = Contrast.hex(Contrast.mix([0, 0, 0], c, 0.85)), light = Contrast.hex(Contrast.mix([255, 255, 255], c, 0.92))
        return Contrast.ratio(dark, colour) >= Contrast.ratio(light, colour) ? dark : light
    }
}

extension Color {
    /// A colour answer's 0xRRGGBB, in sRGB (the card's swatch, Line's search line).
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
