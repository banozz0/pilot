import AppKit
import Observation
import PilotCore
import SwiftUI

/// The helper beside System Settings while a privacy list is open (Sven, Build 71, 2026-10-19): Pilot's icon to drag into
/// the list, and one line. A re-signed Pilot is a new app to macOS, yet TCC keeps the old signature's row under the same
/// bundle id ("Failed to match existing code requirement"), and while that row is there neither macOS's prompt nor + adds
/// another: the old row goes with −, then the drag adds this Pilot. Screen Recording takes effect only in a new process,
/// so once its grant shows the panel offers Quit & Reopen Pilot.
@MainActor
enum PermissionDragPanel {
    enum List: Sendable {
        case accessibility, fullDiskAccess, screenRecording

        var title: String {
            switch self {
            case .accessibility: "Drag Pilot into Accessibility"
            case .fullDiskAccess: "Drag Pilot into Full Disk Access"
            case .screenRecording: "Drag Pilot into Screen Recording"
            }
        }

        static let line = "Turn Pilot on. If an old Pilot is listed, remove it with − first."
    }

    @Observable @MainActor
    final class Model {
        let list: List
        /// Screen Recording seen granted: the panel's ask turns into Quit & Reopen Pilot.
        var granted = false
        init(list: List, granted: Bool = false) { self.list = list; self.granted = granted }
    }

    private static var panel: NSPanel?
    private static var model: Model?
    private static var watch: Timer?
    /// System Settings was seen running since the panel showed, so its quitting closes the panel.
    private static var settingsSeen = false
    /// The list the shown panel is for, so another list's close leaves it.
    static var shown: List? { model?.list }

    static func show(_ list: List) {
        close()
        let m = Model(list: list)
        let p = HUD.makePanel(PermissionDragView(model: m, close: { close() }, relaunch: relaunch)
            .allowsWindowActivationEvents(true).fixedSize())
        panel = p
        model = m
        settingsSeen = false
        corner(p)
        if let settings = settingsApp() { place(p, settings: settings.processIdentifier) }
        p.orderFrontRegardless()
        // Twice a second while shown (Sven's first run, 2026-10-28: it stayed in the middle of the screen until closed): the
        // panel follows Settings' window, which opens a moment after the press and may be moved or tiled; it closes once its
        // grant shows or Settings quits, and Screen Recording's grant turns it into Quit & Reopen. No check prompts; Screen
        // Recording's preflight runs only after a press opened its pane (ADR 0012).
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    private static func tick() {
        guard let panel, let model else { return }
        if isGranted(model.list) {
            guard model.list == .screenRecording else { return close() }
            // The ask stays until Later or Quit & Reopen, Settings or not.
            model.granted = true
            watch?.invalidate(); watch = nil
            return
        }
        guard let settings = settingsApp() else { if settingsSeen { close() }; return }
        settingsSeen = true
        place(panel, settings: settings.processIdentifier)
    }

    /// Read without a prompt. Full Disk Access may show only after Pilot reopens; Settings quitting, Close and onboarding
    /// moving on close the panel then.
    private static func isGranted(_ list: List) -> Bool {
        switch list {
        case .accessibility: AXIsProcessTrusted()
        case .fullDiskAccess: FileIndex.hasFullDiskAccess()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }

    /// Screen Recording's pane with the panel beside it: every Allow and Open for Screen Recording, each at a press.
    static func openScreenRecording() {
        NSWorkspace.shared.open(MenuItemPictures.privacyPane)
        show(.screenRecording)
    }

    static func close(_ list: List? = nil) {
        guard list == nil || list == shown else { return }
        watch?.invalidate(); watch = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    /// Quits Pilot and opens it again through LaunchServices (so Info.plist's LSEnvironment applies) once this process
    /// has gone: a detached shell waits on the pid, then `open`s the bundle.
    static func relaunch() { relaunch(for: "Screen Recording") }

    static func relaunch(for reason: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; "
            + "/usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do { try task.run() } catch { return log.error("relaunch: \(error.localizedDescription, privacy: .public)") }
        log.notice("relaunch: quitting for \(reason, privacy: .public)")
        NSApp.terminate(nil)
    }

    /// Right of System Settings' window, top edges level, or left of it where the screen ends; with no room either side,
    /// inside Settings' bottom-left corner, over its sidebar's foot, never the middle of the list. While Settings has no
    /// window on screen, the panel stays where it is.
    private static func place(_ p: NSPanel, settings pid: pid_t) {
        guard let settings = settingsFrame(pid),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(settings) })?.visibleFrame else { return }
        let size = p.frame.size
        let right = settings.maxX + 12, left = settings.minX - 12 - size.width
        let beside: CGFloat? = right + size.width <= screen.maxX ? right : left >= screen.minX ? left : nil
        let origin = beside.map { CGPoint(x: $0, y: min(max(settings.maxY - size.height, screen.minY), screen.maxY - size.height)) }
            ?? CGPoint(x: max(settings.minX + 12, screen.minX), y: max(settings.minY + 12, screen.minY))
        if p.frame.origin != origin { p.setFrameOrigin(origin) }
    }

    /// Before Settings has a window: the focused screen's top-right corner, clear of the middle where Settings opens.
    private static func corner(_ p: NSPanel) {
        guard let f = Screens.focusedScreen?.visibleFrame else { return }
        p.setFrameOrigin(CGPoint(x: f.maxX - p.frame.width - 12, y: f.maxY - p.frame.height - 12))
    }

    private static func settingsApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first { !$0.isTerminated }
    }

    /// System Settings' window from the window list, whose bounds need no grant (its Accessibility tree would need the one
    /// being asked for), turned from the list's top-left origin to AppKit's. Its largest, so a sheet over it is not taken
    /// for it.
    private static func settingsFrame(_ pid: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let top = NSScreen.screens.first?.frame.maxY else { return nil }
        let frames = windows.compactMap { w -> CGRect? in
            guard w[kCGWindowOwnerPID as String] as? pid_t == pid, w[kCGWindowLayer as String] as? Int == 0,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        guard let r = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }
}

/// The panel's face: Pilot's icon to drag, the title, the one line, Close; Screen Recording granted, Quit & Reopen Pilot.
struct PermissionDragView: View {
    @Environment(\.style) private var style
    let model: PermissionDragPanel.Model
    let close: () -> Void
    let relaunch: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            DraggableApp().frame(width: 64, height: 64)
                .help("Drag Pilot into the list")
            VStack(alignment: .leading, spacing: 6) {
                Text(model.granted ? "Screen Recording is on" : model.list.title).styleText(\.title).foregroundStyle(style.color(\.text))
                Text(model.granted ? "macOS applies it once Pilot reopens; captures fail until then." : PermissionDragPanel.List.line)
                    .styleText(\.body).foregroundStyle(style.color(\.text2))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(model.granted ? "Later" : "Close", action: close).buttonStyle(.pilot)
                    if model.granted { Button("Quit & Reopen Pilot", action: relaunch).buttonStyle(.pilotPrimary) }
                }
                .padding(.top, 4)
            }
            .frame(width: 260, alignment: .leading)
        }
        .padding(18)
    }
}

/// Pilot's own icon as a drag source carrying the app's file URL, which the privacy lists take as a dropped app.
private struct DraggableApp: NSViewRepresentable {
    func makeNSView(context: Context) -> Source {
        let view = Source()
        view.image = NSApp.applicationIconImage
        view.imageScaling = .scaleProportionallyUpOrDown
        // The icon's own size would win over the frame SwiftUI gives it.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: Source, context: Context) {}

    final class Source: NSImageView, NSDraggingSource {
        /// The panel never activates, so the first click must start the drag.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }
    }
}
