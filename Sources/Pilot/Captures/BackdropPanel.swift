import AppKit
import Observation
import PilotCore
import SwiftUI

// The backdrop panel (P70, after Snapzy's background sidebar, BSD-3): the capture editor's left-hand column, a view of
// its own that takes a backdrop and hands changes back, so the video editor (P71) mounts the same panel over its own
// model. Instrument's language: eyebrow capitals over hairline-ruled groups, square tiles on a hairline ring, the picked
// one ringed in the text colour (the signal keeps its one meaning), mono numbers, no shadows; Toybox's ink outlines.

/// What the panel offers beside the backdrop itself: the saved presets (a capture's backdrops, a video's whole looks),
/// the wallpapers of Look › Wallpaper with small pictures of them, and whether the panel shows. Pictures are read small (96 pixels) off the main thread while an editor
/// is open, and let go when the last one closes.
@Observable @MainActor
final class BackdropLibrary {
    static let shared = BackdropLibrary()

    private(set) var presets: [BackdropPreset] { didSet { save() } }
    /// R12: the video editor's saved looks, kept apart from the capture's backdrops.
    private(set) var videoPresets: [VideoPreset] { didSet { save() } }
    /// R12: the saved look every video the editor opens starts in; nil for none.
    private(set) var everyRecordingID: UUID? {
        didSet { defaults.set(everyRecordingID?.uuidString, forKey: Self.everyRecordingKey) }
    }
    /// The desktop's picture now, then Look › Wallpaper's images by name, at most `wallpaperCount`.
    private(set) var wallpapers: [URL] = []
    /// The newest captures in History, for Add a capture (C8), at most `wallpaperCount`; their small pictures are in `thumbs`.
    private(set) var recent: [URL] = []
    private(set) var thumbs: [String: CGImage] = [:]
    /// Whether the editor shows the panel; remembered, so a panel opened once opens with every capture.
    var panelOpen: Bool { didSet { defaults.set(panelOpen, forKey: Self.openKey) } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loading: Task<Void, Never>?
    nonisolated static let wallpaperCount = 11
    private static let presetsKey = "capture.backdropPresets", openKey = "capture.backdropPanel"
    private static let videoPresetsKey = "capture.videoPresets", everyRecordingKey = "capture.videoPresetEveryRecording"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        presets = defaults.data(forKey: Self.presetsKey).flatMap { try? JSONDecoder().decode([BackdropPreset].self, from: $0) } ?? []
        videoPresets = defaults.data(forKey: Self.videoPresetsKey).flatMap { try? JSONDecoder().decode([VideoPreset].self, from: $0) } ?? []
        everyRecordingID = defaults.string(forKey: Self.everyRecordingKey).flatMap(UUID.init(uuidString:))
        panelOpen = defaults.bool(forKey: Self.openKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.presetsKey) }
        if let data = try? JSONEncoder().encode(videoPresets) { defaults.set(data, forKey: Self.videoPresetsKey) }
    }

    /// R12: saves `look` as the next "Look N"; it is returned.
    @discardableResult
    func saveVideoPreset(_ look: VideoPreset) -> VideoPreset {
        var preset = look
        preset.id = UUID()
        preset.name = VideoPreset.nextName(videoPresets)
        videoPresets.append(preset)
        return preset
    }

    func deleteVideoPreset(_ id: UUID) {
        videoPresets.removeAll { $0.id == id }
        if everyRecordingID == id { everyRecordingID = nil }
    }

    /// The saved look `look` is, for the Presets menu's tick.
    func videoPreset(matching look: VideoPreset) -> VideoPreset? { videoPresets.first { $0.sameLook(look) } }

    /// The look every video opens in, nil for none.
    var everyRecording: VideoPreset? { everyRecordingID.flatMap { id in videoPresets.first { $0.id == id } } }

    func setEveryRecording(_ preset: VideoPreset?) { everyRecordingID = preset?.id }

    /// Saves `backdrop` as the next "Preset N"; it is returned.
    @discardableResult
    func savePreset(_ backdrop: Backdrop) -> BackdropPreset {
        let preset = BackdropPreset(name: BackdropPreset.nextName(presets), backdrop: backdrop)
        presets.append(preset)
        return preset
    }

    func deletePreset(_ id: UUID) { presets.removeAll { $0.id == id } }

    /// The preset that holds exactly `backdrop`, for the video Presets menu's tick.
    func preset(matching backdrop: Backdrop?) -> BackdropPreset? { backdrop.flatMap { b in presets.first { $0.backdrop == b } } }

    /// Pilot's own looks, then the saved presets (C1).
    var looks: [BackdropPreset] { BackdropPreset.looks + presets }

    /// The look `backdrop` is, Pilot's or a saved one: a balanced look whatever edge colour it read.
    func look(matching backdrop: Backdrop?) -> BackdropPreset? { backdrop.flatMap { b in looks.first { $0.backdrop.sameLook(b) } } }

    /// The look every capture's copy is framed in (C11), nil for none or a preset deleted since.
    var everyCapture: BackdropPreset? {
        CaptureSettingsStore.shared.settings.everyCaptureLook.flatMap { BackdropPreset.find($0, in: presets) }
    }

    func setEveryCapture(_ look: BackdropPreset?) { CaptureSettingsStore.shared.settings.everyCaptureLook = look?.id.uuidString }

    /// Lists the wallpapers again and reads the pictures not read yet, off the main thread (a folder of thousands is
    /// listed in a child task, never on the tap's run loop).
    func load() {
        guard !fixed else { return }
        loading?.cancel()
        let sources = WallpaperSettings.shared.urls
        let desktop = NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) }.filter { WallpaperCycle.isImage($0) }
        let known = Set(thumbs.keys)
        loading = Task { @MainActor in
            let captures = await CaptureHistoryStore.shared.entries().filter { $0.kind == .capture }.prefix(Self.wallpaperCount).map(\.url)
            let found = await Task.detached(priority: .utility) { () -> ([URL], [String: Unchecked<CGImage>]) in
                var seen = Set<String>()
                let list = (desktop + WallpaperCycle.images(in: sources)).filter { seen.insert($0.standardizedFileURL.path).inserted }
                    .prefix(Self.wallpaperCount)
                var read: [String: Unchecked<CGImage>] = [:]
                for url in list + captures where !known.contains(url.path) {
                    if Task.isCancelled { break }
                    if let thumb = MarkupRenderer.readPicture(url, side: 96) { read[url.path] = Unchecked(thumb) }
                }
                return (Array(list), read)
            }.value
            guard !Task.isCancelled else { return }
            wallpapers = found.0
            recent = captures
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
    func setWallpapersNow(_ urls: [URL], recent captures: [URL] = []) {
        fixed = true
        wallpapers = urls
        recent = captures
        for url in urls + captures { thumbs[url.path] = MarkupRenderer.readPicture(url, side: 96) }
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

/// The panel: Presets, Gradients, Wallpapers, Blurred and Colours, then Padding, Shadow and Corners, then Ratio (a
/// video's Shape). `set` keeps a change (one undo step); `live` shows a slider's value while it moves, `set` follows when
/// it lets go. `subject` is what a capture fill shows (the capture, or a video's frame), for the Blurred tiles.
struct BackdropPanel: View {
    @Environment(\.style) private var style
    let backdrop: Backdrop?
    let set: (Backdrop?) -> Void
    var live: (Backdrop) -> Void = { _ in }
    let subject: CGImage?
    var library = BackdropLibrary.shared
    /// The capture editor's own rows: Looks with Every capture (C1, C11), Balance (C2), sizes by place (C9).
    var capture = false
    /// Add a capture (C8): the picked file and how the two sit; nil hides the group.
    var add: ((URL, CombineLayout.Direction) -> Void)?
    /// The video editor's rows: Presets of the whole look (R12) beside the saved backdrops, and Shape (R9) over Ratio.
    var video: VideoLookControls?

    /// What the video editor hands the panel: its edit's look now, and how to apply a saved one or a shape.
    struct VideoLookControls {
        let look: VideoPreset
        let apply: (VideoPreset) -> Void
        let setShape: (VideoShape) -> Void
    }
    @State private var direction: CombineLayout.Direction = .sideBySide
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
                if capture { looks } else if let video { videoPresets(video) }
                group("Gradients") {
                    grid(BackdropLibrary.gradients(accent: accent).map { Backdrop.Fill.gradient($0) }, help: "Gradient")
                }
                group("Wallpapers") { wallpapers }
                group("Blurred") { blurred }
                group("Colours") {
                    tiles(([.clear] + BackdropLibrary.colours(accent: accent, ground: style.colors.canvas.rgb).map { Backdrop.Fill.colour($0) }).map { ($0, "Colour") }) {
                        if capture { balanceTile }
                    }
                }
                style.color(\.line).frame(height: 1)
                sliders
                style.color(\.line).frame(height: 1)
                if let video { shapes(video) }
                if video?.look.shape ?? .recorded == .recorded { ratio }
                if let add {
                    style.color(\.line).frame(height: 1)
                    adding(add)
                }
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

    /// R12: None, the saved looks (each the backdrop, shape, motion blur and pointer) and the saved backdrops, save this
    /// look, delete it, and the look every video opens in (over a recording's own pointer settings).
    private func videoPresets(_ video: VideoLookControls) -> some View {
        let current = library.videoPreset(matching: video.look), every = library.everyRecording, backdropPreset = library.preset(matching: backdrop)
        return group("Presets") {
            HStack(spacing: 6) {
                PanelChip(title: "None", lit: backdrop == nil) { set(nil) }.help("No backdrop: the recording as it is")
                Menu {
                    Section("Looks") {
                        ForEach(library.videoPresets) { p in
                            Button { video.apply(p) } label: { Text(p.name) + Text(p.id == current?.id ? "  ✓" : "") }
                        }
                    }
                    if !library.presets.isEmpty {
                        Section("Backdrops") {
                            ForEach(library.presets) { p in
                                Button { set(p.backdrop) } label: { Text(p.name) + Text(p.id == backdropPreset?.id ? "  ✓" : "") }
                            }
                        }
                    }
                    Divider()
                    Button("Save this look") { library.saveVideoPreset(video.look) }
                    if let current {
                        if every?.id == current.id { Button("Stop opening videos in \(current.name)") { library.setEveryRecording(nil) } }
                        else { Button("Open videos in \(current.name)") { library.setEveryRecording(current) } }
                        Button("Delete \(current.name)", role: .destructive) { library.deleteVideoPreset(current.id) }
                    }
                    if let backdropPreset { Button("Delete backdrop \(backdropPreset.name)", role: .destructive) { library.deletePreset(backdropPreset.id) } }
                } label: {
                    HStack(spacing: 4) {
                        Text(current?.name ?? (library.videoPresets.isEmpty ? "No looks" : "Looks")).styleText(\.small).lineLimit(1)
                            .foregroundStyle(style.color(current == nil ? \.text2 : \.text))
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(style.color(\.text3))
                    }
                    .padding(.horizontal, 9).frame(maxWidth: .infinity)
                    .panelChipFace(style)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .help("Apply a saved look (backdrop, shape, motion blur, pointer) or backdrop, save this look, or open videos in it")
                Button { library.saveVideoPreset(video.look) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: style.kind == .toybox ? .bold : .medium)).foregroundStyle(style.color(\.text2))
                        .frame(width: 26).panelChipFace(style)
                }
                .buttonStyle(.plain).help("Save this look: backdrop, shape, motion blur and pointer").accessibilityLabel("Save this look")
            }
            if let every {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(style.color(\.text3))
                    Text("Videos open in \(every.name)").styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1)
                    Spacer(minLength: 2)
                    Button("Stop") { library.setEveryRecording(nil) }.buttonStyle(.plain).styleText(\.caption).foregroundStyle(style.color(\.text3))
                        .help("Videos stop opening in this look")
                }
            }
        }
    }

    /// R9: the export's shape; any but Auto aims the camera at the pointer inside it.
    private func shapes(_ video: VideoLookControls) -> some View {
        group("Shape") {
            HStack(spacing: 4) {
                ForEach(VideoShape.allCases, id: \.self) { shape in
                    PanelChip(title: shape.title, lit: video.look.shape == shape, mono: shape != .recorded, full: true) { video.setShape(shape) }
                        .help(shape == .recorded ? "The recording's own shape" : "A \(shape.title) frame that follows the pointer")
                }
            }
            if video.look.shape != .recorded {
                Text("The frame follows the pointer; zooms go in from there. Ratio waits for Auto.").styleText(\.caption).foregroundStyle(style.color(\.text3))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Looks (C1): None, Pilot's own, the saved presets, then save this one; each a small picture of the look round the
    /// capture, one click to apply. The menu saves, deletes a saved one, and sets the look every capture's copy gets (C11).
    private var looks: some View {
        let all = library.looks, current = library.look(matching: backdrop), every = library.everyCapture
        let read = subject.map(Self.read), saved = Set(library.presets.map(\.id))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LOOKS").styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    if let current { lookActions(current, every: every, saved: saved) }
                    else if every != nil { Button("Stop framing every capture") { library.setEveryCapture(nil) } }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(style.color(\.text2))
                        .frame(width: 26, height: 18).contentShape(.rect)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Frame every capture in this look, or delete a saved one").accessibilityLabel("Look options")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.gap), count: 4), alignment: .leading, spacing: Self.gap) {
                lookTile("None", lit: backdrop == nil, help: "No backdrop: the capture as it is") { Checker() } run: { set(nil) }
                ForEach(all) { look in
                    let shown = look.backdrop.resolved(edge: read?.edge)
                    lookTile(look.name, lit: current?.id == look.id, every: every?.id == look.id,
                             help: every?.id == look.id ? "\(look.name), on every capture" : look.name) {
                        LookSwatch(backdrop: shown, subject: read?.thumb)
                    } run: { set(shown) }
                    .contextMenu { lookActions(look, every: every, saved: saved) }
                }
                lookTile("Save", lit: false, help: "Save this backdrop as a look") {
                    Image(systemName: "plus").font(.system(size: 12, weight: style.kind == .toybox ? .bold : .medium)).foregroundStyle(style.color(\.text2))
                } run: { library.savePreset(base) }
                .disabled(backdrop == nil).opacity(backdrop == nil ? 0.4 : 1)
            }
            if let every {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(style.color(\.text3))
                    Text("Every capture: \(every.name)").styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1)
                    Spacer(minLength: 2)
                    Button("Stop") { library.setEveryCapture(nil) }.buttonStyle(.plain).styleText(\.caption).foregroundStyle(style.color(\.text3))
                        .help("Copies stop getting this look")
                }
            }
        }
    }

    /// A look's menu, on its tile and the row's ⋯: frame every capture in it (or stop), and delete it when it is saved.
    @ViewBuilder private func lookActions(_ look: BackdropPreset, every: BackdropPreset?, saved: Set<UUID>) -> some View {
        if every?.id == look.id { Button("Stop framing every capture") { library.setEveryCapture(nil) } }
        else { Button("Frame every capture in \(look.name)") { library.setEveryCapture(look) } }
        if saved.contains(look.id) { Button("Delete \(look.name)", role: .destructive) { library.deletePreset(look.id) } }
    }

    private func lookTile(_ name: String, lit: Bool, every: Bool = false, help: String, @ViewBuilder _ face: () -> some View,
                          run: @escaping () -> Void) -> some View {
        let face = face()
        return Button(action: run) {
            VStack(spacing: 3) {
                PanelTile(lit: lit, height: 34) { face }
                    .overlay(alignment: .topTrailing) {
                        if every {
                            Image(systemName: "sparkles").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                .padding(2).background(Circle().fill(Color.black.opacity(0.45))).padding(4)
                        }
                    }
                Text(name).styleText(\.caption).foregroundStyle(style.color(lit ? \.text : \.text3)).lineLimit(1)
            }
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(name).accessibilityAddTraits(lit ? .isSelected : [])
    }

    /// Auto balance (C2): the padding takes the capture's edge colour; the tile shows that colour.
    private var balanceTile: some View {
        let lit = backdrop?.balance == true
        let edge = subject.map(Self.read)?.edge
        return Button {
            var b = base
            b.balance = true
            set(b.resolved(edge: edge))
        } label: {
            PanelTile(lit: lit) {
                ZStack {
                    if let edge { Color(Paint(edge)) }
                    Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(edge.map { Contrast.luminance(Contrast.rgb($0)) > 0.45 ? Color.black.opacity(0.7) : Color.white.opacity(0.85) }
                                         ?? style.color(\.text2))
                }
            }
        }
        .buttonStyle(.plain).help("Auto balance: the padding takes the capture's edge colour").accessibilityLabel("Auto balance")
        .accessibilityAddTraits(lit ? .isSelected : [])
    }

    /// The last capture's edge colour (Balance's) and small picture (the look tiles'), read once per capture, not per draw;
    /// held with the capture itself, so a later one at the same address never reads as it, and let go when an editor closes.
    @MainActor private static var subjectRead: (image: CGImage, edge: UInt32, thumb: CGImage)?
    static func read(_ image: CGImage) -> (edge: UInt32, thumb: CGImage) {
        if let r = subjectRead, r.image === image { return (r.edge, r.thumb) }
        let r = (image: image, edge: MarkupRenderer.edgeColour(image), thumb: MarkupRenderer.scaled(image, side: 160) ?? image)
        subjectRead = r
        return (r.edge, r.thumb)
    }

    static func forgetSubject() { subjectRead = nil }

    /// Add a capture (C8): History's newest captures and Choose…; the one picked joins this one, beside it or under it,
    /// in a new capture with this backdrop.
    private func adding(_ add: @escaping (URL, CombineLayout.Direction) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ADD A CAPTURE").styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).accessibilityAddTraits(.isHeader)
                Spacer()
                HStack(spacing: 2) {
                    layoutButton(.sideBySide, symbol: "rectangle.split.2x1")
                    layoutButton(.stacked, symbol: "rectangle.split.1x2")
                }
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: Self.gap), count: Self.columns)
            LazyVGrid(columns: columns, alignment: .leading, spacing: Self.gap) {
                ForEach(library.recent, id: \.self) { url in
                    Button { add(url, direction) } label: {
                        PanelTile(lit: false) {
                            if let thumb = library.thumbs[url.path] { Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                            else { Color.gray.opacity(0.2) }
                        }
                    }
                    .buttonStyle(.plain).help("Add \(url.deletingPathExtension().lastPathComponent)").accessibilityLabel("Add \(url.lastPathComponent)")
                }
                Button { if let url = Self.choose() { add(url, direction) } } label: {
                    PanelTile(lit: false) { Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(style.color(\.text3)) }
                }
                .buttonStyle(.plain).help("Add a picture from a file").accessibilityLabel("Choose a picture")
            }
            Text("Before and after: both in one capture, this backdrop round them.").styleText(\.caption).foregroundStyle(style.color(\.text3))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func layoutButton(_ d: CombineLayout.Direction, symbol: String) -> some View {
        iconToggle(symbol: symbol, lit: direction == d, help: d.title, label: d.title) { direction = d }
    }

    /// An image file picked in an open panel, from the captures folder.
    private static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.directoryURL = CaptureSettingsStore.shared.folder(.capture)
        panel.prompt = "Add"
        return panel.runModal() == .OK ? panel.url : nil
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
        b.balance = false
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
        b = Backdrop(fill: b.fill, blur: b.blur, pad: b.pad, radius: b.radius, shadow: b.shadow, ratio: b.ratio, portrait: b.portrait,
                     balance: b.balance, place: b.place)
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
                    PanelChip(title: r.name(portrait: base.portrait), lit: backdrop.map { $0.ratio == r && $0.place == nil } ?? false, mono: r != .auto, full: true) {
                        var b = base
                        b.ratio = r
                        b.place = nil
                        set(b)
                    }
                    .help(r == .auto ? "The padded capture's own shape" : "Grow the backdrop to \(r.name(portrait: base.portrait))")
                }
            }
            if capture { places }
        }
    }

    /// Sizes by place (C9): each grows the backdrop to the place's shape and exports at its pixels; picked again, off.
    private var places: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SIZE FOR").styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(Backdrop.Place.allCases, id: \.self) { p in
                    let lit = backdrop?.place == p
                    PanelChip(title: p.name, lit: lit, full: true) {
                        var b = base
                        b.place = lit ? nil : p
                        set(b)
                    }
                    .help(lit ? "Back to the ratio" : "Export at \(Int(p.pixels.width)) × \(Int(p.pixels.height)) for \(p.name), never stretched")
                }
            }
            if let p = backdrop?.place {
                Text(verbatim: "\(Int(p.pixels.width)) × \(Int(p.pixels.height)) px, the capture never stretched").styleText(\.caption)
                    .foregroundStyle(style.color(\.text3)).monospacedDigit()
            }
        }
    }

    private func orientation(_ tall: Bool, symbol: String, label: String) -> some View {
        iconToggle(symbol: symbol, lit: base.portrait == tall, help: "\(label) ratios", label: label) {
            var b = base
            b.portrait = tall
            set(b)
        }
    }

    /// A small glyph toggle beside an eyebrow: Ratio's wide and tall, Add a capture's beside and under.
    private func iconToggle(symbol: String, lit: Bool, help: String, label: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 10, weight: style.kind == .toybox ? .bold : .regular))
                .foregroundStyle(style.color(lit ? \.text : \.text3)).frame(width: 22, height: 18)
                .background { if lit { RoundedRectangle(cornerRadius: style.radii.chip, style: .continuous).fill(style.color(\.raised)) } }
                .overlay { if lit { RoundedRectangle(cornerRadius: style.radii.chip, style: .continuous).strokeBorder(style.color(\.line2)) } }
                .contentShape(.rect)
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(label).accessibilityAddTraits(lit ? .isSelected : [])
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
                let lit = backdrop.map { $0.fill == fill && !$0.balance } ?? false
                Button { pick(fill) } label: { PanelTile(lit: lit) { FillSwatch(fill: fill, thumbs: library.thumbs) } }
                    .buttonStyle(.plain).help(Self.help(fill, help)).accessibilityLabel(Self.help(fill, help))
                    .accessibilityAddTraits(lit ? .isSelected : [])
            }
            extra()
        }
    }

    /// A fill picked: a new backdrop in it, or the one there is with it; a wallpaper comes sharp.
    private func pick(_ fill: Backdrop.Fill) {
        var b = base
        b.balance = false
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

/// A look in a tile (C1): its fill, and the capture as a small rounded card in it with the look's padding and shadow.
struct LookSwatch: View {
    let backdrop: Backdrop
    let subject: CGImage?

    var body: some View {
        GeometryReader { geo in
            let pad = 3 + 5 * backdrop.pad / Backdrop.maxPad
            ZStack {
                FillSwatch(fill: backdrop.fill)
                if backdrop.fill.picture, let subject {
                    Image(decorative: subject, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: backdrop.shownBlur.radius / 10, opaque: true)
                        .overlay { Color(Paint(backdrop.shownBlur.tint.rgb, backdrop.shownBlur.tint.alpha)) }
                }
                Group {
                    if let subject { Image(decorative: subject, scale: 1).resizable().aspectRatio(contentMode: .fill) } else { Color.white }
                }
                .frame(width: max(4, geo.size.width - 2 * pad), height: max(4, geo.size.height - 2 * pad))
                .clipShape(RoundedRectangle(cornerRadius: backdrop.radius / 8, style: .continuous))
                .shadow(color: .black.opacity(0.4 * backdrop.shadow), radius: 2 * backdrop.shadow, y: backdrop.shadow)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
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
