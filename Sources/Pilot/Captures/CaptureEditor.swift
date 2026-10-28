import AppKit
import Clipboard
import OSLog
import PilotCore
import SwiftUI
import UniformTypeIdentifiers

/// The capture editor (spec `capture.html` CP6, CP7; Q158: it opens after every capture; direction A, Q169): one solid
/// panel, the tools in the top bar, the capture on the sunken ground, the picked tool's options in the footer with
/// Cancel and Done. Done copies the marked-up capture and writes it over the file the capture was saved to; ⌘C copies
/// and ⌘S saves a copy beside it without closing; Escape (twice when there are marks) and Cancel leave the capture as
/// taken. The marks are flattened, encoded and written off the main thread.
@MainActor
enum CaptureEditor {
    /// The open editors by their capture: the file, or the picture when it was not saved. One editor a capture at most.
    private static var open: [String: EditorPanel] = [:]
    /// False in tests: the panel is made, never ordered onto Sven's screen.
    static var onScreen = true

    static func key(file: URL?, image: CGImage) -> String { file?.standardizedFileURL.path ?? "image:\(ObjectIdentifier(image).hashValue)" }

    /// How many editors are open, for tests.
    static var openCount: Int { open.count }
    static func isOpen(file: URL) -> Bool { open[file.standardizedFileURL.path] != nil }
    nonisolated static let log = Logger(subsystem: "dev.banozz.pilot", category: "captures")

    /// Opens the editor on `image` (`scale` pixels a point), saved at `file`, centred on the screen under the pointer.
    static func show(_ image: CGImage, scale: CGFloat, file: URL?, capture: PilotCapture) {
        let key = key(file: file, image: image)
        if let panel = open[key] {
            // That capture's editor is open already: it comes to the front, no second one.
            if onScreen { panel.makeKeyAndOrderFront(nil); panel.raised() }
            return
        }
        MarkupRenderer.forgetBlurs()
        let look = Look.shared
        let tokens = look.chromeTokens(.hud)
        let model = EditorModel(image: image, scale: scale, accent: tokens.colors.accent.rgb, dark: tokens.dark, ground: tokens.colors.canvas.rgb)
        // It opens on Select, so a stray click draws nothing (Sven after build 82); the overlay's markup keeps the arrow.
        model.pick(.select)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let library = BackdropLibrary.shared
        model.panelOpen = library.panelOpen
        model.panelChanged = { library.panelOpen = $0 }
        _ = sizeWatch
        let least = EditorLayout.least(panel: model.panelOpen)
        let size = EditorLayout.opening(room: screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900), least: least,
                                        saved: EditorLayout.saved(sizeKey))
        let panel = EditorPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                backing: .buffered, defer: false)
        panel.minSize = least
        panel.model = model
        let finish: (EditorModel.Outcome) -> Void = { [weak panel] outcome in
            guard let panel else { return }
            Task { @MainActor in await act(outcome, model: model, file: file, capture: capture, panel: panel) }
        }
        model.finish = finish
        model.readText = { [weak model] in
            Task { @MainActor in
                guard let model, let image = await model.export() else { return }
                let lines = await PilotCapture.read(image, scale: scale, with: capture.reader)
                if !lines.isEmpty {
                    capture.pasteboard.clearContents()
                    capture.pasteboard.setString(ReadLines.copied(lines), forType: .string)
                }
                model.showRead(lines)
            }
        }
        model.readCapture = { await PilotCapture.read(image, scale: scale, with: capture.reader) }
        model.copyColour = { hex in
            capture.pasteboard.clearContents()
            capture.pasteboard.setString(hex, forType: .string)
        }
        model.startUpscale = { [weak model] in Task { @MainActor in if let model { await upscale(model, file: file, capture: capture) } } }
        let view = CaptureEditorView(model: model, save: { finish(.saveCopy); model.say("Saved a copy") },
                                     copy: { finish(.copy); model.say("Copied") }, pin: { finish(.pin) }, cancel: { finish(.cancel) },
                                     done: { finish(.done) }, ask: { Task { @MainActor in if let image = await model.export() { CaptureAskAI.ask(image) } } },
                                     drag: { [weak model] in dragOut(model, file: file) })
        panel.contentView = NSHostingView(rootView: view.styled(.hud, look: look).pilotTheme(look: look))
        panel.appearance = look.appearance(for: .hud)
        if let f = screen?.visibleFrame { panel.setFrameOrigin(CGPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2)) }
        open[key] = panel
        guard onScreen else { return }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        // The chrome comes in fast, under the 165 ms budget for showing the editor.
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        log.notice("editor open: \(Int(model.size.width))×\(Int(model.size.height)) pt in a \(Int(size.width))×\(Int(size.height)) window")
    }

    /// Where the size the editor was last dragged to is kept.
    static let sizeKey = "capture.editorSize"
    /// A size the editor is dragged to is the one it opens at from then on.
    private static let sizeWatch = EditorLayout.watchSize(of: EditorPanel.self, key: sizeKey)

    /// Does what the editor asked: copy, save a copy, Done (copy, write over the capture's file, close), or Cancel.
    private static func act(_ outcome: EditorModel.Outcome, model: EditorModel, file: URL?, capture: PilotCapture, panel: EditorPanel) async {
        if outcome == .cancel { return close(panel) }
        if outcome == .pin {
            // The pin takes the canvas's place: its top left where the capture's is.
            let top = CGPoint(x: panel.frame.minX + model.room.minX + model.origin.x, y: panel.frame.maxY - model.room.minY - model.origin.y)
            close(panel)
            guard let image = await model.export() else { return }
            Pins.pin(image, scale: model.scale, topLeft: top)
            return
        }
        if outcome == .done { close(panel) }
        guard let image = await model.export() else { return capture.tell("The marked-up capture could not be drawn.", nil) }
        let scale = model.scale, folder = capture.store.folder(.capture), still = Unchecked(image)
        let written: (png: Data?, url: URL?) = await Task.detached(priority: .userInitiated) {
            guard let png = PilotCapture.png(still.value, scale: scale) else { return (nil, nil) }
            switch outcome {
            case .saveCopy: return (png, PilotCapture.write(png, near: file, in: folder, suffix: " edited"))
            case .done:
                if let file, (try? png.write(to: file, options: .atomic)) != nil { return (png, file) }
                return (png, PilotCapture.write(png, near: nil, in: folder, suffix: ""))
            default: return (png, nil)
            }
        }.value
        guard let png = written.png else { return capture.tell("The marked-up capture could not be encoded.", nil) }
        if let url = written.url { CaptureHistoryStore.shared.note(url, madeFrom: file) }
        if outcome != .saveCopy {
            capture.pasteboard.clearContents()
            capture.pasteboard.setData(png, forType: .png)
        }
        if outcome == .done {
            let url = written.url
            capture.tell(url == nil ? "Copied, but not saved." : "Copied, and saved to \(PilotCapture.shortPath(folder))",
                         url.map { url in HUD.TipAction(title: "Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) } })
        } else if outcome == .saveCopy, written.url == nil {
            model.say("The copy was not saved")
        }
    }

    /// The top bar's Upscale: the capture as marked up (and resized) goes to the upscaler through a file of its own, and the
    /// result lands beside the capture's file as "<name> 4x.png", or in the captures folder when it was never saved.
    private static func upscale(_ model: EditorModel, file: URL?, capture: PilotCapture) async {
        guard !model.upscale.busy, let image = await model.export() else { return }
        let scale = model.scale, still = Unchecked(image)
        let input = FileManager.default.temporaryDirectory.appending(path: "pilot-upscale-\(UUID().uuidString).png")
        let saved = await Task.detached(priority: .userInitiated) { PilotCapture.png(still.value, scale: scale).map { (try? $0.write(to: input)) != nil } ?? false }.value
        guard saved else { return model.say("The capture could not be written for the upscaler") }
        let item = UpscaleJob.Item(image: input, folder: file?.deletingLastPathComponent() ?? capture.store.folder(.capture),
                                   stem: file?.deletingPathExtension().lastPathComponent ?? "Capture")
        // The editor may close meanwhile: the run goes on and tells its result, which keeps nothing of the editor.
        model.upscale.start([item]) { written, failure in
            try? FileManager.default.removeItem(at: input)
            if let url = written.first {
                CaptureHistoryStore.shared.note(url, madeFrom: file)
                capture.tell("Upscaled to \(url.lastPathComponent)", HUD.TipAction(title: "Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            } else if let failure {
                capture.tell(failure, nil)
            }
        }
    }

    /// The Drag cap's item (P70, Snapzy's Drag to app): the export, backdrop and all, as a PNG file named after the capture,
    /// drawn and written off the main thread only when the app it is dropped on asks for it.
    private static func dragOut(_ model: EditorModel?, file: URL?) -> NSItemProvider {
        let provider = NSItemProvider()
        let stem = file?.deletingPathExtension().lastPathComponent ?? "Capture"
        provider.suggestedName = stem
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { done in
            Task { @MainActor in
                guard let model, let image = await model.export() else { return done(nil, false, CocoaError(.fileWriteUnknown)) }
                let scale = model.scale, still = Unchecked(image)
                let url = FileManager.default.temporaryDirectory.appending(path: "Pilot drags/\(UUID().uuidString)/\(stem).png")
                let written = await Task.detached(priority: .userInitiated) { () -> Bool in
                    guard let png = PilotCapture.png(still.value, scale: scale) else { return false }
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    return (try? png.write(to: url)) != nil
                }.value
                done(written ? url : nil, false, written ? nil : CocoaError(.fileWriteUnknown))
            }
            return nil
        }
        return provider
    }

    /// Every editor closed, its edits dropped; for tests.
    static func closeAll() { open.values.forEach(close) }

    private static func close(_ panel: EditorPanel) {
        panel.orderOut(nil)
        panel.contentView = nil
        panel.model = nil
        open = open.filter { $0.value !== panel }
        MarkupRenderer.forgetBlurs()
        if open.isEmpty, VideoEditor.openCount == 0 { BackdropLibrary.shared.forget() }
    }
}

/// The editor's window sizes: the bars from the style's control height, a 16-point margin round the capture, and never
/// narrower than its tools need. Both editors open at one size whatever the capture's shape (Sven on build 76).
enum EditorLayout {
    static let margin: CGFloat = 16
    /// Toybox's widest footer, the ruler's options beside the zoom and the size, is 950 wide (P33; the backdrop's drops its
    /// words to fit); its top bar, Redact sensitive text, Ask AI, Crop, the colour picker and Upscale in it, 977
    /// (CaptureEditorBarWidth).
    static let minWidth: CGFloat = 980

    /// The backdrop panel's column and its hairline, and the height that shows it without much scrolling.
    static let panel: CGFloat = BackdropPanel.width + 1
    static let panelHeight: CGFloat = 720

    static func bar(_ s: StyleTokens) -> CGFloat { s.density.control + 16 }
    static func foot(_ s: StyleTokens) -> CGFloat { s.density.control + 12 }

    /// The size an editor opens at on a screen whose visible frame is `room`: the one it was last dragged to (`saved`), else
    /// 70 % of the screen up to 1600 × 1050; never under `least`, never past the screen. The capture is fitted inside.
    static func opening(room: CGSize, least: CGSize, saved: CGSize? = nil) -> CGSize {
        func side(_ room: CGFloat, _ least: CGFloat, _ most: CGFloat, _ saved: CGFloat?) -> CGFloat {
            min(room - 40, max(least, saved ?? min(most, room * 0.7)))
        }
        return CGSize(width: side(room.width, least.width, 1600, saved?.width), height: side(room.height, least.height, 1050, saved?.height))
    }

    /// The capture editor's smallest window: its tools' width, the backdrop panel's column beside them when it is open.
    static func least(panel open: Bool) -> CGSize {
        CGSize(width: minWidth + (open ? panel : 0), height: open ? panelHeight : 640)
    }

    /// The size kept under `key` by `watchSize`, if the editor was ever dragged to one.
    static func saved(_ key: String, defaults: UserDefaults = .pilot()) -> CGSize? {
        (defaults.array(forKey: key) as? [Double]).flatMap { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil }
    }

    /// Keeps the size a window of `kind` is dragged to under `key`, for every one opened from now on.
    static func watchSize(of kind: NSWindow.Type, key: String, defaults: UserDefaults = .pilot()) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main) { note in
            // Posted on the main queue.
            nonisolated(unsafe) let window = note.object as? NSWindow
            guard let size = MainActor.assumeIsolated({ window.flatMap { type(of: $0) == kind ? $0.frame.size : nil } }) else { return }
            defaults.set([Double(size.width), Double(size.height)], forKey: key)
        }
    }

    /// The zoom that shows all of `capture` inside `space`, from 10 % to actual size.
    static func fit(_ capture: CGSize, inside space: CGSize) -> CGFloat {
        max(0.1, min(1, space.width / max(capture.width, 1), space.height / max(capture.height, 1)))
    }

    /// The window that holds `capture` at `fit` and nothing more, which the renders draw; with the backdrop panel open it is
    /// the panel wider and at least `panelHeight` high.
    static func window(_ capture: CGSize, fit: CGFloat, tokens: StyleTokens, panel open: Bool = false) -> CGSize {
        let side = open ? panel : 0
        return CGSize(width: max(minWidth, capture.width * fit + 2 * margin) + side,
                      height: max(open ? panelHeight : 0, bar(tokens) + foot(tokens) + capture.height * fit + 2 * margin + 2))
    }
}

/// The editor's panel: it takes the keys without activating Pilot, and hands them to the model first, so 1 to 0, C, F,
/// ⌘Z, ⌘C, ⌘S, ⌘+, ⌘−, ⌘0, Return, Delete and Escape work wherever the pointer is; while text is typed the field gets
/// them. Over the capture's room a pinch and ⌘-scroll zoom about the pointer, and a plain scroll moves the capture.
final class EditorPanel: NSPanel, BorderedWindow {
    var model: EditorModel?

    override var canBecomeKey: Bool { true }

    /// As every Pilot pop-up (KeyPanel): clear, on every Space, kept while Pilot is inactive, no window-server shadow.
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let model, let key = Self.key(event), MainActor.assumeIsolated({ model.key(key) }) { return }
        if event.type == .scrollWheel || event.type == .magnify, let model, let height = contentView?.bounds.height,
           MainActor.assumeIsolated({ Self.zoom(event, model, at: CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)) }) { return }
        super.sendEvent(event)
        if event.type == .leftMouseDown { raised() }
    }

    /// A pinch or scroll at `at` (the window's points from its top left); false off the capture's room.
    private static func zoom(_ event: NSEvent, _ model: EditorModel, at: CGPoint) -> Bool {
        let p = CGPoint(x: at.x - model.room.minX, y: at.y - model.room.minY)
        guard CGRect(origin: .zero, size: model.room.size).contains(p) else { return false }
        // A mouse wheel's deltas are lines, a trackpad's points.
        let k: CGFloat = event.type == .scrollWheel && !event.hasPreciseScrollingDeltas ? 10 : 1
        if event.type == .magnify {
            model.zoom(to: model.zoom * (1 + event.magnification), about: p)
        } else if event.modifierFlags.contains(.command) {
            model.zoom(to: model.zoom * exp(event.scrollingDeltaY * k / 100), about: p)
        } else {
            model.pan(by: CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k))
        }
        return true
    }

    static func key(_ event: NSEvent) -> EditorModel.Key? {
        switch Int64(event.keyCode) {
        case KeyCode.escape: return .escape
        case 36, 76: return .enter
        case 51, 117: return .delete
        default:
            guard let c = event.charactersIgnoringModifiers, !c.isEmpty else { return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.isDisjoint(with: [.control, .option]) else { return nil }
            return .char(c, command: flags.contains(.command), shift: flags.contains(.shift))
        }
    }
}

/// Direction A: the top bar, a hairline, the capture on the sunken ground, a hairline, the footer, on one panel.
struct CaptureEditorView: View {
    @Environment(\.style) private var style
    let model: EditorModel
    var save: () -> Void = {}
    var copy: () -> Void = {}
    var pin: () -> Void = {}
    var cancel: () -> Void = {}
    var done: () -> Void = {}
    var ask: () -> Void = {}
    var drag: (() -> NSItemProvider)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.pop, style: .continuous)
        VStack(spacing: 0) {
            EditorTopBar(model: model, save: save, copy: copy, pin: pin, ask: ask, drag: drag).frame(height: EditorLayout.bar(style))
            style.color(\.line).frame(height: 1)
            HStack(spacing: 0) {
                if model.panelOpen {
                    BackdropPanel(backdrop: model.backdrop, set: model.setBackdrop, live: model.previewBackdrop, subject: model.image)
                        .frame(maxHeight: .infinity)
                    style.color(\.line).frame(width: 1)
                }
                EditorCanvas(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(style.color(\.sunken))
                    .overlay(alignment: .bottom) { if let hint = model.hint { EditorHint(text: hint).padding(.bottom, 18) } }
                    .zIndex(1)
            }
            // Over the bars, so the colour picker's loupe is whole at the capture's edge.
            .zIndex(1)
            style.color(\.line).frame(height: 1)
            EditorFooter(model: model, cancel: cancel, done: done).padding(.horizontal, 12).frame(height: EditorLayout.foot(style))
        }
        .background(style.color(\.panel))
        .clipShape(shape)
        .overlay {
            if style.kind == .toybox { shape.strokeBorder(style.color(\.outline), lineWidth: 2) } else { shape.strokeBorder(style.color(\.line2)) }
        }
    }
}

/// The capture with its marks on its room, drawn by the same renderer the export uses at the model's zoom; a drag on the
/// capture draws with the picked tool.
struct EditorCanvas: View {
    @Environment(\.style) private var style
    let model: EditorModel
    /// The press under way: true on the capture, false when it began off it and draws nothing; nil with none.
    @State private var press: Bool?
    @FocusState private var typing: Bool

    var body: some View {
        let size = model.size, zoom = model.zoom, origin = model.origin
        Canvas { ctx, _ in
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.scaleBy(x: zoom, y: zoom)
            let ring = ctx
            if let backdrop = model.framed { frame(&ctx, backdrop) }
            ctx.draw(Image(decorative: model.image, scale: model.scale), in: CGRect(origin: .zero, size: size))
            let marks = shown()
            ctx.withCGContext { cg in MarkupRenderer.draw(marks, in: cg, image: model.image, scale: model.scale, size: size) }
            chrome(&ctx, size: size)
            if case .read(let lines) = model.reading { boxes(&ctx, lines, size: size) }
            ring.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: 0.5 / zoom, dy: 0.5 / zoom)),
                        with: .color(Color(hex: style.dark ? 0xFFFFFF : 0x000000, opacity: 0.1)), lineWidth: 1 / zoom)
        }
        .clipped()
        .overlay(alignment: .topLeading) { field }
        .overlay(alignment: .topLeading) { LoupeLayer(model: model).allowsHitTesting(false) }
        .pointerVisibility(model.loupeShown ? .hidden : .automatic)
        .pointerStyle(model.hoverGrip?.pointer)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let flags = NSEvent.modifierFlags
            switch press {
            case nil:
                // A handle can sit just off the capture, and a crop can start anywhere round it.
                press = model.shown.contains(g.location) || model.tool == .crop || model.grip(at: point(g.location)) != nil
                if press == true { model.begin(point(g.location), shift: flags.contains(.shift)) }
            case true?: model.drag(point(g.location), shift: flags.contains(.shift), option: flags.contains(.option))
            case false?: break
            }
        }.onEnded { g in
            let flags = NSEvent.modifierFlags
            if press == true { model.end(point(g.location), shift: flags.contains(.shift), option: flags.contains(.option)) }
            press = nil
        })
        .onContinuousHover { phase in
            // Off the capture too: a handle can sit past its edge; the ruler and the colour picker read nothing there.
            if case .active(let at) = phase { model.hover(point(at)) } else { model.hover(nil) }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.setRoom($0) }
        .onChange(of: model.typing) { typing = model.typing != nil }
    }

    /// A point on the view as a point on the capture, through the zoom and the backdrop's preview.
    private func point(_ at: CGPoint) -> CGPoint { model.capturePoint(inRoom: at) }

    /// The backdrop's preview, drawn as MarkupRenderer.framed draws the export: its fill over the export's canvas fitted
    /// to the room (a picture fill's picture covering it), a shadow under the capture's rounded spot, then the space moved
    /// and clipped so the capture and its marks draw inside it.
    private func frame(_ ctx: inout GraphicsContext, _ b: Backdrop) {
        let v = model.preview
        ctx.translateBy(x: v.origin.x, y: v.origin.y)
        ctx.scaleBy(x: v.k, y: v.k)
        let e = CGRect(origin: .zero, size: v.canvas)
        switch b.fill {
        case .colour(let rgb): ctx.fill(Path(e), with: .color(Color(Paint(rgb))))
        case .gradient(let colours) where colours.count > 1:
            ctx.fill(Path(e), with: .linearGradient(Gradient(colors: colours.map { Color(Paint($0)) }), startPoint: .zero, endPoint: CGPoint(x: e.maxX, y: e.maxY)))
        case .image, .capture:
            if let picture = model.backdropPicture {
                var clipped = ctx
                clipped.clip(to: Path(e))
                clipped.draw(Image(decorative: picture, scale: 1), in: MarkupRenderer.cover(CGSize(width: picture.width, height: picture.height), e))
            } else {
                ctx.fill(Path(e), with: .color(.gray.opacity(0.15)))
            }
        default:
            // See-through: a faint wash, so the canvas's edge shows.
            ctx.fill(Path(e), with: .color(.gray.opacity(0.15)))
        }
        let spot = Path(roundedRect: v.spot, cornerRadius: min(b.radius, min(v.spot.width, v.spot.height) / 2))
        if b.shadow > 0 {
            var shadow = ctx
            shadow.addFilter(.shadow(color: .black.opacity(0.55 * b.shadow), radius: (10 + 26 * b.shadow) / 2, y: 12 * b.shadow))
            shadow.fill(spot, with: .color(.white))
        }
        ctx.clip(to: spot)
        ctx.translateBy(x: v.spot.minX - v.area.minX, y: v.spot.minY - v.area.minY)
    }

    /// The marks as they look now: the one being typed with its words so far, the one being moved where it is going,
    /// and the one being drawn.
    private func shown() -> [Mark] {
        var marks = model.document.marks.map { mark in
            var m = mark
            if mark.id == model.typing, case .text(_, let at, let pill) = mark.kind { m.kind = .text("", at: at, pill: pill) }
            if model.picked.contains(mark.id), let d = model.draftMove { m = m.moved(by: d) }
            if let resized = model.draftResize, resized.id == mark.id { m = resized }
            return m
        }
        marks.removeAll { $0.id == model.typing }
        if let draft = model.draft { marks.append(draft) }
        return marks + model.hovering
    }

    /// The crop's shade and frame (with its thirds and handles while Crop is the tool), each picked mark's frame, the one
    /// picked mark's handles, and the marquee, in the fixed selection blue.
    private func chrome(_ ctx: inout GraphicsContext, size: CGSize) {
        let blue = Color(Paint(EditorModel.selection)), z = model.zoom * model.preview.k
        if model.tool == .crop {
            if let crop = model.cropEdit, crop.width >= 1, crop.height >= 1 { cropFrame(&ctx, crop, size: size, z: z) }
        } else if model.framed == nil, let crop = model.document.crop {
            var shade = Path(CGRect(origin: .zero, size: size))
            shade.addRect(crop)
            ctx.fill(shade, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
            ctx.stroke(Path(crop), with: .color(.white), lineWidth: 1.5 / z)
        }
        if let marquee = model.marquee?.box {
            ctx.fill(Path(marquee), with: .color(blue.opacity(0.12)))
            ctx.stroke(Path(marquee), with: .color(blue), lineWidth: 1 / z)
        }
        let one = model.picked.count == 1
        for picked in model.document.marks where model.picked.contains(picked.id) {
            var mark = picked
            if let d = model.draftMove { mark = mark.moved(by: d) }
            if let resized = model.draftResize, resized.id == mark.id { mark = resized }
            let grips = one ? Grip.grips(of: mark) : []
            // A line's two ends are its handles; its frame would only hide what it points at.
            if !(one && grips.first?.grip == .start) {
                ctx.stroke(Path(Grip.frame(of: mark)), with: .color(blue), style: StrokeStyle(lineWidth: 1.5 / z, dash: [4 / z, 3 / z]))
            }
            for (_, at) in grips {
                let r = 4.5 / z
                let dot = Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(dot, with: .color(.white))
                ctx.stroke(dot, with: .color(blue), lineWidth: 1.5 / z)
            }
        }
    }

    /// Crop at work: the rest shaded, the kept part's edge and thirds, and its handles as white corner brackets and edge
    /// bars, as Photos draws them.
    private func cropFrame(_ ctx: inout GraphicsContext, _ crop: CGRect, size: CGSize, z: CGFloat) {
        var shade = Path(CGRect(origin: .zero, size: size))
        shade.addRect(crop)
        ctx.fill(shade, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
        var thirds = Path()
        for i in 1...2 {
            let x = crop.minX + crop.width * CGFloat(i) / 3, y = crop.minY + crop.height * CGFloat(i) / 3
            thirds.move(to: CGPoint(x: x, y: crop.minY)); thirds.addLine(to: CGPoint(x: x, y: crop.maxY))
            thirds.move(to: CGPoint(x: crop.minX, y: y)); thirds.addLine(to: CGPoint(x: crop.maxX, y: y))
        }
        ctx.stroke(thirds, with: .color(.white.opacity(0.4)), lineWidth: 1 / z)
        ctx.stroke(Path(crop), with: .color(.white), lineWidth: 1.5 / z)
        let arm = min(18 / z, crop.width / 3, crop.height / 3), w = 3.5 / z, o = w / 2
        var handles = Path()
        for case .box(let x, let y) in Grip.eight {
            let p = Grip.box(x, y).point(on: crop.insetBy(dx: -o, dy: -o))
            if x != 0 && y != 0 {
                handles.move(to: CGPoint(x: p.x, y: p.y - CGFloat(y) * arm)); handles.addLine(to: p); handles.addLine(to: CGPoint(x: p.x - CGFloat(x) * arm, y: p.y))
            } else if x == 0 {
                handles.move(to: CGPoint(x: p.x - arm / 2, y: p.y)); handles.addLine(to: CGPoint(x: p.x + arm / 2, y: p.y))
            } else {
                handles.move(to: CGPoint(x: p.x, y: p.y - arm / 2)); handles.addLine(to: CGPoint(x: p.x, y: p.y + arm / 2))
            }
        }
        ctx.stroke(handles, with: .color(.white), style: StrokeStyle(lineWidth: w, lineCap: .square))
    }

    /// Read text's lines, boxed where they were read, in the selection's fixed blue over a light shade.
    private func boxes(_ ctx: inout GraphicsContext, _ lines: [ReadLine], size: CGSize) {
        let blue = Color(Paint(EditorModel.selection)), area = model.readArea
        ctx.fill(Path(area), with: .color(.black.opacity(0.06)))
        for line in lines {
            let r = CGRect(x: area.minX + line.box.minX * area.width, y: area.minY + line.box.minY * area.height,
                           width: line.box.width * area.width, height: line.box.height * area.height).insetBy(dx: -3, dy: -1)
            let box = Path(roundedRect: r, cornerRadius: 3)
            ctx.fill(box, with: .color(blue.opacity(0.12)))
            ctx.stroke(box, with: .color(blue.opacity(0.75)), lineWidth: 1 / model.zoom)
        }
    }

    /// The text being typed: a field over its mark, in the mark's size and colour.
    @ViewBuilder private var field: some View {
        if let id = model.typing, let mark = model.document.marks.first(where: { $0.id == id }), case .text(_, let at, let pill) = mark.kind {
            let place = model.roomPoint(at), k = model.preview.k * model.zoom
            TextField("Type, then Return", text: Binding(get: { model.typed }, set: { model.typed = $0 }))
                .textFieldStyle(.plain)
                .font(Font(mark.face.font(mark.fontSize * k)))
                .foregroundStyle(pill ? .white : Color(Paint(mark.colour)))
                .padding(.horizontal, pill ? mark.fontSize * 0.6 * k : 0)
                .frame(minWidth: 140, alignment: .leading)
                .fixedSize()
                .background { if pill { Capsule().fill(Color(Paint(mark.colour))) } }
                .offset(x: place.x, y: place.y)
                .focused($typing)
                .onSubmit { model.commitText() }
        }
    }
}

/// The colour picker's loupe in the pointer's place: a view of its own, so a pointer move redraws it and never the capture.
struct LoupeLayer: View {
    let model: EditorModel

    var body: some View {
        if let at = model.loupeAt, let rgb = model.sampled {
            ColourLoupe(pixels: model.pixels(around: at, side: ColourLoupe.side), colour: rgb)
                .position(model.roomPoint(at))
        }
    }
}

/// The colour picker's loupe (Sven on build 62, macOS's colour sampler and CleanShot's as the bar): the capture's own
/// pixels round the pointer, `side` a side, magnified in a ring, the centre one framed, and its hex on a swatch under it.
struct ColourLoupe: View {
    static let side = 11
    static let cell: CGFloat = 10
    let pixels: [UInt32?]
    let colour: UInt32

    var body: some View {
        let n = Self.side, d = CGFloat(n) * Self.cell
        Canvas { ctx, _ in
            for (i, rgb) in pixels.enumerated() {
                let r = CGRect(x: CGFloat(i % n) * Self.cell, y: CGFloat(i / n) * Self.cell, width: Self.cell, height: Self.cell)
                ctx.fill(Path(r), with: .color(rgb.map { Color(Paint($0)) } ?? Color(white: 0.5, opacity: 0.25)))
            }
            var grid = Path()
            for k in 1..<n {
                let v = CGFloat(k) * Self.cell
                grid.move(to: CGPoint(x: v, y: 0)); grid.addLine(to: CGPoint(x: v, y: d))
                grid.move(to: CGPoint(x: 0, y: v)); grid.addLine(to: CGPoint(x: d, y: v))
            }
            ctx.stroke(grid, with: .color(.black.opacity(0.12)), lineWidth: 0.5)
            let centre = CGRect(x: CGFloat(n / 2) * Self.cell, y: CGFloat(n / 2) * Self.cell, width: Self.cell, height: Self.cell)
            ctx.stroke(Path(centre.insetBy(dx: -1, dy: -1)), with: .color(.black), lineWidth: 1)
            ctx.stroke(Path(centre), with: .color(.white), lineWidth: 1)
        }
        .frame(width: d, height: d)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
        .overlay { Circle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        .overlay(alignment: .bottom) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(Color(Paint(colour))).frame(width: 12, height: 12)
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.6), lineWidth: 1) }
                Text(ColourAnswer.hex(colour)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white).fixedSize()
            }
            .padding(.horizontal, 7).frame(height: 22)
            .background { Capsule().fill(.black.opacity(0.78)) }
            .offset(y: 30)
        }
    }
}
