import AppKit
import Observation
import PilotCore
import SwiftUI

// The backdrop panel (P70, after Snapzy's background sidebar, BSD-3): the capture editor's left-hand column, a view of
// its own that takes a backdrop and hands changes back, so the video editor (P71) mounts the same panel over its own
// model. Instrument's language: eyebrow capitals over hairline-ruled groups, square tiles on a hairline ring, the picked
// one ringed in the text colour (the signal keeps its one meaning), mono numbers, no shadows; Toybox's ink outlines.

/// What the panel offers beside the backdrop itself: the saved presets, the wallpapers of Look › Wallpaper with small
/// pictures of them, and whether the panel shows. Pictures are read small (96 pixels) off the main thread while an editor
/// is open, and let go when the last one closes.
@Observable @MainActor
final class BackdropLibrary {
    static let shared = BackdropLibrary()

    private(set) var presets: [BackdropPreset] { didSet { save() } }
    /// The desktop's picture now, then Look › Wallpaper's images by name, at most `wallpaperCount`.
    private(set) var wallpapers: [URL] = []
    private(set) var thumbs: [String: CGImage] = [:]
    /// Whether the editor shows the panel; remembered, so a panel opened once opens with every capture.
    var panelOpen: Bool { didSet { defaults.set(panelOpen, forKey: Self.openKey) } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loading: Task<Void, Never>?
    nonisolated static let wallpaperCount = 11
    private static let presetsKey = "capture.backdropPresets", openKey = "capture.backdropPanel"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        presets = defaults.data(forKey: Self.presetsKey).flatMap { try? JSONDecoder().decode([BackdropPreset].self, from: $0) } ?? []
        panelOpen = defaults.bool(forKey: Self.openKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.presetsKey) }
    }

    /// Saves `backdrop` as the next "Preset N"; it is returned.
    @discardableResult
    func savePreset(_ backdrop: Backdrop) -> BackdropPreset {
        let preset = BackdropPreset(name: BackdropPreset.nextName(presets), backdrop: backdrop)
        presets.append(preset)
        return preset
    }

    func deletePreset(_ id: UUID) { presets.removeAll { $0.id == id } }

    /// The preset that holds exactly `backdrop`, for the Presets menu's tick.
    func preset(matching backdrop: Backdrop?) -> BackdropPreset? { backdrop.flatMap { b in presets.first { $0.backdrop == b } } }

    /// Lists the wallpapers again and reads the pictures not read yet, off the main thread (a folder of thousands is
    /// listed in a child task, never on the tap's run loop).
    func load() {
        guard !fixed else { return }
        loading?.cancel()
        let sources = WallpaperSettings.shared.urls
        let desktop = NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) }.filter { WallpaperCycle.isImage($0) }
        let known = Set(thumbs.keys)
        loading = Task { @MainActor in
            let found = await Task.detached(priority: .utility) { () -> ([URL], [String: Unchecked<CGImage>]) in
                var seen = Set<String>()
                let list = (desktop + WallpaperCycle.images(in: sources)).filter { seen.insert($0.standardizedFileURL.path).inserted }
                    .prefix(Self.wallpaperCount)
                var read: [String: Unchecked<CGImage>] = [:]
                for url in list where !known.contains(url.path) {
                    if Task.isCancelled { break }
                    if let thumb = MarkupRenderer.readPicture(url, side: 96) { read[url.path] = Unchecked(thumb) }
                }
                return (Array(list), read)
            }.value
            guard !Task.isCancelled else { return }
            wallpapers = found.0
            for (path, thumb) in found.1 { thumbs[path] = thumb.value }
        }
    }

    /// Lets the pictures go: the last editor closed.
    func forget() {
        loading?.cancel()
        thumbs = [:]
    }

    /// A render's wallpapers stay as it set them.
    @ObservationIgnored private var fixed = false

    #if DEBUG
    /// Wallpapers read at once, for a render; the panel's own listing is off from then on.
    func setWallpapersNow(_ urls: [URL]) {
        fixed = true
        wallpapers = urls
        for url in urls { thumbs[url.path] = MarkupRenderer.readPicture(url, side: 96) }
    }
    #endif

    /// The gradients: the theme accent's wash first, then eleven of Pilot's own.
    static func gradients(accent: UInt32) -> [[UInt32]] {
        [[accent, 0x1D3B8F], [0xF7B267, 0xF25F5C, 0x8E44AD], [0x9BE7C4, 0x3BA7A0], [0x3A3D46, 0x121317], [0xFBD3E9, 0xBB6BD9],
         [0x5B8DEF, 0x1E2A78], [0xD4FC79, 0x5FC88F], [0xFFD8B1, 0xF38FA9], [0xC3B1E1, 0x5B4BB7], [0xFF7A59, 0xB3123F],
         [0x2A3045, 0x0B0C10], [0xF4F1EA, 0xDCD4C3]]
    }

    /// The plain colours: the theme's ground first, white, paper, ink, slate, the accent, then the marks' red, amber,
    /// green and blue, and violet. The panel puts see-through before them.
    static func colours(accent: UInt32, ground: UInt32) -> [UInt32] {
        [ground, 0xFFFFFF, 0xF4F1EA, 0x15161A, 0x2A2D35, accent, EditorModel.red, EditorModel.amber, EditorModel.green, EditorModel.blue, 0x8E5CF7]
    }

    /// A new backdrop's: the accent's wash, 48 points round, 12-point corners, half a shadow.
    static func standard(accent: UInt32) -> Backdrop { Backdrop(fill: .gradient(gradients(accent: accent)[0])) }
}

/// The panel: Presets, Gradients, Wallpapers, Blurred and Colours, then Padding, Shadow and Corners, then Ratio. `set`
/// keeps a change (one undo step); `live` shows a slider's value while it moves, `set` follows when it lets go. `subject`
/// is what a capture fill shows (the capture, or a video's frame), for the Blurred tiles.
struct BackdropPanel: View {
    @Environment(\.style) private var style
    let backdrop: Backdrop?
    let set: (Backdrop?) -> Void
    var live: (Backdrop) -> Void = { _ in }
    let subject: CGImage?
    var library = BackdropLibrary.shared
    nonisolated static let width: CGFloat = 248
    static let inset: CGFloat = 14
    static let columns = 6
    static let gap: CGFloat = 6

    private var accent: UInt32 { style.colors.accent.rgb }
    /// The backdrop a tile or slider changes: the one there is, or a new one.
    private var base: Backdrop { backdrop ?? BackdropLibrary.standard(accent: accent) }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                presets
                group("Gradients") {
                    grid(BackdropLibrary.gradients(accent: accent).map { Backdrop.Fill.gradient($0) }, help: "Gradient")
                }
                group("Wallpapers") { wallpapers }
                group("Blurred") { blurred }
                group("Colours") {
                    grid([.clear] + BackdropLibrary.colours(accent: accent, ground: style.colors.canvas.rgb).map { Backdrop.Fill.colour($0) }, help: "Colour")
                }
                style.color(\.line).frame(height: 1)
                sliders
                style.color(\.line).frame(height: 1)
                ratio
            }
            .padding(.horizontal, Self.inset).padding(.vertical, 14)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        .onAppear { library.load() }
    }

    // MARK: Groups

    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).lineLimit(1).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var presets: some View {
        group("Presets") {
            HStack(spacing: 6) {
                PanelChip(title: "None", lit: backdrop == nil) { set(nil) }.help("No backdrop: the capture as it is")
                let current = library.preset(matching: backdrop)
                Menu {
                    ForEach(library.presets) { p in
                        Button { set(p.backdrop) } label: { Text(p.name) + Text(p.id == current?.id ? "  ✓" : "") }
                    }
                    if !library.presets.isEmpty { Divider() }
                    Button("Save as new preset") { library.savePreset(base) }.disabled(backdrop == nil)
                    if let current { Button("Delete \(current.name)", role: .destructive) { library.deletePreset(current.id) } }
                } label: {
                    HStack(spacing: 4) {
                        Text(current?.name ?? (library.presets.isEmpty ? "No presets" : "Presets")).styleText(\.small).lineLimit(1)
                            .foregroundStyle(style.color(current == nil ? \.text2 : \.text))
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(style.color(\.text3))
                    }
                    .padding(.horizontal, 9).frame(maxWidth: .infinity)
                    .panelChipFace(style)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .help("Apply a saved backdrop, save this one, or delete one")
                Button { library.savePreset(base) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: style.kind == .toybox ? .bold : .medium)).foregroundStyle(style.color(\.text2))
                        .frame(width: 26).panelChipFace(style)
                }
                .buttonStyle(.plain).disabled(backdrop == nil).opacity(backdrop == nil ? 0.4 : 1)
                .help("Save this backdrop as a preset").accessibilityLabel("Save as preset")
            }
        }
    }

    @ViewBuilder private var wallpapers: some View {
        let fills = library.wallpapers.map { Backdrop.Fill.image($0.path) }
        if fills.isEmpty {
            Text("Add wallpaper folders in Look › Wallpaper").styleText(\.caption).foregroundStyle(style.color(\.text3))
        }
        tiles(fills.map { fill in (fill, "Wallpaper") }, extra: {
            Button { AppWindowController.shared.open(.look) } label: {
                PanelTile(lit: false) { Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(style.color(\.text3)) }
            }
            .buttonStyle(.plain).help("Pick the wallpaper folders in Look › Wallpaper").accessibilityLabel("Wallpaper folders")
        })
    }

    /// The four blurs as wide tiles, each showing the picture blurred that way: the wallpaper picked, else the capture.
    private var blurred: some View {
        let picture = blurSource
        return HStack(spacing: Self.gap) {
            ForEach(Backdrop.Blur.allCases.filter { $0 != .off }, id: \.self) { blur in
                let lit = backdrop.map { $0.fill.picture && $0.blur == blur } ?? false
                Button { pickBlur(blur) } label: {
                    VStack(spacing: 4) {
                        PanelTile(lit: lit, height: 30) {
                            if let picture {
                                Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                    .blur(radius: blur.radius / 8, opaque: true)
                                    .saturation(blur.saturation).brightness(blur.brightness)
                                    .overlay { Color(Paint(blur.tint.rgb, blur.tint.alpha)) }
                            }
                        }
                        Text(blur.name).styleText(\.caption).foregroundStyle(style.color(lit ? \.text : \.text3)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .help(backdrop?.fill.picture == true ? "Blur the picture: \(blur.name)" : "The capture itself, blurred: \(blur.name)")
            }
        }
    }

    /// What the Blurred tiles show: the picked wallpaper's small picture, else the capture's.
    private var blurSource: CGImage? {
        if case .image(let path)? = backdrop?.fill, let thumb = library.thumbs[path] { return thumb }
        return subject
    }

    /// A blur picked: on a picture it blurs it (picked again, sharp again); on anything else the capture becomes the fill.
    private func pickBlur(_ blur: Backdrop.Blur) {
        var b = base
        if b.fill.picture {
            b.blur = b.blur == blur ? .off : blur
        } else {
            b.fill = .capture
            b.blur = blur
        }
        set(b)
    }

    private var sliders: some View {
        VStack(spacing: 10) {
            PanelSlider(label: "Padding", value: base.pad, range: 0...Backdrop.maxPad, step: 4, unit: "pt") { v, done in change(done) { $0.pad = v } }
            PanelSlider(label: "Shadow", value: base.shadow * 100, range: 0...100, step: 5, unit: "%") { v, done in change(done) { $0.shadow = v / 100 } }
            PanelSlider(label: "Corners", value: base.radius, range: 0...Backdrop.maxRadius, step: 1, unit: "pt") { v, done in change(done) { $0.radius = v } }
        }
    }

    private func change(_ done: Bool, _ edit: (inout Backdrop) -> Void) {
        var b = base
        edit(&b)
        b = Backdrop(fill: b.fill, blur: b.blur, pad: b.pad, radius: b.radius, shadow: b.shadow, ratio: b.ratio, portrait: b.portrait)
        if done { set(b) } else { live(b) }
    }

    private var ratio: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RATIO").styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).accessibilityAddTraits(.isHeader)
                Spacer()
                HStack(spacing: 2) {
                    orientation(false, symbol: "rectangle", label: "Wide")
                    orientation(true, symbol: "rectangle.portrait", label: "Tall")
                }
            }
            HStack(spacing: 4) {
                ForEach(Backdrop.Ratio.allCases, id: \.self) { r in
                    PanelChip(title: r.name(portrait: base.portrait), lit: backdrop?.ratio == r, mono: r != .auto, full: true) {
                        var b = base
                        b.ratio = r
                        set(b)
                    }
                    .help(r == .auto ? "The padded capture's own shape" : "Grow the backdrop to \(r.name(portrait: base.portrait))")
                }
            }
        }
    }

    private func orientation(_ tall: Bool, symbol: String, label: String) -> some View {
        let lit = base.portrait == tall
        return Button {
            var b = base
            b.portrait = tall
            set(b)
        } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: style.kind == .toybox ? .bold : .regular))
                .foregroundStyle(style.color(lit ? \.text : \.text3)).frame(width: 22, height: 18)
                .background { if lit { RoundedRectangle(cornerRadius: style.radii.chip, style: .continuous).fill(style.color(\.raised)) } }
                .overlay { if lit { RoundedRectangle(cornerRadius: style.radii.chip, style: .continuous).strokeBorder(style.color(\.line2)) } }
                .contentShape(.rect)
        }
        .buttonStyle(.plain).help("\(label) ratios").accessibilityLabel(label).accessibilityAddTraits(lit ? .isSelected : [])
    }

    // MARK: Tiles

    private func grid(_ fills: [Backdrop.Fill], help: String) -> some View {
        tiles(fills.map { ($0, help) }, extra: { EmptyView() })
    }

    private func tiles(_ fills: [(Backdrop.Fill, String)], @ViewBuilder extra: () -> some View) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: Self.gap), count: Self.columns)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: Self.gap) {
            ForEach(Array(fills.enumerated()), id: \.offset) { _, item in
                let (fill, help) = item
                Button { pick(fill) } label: { PanelTile(lit: backdrop?.fill == fill) { FillSwatch(fill: fill, thumbs: library.thumbs) } }
                    .buttonStyle(.plain).help(Self.help(fill, help)).accessibilityLabel(Self.help(fill, help))
                    .accessibilityAddTraits(backdrop?.fill == fill ? .isSelected : [])
            }
            extra()
        }
    }

    /// A fill picked: a new backdrop in it, or the one there is with it; a wallpaper comes sharp.
    private func pick(_ fill: Backdrop.Fill) {
        var b = base
        b.fill = fill
        if case .image = fill, backdrop?.fill != fill { b.blur = .off }
        set(b)
    }

    static func help(_ fill: Backdrop.Fill, _ kind: String) -> String {
        switch fill {
        case .clear: "See-through"
        case .colour(let rgb): "\(kind) \(ColourAnswer.hex(rgb))"
        case .image(let path): URL(filePath: path).deletingPathExtension().lastPathComponent
        default: kind
        }
    }
}

/// One fill drawn in a tile: a checkerboard for see-through, the colour, the gradient, or the picture's small one.
struct FillSwatch: View {
    let fill: Backdrop.Fill
    var thumbs: [String: CGImage] = [:]

    var body: some View {
        switch fill {
        case .clear: Checker()
        case .colour(let rgb): Color(Paint(rgb))
        case .gradient(let colours): LinearGradient(colors: colours.map { Color(Paint($0)) }, startPoint: .topLeading, endPoint: .bottomTrailing)
        case .image(let path):
            if let thumb = thumbs[path] { Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill) } else { Color.gray.opacity(0.2) }
        case .capture: Color.gray.opacity(0.2)
        }
    }
}

/// A square tile (or `height` high, the Blurred row's): its content clipped to the style's chip corners on a hairline
/// ring; picked, ringed outside in the text colour.
struct PanelTile<Content: View>: View {
    @Environment(\.style) private var style
    let lit: Bool
    var height: CGFloat?
    @ViewBuilder let content: () -> Content

    var body: some View {
        let toy = style.kind == .toybox, r: CGFloat = toy ? 7 : 5
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        Group {
            if let height { Color.clear.frame(maxWidth: .infinity).frame(height: height) }
            else { Color.clear.frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit) }
        }
            .overlay { content() }
            .background(style.color(\.raised))
            .clipShape(shape)
            .overlay { shape.strokeBorder(toy ? style.color(\.outline) : Color(hex: style.dark ? 0xFFFFFF : 0x000000, opacity: 0.12), lineWidth: toy ? 2 : 1) }
            .padding(2)
            .overlay { if lit { RoundedRectangle(cornerRadius: r + 2, style: .continuous).strokeBorder(style.color(\.text), lineWidth: toy ? 2.5 : 1.5) } }
            .contentShape(.rect)
    }
}

/// A small word button on the chips' face: None, the ratios; lit, the raised fill in the text colour's ring.
struct PanelChip: View {
    @Environment(\.style) private var style
    let title: String
    let lit: Bool
    var mono = false
    var full = false
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            Text(title)
                .font(mono ? Font(DisplayFaces.font(style.kind == .toybox ? StyleTokens.jetBrainsMono(600) : StyleTokens.geistMono(500), size: 10.5)) : nil)
                .styleText(\.small)
                .foregroundStyle(style.color(lit ? \.text : \.text2)).lineLimit(1).fixedSize()
                .padding(.horizontal, full ? 0 : 10).frame(maxWidth: full ? .infinity : nil)
                .panelChipFace(style, lit: lit)
                .contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityAddTraits(lit ? .isSelected : [])
    }
}

extension View {
    /// The panel's chip face: 24 high on the raised fill in a hairline (Toybox's ink outline); lit, ringed in the text
    /// colour, as a picked tile is.
    func panelChipFace(_ style: StyleTokens, lit: Bool = false) -> some View {
        let toy = style.kind == .toybox
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        return frame(height: toy ? 28 : 24)
            .background { shape.fill(style.color(\.raised)) }
            .overlay { shape.strokeBorder(lit ? style.color(\.text) : style.color(toy ? \.outline : \.line2), lineWidth: lit ? 1.5 : (toy ? 2 : 1)) }
    }
}

/// A slider with its word on the left and its value in mono on the right, in its own units; `set` hears every move,
/// `done` true on the last.
struct PanelSlider: View {
    @Environment(\.style) private var style
    let label: String
    let value: CGFloat
    let range: ClosedRange<CGFloat>
    var step: CGFloat = 1
    var unit = ""
    let set: (CGFloat, _ done: Bool) -> Void

    var body: some View {
        let toy = style.kind == .toybox
        HStack(spacing: 10) {
            Text(label).styleText(\.small).foregroundStyle(style.color(\.text2)).frame(width: 52, alignment: .leading).lineLimit(1)
            GeometryReader { geo in
                let width = geo.size.width, knob: CGFloat = toy ? 16 : 12
                let fraction = (min(range.upperBound, max(range.lowerBound, value)) - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Capsule().fill(style.color(toy ? \.sunken : \.line2)).frame(height: toy ? 8 : 4)
                        .overlay { if toy { Capsule().strokeBorder(style.color(\.outline), lineWidth: 2) } }
                    Capsule().fill(style.color(toy ? \.accent : \.text2)).frame(width: (width - knob) * fraction + knob / 2, height: toy ? 8 : 4)
                    Circle().fill(style.color(\.knob))
                        .overlay { Circle().strokeBorder(style.color(toy ? \.outline : \.line2), lineWidth: toy ? 2 : 1) }
                        .shadow(color: .black.opacity(toy ? 0 : 0.25), radius: 1, y: 0.5)
                        .frame(width: knob, height: knob)
                        .offset(x: (width - knob) * fraction)
                }
                .frame(height: geo.size.height)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in set(at(g.location.x, width: width, knob: knob), false) }
                    .onEnded { g in set(at(g.location.x, width: width, knob: knob), true) })
            }
            .frame(height: 20)
            Text(verbatim: "\(Int(value.rounded()))")
                .font(Font(DisplayFaces.font(toy ? StyleTokens.jetBrainsMono(600) : StyleTokens.geistMono(500), size: 11)))
                .monospacedDigit().foregroundStyle(style.color(\.text)).frame(width: 26, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value.rounded())) \(unit == "%" ? "percent" : "points")")
        .accessibilityAdjustableAction { set(min(range.upperBound, max(range.lowerBound, value + ($0 == .increment ? step : -step))), true) }
    }

    /// The value under `x`, on the step.
    private func at(_ x: CGFloat, width: CGFloat, knob: CGFloat) -> CGFloat {
        let f = min(1, max(0, (x - knob / 2) / max(width - knob, 1)))
        return ((range.lowerBound + f * (range.upperBound - range.lowerBound)) / step).rounded() * step
    }
}
