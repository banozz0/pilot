import AppKit
import AVFoundation
import OSLog
import PilotCore
import SwiftUI
import UniformTypeIdentifiers

/// The video editor (P71, after Snapzy's Studio, BSD-3): a recording on a timeline with thumbnails and a playhead, trim,
/// crop, speed, zooms that follow the pointer and its clicks (made from the recording's clicks, each one moved, stretched
/// and set on the timeline), P70's backdrop panel round it, and export to MP4 (H.264 or HEVC) or GIF beside it. It opens
/// from the recording's thumbnail, after a recording when Captures › After capture says Editor, from Edit video… (the
/// Captures menu's, a bind) and from any place that hands it a file. One editor a recording; closing it lets everything go.
@MainActor
enum VideoEditor {
    private static var open: [String: VideoEditorPanel] = [:]
    /// False in tests: the panel is made, never ordered onto Sven's screen.
    static var onScreen = true
    nonisolated static let log = Logger(subsystem: "dev.banozz.pilot", category: "video-editor")
    /// Where Recorder keeps each recording's pointer track (CursorTrack), by the recording's file name.
    nonisolated static let pointerFolder = PilotFolder.support.appending(path: "Recording pointers", directoryHint: .isDirectory)

    static var openCount: Int { open.count }

    /// Whether `url` is a video the editor opens: any movie file.
    nonisolated static func isVideo(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false }

    /// What follows a saved recording, as Captures › After capture says: its thumbnail (a frame of it), the editor, or the
    /// file copied with a tip that offers Edit video.
    static func recorded(_ url: URL, capture: PilotCapture = .shared) {
        switch CaptureSettingsStore.shared.settings.afterCapture {
        case .editor: open(url)
        case .copy:
            capture.pasteboard.clearContents()
            capture.pasteboard.writeObjects([url as NSURL])
            capture.tell("Recording copied", HUD.TipAction(title: "Edit video") { open(url) })
        case .thumbnail:
            Task { @MainActor in
                // No frame to show: a tip instead, so a recording never ends in silence.
                guard let poster = await poster(url) else { return capture.tell("Recording saved", HUD.TipAction(title: "Edit video") { open(url) }) }
                CaptureThumbnails.show(poster, scale: 2, file: url, capture: capture)
            }
        }
    }

    /// A frame of the recording for its thumbnail, read off the main thread at a thumbnail's size.
    static func poster(_ url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.appliesPreferredTrackTransform = true
        return try? await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
    }

    /// Edit video…: a pick of a recording in the recordings folder, then the editor on it.
    static func pick() {
        let panel = NSOpenPanel()
        panel.directoryURL = CaptureSettingsStore.shared.folder(.recording)
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.prompt = "Edit"
        panel.message = "Pick a recording to edit"
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { open(url) }
        }
    }

    /// Opens the editor on the recording at `url`, centred on the screen under the pointer; that recording's editor comes
    /// to the front when it is open already.
    static func open(_ url: URL) {
        let key = url.standardizedFileURL.path
        if let panel = open[key] {
            if onScreen { panel.makeKeyAndOrderFront(nil); panel.raised() }
            return
        }
        let look = Look.shared, tokens = look.chromeTokens(.hud), library = BackdropLibrary.shared
        let model = VideoEditorModel(url: url, panelOpen: library.panelOpen)
        model.panelChanged = { library.panelOpen = $0 }
        model.tell = { text, file in
            HUD.tip(text, seconds: 6, action: file.map { file in HUD.TipAction(title: "Show") { NSWorkspace.shared.activateFileViewerSelecting([file]) } })
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        _ = sizeWatch
        let size = EditorLayout.opening(room: screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900), least: VideoEditorLayout.minSize,
                                        saved: EditorLayout.saved(sizeKey))
        let panel = VideoEditorPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                     backing: .buffered, defer: false)
        panel.minSize = VideoEditorLayout.minSize
        panel.model = model
        model.closeEditor = { [weak panel] in if let panel { close(panel) } }
        let glass = look.material(on: .hud) == .glass
        let host = NSHostingView(rootView: VideoEditorView(model: model, glass: glass).styled(.hud, look: look).pilotTheme(look: look))
        host.frame = CGRect(origin: .zero, size: size)
        // Look's Glass behind the editor, as behind the thumbnail and the HUD (solid in Toybox, or with Glass off); no shadow.
        let backdrop = MaterialBackdrop(content: host, cornerRadius: tokens.radii.pop)
        backdrop.show(look.material(on: .hud), tint: look.glassTint(tokens.color(\.panel)))
        panel.contentView = backdrop
        panel.appearance = look.appearance(for: .hud)
        if let f = screen?.visibleFrame { panel.setFrameOrigin(CGPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2)) }
        open[key] = panel
        Task { @MainActor in await model.load(pointerFolder: pointerFolder) }
        guard onScreen else { return }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        log.notice("video editor open: \(url.lastPathComponent, privacy: .public)")
    }

    static let sizeKey = "capture.videoEditorSize"
    /// A size the editor is dragged to is the one it opens at from then on.
    private static let sizeWatch = EditorLayout.watchSize(of: VideoEditorPanel.self, key: sizeKey)

    static func close(_ panel: VideoEditorPanel) {
        panel.model?.close()
        panel.orderOut(nil)
        panel.contentView = nil
        panel.model = nil
        open = open.filter { $0.value !== panel }
        if open.isEmpty, CaptureEditor.openCount == 0 { BackdropLibrary.shared.forget() }
    }
}

/// The video editor's smallest window; it opens at the capture editor's size (EditorLayout.opening).
enum VideoEditorLayout {
    static let minSize = CGSize(width: 1040, height: 700)
}

/// The editor's panel: borderless, on every Space, kept while Pilot is inactive, no window-server shadow; its keys go to
/// the model first wherever the pointer is.
final class VideoEditorPanel: NSPanel, BorderedWindow {
    var model: VideoEditorModel?

    override var canBecomeKey: Bool { true }

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
        super.sendEvent(event)
        if event.type == .leftMouseDown { raised() }
    }

    static func key(_ event: NSEvent) -> VideoEditorModel.Key? {
        switch Int64(event.keyCode) {
        case KeyCode.escape: return .escape
        case KeyCode.returnKey, KeyCode.keypadEnter: return .enter
        case KeyCode.delete, KeyCode.forwardDelete: return .delete
        case 49: return .space
        default:
            guard let c = event.charactersIgnoringModifiers, !c.isEmpty else { return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.isDisjoint(with: [.control, .option, .shift]) else { return nil }
            return .char(c, command: flags.contains(.command))
        }
    }
}
