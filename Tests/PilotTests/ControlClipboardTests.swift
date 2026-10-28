import AppKit
@testable import Clipboard
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// `pilot clip` and the clipboard's lists (CLI W11), asked through the registry the socket answers from, on a throwaway
/// history, a pasteboard of the test's own and fakes for the front app, Cmd+V and Finder: nothing touches Sven's
/// clipboard, his history or his screen. The fixtures' words are marked so a leak of item content is easy to catch.
@MainActor
@Suite("Control clipboard", .serialized)
final class ControlClipboardTests {
    let database = FileManager.default.temporaryDirectory.appending(path: "pilot-control-clip-\(UUID().uuidString).sqlite")
    let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-control-clip-\(UUID().uuidString)")
    nonisolated(unsafe) let pasteboard = NSPasteboard(name: .init("dev.banozz.pilot.test.\(UUID().uuidString)"))
    let tools = ClipboardTools()
    let verbs = ControlVerbs()
    let store: ClipboardStore
    var asked: [ControlGate.Ask] = []
    var allow = true
    var fronted: [String] = []
    var posts = 0
    var sequenced: [[Int64]] = []
    let opener = FakeOpener()
    /// The fixtures' ids: a text, a pinned text tagged work, a link, an image with text read from it, a file.
    var text: Int64 = 0, pinned: Int64 = 0, link: Int64 = 0, image: Int64 = 0, file: Int64 = 0

    final class FakeOpener: ClipOpening {
        var opened: [URL] = [], revealed: [URL] = []
        func open(_ url: URL) { opened.append(url) }
        func openWith(_ urls: [URL]) {}
        func reveal(_ urls: [URL]) { revealed += urls }
        func copy(_ text: String, tip: String) {}
        func saveImage(_ data: Data, named name: String) {}
    }

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try ClipboardStore(path: database)
        func add(_ item: ClipItem, _ second: Double) throws -> Int64 { try store.add(item, at: Date(timeIntervalSince1970: 1_800_000_000 + second)) }
        text = try add(.plainText("SECRET-TEXT-ALPHA\nsecond line", sourceApp: "com.apple.Safari"), 1)
        pinned = try add(.plainText("pinned words", sourceApp: "com.apple.Notes"), 2)
        link = try add(.plainText("https://example.com/page", sourceApp: nil), 3)
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
        image = try add(ClipItem(kind: .image, text: "", contents: [["public.png": png]], sourceApp: "com.apple.Preview"), 4)
        file = try add(ClipItem(kind: .file, text: "/tmp/report.pdf", contents: [["public.file-url": Data("file:///tmp/report.pdf".utf8)]], sourceApp: "com.apple.finder"), 5)
        try store.setRecognised(image, "INVOICE-OCR-BETA")
        try store.setPinned(pinned, true)
        try store.tag([pinned], with: "work")
        try store.rename(text, to: "NAMED-GAMMA")

        tools.history = ClipboardHistory(defaults: UserDefaults(suiteName: testSuite())!, store: store)
        tools.gate = ControlGate(wait: .seconds(5)) { [unowned self] ask, _ in asked.append(ask); return allow }
        tools.pasteboard = pasteboard
        tools.front = { [unowned self] app throws(ControlError) in fronted.append(app) }
        tools.post = { [unowned self] in posts += 1 }
        tools.sequence = { [unowned self] clips in sequenced.append(clips.map(\.id)) }
        tools.opener = opener
        tools.installed = { $0 != "com.example.missing" }
        verbs.registerClipboard(tools)
    }

    deinit {
        pasteboard.releaseGlobally()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: database.path + suffix) }
        try? FileManager.default.removeItem(at: folder)
    }

    func ask(_ verb: String, _ args: String..., cwd: String? = nil) async -> ControlAnswer {
        await verbs.answer(ControlRequest(verb: verb, args: args, cwd: cwd), peer: nil)
    }

    static func field(_ answer: ControlAnswer, _ name: String) -> JSONValue? {
        if case .object(let o)? = answer.result { o[name] } else { nil }
    }

    static func ids(_ value: JSONValue?) -> [Int64] {
        guard case .array(let rows)? = value else { return [] }
        return rows.compactMap {
            if case .object(let o) = $0, case .number(let id)? = o["id"] { Int64(id) } else if case .number(let id) = $0 { Int64(id) } else { nil }
        }
    }

    /// No fixture's text, name or image text in an answer.
    static func leaks(_ answer: ControlAnswer) -> Bool {
        let all = "\(answer)"
        return ["SECRET-TEXT-ALPHA", "NAMED-GAMMA", "INVOICE-OCR-BETA", "pinned words", "example.com", "report.pdf"].contains { all.contains($0) }
    }

    @Test("list answers metadata only, pins first, with kept and reading counts and a limit, and asks nothing")
    func list() async throws {
        try store.setRecognised(image, "")
        _ = try store.add(ClipItem(kind: .image, text: "", contents: [["public.png": Data([1, 2, 3])]], sourceApp: nil), at: Date(timeIntervalSince1970: 1_800_000_010))
        let answer = await ask("clip")
        #expect(answer.error == nil && !Self.leaks(answer) && asked.isEmpty)
        #expect(Self.field(answer, "kept") == .number(6) && Self.field(answer, "reading") == .number(1))
        let rows = Self.ids(Self.field(answer, "rows"))
        #expect(rows.first == pinned && rows.count == 6)
        guard case .array(let all)? = Self.field(answer, "rows"), case .object(let first)? = all.first else { Issue.record("no rows"); return }
        #expect(first["kind"] == .string("text") && first["app"] == .string("com.apple.Notes") && first["pinned"] == .bool(true))
        #expect(first["tags"] == .array([.string("work")]) && first["text"] == nil && first["title"] == nil)
        #expect(Self.ids(Self.field(await ask("clip", "list", "--limit", "2"), "rows")).count == 2)
        #expect(await ask("clip", "list", "--limit", "0").error?.code == .outOfRange)
        #expect(await ask("clip", "list", "words").error?.code == .badRequest)
    }

    @Test("search: filters run freely; words and an unknown #tag ask Allow first, and a deny lists nothing")
    func search() async {
        let images = await ask("clip", "search", "type:image")
        #expect(Self.ids(Self.field(images, "rows")) == [image] && Self.field(images, "matched") == .number(1) && asked.isEmpty)
        #expect(Self.ids(Self.field(await ask("clip", "search", "#work", "is:pinned"), "rows")) == [pinned] && asked.isEmpty)
        #expect(Self.ids(Self.field(await ask("clip", "search", "app:com.apple.Safari"), "rows")) == [text] && asked.isEmpty)

        allow = false
        let denied = await ask("clip", "search", "SECRET")
        #expect(denied.error?.code == .denied && asked.last == ControlGate.Ask("Search the clipboard history's text for", "SECRET"))
        #expect(await ask("clip", "search", "#nosuchtag").error?.code == .denied)
        // ClipQuery reads app: in lower case only, so APP:x is searched as text and asks too.
        #expect(await ask("clip", "search", "APP:Safari").error?.code == .denied)
        allow = true
        let found = await ask("clip", "search", "type:text", "SECRET")
        #expect(Self.ids(Self.field(found, "rows")) == [text] && !Self.leaks(found))
        #expect(await ask("clip", "search", "type:snippet").error?.code == .badValue)
    }

    @Test("show asks with id, kind and app only; Allow answers the text, name and image text; a deny answers none")
    func show() async {
        allow = false
        let denied = await ask("clip", "show", "\(text)")
        #expect(denied.error?.code == .denied && !Self.leaks(denied))
        #expect(asked.last?.title == "Show clipboard item" && asked.last?.detail.hasPrefix("#\(text) text from Safari") == true)
        allow = true
        let shown = await ask("clip", "show", "#\(text)")
        #expect(Self.field(shown, "text") == .string("SECRET-TEXT-ALPHA\nsecond line") && Self.field(shown, "title") == .string("NAMED-GAMMA"))
        #expect(Self.field(await ask("clip", "show", "\(image)"), "recognised") == .string("INVOICE-OCR-BETA"))
        #expect(await ask("clip", "show", "999").error?.code == .badValue)
        #expect(await ask("clip", "show", "\(text)", "\(link)").error?.code == .badRequest)
    }

    @Test("show --image saves a new PNG relative to the caller's folder; an existing path and a non-image are refused unasked")
    func showImage() async throws {
        let saved = await ask("clip", "show", "\(image)", "--image", "shot.png", cwd: folder.path)
        let path = folder.appending(path: "shot.png").path
        #expect(Self.field(saved, "image") == .string(path))
        #expect(try NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: path))) != nil)
        let count = asked.count
        #expect(await ask("clip", "show", "\(image)", "--image", "shot.png", cwd: folder.path).error?.code == .badValue)
        #expect(await ask("clip", "show", "\(text)", "--image", "x.png", cwd: folder.path).error?.code == .badValue)
        #expect(asked.count == count)
    }

    @Test("copy asks, then writes the test's pasteboard as the panel does; plain writes the text; a deny writes nothing")
    func copy() async {
        allow = false
        #expect(await ask("clip", "copy", "\(link)").error?.code == .denied && pasteboard.string(forType: .string) == nil)
        allow = true
        let copied = await ask("clip", "copy", "\(link)", "\(pinned)", "--plain")
        #expect(Self.ids(Self.field(copied, "copied")) == [link, pinned] && !Self.leaks(copied))
        #expect(pasteboard.string(forType: .string) == "https://example.com/page\npinned words")
        #expect(asked.last?.detail.hasSuffix("; as plain text") == true)
    }

    @Test("paste needs --app, asks, brings the app forward, writes, then one Cmd+V; --delete takes them out; one by one uses the sequence")
    func paste() async throws {
        #expect(await ask("clip", "paste", "\(link)").error?.code == .badRequest && asked.isEmpty)
        #expect(await ask("clip", "paste", "\(link)", "--app", "TextEdit", "--one-by-one", "--plain").error?.code == .badRequest)
        allow = false
        #expect(await ask("clip", "paste", "\(link)", "--app", "TextEdit").error?.code == .denied && fronted.isEmpty && posts == 0)
        allow = true
        let pasted = await ask("clip", "paste", "\(link)", "--app", "TextEdit", "--delete")
        #expect(pasted.error == nil && fronted == ["TextEdit"] && posts == 1 && pasteboard.string(forType: .string) == "https://example.com/page")
        #expect(try asked.last?.title == "Paste into TextEdit" && store.clips([link]).isEmpty)
        let sequence = await ask("clip", "paste", "\(text)", "\(pinned)", "--app", "TextEdit", "--one-by-one")
        #expect(Self.field(sequence, "oneByOne") == .bool(true) && sequenced == [[text, pinned]] && posts == 2)
    }

    @Test("pin, unpin, tag and untag answer the rows as stored, and ask nothing")
    func pinAndTag() async throws {
        #expect(await ask("clip", "pin", "\(text)", "\(link)").result == Self.rows([text, link], store))
        #expect(try store.clips([text, link]).allSatisfy(\.pinned))
        #expect(try await ask("clip", "unpin", "\(text)").error == nil && !(store.clips([text])[0].pinned))
        let tagged = await ask("clip", "tag", "\(text)", "--tag", "#Big Ideas")
        #expect(try store.clips([text])[0].tags.map(\.name) == ["Big-Ideas"] && tagged.result == Self.rows([text], store))
        #expect(try await ask("clip", "untag", "\(text)", "--tag", "big-ideas").error == nil && (store.tags().map(\.name)) == ["work"])
        #expect(await ask("clip", "untag", "\(text)", "--tag", "nope").error?.code == .badValue)
        #expect(await ask("clip", "tag", "\(text)").error?.code == .badRequest)
        #expect(asked.isEmpty)
    }

    static func rows(_ ids: [Int64], _ store: ClipboardStore) -> JSONValue? { ControlVerbs.clipRows((try? store.clips(ids)) ?? []) }

    @Test("tag-edit renames and recolours as the page does; a taken name and a colour past eight are refused")
    func tagEdit() async throws {
        _ = try store.tag([text], with: "home")
        #expect(await ask("clip", "tag-edit", "work", "--name", "deep work", "--colour", "3").result == .object(["name": .string("deep-work"), "colour": .number(3)]))
        #expect(try store.tags().first { $0.name == "deep-work" }?.colour == 2)
        #expect(await ask("clip", "tag-edit", "deep-work", "--name", "HOME").error?.code == .taken)
        #expect(await ask("clip", "tag-edit", "home", "--colour", "9").error?.code == .outOfRange)
        #expect(await ask("clip", "tag-edit", "home").error?.code == .badRequest)
    }

    @Test("rename answers the name; edit, split, merge and format run only where the panel's Cmd+K offers them")
    func edits() async throws {
        #expect(Self.field(await ask("clip", "rename", "\(link)", "--title", "Docs"), "title") == .string("Docs"))
        #expect(try Self.field(await ask("clip", "rename", "\(link)", "--title", ""), "title") == nil && (store.clips([link])[0].customTitle) == nil)
        #expect(try await ask("clip", "edit", "\(pinned)", "--text", "new words").error == nil && (store.clips([pinned])[0].text) == "new words")
        #expect(await ask("clip", "edit", "\(image)", "--text", "x").error?.code == .badValue)
        let split = await ask("clip", "split", "\(text)")
        #expect(Self.ids(Self.field(split, "made")).count == 2 && !Self.leaks(split))
        let merged = Self.ids(Self.field(await ask("clip", "merge", "\(pinned)", "\(link)"), "made"))
        #expect(try merged.count == 1 && (store.clips(merged)[0].text) == "new words\nhttps://example.com/page")
        #expect(try await ask("clip", "format", "\(pinned)", "--as", "uppercase").error == nil && (store.clips([pinned])[0].text) == "NEW WORDS")
        #expect(await ask("clip", "format", "\(pinned)", "--as", "shout").error?.code == .badValue)
        #expect(await ask("clip", "format", "\(file)", "--as", "uppercase").error?.code == .badValue)
        #expect(await ask("clip", "split", "\(link)").error?.code == .badValue)
        #expect(asked.isEmpty)
    }

    @Test("delete and clear ask; clear keeps the pins; open asks and reveal does not")
    func deleteClearOpen() async throws {
        allow = false
        #expect(try await ask("clip", "delete", "\(text)").error?.code == .denied && (store.clips([text])).count == 1)
        allow = true
        #expect(try Self.ids(Self.field(await ask("clip", "delete", "\(text)"), "deleted")) == [text] && (store.clips([text])).isEmpty)
        #expect(await ask("clip", "open", "\(link)").error == nil && opener.opened == [URL(string: "https://example.com/page")!])
        #expect(asked.last?.title == "Open clipboard items")
        let count = asked.count
        #expect(await ask("clip", "reveal", "\(file)").error == nil && opener.revealed == [URL(string: "file:///tmp/report.pdf")!] && asked.count == count)
        #expect(await ask("clip", "reveal", "\(link)").error?.code == .badValue)
        let cleared = await ask("clip", "clear")
        #expect(try cleared.result == .object(["kept": .number(1)]) && (store.recent().map(\.id)) == [pinned])
        #expect(asked.last?.title == "Clear the clipboard history" && asked.last?.detail == "3 items go; 1 pinned stay")
    }

    @Test("clipboard-ignored lists, adds an installed app and removes one, through the settings the page saves")
    func ignored() async {
        #expect(await ask("list", "clipboard-ignored").result.map { "\($0)" }?.contains("com.bitwarden.desktop") == true)
        #expect(await ask("add", "clipboard-ignored", "--app", "com.example.tool").result == .object(["app": .string("com.example.tool"), "name": .string("Tool")]))
        #expect(tools.history.settings.ignoredApps.last == "com.example.tool" && tools.history.settings.capture.ignoredApps.contains("com.example.tool"))
        #expect(await ask("add", "clipboard-ignored", "--app", "com.example.missing").error?.code == .badValue)
        #expect(await ask("remove", "clipboard-ignored", "com.example.tool").error == nil && !tools.history.settings.ignoredApps.contains("com.example.tool"))
        #expect(await ask("remove", "clipboard-ignored", "com.example.tool").error?.code == .badValue)
    }

    @Test("clipboard-tags lists name and colour; remove asks, deletes the tag and keeps its items")
    func tags() async throws {
        #expect(await ask("list", "clipboard-tags").result == .array([.object(["name": .string("work"), "colour": .number(1)])]))
        allow = false
        #expect(try await ask("remove", "clipboard-tags", "work").error?.code == .denied && (store.tags()).count == 1)
        allow = true
        #expect(await ask("remove", "clipboard-tags", "WORK").result == .object(["deleted": .string("work"), "tags": .array([])]))
        #expect(try store.tags().isEmpty && store.clips([pinned]).count == 1)
        #expect(asked.last?.title == "Delete clipboard tag #work")
    }

    @Test("Refusals: an unknown subcommand, flag or id; a history not running is not-ready")
    func refusals() async {
        #expect(await ask("clip", "frobnicate").error?.code == .badValue)
        #expect(await ask("clip", "list", "--app", "X").error?.code == .unknownFlag)
        #expect(await ask("clip", "pin", "abc").error?.code == .badValue)
        #expect(await ask("clip", "pin").error?.code == .badRequest)
        tools.history = ClipboardHistory(defaults: UserDefaults(suiteName: testSuite())!)
        #expect(await ask("clip").error?.code == .notReady)
        #expect(await ask("list", "clipboard-tags").error?.code == .notReady)
    }
}
