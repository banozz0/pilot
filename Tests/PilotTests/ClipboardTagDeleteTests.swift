@testable import Clipboard
import Foundation
import Testing
@testable import Pilot

/// Card agent-bo-95422986: Cmd+Shift+Backspace on a tag's tab asks first, then deletes the tag and keeps its items; a tag
/// whose last item loses it leaves the tabs. A throwaway store; nothing touches the real clipboard.
@MainActor
@Suite("Clipboard tag delete", .serialized)
final class ClipboardTagDeleteTests {
    let database = FileManager.default.temporaryDirectory.appending(path: "pilot-clip-tag-delete-\(UUID().uuidString).sqlite")

    deinit {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: database.path + suffix) }
    }

    func model() throws -> (PanelModel, ClipboardStore, ClipTag) {
        let store = try ClipboardStore(path: database)
        var ids: [Int64] = []
        for (i, text) in ["a", "b", "c"].enumerated() {
            ids.append(try store.add(ClipItem(kind: .text, text: text, contents: [["public.utf8-plain-text": Data(text.utf8)]], sourceApp: nil),
                                     at: Date(timeIntervalSince1970: 1_800_000_000 + Double(i))))
        }
        let work = try store.tag(Array(ids.prefix(2)), with: "work")
        return (PanelModel(store: store), store, work)
    }

    @Test("On a tag's tab it asks; Escape keeps the tag; Return deletes it, keeps every item and goes back to All")
    func asksThenDeletes() throws {
        let (model, store, work) = try model()
        model.tab = .tag(work)
        model.askDeleteTag()
        #expect(model.prompt == .deleteTag(work))
        model.dismiss()
        #expect(try store.tags() == [work])
        model.askDeleteTag()
        #expect(model.confirm() == false)
        #expect(try store.tags().isEmpty)
        #expect(try store.recent().count == 3)
        #expect(model.tab == .kind(.all) && model.tabs.allSatisfy { if case .tag = $0 { false } else { true } })
        #expect(model.rows.count == 3)
    }

    @Test("On a kind's tab Cmd+Shift+Backspace asks nothing")
    func kindTabAsksNothing() throws {
        let (model, store, _) = try model()
        model.askDeleteTag()
        #expect(model.prompt == nil)
        #expect(try store.tags().count == 1)
    }

    @Test("Untagging the tag's last items drops its tab and lands on All")
    func emptyTagLeavesTabs() throws {
        let (model, _, work) = try model()
        model.tab = .tag(work)
        model.pickAll()
        model.open(.tag)
        model.type("work")
        #expect(model.confirm() == false)
        #expect(!model.tabs.contains(.tag(work)))
        #expect(model.tab == .kind(.all) && model.rows.count == 3)
    }
}
