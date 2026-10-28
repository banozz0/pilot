// Written from scratch for Pilot (card agent-bo-95423071); Raycast's and SuperCmd's paste one by one are the behaviour reference.
import AppKit

/// Paste in sequence: the picks go on the pasteboard one at a time, in pick order, and each paste Sven makes gives the
/// next, once the app in front has had time to read the one it pasted. Each goes on as a single copy marked transient,
/// so the history does not move it to the top. Anything else written to the pasteboard meanwhile ends it.
@MainActor
public final class PasteSequence {
    public enum Event: Equatable {
        case started(Int), next(Int, of: Int), done(Int), ended
    }

    /// How long after a paste the next item goes on: the app reads the pasteboard as it handles Cmd+V.
    public static let settle: TimeInterval = 0.25

    private let pasteboard: NSPasteboard
    private let after: PasteBack.Later
    private let report: (Event) -> Void
    /// The picks in pick order, each read from the store as it goes on, so a sequence of images holds none in memory.
    private var clips: [StoredClip] = []
    private var store: ClipboardStore?
    /// The pick on the pasteboard now.
    private var index = 0
    /// The pasteboard's change count once Pilot wrote that pick: another number means something else was copied.
    private var changeCount = 0
    /// A paste seen and its next item not on yet: a second paste meanwhile pasted the same item, so it moves on once.
    private var pending = false
    /// Which start a scheduled step belongs to, so a step of a replaced sequence does nothing.
    private var run = 0

    public init(pasteboard: NSPasteboard = .general,
                after: @escaping PasteBack.Later = PasteBack.onMain,
                report: @escaping (Event) -> Void) {
        self.pasteboard = pasteboard
        self.after = after
        self.report = report
    }

    var isRunning: Bool { !clips.isEmpty }

    /// Puts the first clip on the pasteboard; a sequence already running is replaced.
    public func start(_ clips: [StoredClip], from store: ClipboardStore) throws {
        self.clips = clips
        self.store = store
        guard isRunning else { return }
        run += 1
        index = 0
        pending = false
        do { try put() } catch { self.clips = []; throw error }
        report(.started(clips.count))
    }

    /// A paste was pressed, by Sven or by Pilot: the next item goes on after `settle`.
    public func pasted() {
        guard isRunning, !pending else { return }
        pending = true
        after(Self.settle) { [weak self, run] in
            guard let self, self.run == run else { return }
            self.step()
        }
    }

    private func step() {
        pending = false
        guard pasteboard.changeCount == changeCount else { return end(.ended) }
        index += 1
        guard index < clips.count else { return end(.done(clips.count)) }
        // A pick deleted from the history meanwhile has nothing left to paste: the sequence ends there.
        guard (try? put()) != nil else { return end(.ended) }
        report(.next(index + 1, of: clips.count))
    }

    private func end(_ event: Event) {
        clips = []
        store = nil
        report(event)
    }

    private func put() throws {
        guard let store else { return }
        let paste = try PanelRows.pastes([clips[index]], from: store, plain: false)
        guard paste.first?.contents.isEmpty == false else { throw ClipboardStoreError.sqlite("pick \(clips[index].id) is gone") }
        PanelRows.write(paste, plain: false, forget: true, to: pasteboard)
        changeCount = pasteboard.changeCount
    }
}
