import AppKit
import PilotCore
import SwiftUI

// The capture editor's two modes (C, Sven Q238; capture editor round 1): Mark up, the fourteen tools in a dock of named
// caps under the capture with the picked tool's options over it; and Frame, a strip of this capture in every look, then
// one row of fill kinds, padding, shadow, corners and the ratio's menu. One job at a time: the switch in the top bar, M and
// B, or a tool's key.

/// The top bar's Mark up / Frame switch; the live mode in the accent's soft fill (Instrument) or Toybox's segments.
struct ModeSwitch: View {
    @Environment(\.style) private var style
    let model: EditorModel

    var body: some View {
        if style.kind == .toybox {
            ToolSegments(options: [(false, "Mark up"), (true, "Frame")], label: "Mode",
                         selection: Binding(get: { model.panelOpen }, set: { model.frame($0) }))
                .help("Mark up  M · Frame  B")
        } else {
            let shape = RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous)
            HStack(spacing: 2) {
                segment("Mark up", symbol: "pencil.tip.crop.circle", key: "M", frame: false)
                segment("Frame", symbol: "photo.artframe", key: "B", frame: true)
            }
            .padding(3)
            .background(shape.fill(style.color(\.sunken)))
            .overlay(shape.strokeBorder(style.color(\.line)))
            .fixedSize()
        }
    }

    private func segment(_ title: String, symbol: String, key: String, frame: Bool) -> some View {
        let lit = model.panelOpen == frame, shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        return Button { model.frame(frame) } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                Text(title).styleText(\.strong)
                Text(key).font(Font(EditorFooter.mono(style, 10))).foregroundStyle(style.color(\.text3))
            }
            .foregroundStyle(lit ? style.color(\.accentText) : style.color(\.text2))
            .padding(.horizontal, 14).frame(height: 28)
            .background { if lit { shape.fill(style.color(\.accentSoft)) } }
            .overlay { if lit { shape.strokeBorder(style.color(\.accentLine)) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(frame ? "Frame: looks, fills, padding, shadow, corners and ratio  B" : "Mark up: the tools  M")
        .accessibilityLabel(title).accessibilityAddTraits(lit ? .isSelected : [])
    }
}

/// Mark up's dock: the fourteen tools in their families (pick; draw; words; hide; crop; measure), each named under its
/// symbol, the picked one in the accent. Their keys (1 to 0, C, F, R, I) are in the tooltips.
struct ToolDock: View {
    static let groups: [[MarkTool]] = [[.select], [.arrow, .rect, .ellipse, .pen, .highlighter], [.text, .step], [.blur, .box, .spotlight],
                                       [.crop], [.ruler, .eyedropper]]
    let model: EditorModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { i, group in
                if i > 0 { EditorRule().padding(.horizontal, 4) }
                HStack(spacing: 0) {
                    ForEach(group, id: \.self) { t in
                        Button { model.pick(t) } label: { DockTool(tool: t, picked: model.tool == t) }
                            .buttonStyle(.plain).help("\(t.name)  \(t.key)")
                            .accessibilityLabel(t.name).accessibilityAddTraits(model.tool == t ? .isSelected : [])
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .editorPill(radius: \.pop)
    }
}

/// One tool in the dock: its symbol on a cap, its name under it.
struct DockTool: View {
    @Environment(\.style) private var style
    let tool: MarkTool
    let picked: Bool

    static let width: CGFloat = 62
    static func cap(_ s: StyleTokens) -> CGSize { s.kind == .toybox ? CGSize(width: 40, height: 34) : CGSize(width: 38, height: 32) }
    /// The cap, the gap and the name.
    static func height(_ s: StyleTokens) -> CGFloat { cap(s).height + 4 + 14 }

    static func short(_ tool: MarkTool) -> String { tool == .eyedropper ? "Colour" : tool.name }

    var body: some View {
        let size = Self.cap(style)
        VStack(spacing: 4) {
            if style.kind == .toybox {
                Image(systemName: ToolCap.symbol(tool)).font(.system(size: 15, weight: .bold))
                    .foregroundStyle(picked ? style.color(\.onHyper) : style.color(\.text))
                    .padding(.bottom, 3)
                    .frame(width: size.width, height: size.height)
                    .background(Toy.block(style, fill: picked ? style.color(\.hyper) : style.color(\.raised), radius: style.radii.chip + 2, edge: 3))
                    .offset(y: picked ? 1 : 0)
            } else {
                let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
                Image(systemName: ToolCap.symbol(tool)).font(.system(size: 16))
                    .foregroundStyle(picked ? style.color(\.accentText) : style.color(\.text2))
                    .frame(width: size.width, height: size.height)
                    .background { if picked { shape.fill(style.color(\.accentSoft)) } }
                    .overlay { if picked { shape.strokeBorder(style.color(\.accentLine)) } }
            }
            Text(Self.short(tool)).styleText(\.caption)
                .foregroundStyle(picked ? style.color(\.text) : style.color(\.text3))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(height: 14)
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
    }
}

/// Frame's strip: big previews of this capture, in every look or in the swatches of the fill kind picked, then one row
/// of the fill kinds, Padding, Shadow and Corners, the ratio's menu (Size for and Every capture in it) and the View pill.
/// A tile keeps its change as one undo step; a slider shows its value as it moves and keeps it when it lets go.
struct FrameStrip: View {
    @Environment(\.style) private var style
    let model: EditorModel
    var library = BackdropLibrary.shared
    @State private var kind: Kind

    /// `kind`: the swatches it opens on; a render picks one, the editor opens on the looks.
    init(model: EditorModel, kind: Kind = .looks) {
        self.model = model
        _kind = State(initialValue: kind)
    }

    enum Kind: CaseIterable {
        case looks, gradients, wallpapers, blurred, colours
        var title: String {
            switch self {
            case .looks: "Looks"
            case .gradients: "Gradients"
            case .wallpapers: "Wallpapers"
            case .blurred: "Blurred"
            case .colours: "Colours"
            }
        }
    }

    static let tile = CGSize(width: 120, height: 76)
    /// The strip's height: its padding, the tiles and their names, the gap, the row of controls.
    static func height(_ s: StyleTokens) -> CGFloat { 14 + tile.height + 4 + 14 + 12 + (s.kind == .toybox ? 34 : 28) + 14 }

    private var backdrop: Backdrop? { model.backdrop }
    private var accent: UInt32 { style.colors.accent.rgb }
    private var base: Backdrop { backdrop ?? BackdropLibrary.standard(accent: accent) }
    private var read: (edge: UInt32, thumb: CGImage) { BackdropPanel.read(model.image) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) { tiles }.padding(.horizontal, 16)
            }
            .scrollIndicators(.never)
            .frame(height: Self.tile.height + 4 + 14)
            ViewThatFits(in: .horizontal) {
                controls(view: true)
                controls(view: false)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 14)
        .onAppear { library.load() }
    }

    // MARK: Tiles

    @ViewBuilder private var tiles: some View {
        switch kind {
        case .looks: looks
        case .gradients:
            ForEach(Array(BackdropLibrary.gradients(accent: accent).enumerated()), id: \.offset) { _, g in fillTile(.gradient(g), name: "") }
        case .wallpapers:
            ForEach(library.wallpapers, id: \.self) { url in
                fillTile(.image(url.path), name: url.deletingPathExtension().lastPathComponent)
            }
            tile("Folders…", lit: false, help: "Pick the wallpaper folders in Look › Wallpaper") {
                Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(style.color(\.text3))
            } run: { AppWindowController.shared.open(.look) }
        case .blurred:
            ForEach(Backdrop.Blur.allCases.filter { $0 != .off }, id: \.self) { blur in
                let lit = backdrop.map { $0.fill.picture && $0.blur == blur } ?? false
                tile(blur.name, lit: lit, help: backdrop?.fill.picture == true ? "Blur the picture: \(blur.name)" : "The capture itself, blurred: \(blur.name)") {
                    FramePreview(backdrop: blurred(blur, toggling: false), subject: read.thumb, thumbs: library.thumbs)
                } run: { set(blurred(blur, toggling: true)) }
            }
        case .colours:
            fillTile(.clear, name: "See-through")
            ForEach(BackdropLibrary.colours(accent: accent, ground: style.colors.canvas.rgb), id: \.self) { rgb in
                fillTile(.colour(rgb), name: ColourAnswer.hex(rgb))
            }
            balanceTile
        }
    }

    /// None, Pilot's looks and the saved ones, then Save look; a look's menu frames every capture in it, or deletes a
    /// saved one (C1, C11).
    @ViewBuilder private var looks: some View {
        let current = library.look(matching: backdrop), every = library.everyCapture, saved = Set(library.presets.map(\.id))
        tile("None", lit: backdrop == nil, help: "No backdrop: the capture as it is") {
            FramePreview(backdrop: nil, subject: read.thumb)
        } run: { set(nil) }
        ForEach(library.looks) { look in
            let shown = look.backdrop.resolved(edge: read.edge)
            tile(look.name, lit: current?.id == look.id, every: every?.id == look.id,
                 help: every?.id == look.id ? "\(look.name), on every capture" : look.name) {
                FramePreview(backdrop: shown, subject: read.thumb, thumbs: library.thumbs)
            } run: { set(shown) }
            .contextMenu {
                if every?.id == look.id { Button("Stop Framing Every Capture") { library.setEveryCapture(nil) } }
                else { Button("Frame Every Capture in \(look.name)") { library.setEveryCapture(look) } }
                if saved.contains(look.id) { Button("Delete \(look.name)", role: .destructive) { library.deletePreset(look.id) } }
            }
        }
        tile("Save look", lit: false, help: "Save this backdrop as a look") {
            Image(systemName: "plus").font(.system(size: 15, weight: style.kind == .toybox ? .bold : .medium)).foregroundStyle(style.color(\.text2))
        } run: { library.savePreset(base) }
        .disabled(backdrop == nil).opacity(backdrop == nil ? 0.4 : 1)
    }

    /// A fill's tile: this capture on it, with the backdrop's padding, corners and shadow.
    private func fillTile(_ fill: Backdrop.Fill, name: String) -> some View {
        let lit = backdrop.map { $0.fill == fill && !$0.balance } ?? false
        return tile(name, lit: lit, help: BackdropPanel.help(fill, kind.title)) {
            FramePreview(backdrop: filled(fill), subject: read.thumb, thumbs: library.thumbs)
        } run: { set(filled(fill)) }
    }

    /// Auto balance (C2): the padding takes the capture's edge colour.
    private var balanceTile: some View {
        var b = base
        b.balance = true
        let balanced = b.resolved(edge: read.edge)
        return tile("Auto balance", lit: backdrop?.balance == true, help: "Auto balance: the padding takes the capture's edge colour") {
            FramePreview(backdrop: balanced, subject: read.thumb)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "wand.and.stars").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .padding(3).background(Circle().fill(Color.black.opacity(0.45))).padding(5)
                }
        } run: { set(balanced) }
    }

    private func tile(_ name: String, lit: Bool, every: Bool = false, help: String, @ViewBuilder _ face: () -> some View,
                      run: @escaping () -> Void) -> some View {
        let face = face()
        return Button(action: run) {
            VStack(spacing: 4) {
                PanelTile(lit: lit, height: Self.tile.height) { face }
                    .overlay(alignment: .topTrailing) {
                        if every {
                            Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(3).background(Circle().fill(Color.black.opacity(0.45))).padding(6)
                        }
                    }
                Text(name).styleText(\.caption).foregroundStyle(style.color(lit ? \.text : \.text3)).lineLimit(1).truncationMode(.middle)
                    .frame(height: 14)
            }
            .frame(width: Self.tile.width)
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(name.isEmpty ? help : name).accessibilityAddTraits(lit ? .isSelected : [])
    }

    // MARK: Controls

    private func controls(view: Bool) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                ForEach(Kind.allCases, id: \.self) { k in PanelChip(title: k.title, lit: kind == k) { kind = k } }
            }
            EditorRule()
            sliders
            EditorRule()
            ratio
            if view {
                Spacer(minLength: 0)
                EditorViewPill(model: model)
            }
        }
    }

    private var sliders: some View {
        HStack(spacing: 14) {
            PanelSlider(label: "Padding", value: base.pad, range: 0...Backdrop.maxPad, step: 4, unit: "pt") { v, done in change(done) { $0.pad = v } }
                .frame(width: 170)
            PanelSlider(label: "Shadow", value: base.shadow * 100, range: 0...100, step: 5, unit: "%") { v, done in change(done) { $0.shadow = v / 100 } }
                .frame(width: 170)
            PanelSlider(label: "Corners", value: base.radius, range: 0...Backdrop.maxRadius, step: 1, unit: "pt") { v, done in change(done) { $0.radius = v } }
                .frame(width: 170)
        }
    }

    /// The ratio's menu: Auto and the ratios, wide or tall, Size for's places (C9), and the look every capture gets (C11).
    private var ratio: some View {
        let b = base, place = backdrop?.place, current = library.look(matching: backdrop), every = library.everyCapture
        let title = place?.name ?? b.ratio.name(portrait: b.portrait)
        return Menu {
            Section("Ratio") {
                ForEach(Backdrop.Ratio.allCases, id: \.self) { r in
                    Toggle(r.name(portrait: b.portrait), isOn: Binding(get: { backdrop.map { $0.ratio == r && $0.place == nil } ?? false }, set: { _ in
                        var n = base
                        n.ratio = r
                        n.place = nil
                        set(n)
                    }))
                }
            }
            Section {
                Toggle("Wide", isOn: Binding(get: { !b.portrait }, set: { _ in orient(false) }))
                Toggle("Tall", isOn: Binding(get: { b.portrait }, set: { _ in orient(true) }))
            }
            Section("Size For") {
                ForEach(Backdrop.Place.allCases, id: \.self) { p in
                    Toggle("\(p.name)  \(Int(p.pixels.width)) × \(Int(p.pixels.height))", isOn: Binding(get: { place == p }, set: { _ in
                        var n = base
                        n.place = place == p ? nil : p
                        set(n)
                    }))
                }
            }
            Section("Every Capture") {
                if let current {
                    Toggle("Frame Every Capture in \(current.name)", isOn: Binding(get: { every?.id == current.id }, set: { on in
                        library.setEveryCapture(on ? current : nil)
                    }))
                } else if let every {
                    Button("Stop Framing Every Capture in \(every.name)") { library.setEveryCapture(nil) }
                } else {
                    Text("Pick a look to frame every capture in it")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Ratio").styleText(\.small).foregroundStyle(style.color(\.text3))
                Text(title).font(place == nil && b.ratio != .auto ? Font(EditorFooter.mono(style, 11)) : nil).styleText(\.small)
                    .foregroundStyle(style.color(\.text)).lineLimit(1)
                if every != nil { Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(style.color(\.text3)) }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(style.color(\.text3))
            }
            .padding(.horizontal, 10)
            .panelChipFace(style)
            .contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Ratio, size for a place, and the look every capture gets")
        .accessibilityLabel("Ratio, \(title)")
    }

    // MARK: Changes

    private func set(_ b: Backdrop?) { model.setBackdrop(b) }

    /// `fill` on the backdrop there is, or a new one; a wallpaper comes sharp.
    private func filled(_ fill: Backdrop.Fill) -> Backdrop {
        var b = base
        b.balance = false
        b.fill = fill
        if case .image = fill, backdrop?.fill != fill { b.blur = .off }
        return b
    }

    /// A blur: on a picture it blurs it (picked again with `toggling`, sharp again); on anything else the capture
    /// becomes the fill.
    private func blurred(_ blur: Backdrop.Blur, toggling: Bool) -> Backdrop {
        var b = base
        b.balance = false
        if b.fill.picture {
            b.blur = toggling && b.blur == blur ? .off : blur
        } else {
            b.fill = .capture
            b.blur = blur
        }
        return b
    }

    private func orient(_ tall: Bool) {
        var b = base
        b.portrait = tall
        set(b)
    }

    private func change(_ done: Bool, _ edit: (inout Backdrop) -> Void) {
        var b = base
        edit(&b)
        b = Backdrop(fill: b.fill, blur: b.blur, pad: b.pad, radius: b.radius, shadow: b.shadow, ratio: b.ratio, portrait: b.portrait,
                     balance: b.balance, place: b.place)
        if done { set(b) } else { model.previewBackdrop(b) }
    }
}

/// A look as Frame's tiles show it: this capture as a card on the backdrop's fill (a picture fill's picture, blurred as
/// the backdrop blurs it), with its padding, corners and shadow scaled to the tile; with no backdrop, on a checkerboard.
struct FramePreview: View {
    let backdrop: Backdrop?
    let subject: CGImage?
    var thumbs: [String: CGImage] = [:]

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height), k = side / 200
            let pad = backdrop.map { side * (0.07 + 0.13 * $0.pad / Backdrop.maxPad) } ?? 6
            ZStack {
                if let backdrop { fill(backdrop) } else { Checker() }
                if let subject {
                    Image(decorative: subject, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: (backdrop?.radius ?? 0) * k, style: .continuous))
                        .shadow(color: .black.opacity(0.4 * (backdrop?.shadow ?? 0)), radius: 4 * (backdrop?.shadow ?? 0), y: 2 * (backdrop?.shadow ?? 0))
                        .padding(pad)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    @ViewBuilder private func fill(_ b: Backdrop) -> some View {
        let blur = b.shownBlur
        switch b.fill {
        case .image(let path):
            if let picture = thumbs[path] { blurred(Image(decorative: picture, scale: 1), blur) } else { Color.gray.opacity(0.2) }
        case .capture:
            if let subject { blurred(Image(decorative: subject, scale: 1), blur) } else { Color.gray.opacity(0.2) }
        default:
            FillSwatch(fill: b.fill)
        }
    }

    private func blurred(_ image: Image, _ blur: Backdrop.Blur) -> some View {
        image.resizable().aspectRatio(contentMode: .fill)
            .blur(radius: blur == .off ? 0 : blur.radius / 6, opaque: true)
            .saturation(blur == .off ? 1 : blur.saturation).brightness(blur == .off ? 0 : blur.brightness)
            .overlay { if blur != .off { Color(Paint(blur.tint.rgb, blur.tint.alpha)) } }
    }
}
