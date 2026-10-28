// Written from scratch for Pilot (Sven, build 36: a Return on picks with an image among them landed only one of them).
import AppKit

/// Return on several picks that cannot go on as one (PanelRows.steps): each step goes on the pasteboard, transient, and
/// is pasted with its own Cmd+V; the next goes on once the app has read it, and after the last Sven's copy goes back,
/// as PasteBack puts it back. Anything copied meanwhile ends it there and stays on. An app that takes no image (a
/// terminal) pastes the texts and nothing for an image.
///
/// An image step's data is promised, not written (Sven, build 46: three images took two seconds to land): the app
/// asking for it is the sign it has read the step, so the next goes on `afterRead` later rather than after
/// `imageRead`, which stays the wait for an app that never asks.
@MainActor
public struct PasteSteps {
    /// How long an app gets to read an image step it has not asked for: larger than a text, and some read it late (a
    /// terminal app asking for it).
    public static let imageRead: TimeInterval = 1
    /// After the app asked for an image step's data: room for another type it asks for in the same paste, before the
    /// next step replaces it.
    public static let afterRead: TimeInterval = 0.15

    let pasteboard: NSPasteboard
    /// Sends Cmd+V into the focused app.
    let post: () -> Void
    let later: PasteBack.Later

    public init(pasteboard: NSPasteboard = .general, post: @escaping () -> Void, later: @escaping PasteBack.Later = PasteBack.onMain) {
        self.pasteboard = pasteboard; self.post = post; self.later = later
    }

    public func run(_ steps: [PanelRows.Paste]) {
        paste(steps[...], saved: PasteBack.copy(on: pasteboard))
    }

    private func paste(_ steps: ArraySlice<PanelRows.Paste>, saved: [[String: Data]]) {
        guard let step = steps.first else { return }
        let rest = steps.dropFirst(), last = rest.isEmpty
        let image = step.text.isEmpty
        let promise = Promise()
        if image { promise.write(step, to: pasteboard) } else { PanelRows.write([step], plain: false, forget: true, to: pasteboard) }
        let ours = pasteboard.changeCount
        // Once, whichever wait ends first; nothing when something else was copied meanwhile.
        let next: @MainActor () -> Void = { [self] in
            guard !promise.done else { return }
            promise.done = true
            promise.read = nil
            guard pasteboard.changeCount == ours else { return }
            if last { PasteBack.putBack(saved, on: pasteboard) } else { paste(rest, saved: saved) }
        }
        promise.read = { later(last ? PasteBack.after : Self.afterRead, next) }
        post()
        later(image ? Self.imageRead : last ? PasteBack.after : PasteSequence.settle, next)
    }
}

/// An image step's items, each handing its data over as the app asks for it; the first ask calls `read`.
@MainActor
private final class Promise {
    var read: (() -> Void)?
    var done = false
    /// Held until the step is done, whether or not the pasteboard holds them.
    private var items: [PromisedItem] = []

    /// The step on the pasteboard as `PanelRows.write` puts it, transient, every type promised.
    func write(_ step: PanelRows.Paste, to pasteboard: NSPasteboard) {
        items = step.contents.map { PromisedItem(data: $0, asked: { [weak self] in self?.asked() }) }
        pasteboard.clearContents()
        pasteboard.writeObjects(items.enumerated().map { index, promised in
            let item = NSPasteboardItem()
            item.setDataProvider(promised, forTypes: promised.data.keys.map { .init($0) })
            if index == 0 { item.setData(Data(), forType: ClipboardCapture.transient) }
            return item
        })
    }

    private func asked() {
        guard let read else { return }
        self.read = nil
        read()
    }
}

/// One promised item's stored types; a TIFF asked for comes as its PNG.
private final class PromisedItem: NSObject, NSPasteboardItemDataProvider, Sendable {
    let data: [String: Data]
    let asked: @MainActor @Sendable () -> Void

    init(data: [String: Data], asked: @escaping @MainActor @Sendable () -> Void) { self.data = data; self.asked = asked }

    /// AppKit asks on the main thread as the app's read reaches Pilot's run loop; an ask anywhere else still gets its
    /// data, and the step moves on after `imageRead`.
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let data = data[type.rawValue] { item.setData(data, forType: type) }
        if Thread.isMainThread { MainActor.assumeIsolated { asked() } }
    }
}
