import PilotCore
import SwiftUI

/// Tiling › Focused window (page map, Sven 2026-10-17: off Look's Transparency block): the focused window's border, its
/// width and colour; Defocus's blur and dim with what sets it off; the shake that toggles it; and the contrast badge. The
/// same controls on the same Look as before; its keys stay `look.*`.
struct FocusedWindowBlock: View {
    @Environment(\.ink) private var ink
    /// Defocus's bind as bound now; none offscreen, where a page is drawn without an engine.
    @Environment(Engine.self) private var engine: Engine?
    let look: Look

    /// What each row does, the ⓘ's words.
    enum Info {
        static let border = "A line around the window in front, in the theme's accent or a colour you pick."
        static let borderWidth = "How thick that line is, in points."
        static let borderColour = "The line's colour: Theme follows the theme's accent, Custom keeps the one you pick."
        static let defocus = "How strongly the other windows blur, so the one in front stands out: Off, or 1 light to 5 heavy."
        static let defocusDim = "How dark the other windows go, from Off to 80% black, with the blur or without it."
        static let shake = "Shaking the mouse turns Dim other windows (Defocus) on or off."
        static let swings = "How many quick side-to-side swings count as a shake."
        static let within = "How fast those swings must come, in seconds."
        static let contrast = "How well Pilot's dimmest text reads over the brightest spot behind its glass. Amber means Pilot raised the surface to keep it readable."
    }

    var body: some View {
        @Bindable var look = look
        // Whole on Tiling's front again (Sven, 2026-11-11, after 2276; split front and More by simplify-pages T9).
        KitBlock(title: "Focused window", symbol: "macwindow") {
            BlockRow(first: true) { Toggle("Border on the focused window", isOn: $look.windowBorder).toggleStyle(.pilotSwitchRow(info: Info.border)) }
            BlockRow { label("Border width", Info.borderWidth); borderWidth }
            BlockRow { label("Border colour", Info.borderColour); borderColour }
            BlockRow {
                VStack(alignment: .leading, spacing: 1) {
                    label("Dim other windows", Info.defocus)
                    defocusHint.font(ink.ui(12))
                }
                .padding(.vertical, 7)
                defocusSteps
            }
            tuning
        }
    }

    /// Defocus's tuning and the contrast badge.
    @ViewBuilder private var tuning: some View {
        @Bindable var look = look
        BlockRow {
            label("How dark the others go", Info.defocusDim)
            defocusDimSlider
            defocusDimValue.frame(width: 38, alignment: .trailing)
        }
        BlockRow { Toggle("Shake to dim other windows", isOn: $look.defocusShake).toggleStyle(.pilotSwitchRow(info: Info.shake)) }
        BlockRow { label("How hard to shake", Info.swings); shakeSwings }
        BlockRow { label("Within", Info.within); shakeWithin }
        BlockRow { contrastBadge.font(ink.ui(12)).padding(.vertical, 6); InfoMark(text: Info.contrast) }
    }

    /// A row's label with its ⓘ beside it, taking the row's spare width.
    private func label(_ title: String, _ info: String) -> some View {
        HStack(spacing: 6) { Text(title); InfoMark(text: info) }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The focused window's border width in points (card agent-bo-95422950), still while the border is off.
    private var borderWidth: some View {
        @Bindable var look = look
        return Stepper(value: $look.windowBorderWidth, in: WindowBorder.widths) {
            Text("\(look.windowBorderWidth) pt").font(ink.mono(11.5)).foregroundStyle(ink.text2)
        }
        .disabled(!look.windowBorder)
        .accessibilityLabel("Border width").accessibilityValue("\(look.windowBorderWidth) points")
    }

    /// The border's colour, Theme (the accent) or Custom, still while the border is off.
    private var borderColour: some View {
        @Bindable var look = look
        return ColourChoicePicker(choice: $look.windowBorderColour, theme: look.theme.accent, label: "Border colour").disabled(!look.windowBorder)
    }

    /// The direction changes a shake takes (C2, 2026-10-09), still while the shake is off.
    private var shakeSwings: some View {
        @Bindable var look = look
        return Stepper(value: $look.defocusShakeSwings, in: ShakeDetector.swingsRange) {
            Text("\(look.defocusShakeSwings) swings").font(ink.mono(11.5)).foregroundStyle(ink.text2)
        }
        .disabled(!look.defocusShake)
        .accessibilityLabel("How hard to shake").accessibilityValue("\(look.defocusShakeSwings) swings")
    }

    /// The seconds those swings must fall within, a tenth a step, still while the shake is off.
    private var shakeWithin: some View {
        @Bindable var look = look
        let seconds = look.defocusShakeWithin.formatted(.number.precision(.fractionLength(1)))
        return Stepper(value: $look.defocusShakeWithin, in: ShakeDetector.withinRange, step: 0.1) {
            Text("\(seconds) s").font(ink.mono(11.5)).foregroundStyle(ink.text2)
        }
        .disabled(!look.defocusShake)
        .accessibilityLabel("Shake within").accessibilityValue("\(seconds) seconds")
    }

    /// Defocus's blur (card agent-bo-95423220): Off, then five steps from a light blur to a heavy one, a pick each.
    private var defocusSteps: some View {
        @Bindable var look = look
        return Segments(selection: $look.defocusStrength, options: Defocus.strengths.map { ($0, $0 == 0 ? "Off" : "\($0)") },
                        label: "Dim other windows")
    }

    /// Defocus's dim (Sven, 2026-10-16), Off to 80 % black, with the blur or without it.
    private var defocusDimSlider: some View {
        KitSlider(value: Binding(get: { Double(look.defocusDim) }, set: { if Int($0) != look.defocusDim { look.defocusDim = Int($0) } }),
                  range: Double(Defocus.dims.lowerBound)...Double(Defocus.dims.upperBound), step: 1, label: "How dark the others go")
    }

    private var defocusDimValue: some View {
        Text(look.defocusDim == 0 ? "Off" : "\(look.defocusDim)%").font(ink.mono(11.5)).foregroundStyle(ink.text2).fixedSize()
    }

    /// What sets Defocus off now: the shake while its switch is on, and its bind in mono, as keys are, or a nudge to bind one.
    private var defocusTrigger: Text {
        let key = engine?.binds.store.trigger(for: Defocus.actionID)
        var hint = AttributedString(Defocus.hint(key: key, shake: look.defocusShake))
        if let label = key?.label, let range = hint.range(of: label) { hint[range].font = ink.mono(11) }
        return Text(hint)
    }

    /// What Defocus does as set and what sets it off, or that it has nothing to do with Blur and Dim both off; with Reduce
    /// Transparency on and a blur picked, that it dims without the blur. Muted, the size its row gives.
    private var defocusHint: some View {
        let summary = Text(Defocus.summary(strength: look.defocusStrength, dim: look.defocusDim))
        return VStack(alignment: .leading, spacing: 0) {
            look.defocusStrength > 0 || look.defocusDim > 0 ? Text("\(summary) \(defocusTrigger).") : summary
            if look.reduceTransparency, look.defocusStrength > 0 { Text("Reduce transparency is on, so other windows only dim.") }
        }
        .foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
    }

    /// The dimmest body text against the brightest spot behind it: green, or amber once the floor raised the surface.
    private var contrastBadge: some View {
        let values = look.layers
        let ratio = values.contrast.formatted(.number.precision(.fractionLength(1)))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(values.lifted ? ink.yellow : ink.green).frame(width: 7, height: 7)
                Text("Text stays readable: \(Text("\(ratio):1").font(ink.mono(11.5)))\(values.lifted ? ", floor raised" : "")")
                    .foregroundStyle(ink.text2)
            }
            .lineLimit(1)
            if look.reduceTransparency {
                Text("Reduce transparency is on, so the window is solid.").foregroundStyle(ink.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 14)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
