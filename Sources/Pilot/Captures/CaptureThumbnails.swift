import AppKit
import Observation
import PilotCore
import SwiftUI
import UniformTypeIdentifiers

/// After a capture (Sven, build 54; Captures › After capture: Thumbnail, the default): a small picture of it floats in
/// the screen's bottom-right corner (Captures › Thumbnail place: any corner or the middle), stacked above earlier ones, at most four. A click opens it in the editor, a drag
/// takes the file out to any app, and on hover it offers edit, close, copy and Save As, with their keys while the pointer
/// is on it (⌘E, ⌘W, ⌘C, ⌘S; Q189, CleanShot's overlay); it goes on its own after six seconds, or three after the
/// pointer leaves it. The last one closed comes back with Show the last thumbnail again. A thumbnail takes the keys only
/// while the pointer is on it, and never the front app's place.
@MainActor
enum CaptureThumbnails {
    private(set) static var shown: [ThumbnailPanel] = []
    /// The file of the last thumbnail that went, however it went, for Show the last thumbnail again: its file, never its
    /// picture, which is cut from the whole display's still and would keep all of it alive while Pilot idles.
    private(set) static var lastClosed: URL?
    /// The capture a thumbnail's actions act for; the app's own.
    private static var capture: PilotCapture?
    /// False in tests: the panels are made, never ordered onto Sven's screen.
    static var onScreen = true

    /// `look` is Every capture's (C11): Copy frames the capture in it, and the editor opens in it.
    @discardableResult
    static func show(_ image: CGImage, scale: CGFloat, file: URL?, capture: PilotCapture, look: Backdrop? = nil) -> ThumbnailPanel {
        self.capture = capture
        let model = ThumbnailModel(image: image, scale: scale, file: file)
        let panel = ThumbnailPanel(model: model)
        // A recording's thumbnail (P71) is a frame of it: Edit opens the video editor, Copy and Save As take the file.
        let video = file.flatMap { VideoEditor.isVideo($0) ? $0 : nil }
        model.open = { [weak panel] in
            guard let panel else { return }
            // The editor first, so it holds the capture's grab before the thumbnail lets go of it.
            if let video { VideoEditor.open(video) } else { CaptureEditor.show(image, scale: scale, file: file, capture: capture, backdrop: look) }
            dismiss(panel)
        }
        // A new recording goes with its pointer drawn in (Q821): drawn from the start in the background, its progress on
        // the card, so Copy and a drag rarely wait (a press that waits raises the export's priority).
        if let video {
            Task { @MainActor [weak model] in
                _ = try? await RecordingHandout.file(for: video, priority: .utility, restart: false) { model?.drawing($0) }
                model?.drawing(nil)
            }
            model.drag = { RecordingHandout.provider(for: video) }
            model.copySays = true
        }
        model.copy = { [weak model] in
            if let video {
                Task { @MainActor in
                    guard let file = try? await RecordingHandout.file(for: video, progress: { model?.drawing($0) }) else { return }
                    model?.drawing(nil)
                    capture.pasteboard.clearContents()
                    capture.pasteboard.writeObjects([file as NSURL])
                    model?.flash("Copied")
                }
                return
            }
            capture.pasteboard.clearContents()
            guard let look else {
                guard let png = PilotCapture.png(image, scale: scale) else { return }
                capture.pasteboard.setData(png, forType: .png)
                return
            }
            Task { @MainActor in
                if let png = await PilotCapture.framedPNG(image, scale: scale, look: look).value { capture.pasteboard.setData(png, forType: .png) }
            }
        }
        model.saveAs = { [weak panel] in
            if let panel { dismiss(panel) }
            if let video { saveAs(video) } else { saveAs(image, scale: scale, suggested: file?.lastPathComponent) }
        }
        model.close = { [weak panel] in if let panel { dismiss(panel) } }
        model.askAI = { [weak panel] in
            if let panel { dismiss(panel) }
            // A recording's frame goes with its pointer drawn in, as the recording is handed out (Q821).
            guard let video else { return CaptureAskAI.ask(image) }
            Task { @MainActor in CaptureAskAI.ask(await RecordingHandout.frame(image, of: video)) }
        }
        shown.append(panel)
        // Its screen, kept for uncrop (P77), stays while the thumbnail does, and while the editor it opens does.
        if video == nil { CaptureHistoryStore.shared.holdGrab(file) }
        while shown.count > ThumbnailStack.most { dismiss(shown[0]) }
        layout()
        if onScreen { panel.orderFrontRegardless() }
        model.startClock()
        return panel
    }

    static func dismiss(_ panel: ThumbnailPanel) {
        guard shown.contains(where: { $0 === panel }) else { return }
        // An unsaved capture's thumbnail cannot come back: the one before it still can.
        if let file = panel.model.file { lastClosed = file }
        panel.model.stopClock()
        panel.orderOut(nil)
        shown.removeAll { $0 === panel }
        if let file = panel.model.file, !VideoEditor.isVideo(file) { CaptureHistoryStore.shared.releaseGrab(file) }
        layout()
    }

    /// Every thumbnail of the capture at `file` gone: the file was written over, so their pictures are out of date.
    static func dismiss(showing file: URL) {
        shown.filter { $0.model.file?.standardizedFileURL == file.standardizedFileURL }.forEach(dismiss)
    }

    #if DEBUG
    /// No thumbnails and nothing to show again: a test's clean start.
    static func reset() {
        shown.forEach(dismiss)
        lastClosed = nil
    }
    #endif

    /// The newest thumbnail up, opened in the editor (Edit the last capture); false when none is up.
    static func editNewest() -> Bool {
        guard let panel = shown.last else { return false }
        panel.model.open()
        return true
    }

    /// The last thumbnail that went, shown again once its file is read off the main thread (a recording's frame, a
    /// capture's picture); false when none has gone yet. A file gone meanwhile says so. It comes back without the screen
    /// it was cut from (let go with the thumbnail, P77), so its editor has no uncrop.
    @discardableResult
    static func restore() -> Bool {
        guard let file = lastClosed else { return false }
        lastClosed = nil
        let capture = capture ?? .shared
        Task { @MainActor in
            let read = VideoEditor.isVideo(file) ? await VideoEditor.poster(file).map { Unchecked(($0, CGFloat(2))) }
                : await Task.detached { Pins.load(file).map(Unchecked.init) }.value
            guard let (image, scale) = read?.value else { return HUD.tip("That capture is gone.") }
            show(image, scale: scale, file: file, capture: capture)
        }
        return true
    }

    /// Every thumbnail at its place (Captures › Thumbnail place) on the screen under the pointer.
    static func layout() {
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frames = ThumbnailStack.frames(shown.map { ThumbnailStack.size($0.model.size) }, in: screen,
                                           place: CaptureSettingsStore.shared.settings.thumbnailPlace)
        for (panel, frame) in zip(shown, frames) { panel.setFrame(frame, display: true, animate: onScreen && panel.isVisible) }
    }

    /// A recording's Save As: a save panel for a copy of the file anywhere.
    static func saveAs(_ video: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = video.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: video.pathExtension) ?? .movie]
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url, url != video else { return }
            // The copy has the pointer drawn in when the recording kept it out (Q821).
            RecordingHandout.handOut([video]) { files in
                guard let file = files.first else { return }
                Task.detached(priority: .userInitiated) {
                    do {
                        try? FileManager.default.removeItem(at: url)
                        try FileManager.default.copyItem(at: file, to: url)
                    } catch {
                        RecordingHandout.log.error("save as: \(url.lastPathComponent, privacy: .public) not saved: \(String(describing: error), privacy: .public)")
                        await MainActor.run { HUD.tip("\(url.lastPathComponent) was not saved: \(error.localizedDescription)") }
                    }
                }
            }
        }
    }

    /// Save As: a save panel for a copy anywhere, Pilot brought forward for it.
    static func saveAs(_ image: CGImage, scale: CGFloat, suggested: String?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested ?? CaptureFiles.name(.capture, at: Date())
        panel.allowedContentTypes = [.png]
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let still = Unchecked(image)
            Task.detached(priority: .userInitiated) { if let png = PilotCapture.png(still.value, scale: scale) { try? png.write(to: url, options: .atomic) } }
        }
    }
}

/// One thumbnail's state: its capture, whether the pointer is on it, and its clock.
@Observable @MainActor
final class ThumbnailModel {
    let image: CGImage
    let scale: CGFloat
    let file: URL?
    var hovered = false {
        didSet {
            hovered ? stopClock() : startClock(after: leave)
            onHover(hovered)
        }
    }
    /// The panel takes the keys while the pointer is on it and gives them back after.
    @ObservationIgnored var onHover: (Bool) -> Void = { _ in }
    @ObservationIgnored var open: () -> Void = {}
    @ObservationIgnored var copy: () -> Void = {}
    @ObservationIgnored var saveAs: () -> Void = {}
    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored var askAI: () -> Void = {}
    /// A recording's drag: its file with the pointer drawn in (Q821); nil drags the file or the picture.
    @ObservationIgnored var drag: (() -> NSItemProvider)?
    /// Whether Copy says "Copied" itself, once the file is on the pasteboard: a recording's, which may wait on its pointer.
    @ObservationIgnored var copySays = false
    /// Six seconds up, three more after the pointer leaves; a test's are short.
    @ObservationIgnored var stay: Duration = .seconds(6)
    @ObservationIgnored var leave: Duration = .seconds(3)
    @ObservationIgnored private var clock: Task<Void, Never>?

    init(image: CGImage, scale: CGFloat, file: URL?) {
        self.image = image
        self.scale = scale
        self.file = file
    }

    var size: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }

    func startClock(after wait: Duration? = nil) {
        clock?.cancel()
        let wait = wait ?? stay
        clock = Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, !self.hovered else { return }
            self.close()
        }
    }

    func stopClock() {
        clock?.cancel()
        clock = nil
    }

    /// A word over the thumbnail for a moment ("Copied").
    private(set) var said: String?
    @ObservationIgnored private var saying: Task<Void, Never>?

    func flash(_ word: String) {
        said = word
        saying?.cancel()
        saying = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { self?.said = nil }
        }
    }

    /// ⌘C and the Copy chip: copy, and "Copied" over the thumbnail unless the copy says it itself.
    func copyAndSay() {
        copy()
        if !copySays { flash("Copied") }
    }

    /// A recording's pointer being drawn in (Q821): its progress over the thumbnail, or nil once it is done.
    func drawing(_ fraction: Double?) {
        guard let fraction else { if drawn { said = nil; drawn = false }; return }
        saying?.cancel()
        drawn = true
        said = "Drawing the pointer · \(Int((fraction * 100).rounded())) %"
    }
    @ObservationIgnored private var drawn = false
}

/// The thumbnail's borderless panel: it floats over windows and never takes the keys or the front app's place.
final class ThumbnailPanel: NSPanel {
    let model: ThumbnailModel

    init(model: ThumbnailModel) {
        self.model = model
        let size = ThumbnailStack.size(model.size)
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Look's Glass behind the card, as the HUD's and the AI chat's (solid in Toybox, or when transparency is off).
        let look = Look.shared, material = look.material(on: .hud)
        let host = NSHostingView(rootView: ThumbnailView(model: model, glass: material == .glass).styled(.hud).pilotTheme())
        host.frame = CGRect(origin: .zero, size: size)
        let backdrop = MaterialBackdrop(content: host, cornerRadius: ThumbnailView.radius)
        backdrop.show(material, tint: look.glassTint(look.chromeTokens(.hud).color(\.panel)))
        contentView = backdrop
        model.onHover = { [weak self] on in self?.keys(on) }
    }

    /// Key only while the pointer is on it: ⌘E, ⌘C, ⌘S and ⌘W act on this capture then, and type into nothing else.
    override var canBecomeKey: Bool { model.hovered }

    private func keys(_ on: Bool) {
        if on {
            if isVisible { makeKey() }
        } else if isKeyWindow {
            // Ordered out and back: the key goes back to the window that had it, in the app in front.
            orderOut(nil)
            orderFrontRegardless()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !perform(event) else { return }
        super.keyDown(with: event)
    }

    /// The hover keys; true when the key was one. ⌘E edits, ⌘C copies, ⌘S saves as, ⌘W or Escape closes.
    @discardableResult
    func perform(_ event: NSEvent) -> Bool {
        if Int64(event.keyCode) == KeyCode.escape { model.close(); return true }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "e": model.open()
        case "c": model.copyAndSay()
        case "s": model.saveAs()
        case "w": model.close()
        default: return false
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { perform(event) || super.performKeyEquivalent(with: event) }
}

/// The card (Sven, 2026-10-19): one 4:3 size for every capture, on Look's Glass with a hairline ring and no shadow, the
/// capture fitted inside it with its own small corners. On hover, close at the top left, Edit in the middle, written out,
/// and Copy, Save As and Ask AI with their keys at the foot, all inside the card. A click opens the editor; a drag takes
/// the file (or the picture) out.
struct ThumbnailView: View {
    @Environment(\.style) private var style
    let model: ThumbnailModel
    /// Glass is behind the card (the panel's MaterialBackdrop), so the face is the panel's see-through ground; solid, it is
    /// the panel colour itself.
    var glass = false
    static let radius: CGFloat = 14
    static let inset: CGFloat = 8

    var body: some View {
        let card = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let picture = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack {
            card.fill(style.color(\.panel).opacity(glass ? 0.35 : 1))
            Image(decorative: model.image, scale: model.scale)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .clipShape(picture)
                .overlay { picture.strokeBorder(Color(hex: style.dark ? 0xFFFFFF : 0x000000, opacity: 0.12)) }
                .padding(Self.inset)
            if model.hovered { hover(card) }
            if let said = model.said {
                Text(said).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 24).background(Color.black.opacity(0.65), in: Capsule())
            }
        }
        .frame(width: ThumbnailStack.card.width, height: ThumbnailStack.card.height)
        .clipShape(card)
        .overlay { card.strokeBorder(style.color(\.line2)) }
        .contentShape(card)
        .onHover { model.hovered = $0 }
        .onTapGesture { model.open() }
        .onDrag { provider() }
        .help("Click to edit · drag it out")
    }

    private func hover(_ shape: RoundedRectangle) -> some View {
        ZStack {
            shape.fill(Color.black.opacity(0.32))
            VStack(spacing: 0) {
                HStack {
                    chip("xmark", "Close  ⌘W", action: model.close)
                    Spacer()
                }
                Spacer(minLength: 4)
                // Edit is what a thumbnail is for (Sven on build 54: "how do I open the capture editor?"): said in words.
                Button(action: model.open) {
                    Label("Edit", systemImage: "pencil").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 26).background(Color.black.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain).help("Edit  ⌘E").accessibilityLabel("Edit")
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    chip("doc.on.doc", "Copy  ⌘C", action: model.copyAndSay)
                    chip("square.and.arrow.down", "Save As…  ⌘S", action: model.saveAs)
                    chip("sparkles", "Ask AI", action: model.askAI)
                }
                Text("Click or ⌘E edit · ⌘C copy · ⌘S save").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).padding(.top, 4)
            }
            .padding(8)
        }
    }

    private func chip(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Color.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    /// The file when the capture was saved, else the picture itself.
    private func provider() -> NSItemProvider {
        if let drag = model.drag { return drag() }
        if let file = model.file, let provider = NSItemProvider(contentsOf: file) { return provider }
        let provider = NSItemProvider()
        if let png = PilotCapture.png(model.image, scale: model.scale) {
            provider.registerDataRepresentation(forTypeIdentifier: "public.png", visibility: .all) { done in done(png, nil); return nil }
        }
        return provider
    }
}
