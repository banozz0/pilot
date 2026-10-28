import PilotCore
import SwiftUI

/// The Ask agent's plan as the chat draws it (Ask Pilot, Sven Q178): `pilot plan apply`'s one question, its rows a line
/// each instead of one block of text. A bind's line leads with its key as keycaps and says Free or Taken; a setting's or a
/// list's says old → new; a row that asks on its own today (a shell bind, a confirmed setting) names that question under
/// it, as the Allow covers it too. Who asks and the gate's warning stay under the rows. One answer for the lot: Apply when
/// every row only changes Pilot's own settings, the filled button; when a row asks on its own, Discard stays first and
/// filled, as every other Allow question in the chat. Discard denies, which empties the plan.
struct AIPlanCard: View {
    @Environment(\.ink) private var ink
    let asking: AIChatModel.Asking
    let answer: (Bool) -> Void

    private var rows: [ControlPlan.Change] { asking.ask.rows }
    /// A row that asks on its own: the card keeps the gate's Deny-first order.
    private var asksOnItsOwn: Bool { rows.contains { $0.asks != nil } }
    /// The keycaps column's width, once any row has a key.
    private var keyed: Bool { rows.contains { $0.key != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(ControlGate.Ask.visible(asking.ask.title)).font(ink.ui(13, .semibold)).foregroundStyle(ink.text)
                Spacer(minLength: 12)
                Text(AllowPromptView.question(asking.program)).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.middle)
            }
            .padding(.bottom, 6)
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                line(row).overlay(alignment: .top) { if i > 0 { ink.line.frame(height: 1) } }
            }
            Text(AllowPromptView.warning).font(ink.ui(11)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            HStack(spacing: 8) {
                if asksOnItsOwn {
                    Button("Discard") { answer(false) }.buttonStyle(PilotButtonStyle(primary: true)).fixedSize()
                    Button(applyTitle) { answer(true) }.buttonStyle(PilotButtonStyle()).fixedSize()
                } else {
                    Button(applyTitle) { answer(true) }.buttonStyle(PilotButtonStyle(primary: true)).fixedSize()
                    Button("Discard") { answer(false) }.buttonStyle(PilotButtonStyle()).fixedSize()
                }
            }
            .padding(.top, 10)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(ink.well, in: .rect(cornerRadius: ink.blockRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous).strokeBorder(ink.accent.opacity(0.55), lineWidth: ink.stroke) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AllowPromptView.thing(asking.ask))
    }

    /// "Apply 3 changes": the plan's own title is the verb.
    private var applyTitle: String { rows.count == 1 ? "Apply change" : "Apply \(rows.count) changes" }

    private func line(_ row: ControlPlan.Change) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                if keyed {
                    Group { if let key = row.key { AIPlanKeycaps(key: key) } else { Color.clear.frame(height: 1) } }
                        .frame(width: 112, alignment: .leading)
                }
                Text(ControlGate.Ask.visible(row.what)).font(ink.ui(13, .medium)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(change(row)).font(ink.mono(11)).foregroundStyle(ink.text2).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(-1)
                if let free = row.free {
                    Text(free ? "Free" : "Taken").font(ink.ui(11.5, .medium)).foregroundStyle(free ? ink.muted : ink.red).fixedSize()
                }
            }
            if let asks = row.asks {
                Text("Also allows \(ControlGate.Ask.visible(asks.text))").font(ink.mono(11)).foregroundStyle(ink.accentText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, keyed ? 122 : 0)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    /// A bind with its key shows the key it leaves ("was Hyper+K") only when it had one; anything else, old → new.
    private func change(_ row: ControlPlan.Change) -> String {
        if row.key != nil { return row.old == "none" || row.old.isEmpty ? "" : "was \(ControlGate.Ask.visible(row.old))" }
        return "\(ControlGate.Ask.visible(row.old)) → \(ControlGate.Ask.visible(row.new))"
    }
}

/// "Hyper+L" as small keycaps in the style's key fill.
struct AIPlanKeycaps: View {
    @Environment(\.ink) private var ink
    let key: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.caps(key).enumerated()), id: \.offset) { _, cap in
                Text(cap).font(ink.ui(11, .medium)).foregroundStyle(ink.text2)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(ink.keyFill, in: .rect(cornerRadius: 4, style: .continuous))
            }
        }
        .accessibilityLabel(key)
    }

    /// "Hyper+L" → Hyper, L; "Hyper++" → Hyper, +.
    static func caps(_ key: String) -> [String] {
        let plus = key.hasSuffix("++")
        return key.dropLast(plus ? 2 : 0).split(separator: "+").map(String.init) + (plus ? ["+"] : [])
    }
}
