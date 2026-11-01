import AppKit
import OSLog
import PDFKit
import PilotCore
import Quartz
import SwiftUI

/// Show preview (story 199): one file's contents in a window on Look's glass with no shadow. Markdown is set as GitHub
/// sets a README (MarkdownPreview), its source a click away; text and code in the mono face, a picture whole, a PDF's
/// pages; anything else QuickLook draws (QLPreviewView). At most FileAction.textLimit characters are read. Escape or a
/// click away closes it, and nothing is kept: the panel and its view go with it.
@MainActor
enum FilePreviewWindow {
    /// What the window shows, read off the main thread.
    enum Content {
        case markdown(String), text(String), picture(NSImage), pdf(URL), quickLook(URL)
    }

    private static var panel: KeyPanel?
    private static var resign: NSObjectProtocol?

    static func open(_ url: URL) {
        Task {
            let read = await Task.detached(priority: .userInitiated) { () -> (Unchecked<Content>, [Extension.Detail.Fact]) in
                let facts = FilePreview.read(url.path)?.facts.map { Extension.Detail.Fact(label: $0.label, text: $0.value) } ?? []
                return (Unchecked(content(url)), facts)
            }.value
            show(url, read.0.value, facts: read.1)
        }
    }

    nonisolated static func content(_ url: URL) -> Content {
        switch FileActionsMenu.kind(url) {
        case .text:
            let text = FileActionsMenu.text(of: url).map { FileAction.capped($0).text } ?? ""
            return FileActionsMenu.isMarkdown(url) ? .markdown(text) : .text(text)
        case .image:
            return NoteAttachments.picture(at: url, pixels: 2400).map { .picture(NSImage(cgImage: $0, size: .zero)) } ?? .quickLook(url)
        case .pdf: return .pdf(url)
        case .folder, .other: return .quickLook(url)
        }
    }

    private static func show(_ url: URL, _ content: Content, facts: [Extension.Detail.Fact]) {
        close()
        let look = Look.shared, tokens = look.chromeTokens(.hud)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let room = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: min(max(room.width * 0.55, 560), 1100), height: min(max(room.height * 0.7, 420), 860))
        let view = FilePreviewView(url: url, facts: facts, content: content, close: { close() })
        let host = NSHostingView(rootView: view.styled(.hud, look: look).pilotTheme(look: look))
        host.frame = CGRect(origin: .zero, size: size)
        let p = KeyPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Look's Glass behind it, as behind the video editor and the HUD (solid in Toybox, or with Glass off); no shadow.
        let backdrop = MaterialBackdrop(content: host, cornerRadius: tokens.radii.pop)
        backdrop.show(look.material(on: .hud), tint: look.glassTint(tokens.color(\.panel)))
        p.contentView = backdrop
        p.appearance = look.appearance(for: .hud)
        p.level = HUD.level
        p.escape = { close() }
        p.setFrameOrigin(CGPoint(x: room.midX - size.width / 2, y: room.midY - size.height / 2))
        panel = p
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { close() }
        }
        p.makeKeyAndOrderFront(nil)
        previewLog.notice("preview: \(url.lastPathComponent, privacy: .public) shown")
    }

    static func close() {
        guard let p = panel else { return }
        panel = nil
        if let resign { NotificationCenter.default.removeObserver(resign) }
        resign = nil
        p.escape = nil
        p.orderOut(nil)
        p.contentView = nil
        // Closing lets QuickLook's view go (QLPreviewView closes with its window).
        p.close()
        previewLog.notice("preview: closed")
    }
}

private let previewLog = Logger(subsystem: "dev.banozz.pilot", category: "files")

/// The window's face: the file's name and facts over its contents.
private struct FilePreviewView: View {
    @Environment(\.style) private var style
    let url: URL
    let facts: [Extension.Detail.Fact]
    let content: FilePreviewWindow.Content
    let close: () -> Void
    /// A Markdown file's raw text in place of its rendering.
    @State private var source = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(url.lastPathComponent).styleText(\.strong).foregroundStyle(style.color(\.text)).lineLimit(1).truncationMode(.middle)
                Text(facts.map(\.text).joined(separator: " · ")).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1)
                Spacer(minLength: 8)
                if case .markdown = content { MarkdownModeToggle(source: $source) }
                Button(action: close) { Text("Esc").styleText(\.key).foregroundStyle(style.color(\.text2)) }
                    .buttonStyle(.plain).help("Close")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Rectangle().fill(style.color(\.line)).frame(height: 1)
            contents.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func mono(_ text: String) -> some View {
        ScrollView {
            Text(text).styleText(\.mono).foregroundStyle(style.color(\.text)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(18)
        }
    }

    @ViewBuilder private var contents: some View {
        switch content {
        case .markdown(let text):
            MarkdownPreview(text: text, file: url, showsSource: $source) { mono(text) }
        case .text(let text):
            mono(text)
        case .picture(let image):
            Image(nsImage: image).resizable().scaledToFit().padding(18)
        case .pdf(let url):
            PDFPages(url: url)
        case .quickLook(let url):
            QuickLookView(url: url)
        }
    }
}

/// A PDF's pages, scrolled, fitted to the window's width.
private struct PDFPages: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}

/// QuickLook's own preview of anything Pilot does not draw itself; Apps › Repos' images and PDFs too.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    /// Lets QuickLook's preview go with the view, not only with its window (Repos stays open from file to file).
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
