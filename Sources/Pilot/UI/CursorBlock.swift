import AppKit
import PilotCore
import SwiftUI

/// Look › Cursor (P84, spec §6), Sven's pick B of the cursor and wallpaper round (Q112, 2026-11-12, "Strip and four
/// rows"): Pilot draws it in the block's head, in place of macOS's tile and Restore; a wide preview of the cursor on a
/// light and a dark window with its trail and halos; then Shape, Size, Colours (Theme or Custom, the designs' own colours
/// gone) and Effects, the trail on one row and the halos with their colour on the next. While Accessibility's own pointer
/// colours are on, turning it on or a new shape first offers Reset Colors there, or the set would revert outside the
/// front window.
struct CursorBlock: View {
    @Environment(\.ink) private var ink
    let look: Look
    let cursors: CursorSets
    let effects: CursorEffects
    /// The shape waiting on the Accessibility offer.
    @State private var offered: CursorSetID?
    /// The pictures, made while the page shows.
    @State private var samples = CursorSamples()
    /// The preview's width, the block's inside: what it is drawn at, and whether the wells fit beside Colours.
    @State private var width: CGFloat = 0

    /// The light window the samples sit on, and the ground the weak-pair check was drawn for (the designer's).
    static let lightGround: UInt32 = 0xEEF1F5
    static let darkGround: UInt32 = 0x14161C
    static let previewHeight: CGFloat = 132

    /// The preview's height: 132 pt up to Medium, taller with a bigger Size so the cursors along its foot stay whole.
    private var previewHeight: CGFloat {
        Self.previewHeight * max(1, (cursors.drawn || offered != nil ? cursors.size.scale(offered ?? cursors.shape) : 1) / 1.5)
    }

    /// What each row does, the ⓘ's words.
    enum Info {
        static let drawn = "On, Pilot draws the pointer, I-beam, hands and the rest everywhere, in the shape, size and colours below. Off, macOS's own cursor is back; if any part stays, a restart clears it."
        static let shape = "The cursor's drawing: Quiet, Toybox, Duo or Classic. Every cursor, from the arrow to the spinning wheel, takes it."
        static let size = "How big Pilot draws the cursor: Small is macOS's own size, Medium one and a half times, Large twice and Huge two and a half. Classic is drawn on whole pixels, so it has no Medium and its Huge is three times. The Ring grows with it."
        static let colours = "Theme follows the theme. Custom paints any shape in a fill and an outline you pick, badges too."
        static let effects = "A fading line behind the pointer while it moves: Thread, Comet or Dots. Off while Reduce motion is on."
        static let halos = "Ring: a ring around the pointer that squeezes on a click and hides after 3 s still. Ripple: a ring that spreads from each click, the right button's in the theme's second colour. Spotlight: dims the screen around the pointer while you hold its key; it has no key until you set one. Their colour is the theme's or one you pick."
    }

    var body: some View {
        @Bindable var cursors = cursors
        @Bindable var effects = effects
        KitBlock(title: "Cursor", symbol: "cursorarrow") { drawnSwitch } content: {
            preview.padding(.top, 10).padding(.bottom, 12)
            if let offered { offer(offered) }
            Group {
                BlockRow(first: true) {
                    label("Shape", Info.shape); Spacer()
                    HStack(spacing: 6) { ForEach(CursorSetID.shapes, id: \.self) { tile($0) } }
                }
                BlockRow {
                    label("Size", Info.size); Spacer()
                    Segments(selection: Binding(get: { cursors.size.fits(cursors.shape) ? cursors.size : .large }, set: { cursors.size = $0 }),
                             options: CursorSize.allCases.filter { $0.fits(cursors.shape) }.map { ($0, $0.title) }, label: "Cursor size")
                }
                BlockRow {
                    label("Colours", Info.colours); Spacer()
                    Segments(selection: $cursors.colours, options: CursorColours.allCases.map { ($0, $0.title) }, label: "Cursor colours")
                        .disabled(look.themePressing)
                    if cursors.colours == .custom && wide { wells(titled: false) }
                }
                if cursors.colours == .custom { custom }
            }
            .disabled(!cursors.drawn || cursors.working)
            BlockRow {
                label("Effects", Info.effects); Spacer()
                Segments(selection: $effects.trail, options: CursorTrail.allCases.map { ($0, $0 == .off ? "No trail" : $0.title) }, label: "Cursor trail")
            }
            BlockRow {
                HStack(spacing: 5) {
                    Text("Halos").font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize()
                    InfoMark(text: Info.halos)
                }
                halo("Ring", isOn: $effects.ring)
                halo("Ripple", isOn: $effects.ripple)
                halo("Spotlight", isOn: $effects.spotlight)
                if effects.spotlight { BindKey(action: CursorEffects.spotlightID) }
                Spacer(minLength: 8)
                if wide { effectColour }
            }
            // Narrow, the halos' colour gets a row of its own, or the chips and Spotlight's key squeeze it.
            if !wide { BlockRow { Spacer(); effectColour } }
        }
    }

    private var effectColour: some View {
        @Bindable var effects = effects
        return ColourChoicePicker(choice: $effects.colour, theme: ColourChoicePicker.effectTheme(look.themeID, resolved: look.packAppearance),
                                  label: "Effect colour")
    }

    /// The wells sit beside Colours once the preview, the block's inner width, is this wide; narrower, on a line of their
    /// own under it.
    private var wide: Bool { width >= 600 }

    private func label(_ title: String, _ info: String) -> some View {
        HStack(spacing: 5) { Text(title).fixedSize(); InfoMark(text: info) }
    }

    // MARK: Pilot draws it

    /// The head's switch: on, Pilot draws the cursor; off, macOS's comes back.
    private var drawnSwitch: some View {
        HStack(spacing: 8) {
            Text("Pilot draws it").font(ink.ui(12)).foregroundStyle(ink.text2).fixedSize()
            InfoMark(text: Info.drawn)
            Toggle("Pilot draws the cursor", isOn: Binding(get: { cursors.drawn || offered != nil }, set: { turn($0) }))
                .toggleStyle(.pilotSwitch).labelsHidden().disabled(cursors.working)
        }
    }

    private func turn(_ on: Bool) {
        if on && !cursors.drawn && CursorSets.accessibilityColoursOn { offered = cursors.shape; return }
        offered = nil
        cursors.drawn = on
    }

    private func pick(_ shape: CursorSetID) {
        if cursors.drawn && shape != cursors.shape && CursorSets.accessibilityColoursOn {
            offered = shape
        } else {
            offered = nil
            cursors.shape = shape
        }
    }

    /// Accessibility's pointer colours are on: Reset Colors first, or the set shows only in the front window.
    private func offer(_ shape: CursorSetID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accessibility's pointer colours are on, so \(shape.title) would show only in the front window. Reset Colors in Pointer settings first.")
                .foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Pointer settings") { NSWorkspace.shared.open(CursorSets.pointerSettings) }.buttonStyle(.pilotPrimary)
                Button("Use it anyway") { offered = nil; cursors.set = shape }.buttonStyle(.pilot)
                Button("Cancel") { offered = nil }.buttonStyle(.pilotSoft)
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: Preview

    /// The cursor on a light window and a dark one, at its size, with its trail, Ring and a ripple from the hand's click;
    /// macOS's own while Pilot draws none. Under it the last apply's line, the one place a failed apply shows.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The picture is an overlay on a flexible frame, so its width never feeds back into the layout.
            Color.clear.frame(maxWidth: .infinity).frame(height: previewHeight)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .overlay { if width > 0, let image = stage(width: width) { Image(decorative: image, scale: 2) } }
                .clipShape(.rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ink.line) }
            .accessibilityElement().accessibilityLabel(cursors.drawn ? "\(cursors.shape.title) cursor, \(cursors.size.title.lowercased())" : "macOS's own cursor")
            if let status = cursors.status {
                Text(status).font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stage(width: CGFloat) -> CGImage? {
        let shape = offered ?? cursors.shape, drawn = cursors.drawn || offered != nil
        let key = "\(shape) \(drawn) \(cursors.size) \(cursors.colours) \(cursors.fill.rawValue) \(cursors.outline.rawValue) \(look.themeID) "
            + "\(look.paletteRevision) \(effects.trail) \(effects.ring) \(effects.ripple) \(effects.colour.rawValue) \(width)"
        return samples.preview(key) { draw(shape, drawn: drawn, width: width) }
    }

    private func draw(_ shape: CursorSetID, drawn: Bool, width: CGFloat) -> CGImage? {
        let scale = drawn ? cursors.size.scale(shape) : 1
        let palette = samples.palette(shape, cursors.colours, theme: look.themeID, custom: cursors.custom(shape), resolved: look.packAppearance)
        let effect = CursorEffectColours.of(look.themeID, colour: effects.colour, resolved: look.packAppearance)
        let shown: [String: CursorPreview.Picture] = drawn
            ? Dictionary(uniqueKeysWithValues: CursorSamples.shown.compactMap { name in
                samples.picture(shape, name, palette: palette, side: Int(32 * scale * 2)).map { (name, $0) } })
            : CursorPreview.macOS
        return CursorPreview.stage(shown, scale: scale, pixelated: drawn && shape == .classic,
                                   trail: effects.trail, ring: effects.ring, ripple: effects.ripple, effect: effect,
                                   size: CGSize(width: width, height: previewHeight))
    }

    // MARK: Shape

    /// One shape's arrow in the colours picked, the picked one ringed in the accent.
    private func tile(_ shape: CursorSetID) -> some View {
        let picked = (offered ?? cursors.shape) == shape
        let palette = samples.palette(shape, cursors.colours, theme: look.themeID, custom: cursors.custom(shape), resolved: look.packAppearance)
        return Button { pick(shape) } label: {
            VStack(spacing: 3) {
                Group {
                    if let arrow = samples.image(shape, "arrow", palette: palette) {
                        Image(decorative: arrow, scale: 2).resizable().interpolation(shape == .classic ? .none : .high)
                    } else { Color.clear }
                }
                .frame(width: 26, height: 26)
                Text(shape.title).font(ink.ui(11)).foregroundStyle(picked ? ink.text : ink.text2)
            }
            .frame(width: 62, height: 50)
            .background(RoundedRectangle(cornerRadius: 8).fill(ink.raised))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(picked ? ink.accent : ink.line, lineWidth: picked ? ink.pickedStroke : ink.stroke))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(shape.title) cursor")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    // MARK: Custom

    /// The fill and outline wells under Colours while the block is narrow, and the pair's contrast.
    @ViewBuilder private var custom: some View {
        if !wide { BlockRow { Spacer(); wells(titled: true) } }
        let (fill, outline) = pair
        let ratio = Contrast.ratio(fill, outline), weak = ratio < CursorCustom.weakRatio
        Text("Fill and outline \(String(format: "%.1f", ratio)):1 · "
             + (weak ? "under 2:1, the shape may not read on every window. Your colours stay." : "reads on light and dark windows."))
            .font(ink.ui(12)).foregroundStyle(weak ? ink.yellow : ink.muted).multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .trailing).padding(.bottom, 10)
    }

    /// Custom's fill and outline on the shape: each picked one, or the theme's.
    private var pair: (fill: UInt32, outline: UInt32) {
        let custom = cursors.custom(cursors.shape)
        return custom.colours(samples.palette(cursors.shape, .theme, theme: look.themeID, custom: custom, resolved: look.packAppearance))
    }

    /// Fill and outline with a swap: titled on their own line, bare beside Colours.
    @ViewBuilder private func wells(titled: Bool) -> some View {
        let (fill, outline) = pair
        well(titled ? "Fill" : nil, "Fill", fill) { cursors.fill = .custom($0) }
        well(titled ? "Outline" : nil, "Outline", outline) { cursors.outline = .custom($0) }
        Button { (cursors.fill, cursors.outline) = (.custom(outline), .custom(fill)) } label: { Image(systemName: "arrow.left.arrow.right") }
            .buttonStyle(.pilot).help("Swap fill and outline").accessibilityLabel("Swap fill and outline")
    }

    /// A colour well and its hex, as the page's other wells close their panel (`ColourPanelCloser`).
    private func well(_ title: String?, _ name: String, _ rgb: UInt32, set: @escaping (UInt32) -> Void) -> some View {
        HStack(spacing: 6) {
            if let title { Text(title).foregroundStyle(ink.text2).fixedSize() }
            ColorPicker(name, selection: Binding(get: { Color(hex: rgb) }, set: { set($0.rgb) }), supportsOpacity: false)
                .labelsHidden()
                .onAppear { ColourPanelCloser.shared.wellAppeared() }
                .onHover { if $0 { ColourPanelCloser.shared.pointerOnWell() } }
                .onDisappear { ColourPanelCloser.shared.wellDisappeared() }
            Text(ColourAnswer.hex(rgb)).font(ink.mono(11.5)).foregroundStyle(ink.text2).fixedSize()
        }
    }

    // MARK: Halos

    /// A halo as a chip that turns it on and off.
    private func halo(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: { Chip(text: title, on: isOn.wrappedValue) }
            .buttonStyle(.plain)
            .accessibilityLabel(title).accessibilityValue(isOn.wrappedValue ? "on" : "off").accessibilityAddTraits(.isToggle)
    }
}

/// Look › Cursor's preview, drawn from the shapes' first frames: a light window and a dark one side by side, the arrow
/// just past the seam with a trail sweeping in from the light side, the Ring on it and a ripple from the hand's click,
/// the I-beam, hand and spinning wheel along the foot. Pure, so a render draws the same picture.
enum CursorPreview {
    /// A cursor's first frame, its hotspot from its top left and its size, in points: the shapes' 32 pt canvas.
    struct Picture { let image: CGImage; let hotspot: CGPoint; var size = CGSize(width: 32, height: 32) }

    static let others = ["ibeam", "pointing-hand", "busy"]

    /// macOS's own arrow, I-beam and hand, as AppKit has them: no spinning wheel.
    @MainActor static let macOS: [String: Picture] = {
        let cursors: [(String, NSCursor)] = [("arrow", .arrow), ("ibeam", .iBeam), ("pointing-hand", .pointingHand)]
        return Dictionary(uniqueKeysWithValues: cursors.compactMap { name, cursor in
            var rect = CGRect(origin: .zero, size: cursor.image.size)
            return cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil).map {
                (name, Picture(image: $0, hotspot: cursor.hotSpot, size: cursor.image.size))
            }
        })
    }()

    /// The preview `size` points, drawn at 2x; each picture `scale` times its size.
    static func stage(_ shown: [String: Picture], scale: CGFloat, pixelated: Bool, trail: CursorTrail, ring: Bool, ripple: Bool,
                      effect: CursorEffectColours, size: CGSize) -> CGImage? {
        let s: CGFloat = 2, (w, h) = (size.width, size.height)
        guard w > 0, let ctx = CGContext(data: nil, width: Int(w * s), height: Int(h * s), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(CursorArt.colour(CursorBlock.lightGround)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CursorArt.colour(CursorBlock.darkGround)); ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        // y counts up, as the painter draws.
        let pointer = CGPoint(x: w * 0.55, y: h * 0.62), start = CGPoint(x: w * 0.14, y: pointer.y - 10)
        var state = CursorEffectState()
        state.trail = trail; state.ring = ring; state.ripple = ripple; state.ringScale = scale
        let n = 25, length = trail.length
        state.samples = (0..<n).map { i in
            let k = CGFloat(i) / CGFloat(n - 1)
            return .init(point: CGPoint(x: start.x + (pointer.x - start.x) * k, y: start.y + (pointer.y - start.y) * k + 14 * sin(k * .pi)),
                         time: 1 - length * (1 - Double(k)))
        }
        state.pointer = pointer
        state.ringFade.go(1, 0, instant: true)
        // The I-beam and hand on the light window, the wheel far right on the dark one, clear of the arrow at any Size.
        let spots = [0.12, 0.36, 0.84].map { CGPoint(x: w * $0, y: h * 0.32) }
        if ripple, let hand = others.firstIndex(of: "pointing-hand") {
            state.ripples = [.init(point: spots[hand], time: 1 - 0.15, right: false)]
        }
        CursorEffectPainter.draw(state, effect, now: 1, in: ctx)
        ctx.interpolationQuality = pixelated ? .none : .high
        func put(_ name: String, at p: CGPoint) {
            guard let c = shown[name] else { return }
            let (pw, ph) = (c.size.width * scale, c.size.height * scale)
            // The hotspot is from the picture's top left; the context counts up from the bottom.
            ctx.draw(c.image, in: CGRect(x: p.x - c.hotspot.x * scale, y: p.y - ph + c.hotspot.y * scale, width: pw, height: ph))
        }
        put("arrow", at: pointer)
        for (i, name) in others.enumerated() { put(name, at: spots[i]) }
        return ctx.makeImage()
    }
}
