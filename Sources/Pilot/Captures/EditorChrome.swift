import AppKit
import Clipboard
import ImageScale
import PilotCore
import SwiftUI

// The capture editor's chrome in B (Sven, Q805; editors-round-2's mocks and parity table): every control on a floating
// pill over the sunken ground, nothing over the capture. Drawn from StyleTokens, Instrument's and Toybox's own parts; on
// Glass the pills stand on the window's glass. The designer's notes kept from A: Copy is a plain cap and Done the one
// primary; the selection is a fixed blue, so the theme's colour means only the picked tool; ⌘S says "Saved a copy".

/// The top row: History (undo, redo, delete) at the left; at the right the actions, backdrop, read text, redact, ask AI
/// and upscale, then pin, drag, save a copy and copy, then Cancel and Done. The row's empty room drags the window.
struct EditorTopBar: View {
    @Environment(\.style) private var style
    let model: EditorModel
    @State private var upscaling = false
    var save: () -> Void = {}
    var copy: () -> Void = {}
    var pin: () -> Void = {}
    var ask: () -> Void = {}
    var cancel: () -> Void = {}
    var done: () -> Void = {}
    /// What a drag from the Drag cap carries: the export, backdrop and all, as a PNG file; nil hides the cap.
    var drag: (() -> NSItemProvider)?

    static func cap(_ s: StyleTokens) -> CGSize { s.kind == .toybox ? CGSize(width: 36, height: 36) : CGSize(width: 30, height: 28) }
    static func gap(_ s: StyleTokens) -> CGFloat { s.kind == .toybox ? 6 : 4 }

    var body: some View {
        HStack(spacing: 0) {
            history
            WindowDragArea().frame(minWidth: 16, maxWidth: .infinity, maxHeight: .infinity)
            actions
        }
        .padding(.horizontal, 12)
    }

    private var history: some View {
        HStack(spacing: Self.gap(style)) {
            Button(action: model.undo) { ActionCap(symbol: "arrow.uturn.backward", label: "Undo") }
                .buttonStyle(.plain).help("Undo  ⌘Z").disabled(!model.document.canUndo)
            Button(action: model.redo) { ActionCap(symbol: "arrow.uturn.forward", label: "Redo") }
                .buttonStyle(.plain).help("Redo  ⇧⌘Z").disabled(!model.document.canRedo)
            Button(action: model.deleteSelected) { ActionCap(symbol: "trash", label: "Delete") }
                .buttonStyle(.plain).help("Delete the selected marks  ⌫").disabled(model.selected == nil)
        }
        .padding(4).editorPill()
    }

    private var actions: some View {
        HStack(spacing: Self.gap(style)) {
            Button { model.panelOpen.toggle() } label: { ActionCap(symbol: "photo.artframe", label: "Backdrop", lit: model.panelOpen, key: "B") }
                .buttonStyle(.plain).help("Backdrop: gradients, wallpapers, padding, shadow, corners and ratio  B")
            Button(action: model.startReading) { ActionCap(symbol: "text.viewfinder", label: "Read text", lit: model.reading != nil) }
                .buttonStyle(.plain).help("Read the text and QR codes, and copy them")
            Button(action: model.redactSensitive) { ActionCap(symbol: "eye.slash", label: "Redact sensitive text", lit: model.finding) }
                .buttonStyle(.plain).help("Cover emails, card numbers, IP addresses, keys and phone numbers")
            Button(action: ask) { ActionCap(symbol: "sparkles", label: "Ask AI") }.buttonStyle(.plain).help("Ask AI about the capture, as marked up")
            Button {
                let size = model.exportSize
                model.upscale.size(width: Int(size.width), height: Int(size.height))
                upscaling = true
            } label: { ActionCap(symbol: "arrow.up.left.and.arrow.down.right", label: "Upscale", lit: model.upscale.busy) }
                .buttonStyle(.plain).help("Upscale the capture, as marked up, 2x to 4x beside it")
                .popover(isPresented: $upscaling, arrowEdge: .bottom) { UpscalePopover(model: model) { upscaling = false } }
            rule
            Button(action: pin) { ActionCap(symbol: "pin", label: "Pin") }.buttonStyle(.plain).help("Pin it over your windows, and close the editor")
            if let drag {
                ActionCap(symbol: "hand.point.up.left", label: "Drag into an app")
                    .onDrag(drag)
                    .help("Drag the capture, as marked up, into any app")
            }
            Button(action: save) { ActionCap(symbol: "square.and.arrow.down", label: "Save a copy") }.buttonStyle(.plain).help("Save a copy  ⌘S")
            Button(action: copy) { ActionCap(symbol: "doc.on.doc", label: "Copy") }.buttonStyle(.plain).help("Copy  ⌘C")
            rule
            ToolButtons(primary: "Done", run: done, cancel: cancel).help("Done copies it and saves over the capture  ↩ · Cancel  Esc")
        }
        .padding(4).editorPill()
    }

    private var rule: some View { EditorRule().padding(.horizontal, 4) }
}

/// B's tool rail: all fourteen tools down the room's left, in the keys' order (1 to 0, C, F, R, I); one column fits the
/// smallest window (EditorLayout.least) in either style.
struct ToolRail: View {
    @Environment(\.style) private var style
    let model: EditorModel

    /// A rail cap: the top bar's, a little shorter in Toybox so fourteen fit the smallest window.
    static func cap(_ s: StyleTokens) -> CGSize { s.kind == .toybox ? CGSize(width: 36, height: 32) : EditorTopBar.cap(s) }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(MarkTool.allCases, id: \.self) { t in
                Button { model.pick(t) } label: { ToolCap(tool: t, picked: model.tool == t) }
                    .buttonStyle(.plain).help("\(t.name)  \(t.key)")
            }
        }
        .padding(4).editorPill()
    }
}

/// One tool cap: its symbol, its key at the bottom right; picked, the accent's soft fill, line and text (Instrument),
/// or Toybox's sun cap.
struct ToolCap: View {
    @Environment(\.style) private var style
    let tool: MarkTool
    let picked: Bool

    static func symbol(_ tool: MarkTool) -> String {
        switch tool {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .blur: "drop"
        case .box: "rectangle.fill"
        case .step: "1.circle"
        case .crop: "crop"
        case .spotlight: "light.max"
        case .ruler: "ruler"
        case .eyedropper: "eyedropper"
        }
    }

    var body: some View {
        let size = ToolRail.cap(style)
        if style.kind == .toybox {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: Self.symbol(tool)).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(picked ? style.color(\.onHyper) : style.color(\.text))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                CapKey(key: tool.key, lit: picked)
            }
            .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
            .frame(width: size.width, height: size.height)
            .background(Toy.block(style, fill: picked ? style.color(\.hyper) : style.color(\.raised), radius: style.radii.chip + 2, edge: 4))
            .offset(y: picked ? 1 : 0)
            .contentShape(Rectangle())
        } else {
            let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: Self.symbol(tool)).font(.system(size: 13, weight: .regular))
                    .foregroundStyle(picked ? style.color(\.accentText) : style.color(\.text2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).offset(x: -1, y: -1)
                CapKey(key: tool.key, lit: picked)
            }
            .frame(width: size.width, height: size.height)
            .background { shape.fill(picked ? style.color(\.accentSoft) : style.color(\.raised)) }
            .overlay { shape.strokeBorder(picked ? style.color(\.accentLine) : style.color(\.line)) }
            .contentShape(Rectangle())
        }
    }
}

/// An action at the bar's right, a plain cap (Copy too: Done is the one primary).
struct ActionCap: View {
    @Environment(\.style) private var style
    @Environment(\.isEnabled) private var enabled
    let symbol: String
    let label: String
    /// Lit while its result shows (Read text), in the picked tool's colours.
    var lit = false
    /// Its key, at the bottom right as on a tool cap (the backdrop's B).
    var key: String?

    var body: some View {
        let size = EditorTopBar.cap(style)
        Group {
            if style.kind == .toybox {
                Image(systemName: symbol).font(.system(size: 13.5, weight: .bold)).foregroundStyle(lit ? style.color(\.onHyper) : style.color(\.text))
                    .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
                    .frame(width: size.width, height: size.height)
                    .background(Toy.block(style, fill: lit ? style.color(\.hyper) : style.color(\.raised), radius: style.radii.chip + 2, edge: 4))
            } else {
                let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(lit ? style.color(\.accentText) : style.color(\.text2))
                    .frame(width: size.width, height: size.height)
                    .background { if lit { shape.fill(style.color(\.accentSoft)) } }
                    .overlay { if lit { shape.strokeBorder(style.color(\.accentLine)) } }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Toybox's cap keeps its 4-point edge under the key, as the tool cap's padding does.
            if let key { CapKey(key: key, lit: lit).padding(.bottom, style.kind == .toybox ? 4 : 0) }
        }
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .accessibilityLabel(label)
    }
}

/// The bottom row: the options strip centred under the capture, the View pill (zoom and the export's size) at the right.
struct EditorFooter: View {
    @Environment(\.style) private var style
    let model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            EditorStrip(model: model)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ZoomControl(model: model, font: Font(Self.mono(style, 10.5)))
                ImageSizeChip(model: model, font: Font(Self.mono(style, 10.5)))
            }
            .padding(4).editorPill()
        }
    }

    static func mono(_ style: StyleTokens, _ size: CGFloat) -> NSFont {
        style.kind == .toybox ? DisplayFaces.font(StyleTokens.jetBrainsMono(500), size: size) : DisplayFaces.font(StyleTokens.geistMono(400), size: size)
    }
}

/// The options strip (B): always the one place for the picked tool's or the picked mark's options, Read text's result,
/// or, while cropping, the crop's own strip.
struct EditorStrip: View {
    @Environment(\.style) private var style
    let model: EditorModel

    var body: some View {
        Group {
            if model.tool == .crop { CropStrip(model: model) }
            else if let reading = model.reading { ReadTip(reading: reading, copy: model.copyRead) }
            else { toolOptions }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        // Offered the row's room, so Text's options and a picked mark's still fold when it is short.
        .editorPill(fixed: false)
    }

    @ViewBuilder private var toolOptions: some View {
        let tool = model.tool
        switch tool {
        case .select:
            if model.selected == nil {
                HStack(spacing: 10) {
                    Text("Click a mark to pick it · drag round several").styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1).fixedSize()
                    if !model.panelOpen {
                        Button("Backdrop") { model.panelOpen = true }.buttonStyle(.pilot).help("Show the backdrop panel  B")
                    }
                }
            } else if let mark = model.selectedMark {
                if mark.isText { TextOptions(model: model) } else { picked(mark) }
            } else { Text("Drag to move · ⌫ deletes").styleText(\.caption).foregroundStyle(style.color(\.text3)) }
        case .eyedropper:
            HStack(spacing: 8) {
                if let rgb = model.sampled ?? model.pickedColour {
                    Circle().fill(Color(Paint(rgb))).frame(width: 16, height: 16)
                        .overlay { Circle().strokeBorder(Color(hex: style.dark ? 0xFFFFFF : 0x000000, opacity: 0.14)) }
                    Text(ColourAnswer.hex(rgb)).font(Font(mono(11.5))).foregroundStyle(style.color(\.text)).monospacedDigit().fixedSize()
                }
                Text("Click a pixel: it becomes the colour, its hex is copied").styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize()
            }
        case .text:
            TextOptions(model: model)
        default:
            HStack(spacing: 14) {
                if tool.sized {
                    SizeSlider(value: model.size(of: tool), label: tool == .blur ? "Strength" : tool == .spotlight ? "Darkness" : "Size",
                               set: model.setSize)
                } else if tool == .ruler {
                    Text("Click stamps · drag measures").styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize()
                }
                if tool.coloured { rule; Swatches(palette: model.palette, picked: model.colourIndex(of: tool), pick: model.setColour) }
                if let pair = tool.styles {
                    rule
                    ToolSegments(options: [(0, pair.0), (1, pair.1)], label: "Style",
                                 selection: Binding(get: { model.style(of: tool) }, set: { model.setStyle($0) }))
                }
                if tool == .blur {
                    rule
                    Toggle("Text only", isOn: Binding(get: { model.textOnly }, set: model.setTextOnly)).toggleStyle(.pilotSwitchRow).fixedSize()
                        .help("Blur only the text in the area, and leave the rest")
                    if model.finding { ProgressView().controlSize(.small) }
                }
                if tool == .step {
                    HStack(spacing: 6) {
                        Text("Next").styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize()
                        StepBadge(number: model.document.nextStep, diameter: 20, colour: Color(Paint(model.colour)))
                    }
                }
            }
        }
    }

    private var rule: some View { EditorRule() }

    /// The one picked mark's options (the designer's mock): its size and colour, set on it; the hint goes first when
    /// there is no room.
    private func picked(_ mark: Mark) -> some View {
        let tool = mark.tool, resizable = !Grip.grips(of: mark).isEmpty
        let hint = Text(resizable ? "Drag a handle to resize · ⌫ deletes" : "Drag to move · ⌫ deletes").styleText(\.caption)
            .foregroundStyle(style.color(\.text3)).lineLimit(1).fixedSize()
        let controls = HStack(spacing: 14) {
            if tool.sized {
                SizeSlider(value: mark.size, label: tool == .blur ? "Strength" : tool == .spotlight ? "Darkness" : "Size", set: model.setSize)
            }
            if tool.coloured {
                if tool.sized { rule }
                Swatches(palette: model.palette, picked: model.palette.firstIndex(of: mark.colour) ?? -1, pick: model.setColour)
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { hint; if tool.sized || tool.coloured { rule }; controls }
            controls
        }
    }

    private func mono(_ size: CGFloat) -> NSFont { EditorFooter.mono(style, size) }
}

/// The bars' and strips' upright hairline between groups.
struct EditorRule: View {
    @Environment(\.style) private var style
    var body: some View { style.color(\.line2).frame(width: 1, height: 16) }
}

/// A cap's key at its bottom right (a tool's 1 to I, the backdrop's B); in the lit cap's colours when it is lit.
struct CapKey: View {
    @Environment(\.style) private var style
    let key: String
    let lit: Bool

    var body: some View {
        if style.kind == .toybox {
            Text(key).font(style.toyMono(8.5, bold: true))
                .foregroundStyle(lit ? style.color(\.onHyper).opacity(0.7) : style.color(\.text3)).padding(.trailing, 4).padding(.bottom, 1)
        } else {
            Text(key).font(Font(DisplayFaces.font(StyleTokens.geistMono(500), size: 9)))
                .foregroundStyle(lit ? style.color(\.accentText).opacity(0.75) : style.color(\.text3)).padding(.trailing, 3).padding(.bottom, 1)
        }
    }
}

/// The crop's strip (B): what a drag does, Whole capture, As taken once the capture kept its screen and the crop left its
/// area (P77), then Cancel and Crop (Esc and Return).
struct CropStrip: View {
    @Environment(\.style) private var style
    let model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            Text(hint).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize()
            if model.cropEdit != nil || model.document.crop != nil { Button("Whole capture", action: model.clearCrop).buttonStyle(.pilot) }
            if model.showsAsTaken { Button("As taken", action: model.cropAsTaken).buttonStyle(.pilot) }
            EditorRule()
            ToolButtons(primary: "Crop", run: model.applyCrop, cancel: model.cancelCrop).help("Crop  ↩ · Cancel  Esc")
        }
    }

    private var hint: String {
        // As long as the plain hint, so the strip still fits the smallest window with As taken in it.
        if model.screen != nil { return "Past the edge brings the screen back" }
        return model.cropEdit == nil ? "Drag the part to keep" : "Drag the handles, or drag a new area"
    }
}

extension View {
    /// B's floating pills and cards: the panel's fill in the style's card recipe (Toybox's ink outline and solid edge,
    /// Instrument's hairline ring), no soft shadow, the content clipped to it. A pill keeps its natural size, so a row's
    /// drag room gives way and never a button; `fixed: false` lets a card (the backdrop panel's) fill its column.
    func editorPill(radius: KeyPath<StyleRadii, Double> = \.card, fixed: Bool = true) -> some View {
        modifier(EditorPill(radius: radius, fixed: fixed))
    }
}

private struct EditorPill: ViewModifier {
    @Environment(\.style) private var style
    let radius: KeyPath<StyleRadii, Double>
    let fixed: Bool

    func body(content: Content) -> some View {
        let r = style.radii[keyPath: radius], d = style.depth.card
        let pill = content.clipShape(.rect(cornerRadius: max(r - d.outline, 0), style: .continuous))
            .styleSurface(\.card, fill: \.panel, radius: radius, shadows: false)
        if fixed { pill.fixedSize() } else { pill }
    }
}

struct ToyFaceStyle: ButtonStyle {
    var primary = false
    var ghost = false
    func makeBody(configuration: Configuration) -> some View { ToyButtonFace(configuration: configuration, primary: primary, ghost: ghost, small: true) }
}

/// The 1 to 10 slider with its number (SuperCmd's footer); the filled part in the second text colour, never the signal.
struct SizeSlider: View {
    @Environment(\.style) private var style
    let value: Int
    var label = "Size"
    var width: CGFloat = 104
    var set: (Int) -> Void = { _ in }

    var body: some View {
        let toy = style.kind == .toybox
        let fraction = CGFloat(value - 1) / 9
        let knob: CGFloat = toy ? 16 : 12
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(label))
                .font(.system(size: 11, weight: toy ? .bold : .regular)).foregroundStyle(style.color(\.text3)).help(label)
            ZStack(alignment: .leading) {
                Capsule().fill(style.color(toy ? \.sunken : \.line2)).frame(height: toy ? 8 : 4)
                    .overlay { if toy { Capsule().strokeBorder(style.color(\.outline), lineWidth: 2) } }
                Capsule().fill(style.color(toy ? \.accent : \.text2)).frame(width: max(knob, (width - knob) * fraction + knob / 2), height: toy ? 8 : 4)
                    .overlay { if toy { Capsule().strokeBorder(style.color(\.outline), lineWidth: 2) } }
                Circle().fill(style.color(\.knob))
                    .overlay { Circle().strokeBorder(style.color(toy ? \.outline : \.line2), lineWidth: toy ? 2 : 1) }
                    .shadow(color: .black.opacity(toy ? 0 : 0.25), radius: 1, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: (width - knob) * fraction)
            }
            .frame(width: width, height: 20)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                set(1 + Int(((g.location.x - knob / 2) / (width - knob) * 9).rounded()))
            })
            Text("\(value)").font(Font(toy ? DisplayFaces.font(StyleTokens.jetBrainsMono(700), size: 12) : DisplayFaces.font(StyleTokens.geistMono(500), size: 11.5)))
                .monospacedDigit().foregroundStyle(style.color(\.text)).frame(width: 16, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { $0 == .increment ? set(value + 1) : set(value - 1) }
    }
}

extension SizeSlider {
    static func symbol(_ label: String) -> String {
        switch label {
        case "Strength": "drop"
        case "Darkness": "light.max"
        case "Padding": "rectangle.inset.filled"
        case "Corners": "app"
        default: "lineweight"
        }
    }
}

/// The six swatches; the picked one ringed in the text colour, so the signal keeps its one meaning.
struct Swatches: View {
    @Environment(\.style) private var style
    let palette: [UInt32]
    let picked: Int
    var pick: (Int) -> Void = { _ in }

    var body: some View {
        let toy = style.kind == .toybox
        let d: CGFloat = toy ? 20 : 16
        HStack(spacing: toy ? 7 : 6) {
            ForEach(Array(palette.enumerated()), id: \.offset) { i, rgb in
                Button { pick(i) } label: {
                    Circle().fill(Color(Paint(rgb)))
                        .overlay { Circle().strokeBorder(toy ? style.color(\.outline) : Color(hex: style.dark ? 0xFFFFFF : 0x000000, opacity: 0.14), lineWidth: toy ? 2 : 1) }
                        .frame(width: d, height: d)
                        .padding(3)
                        .overlay { if i == picked { Circle().strokeBorder(style.color(\.text), lineWidth: toy ? 2.5 : 1.5) } }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Tool 0's disc, for the footer's "Next".
struct StepBadge: View {
    let number: Int
    let diameter: CGFloat
    let colour: Color
    var body: some View {
        Text("\(number)").font(.system(size: diameter * 0.52, weight: .bold, design: .rounded)).foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(colour, in: Circle())
            .overlay { Circle().strokeBorder(.white, lineWidth: diameter > 22 ? 2 : 1.5) }
    }
}

/// The short line under the capture ("Saved a copy" with its keys, "Copied", the discard warning), on the pop face.
struct EditorHint: View {
    @Environment(\.style) private var style
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            if text == "Saved a copy" {
                if style.kind == .toybox { ToyKeycap(label: "⌘", small: true); ToyKeycap(label: "S", small: true) }
                else { InstrumentKey(text: "⌘"); InstrumentKey(text: "S") }
            }
            Text(text).styleText(\.strong).foregroundStyle(style.color(\.text)).padding(.leading, 4)
        }
        .padding(.horizontal, 10).frame(height: style.kind == .toybox ? 38 : 32)
        .background { RoundedRectangle(cornerRadius: style.radii.pop, style: .continuous).fill(style.color(\.panel)) }
        .overlay { RoundedRectangle(cornerRadius: style.radii.pop, style: .continuous).strokeBorder(style.color(style.kind == .toybox ? \.outline : \.line2), lineWidth: style.kind == .toybox ? 2 : 1) }
    }
}

/// Empty bar room that drags the window, as a title bar would.
struct WindowDragArea: NSViewRepresentable {
    final class Handle: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> NSView { Handle() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Read text's result in the strip (B): how many lines were read (they are on the pasteboard already), Copy text to copy
/// them again, and Show text for every line.
struct ReadTip: View {
    @Environment(\.style) private var style
    let reading: EditorModel.Reading
    var copy: () -> Void = {}
    @State private var showing = false

    var body: some View {
        HStack(spacing: 10) {
            switch reading {
            case .reading:
                ProgressView().controlSize(.small)
                Text("Reading the text…").styleText(\.strong).foregroundStyle(style.color(\.text2))
            case .read(let lines):
                Image(systemName: lines.isEmpty ? "text.magnifyingglass" : "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(style.color(\.accentText)).frame(width: 20, height: 20).background(style.color(\.accentSoft), in: Circle())
                Text(CaptureText.said(lines)).styleText(\.strong).foregroundStyle(style.color(\.text)).lineLimit(1)
                if !lines.isEmpty {
                    Group {
                        if style.kind == .toybox { Button("Copy text", action: copy).buttonStyle(ToyFaceStyle(ghost: true)) }
                        else { Button("Copy text", action: copy).buttonStyle(InstrumentButtonStyle(kind: .ghost)) }
                    }
                    .help("Copy every line it read")
                    Group {
                        if style.kind == .toybox { Button("Show text") { showing = true }.buttonStyle(ToyFaceStyle()) }
                        else { Button("Show text") { showing = true }.buttonStyle(InstrumentButtonStyle(kind: .raised)) }
                    }
                    .popover(isPresented: $showing, arrowEdge: .top) {
                        ScrollView {
                            Text(ReadLines.copied(lines)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        }
                        .frame(width: 420, height: 260)
                    }
                }
            }
        }
    }
}

/// A see-through square's checkerboard.
struct Checker: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 4
            for x in stride(from: 0, to: size.width, by: s) {
                for y in stride(from: 0, to: size.height, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.35)))
                }
            }
        }
        .background(Color.white)
    }
}

/// The footer's export size as a chip (Q246): a click opens the resize popover; a resized export shows its new size.
struct ImageSizeChip: View {
    @Environment(\.style) private var style
    let model: EditorModel
    let font: Font
    @State private var open = false

    var body: some View {
        let size = model.exportSize, resized = ImageSizePanel.resized(model)
        Button {
            open = true
        } label: {
            Text(verbatim: "\(Int(size.width)) × \(Int(size.height))").font(font).foregroundStyle(style.color(resized ? \.accentText : \.text3)).monospacedDigit()
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 7)
                .chipFace(style, lit: resized)
                .contentShape(.rect)
        }
        .buttonStyle(.plain).help("Image size: click to resize")
        .accessibilityLabel("Image size \(Int(size.width)) by \(Int(size.height)), resize")
        .popover(isPresented: $open, arrowEdge: .top) { ImageSizePanel(model: model, target: model.resizeTarget) { open = false } }
    }
}

/// The size chip's popover: a size typed or picked, Apply; Original size takes a resize back.
struct ImageSizePanel: View {
    @Environment(\.style) private var style
    let model: EditorModel
    @State var target: ResizeTarget
    var close: () -> Void = {}

    /// The export is resized, or a crop is being dragged: the chip is lit and Original size shows.
    static func resized(_ model: EditorModel) -> Bool { model.resized != nil || (model.tool == .crop && model.cropEdit != nil) }

    var body: some View {
        ToolPanel(title: "Image size") {
            ResizeOptions(target: $target)
        } buttons: {
            if Self.resized(model) { Button("Original size") { model.resize(to: nil); close() }.buttonStyle(.pilot) }
            Spacer()
            ToolButtons(primary: "Apply", run: { model.resize(to: target); close() }, cancel: close)
        }
        .background(style.color(\.panel))
    }
}

extension View {
    /// The footer chips' face, the size's and the zoom's: 22 high on the raised fill in a hairline, the accent's when lit.
    func chipFace(_ style: StyleTokens, lit: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        return frame(height: 22)
            .background { shape.fill(style.color(lit ? \.accentSoft : \.raised)) }
            .overlay { shape.strokeBorder(style.color(lit ? \.accentLine : \.line)) }
    }
}

/// The footer's zoom beside the size (Sven, Q281): zoom out, the capture's zoom in per cent of its actual size, zoom in,
/// on the size chip's face. The buttons zoom about the middle of the view, as ⌘− and ⌘+ do; a click on the per cent is
/// actual size, 100 % (Sven on build 67, P46).
struct ZoomControl: View {
    @Environment(\.style) private var style
    let model: EditorModel
    let font: Font

    var body: some View {
        let percent = Int((model.zoom * 100).rounded())
        HStack(spacing: 0) {
            step("minus.magnifyingglass", label: "Zoom out", key: "⌘−", on: model.canZoomOut, run: model.zoomOut)
            Button { model.zoom(to: 1) } label: {
                Text(verbatim: "\(percent) %").font(font).foregroundStyle(style.color(\.text2)).monospacedDigit()
                    .lineLimit(1).fixedSize().frame(minWidth: 38).frame(maxHeight: .infinity).contentShape(.rect)
            }
            .buttonStyle(.plain).help("Actual size, 100 %").accessibilityLabel("Zoom \(percent) percent, actual size")
            step("plus.magnifyingglass", label: "Zoom in", key: "⌘+", on: model.canZoomIn, run: model.zoomIn)
        }
        .chipFace(style)
    }

    private func step(_ symbol: String, label: String, key: String, on: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 11, weight: style.kind == .toybox ? .bold : .regular)).foregroundStyle(style.color(\.text2))
                .frame(width: 24, height: 22).contentShape(.rect)
        }
        .buttonStyle(.plain).help("\(label)  \(key)").accessibilityLabel(label)
        .disabled(!on).opacity(on ? 1 : 0.35)
    }
}

/// The top bar's Upscale: the shared settings, Upscale, and Cancel that stops a run.
struct UpscalePopover: View {
    @Environment(\.style) private var style
    let model: EditorModel
    let close: () -> Void

    var body: some View {
        ToolPanel(title: "Upscale") {
            UpscaleOptions(job: model.upscale)
        } buttons: {
            Spacer()
            ToolButtons(primary: UpscaleOptions.action(model.upscale), disabled: !UpscaleOptions.runs(model.upscale),
                        cancelTitle: model.upscale.busy ? "Stop" : "Cancel", run: model.startUpscale,
                        cancel: { if model.upscale.busy { model.upscale.cancel() } else { close() } })
        }
        .background(style.color(\.panel))
    }
}

/// Text's options (Sven after build 82, the designer's mock): Font, Size in points, Bold and Italic, the colour, and
/// Plain or Pill, for the text tool and for a picked text. The swatches fold into one colour menu when the footer is
/// short of room.
struct TextOptions: View {
    @Environment(\.style) private var style
    let model: EditorModel

    static let sizes: [CGFloat] = [12, 14, 18, 24, 32, 48, 64, 96, 120]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(swatches: true)
            row(swatches: false)
        }
    }

    private var colourIndex: Int {
        if model.tool == .select, let mark = model.selectedMark { return model.palette.firstIndex(of: mark.colour) ?? -1 }
        return model.colourIndex(of: .text)
    }

    private func row(swatches: Bool) -> some View {
        let face = model.shownFace, points = face.points ?? 18
        return HStack(spacing: 14) {
            fontMenu(face)
            sizeStepper(points)
            HStack(spacing: 2) {
                Button { let on = !face.bold; model.setFace { $0.bold = on } } label: { ActionCap(symbol: "bold", label: "Bold", lit: face.bold) }
                    .buttonStyle(.plain).help("Bold")
                Button { let on = !face.italic; model.setFace { $0.italic = on } } label: { ActionCap(symbol: "italic", label: "Italic", lit: face.italic) }
                    .buttonStyle(.plain).help("Italic")
            }
            rule
            if swatches { Swatches(palette: model.palette, picked: colourIndex, pick: model.setColour) } else { colourMenu }
            rule
            ToolSegments(options: [(false, "Plain"), (true, "Pill")], label: "Style",
                         selection: Binding(get: { model.shownPill }, set: { model.setPill($0) }))
        }
    }

    private var rule: some View { EditorRule() }

    private func fontMenu(_ face: TextFace) -> some View {
        Menu {
            Picker("Font", selection: Binding(get: { face.family }, set: { family in model.setFace { $0.family = family } })) {
                ForEach(TextFace.Family.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Text(face.family.name).styleText(\.strong).foregroundStyle(style.color(\.text)).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(style.color(\.text3))
            }
            .padding(.horizontal, 9)
            .chipFace(style)
            .contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Font").accessibilityLabel("Font, \(face.family.name)")
    }

    /// The zoom chip's face: − and + step 2 points, a click on the number picks a size.
    private func sizeStepper(_ points: CGFloat) -> some View {
        HStack(spacing: 0) {
            step("minus", label: "Smaller", on: points > TextFace.range.lowerBound) { model.setFace { $0.points = TextFace.held(points - 2) } }
            Menu {
                ForEach(Self.sizes, id: \.self) { size in Button("\(Int(size)) pt") { model.setFace { $0.points = size } } }
            } label: {
                Text(verbatim: "\(Int(points)) pt").font(Font(mono)).foregroundStyle(style.color(\.text)).monospacedDigit()
                    .lineLimit(1).fixedSize().frame(minWidth: 40).frame(maxHeight: .infinity).contentShape(.rect)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            step("plus", label: "Bigger", on: points < TextFace.range.upperBound) { model.setFace { $0.points = TextFace.held(points + 2) } }
        }
        .chipFace(style)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Size \(Int(points)) points")
    }

    private func step(_ symbol: String, label: String, on: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(style.color(\.text2))
                .frame(width: 22, height: 22).contentShape(.rect)
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .disabled(!on).opacity(on ? 1 : 0.35)
    }

    /// One swatch that opens the palette, for a narrow footer.
    private var colourMenu: some View {
        let names = ["Theme", "Red", "Amber", "Green", "Blue", "Ink", "Picked"], index = colourIndex
        return Menu {
            ForEach(Array(model.palette.enumerated()), id: \.offset) { i, _ in Button(names[min(i, names.count - 1)]) { model.setColour(i) } }
        } label: {
            Circle().fill(Color(Paint(model.palette[max(0, index)]))).frame(width: 16, height: 16)
                .overlay { Circle().strokeBorder(Color(hex: style.dark ? 0xFFFFFF : 0x000000, opacity: 0.14)) }
                .padding(3).overlay { Circle().strokeBorder(style.color(\.text), lineWidth: 1.5) }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Colour")
    }

    private var mono: NSFont { EditorFooter.mono(style, 10.5) }
}
