import PilotCore
import SwiftUI

/// Tiling's focused window (page map, Sven 2026-10-17): Border and Dim other windows, each one block with its preset at its
/// head, Off, Soft, Strong or Custom (pilot-ui-redesign T16, S1 B, round 1 shot 1b), and its exact rows under it (the
/// Tiling pass, Sven on build 3223: "only this page looks a bit bad now", the presets and the rows they set were two
/// blocks apart). The presets are a view over the rows (T15's `BorderLook` and `DimLook`, Open question 10): a pick
/// writes them, and Custom is any mix no pick writes. Dim adds the shake's switch and tuning, what sets Defocus off and
/// the contrast badge. Each block is a place a link or the search lands on; its keys stay `look.*`.
struct FocusedWindowBlock: View {
    @Environment(\.ink) private var ink
    /// Defocus's bind as bound now; none offscreen, where a page is drawn without an engine.
    @Environment(Engine.self) private var engine: Engine?
    var look: Look = .shared
    /// Which block: Border (`.focusedBorder`) or Dim other windows (`.focusedDim`).
    let place: AppSection

    /// What each row does, the ⓘ's words.
    enum Info {
        static let border = "A line around the window in front. Soft is 2 pt and Strong 4 pt, both in the theme's accent. Custom is any other width or colour, set below."
        static let dim = "The other windows blur and darken so the one in front stands out. Soft blurs lightly and darkens 18%, Strong blurs most and darkens 40%. Custom is any other mix, set below."
        static let shake = "Shaking the mouse turns Dim other windows on or off."
        static let borderWidth = "How thick the line around the window in front is, in points."
        static let borderColour = "The line's colour: Theme follows the theme's accent, Custom keeps the one you pick."
        static let blur = "How strongly the other windows blur: Off, or 1 light to 5 heavy."
        static let darken = "How dark the other windows go, from Off to 80% black, with the blur or without it."
        static let swings = "How many quick side-to-side swings count as a shake."
        static let within = "How fast those swings must come, in seconds."
        static let contrast = "How well Pilot's dimmest text reads over the brightest spot behind its glass. Amber means Pilot raised the surface to keep it readable."
    }

    static let presets = FocusPreset.allCases.map { (value: $0, title: $0.title) }

    var body: some View {
        if place == .focusedBorder { borderBlock.id(AppSection.focusedBorder) } else { dimBlock.id(AppSection.focusedDim) }
    }

    /// The border's preset at the head, then its width and colour, set by the preset or by hand (Custom).
    private var borderBlock: some View {
        @Bindable var look = look
        let now = BorderLook(on: look.windowBorder, width: look.windowBorderWidth, colour: look.windowBorderColour)
        // Stretches to its pair's height, so the columns end level.
        return KitBlock(title: AppSection.focusedBorder.title, symbol: "square.dashed", fill: true) {
            preset(AppSection.focusedBorder.title, Info.border, now.preset) { picked in
                // Custom writes nothing: the rows below are the custom border.
                guard let picked = BorderLook.picked(picked, from: now) else { return }
                look.windowBorder = picked.on; look.windowBorderWidth = picked.width; look.windowBorderColour = picked.colour
            }
            .landingRing("look.windowBorder").landingRing("look.windowBorderPreset")
        } content: {
            BlockRow(first: true) {
                label("Width", Info.borderWidth)
                Stepper(value: $look.windowBorderWidth, in: WindowBorder.widths) {
                    Text("\(look.windowBorderWidth) pt").font(ink.mono(11.5)).foregroundStyle(ink.text2)
                }
                .accessibilityLabel("Border width").accessibilityValue("\(look.windowBorderWidth) points")
            }
            .disabled(!look.windowBorder).landingRing("look.windowBorderWidth")
            BlockRow {
                label("Colour", Info.borderColour)
                ColourChoicePicker(choice: $look.windowBorderColour, theme: look.theme.accent, label: "Border colour")
            }
            .disabled(!look.windowBorder).landingRing("look.windowBorderColour")
        }
    }

    /// Dim's preset at the head, then its blur and darkening, what sets it off, the shake's switch and tuning, and how
    /// well text reads over it.
    private var dimBlock: some View {
        @Bindable var look = look
        return KitBlock(title: AppSection.focusedDim.title, symbol: "circle.lefthalf.filled", fill: true) {
            preset(AppSection.focusedDim.title, Info.dim, DimLook(blur: look.defocusStrength, dim: look.defocusDim).preset) { picked in
                // Custom writes nothing: the rows below are the custom dim.
                guard let picked = DimLook.picked(picked) else { return }
                look.defocusStrength = picked.blur; look.defocusDim = picked.dim
            }
            .landingRing("look.defocusPreset")
        } content: {
            BlockRow(first: true) {
                label("Blur", Info.blur)
                Segments(selection: $look.defocusStrength, options: Defocus.strengths.map { ($0, $0 == 0 ? "Off" : "\($0)") }, label: "Blur")
            }
            .landingRing("look.defocusStrength")
            BlockRow {
                label("Darken", Info.darken)
                KitSlider(value: Binding(get: { Double(look.defocusDim) }, set: { if Int($0) != look.defocusDim { look.defocusDim = Int($0) } }),
                          range: Double(Defocus.dims.lowerBound)...Double(Defocus.dims.upperBound), step: 1, label: "Darken")
                Text(look.defocusDim == 0 ? "Off" : "\(look.defocusDim)%").font(ink.mono(11.5)).foregroundStyle(ink.text2).fixedSize()
                    .frame(width: 38, alignment: .trailing)
            }
            .landingRing("look.defocusDim")
            BlockRow { defocusHint.font(ink.ui(12)).padding(.vertical, 6) }
            BlockRow { Toggle("Shake the mouse to dim", isOn: $look.defocusShake).toggleStyle(.pilotSwitchRow(info: Info.shake)) }
                .landingRing("look.defocusShake")
            BlockRow {
                label("How hard to shake", Info.swings)
                Stepper(value: $look.defocusShakeSwings, in: ShakeDetector.swingsRange) {
                    Text("\(look.defocusShakeSwings) swings").font(ink.mono(11.5)).foregroundStyle(ink.text2)
                }
                .accessibilityLabel("How hard to shake").accessibilityValue("\(look.defocusShakeSwings) swings")
            }
            .disabled(!look.defocusShake).landingRing("look.defocusShakeSwings")
            BlockRow {
                let seconds = look.defocusShakeWithin.formatted(.number.precision(.fractionLength(1)))
                label("Within", Info.within)
                Stepper(value: $look.defocusShakeWithin, in: ShakeDetector.withinRange, step: 0.1) {
                    Text("\(seconds) s").font(ink.mono(11.5)).foregroundStyle(ink.text2)
                }
                .accessibilityLabel("Shake within").accessibilityValue("\(seconds) seconds")
            }
            .disabled(!look.defocusShake).landingRing("look.defocusShakeWithin")
            BlockRow { contrastBadge.font(ink.ui(12)).padding(.vertical, 6); InfoMark(text: Info.contrast) }
        }
    }

    /// A feature's preset at its block's head: its ⓘ and the four choices.
    private func preset(_ title: String, _ info: String, _ now: FocusPreset, pick: @escaping (FocusPreset) -> Void) -> some View {
        HStack(spacing: 8) {
            InfoMark(text: info)
            Segments(selection: Binding(get: { now }, set: pick), options: Self.presets, label: title)
        }
    }

    /// A row's label with its ⓘ beside it, taking the row's spare width.
    private func label(_ title: String, _ info: String) -> some View {
        HStack(spacing: 6) { Text(title); InfoMark(text: info) }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What sets Defocus off now: the shake while its switch is on, and its bind in mono, as keys are, or a nudge to bind one.
    private var defocusTrigger: Text {
        let key = engine?.binds.store.trigger(for: Defocus.actionID)
        var hint = AttributedString(Defocus.hint(key: key, shake: look.defocusShake))
        if let label = key?.label, let range = hint.range(of: label) { hint[range].font = ink.mono(11) }
        return Text(hint)
    }

    /// What Defocus does as set and what sets it off, or that it has nothing to do with Blur and Dim both off; with Reduce
    /// Transparency on and a blur picked, that it dims without the blur.
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
