import AppKit
import Clipboard
import CoreImage.CIFilterBuiltins
import PilotCore
import SwiftUI

/// QR codes (Sven, Q386, from Toolbox for Mac). Make: the clipboard's text, or what you type, as a QR code in a small
/// panel with Copy image and Save (into the captures folder). Read: an area you drag on the frozen screen (the capture
/// overlay, so Screen Recording is asked only as any capture asks it, ADR 0012), or an image file (Hyper + right-click ›
/// Read QR code); the text shows with Copy, and Open when it is a link. Codes are read
/// in pilot-text, as Capture text's are, so Vision never stays in Pilot.
@MainActor
enum QRCodes {
    private static var panel: KeyPanel?

    // MARK: Make

    /// The most a code holds at the medium error correction the panel uses (CIQRCodeGenerator's "M"), in bytes.
    nonisolated static let capacity = 2331

    /// `text` as a black-on-white QR code, each module `module` pixels with the generator's own quiet zone round it; nil
    /// for no text or more than a code holds.
    nonisolated static func image(_ text: String, module: CGFloat = 8) -> CGImage? {
        let bytes = Data(text.utf8)
        guard !bytes.isEmpty, bytes.count <= capacity else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = bytes
        filter.correctionLevel = "M"
        guard let code = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: module, y: module)) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false]).createCGImage(code, from: code.extent)
    }

    /// Opens Make with the clipboard's text, or empty to type into.
    static func make(pasteboard: NSPasteboard = .general) {
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        show(QRMakeCard(text: text.utf8.count <= capacity ? text : "", copy: copy, save: save))
    }

    private static func copy(_ code: CGImage) {
        guard let png = PilotCapture.png(code, scale: 1) else { return }
        close()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        HUD.tip("Copied the QR code")
    }

    /// Saved as any capture is (named, never over a file, kept in Captures › History), with Show on the tip.
    private static func save(_ code: CGImage) {
        close()
        let folder = CaptureSettingsStore.shared.folder(.capture), still = Unchecked(code)
        Task { @MainActor in
            let saved = await Task.detached { PilotCapture.encodeAndWrite(still.value, scale: 1, in: folder).file }.value
            guard case .success(let url) = saved else { return HUD.tip("The QR code could not be saved in \(folder.lastPathComponent)") }
            CaptureHistoryStore.shared.note(url, kind: .capture)
            HUD.tip("Saved \(url.lastPathComponent)", seconds: 8, action: HUD.TipAction(title: "Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
    }

    // MARK: Read

    /// One image file's codes (Hyper + right-click › Read QR code), read off the main thread.
    static func read(file: URL) {
        Task {
            guard let data = await Task.detached(operation: { try? Data(contentsOf: file) }).value else { return HUD.tip("Pilot cannot read that image") }
            await read(data, from: file.lastPathComponent)
        }
    }

    /// The codes in an image's bytes, shown; a tip when there are none.
    static func read(_ image: Data, from source: String, reader: any LineReading = CaptureText.standard) async {
        show(await reader.lines(in: image), from: source)
    }

    /// What a read found: the panel for its first code (and how many more), or a tip saying none. Its text lines are
    /// left out.
    static func show(_ lines: [ReadLine], from source: String) {
        let codes = lines.filter(\.code).map(\.text)
        guard let first = codes.first else { return HUD.tip("No QR code found in \(source)") }
        PilotCapture.log.notice("qr read: \(codes.count, privacy: .public) codes from \(source, privacy: .public)")
        let more = codes.count > 1 ? " · \(codes.count - 1) more not shown" : ""
        show(QRReadCard(text: first, subject: "From \(source)\(more)", link: link(first), copy: {
            close()
            SystemModule.copy(first, tip: "Copied the QR code's text")
        }, open: { url in
            close()
            NSWorkspace.shared.open(url)
        }, close: close))
    }

    /// A web or mail link a code holds, which Open opens; nil for anything else, so a code never opens an app's scheme.
    nonisolated static func link(_ text: String) -> URL? { ClipCode.link(text) }

    // MARK: Panel

    private static func show(_ card: some View) {
        close()
        let p = HUD.makePanel(card)
        p.escape = close
        panel = p
        p.makeKeyAndOrderFront(nil)
    }

    static func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

/// Make's panel: the text, its code drawn again only when the text changes, Save and Copy image.
struct QRMakeCard: View {
    @Environment(\.style) private var style
    @State private var text: String
    @State private var code: CGImage?
    let copy: (CGImage) -> Void
    let save: (CGImage) -> Void

    init(text: String, copy: @escaping (CGImage) -> Void, save: @escaping (CGImage) -> Void) {
        _text = State(initialValue: text)
        _code = State(initialValue: QRCodes.image(text))
        self.copy = copy; self.save = save
    }

    var body: some View {
        let over = text.utf8.count > QRCodes.capacity
        ToolPanel(title: "QR code", subject: over ? "Too long for a QR code" : "From the clipboard, or type") {
            TextField("Text or a link", text: $text, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
                .onChange(of: text) { code = QRCodes.image(text) }
            Group {
                if let code {
                    Image(decorative: code, scale: 1).interpolation(.none).resizable().frame(width: 180, height: 180)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(style.color(\.text3).opacity(0.15)).frame(width: 180, height: 180)
                }
            }
            .frame(maxWidth: .infinity)
        } buttons: {
            Spacer()
            // No code, nothing to copy or save.
            ToolButtons(primary: "Copy image", cancelTitle: "Save", run: { code.map(copy) }, cancel: { code.map(save) }).disabled(code == nil)
        }
    }
}

/// Read's panel: the code's text, Copy, and Open when it is a link.
struct QRReadCard: View {
    @Environment(\.style) private var style
    let text: String
    let subject: String
    let link: URL?
    let copy: () -> Void
    let open: (URL) -> Void
    let close: () -> Void

    var body: some View {
        ToolPanel(title: "QR code", subject: subject) {
            Text(text).styleText(\.body).foregroundStyle(style.color(\.text)).textSelection(.enabled).lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            Spacer()
            if let link {
                ToolButtons(primary: "Open", cancelTitle: "Copy", run: { open(link) }, cancel: copy)
            } else {
                ToolButtons(primary: "Copy", cancelTitle: "Close", run: copy, cancel: close)
            }
        }
    }
}
