import Foundation
import ImageIO
import PilotCore
import Testing
import UniformTypeIdentifiers
@testable import Pilot

/// `pilot note` and the `notes` collection (CLI W12), asked through the registry the socket answers from, over a notes
/// model, gate and panel show of the tests' own: Sven's notes folder is never read or written, nothing goes to the real
/// Trash, no Allow prompt and no panel shows.
@MainActor
@Suite("Collections notes")
struct CollectionsNotesTests {
    final class Trashed: @unchecked Sendable { var names: [String] = [] }

    @MainActor final class Rig {
        let root: URL
        var folder: URL { root.appending(path: "notes") }
        let verbs = ControlVerbs()
        let app = ControlNotes()
        let trashed: Trashed
        let model: NotesModel
        var asked: [String] = []
        var shown: [String] = []
        var allow = false

        init() {
            let root = FileManager.default.temporaryDirectory.appending(path: "pilot-cli-notes-\(UUID().uuidString)"), trashed = Trashed()
            self.root = root
            self.trashed = trashed
            model = NotesModel(store: NoteStore(folder: root.appending(path: "notes"), trash: { url in
                trashed.names.append(url.lastPathComponent)
                try FileManager.default.removeItem(at: url)
            }), defaults: UserDefaults(suiteName: testSuite())!)
            let model = model
            app.model = { model }
            app.gate = ControlGate { [unowned self] ask, _ in
                asked.append(ask.text)
                return allow
            }
            app.show = { [unowned self] in shown.append($0) }
            verbs.registerNotes(app)
        }

        func ask(_ verb: String, _ args: String..., cwd: String? = nil) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args, cwd: cwd), peer: nil)
        }

        /// A note added through the command; its id.
        func add(_ text: String) async -> String {
            let answer = await ask("add", "notes", "--text", text)
            return CollectionsNotesTests.string(CollectionsNotesTests.object(answer.result)["id"]) ?? "add failed: \(answer)"
        }

        func onDisk(_ id: String) -> String? { try? String(contentsOf: folder.appending(path: id), encoding: .utf8) }
    }

    static func object(_ value: JSONValue?) -> [String: JSONValue] { ControlActivityTests.object(value) }
    static func array(_ value: JSONValue?) -> [JSONValue] { ControlActivityTests.array(value) }
    static func string(_ value: JSONValue?) -> String? { if case .string(let s)? = value { s } else { nil } }
    static func ids(_ answer: ControlAnswer) -> [String] { array(answer.result).compactMap { string(object($0)["id"]) } }

    @Test("list notes reads the folder in the page's order, Scratch first; add makes a note and answers it as saved")
    func listAndAdd() async throws {
        let rig = Rig()
        #expect(Self.ids(await rig.ask("list", "notes")) == ["Scratch.md"], "Scratch is written when missing")
        let plan = await rig.add("Plan\n- [ ] ship")
        #expect(plan.hasPrefix("plan-") && plan.hasSuffix(".md"), "\(plan)")
        #expect(rig.onDisk(plan) == "Plan\n- [ ] ship")
        let added = Self.object(await rig.ask("add", "notes").result)
        #expect(added["title"] == .string("Untitled") && added["text"] == .string(""), "New note with no text, as the page's button")

        let rows = Self.array(await rig.ask("list", "notes").result).map { Self.object($0) }
        #expect(rows.first?["scratch"] == .bool(true) && rows.first?["group"] == .string("Scratch") && rows.first?["pinned"] == .bool(false))
        let row = try #require(rows.first { $0["id"] == .string(plan) })
        #expect(row["title"] == .string("Plan") && row["pinned"] == .bool(false) && row["group"] == .string("Today"))
        #expect(row["path"] == .string(rig.folder.appending(path: plan).path(percentEncoded: false)))
        #expect(rig.model.notes.contains { $0.id == plan }, "the panel's model reads the new note too")

        #expect(await rig.ask("add", "notes", "--txt", "x").error?.code == .unknownFlag)
        #expect(await rig.ask("list", "notes", "--all").error?.code == .unknownFlag)
        let entry = Self.object(try rig.verbs.schema(collection: "notes"))
        #expect(entry["rowKey"] == .string("id") && entry["asks"] == .array([.string("remove")]))
    }

    @Test("note show reads one note whole; search finds titles first, then words in the text")
    func showAndSearch() async throws {
        let rig = Rig()
        let plan = await rig.add("Plan\n\nship the notes verbs\n![](attachments/shot.png)\n- [x] done")
        let groceries = await rig.add("Groceries\nmilk and plan B")
        let shown = Self.object(await rig.ask("note", "show", String(plan.dropLast(3))).result)
        #expect(shown["id"] == .string(plan), "the id without .md names it")
        #expect(shown["text"] == .string("Plan\n\nship the notes verbs\n![](attachments/shot.png)\n- [x] done"))
        #expect(shown["words"] == .number(7), "the page's count: a - [x] mark left out")
        let picture = Self.object(Self.array(shown["attachments"]).first)
        #expect(picture["name"] == .string("shot.png") && picture["exists"] == .bool(false))
        #expect(Self.object(await rig.ask("note", "show", "scratch").result)["id"] == .string("Scratch.md"))
        #expect(await rig.ask("note", "show", "nope.md").error?.code == .badValue)
        #expect(await rig.ask("note", "show").error?.code == .badRequest)

        #expect(Self.ids(await rig.ask("note", "search", "plan")) == [plan, groceries], "the title match first, then the text")
        #expect(Self.ids(await rig.ask("note", "search", "milk")) == [groceries])
        #expect(await rig.ask("note", "frob").error?.code == .badValue)
        #expect(await rig.ask("note", "show", plan, "--text", "x").error?.code == .unknownFlag, "only write takes --text")
    }

    @Test("note write replaces the text, renames a note on a new first line, and the open note in the panel follows")
    func write() async throws {
        let rig = Rig()
        let plan = await rig.add("Plan\n- [ ] ship")
        rig.model.reload()
        rig.model.open(plan)
        rig.model.text = "Plan\n- [ ] ship\ntyped, not saved yet"
        #expect(await rig.ask("note", "pin", plan).ok)

        let ticked = Self.object(await rig.ask("note", "write", plan, "--text", "Plan\n- [x] ship").result)
        #expect(ticked["id"] == .string(plan) && ticked["text"] == .string("Plan\n- [x] ship"))
        #expect(rig.onDisk(plan) == "Plan\n- [x] ship")
        #expect(rig.model.current == plan && rig.model.text == "Plan\n- [x] ship", "the panel shows what was written")

        let renamed = Self.object(await rig.ask("note", "write", plan, "--text=Launch\n- [x] ship").result)
        let id = try #require(Self.string(renamed["id"]))
        #expect(id != plan && id.hasPrefix("launch-") && id.hasSuffix(String(plan.suffix(9))), "the slug follows the title, the short id kept")
        #expect(rig.onDisk(plan) == nil && rig.onDisk(id) == "Launch\n- [x] ship")
        #expect(renamed["pinned"] == .bool(true), "the pin follows the rename")
        #expect(rig.model.current == id && rig.model.text == "Launch\n- [x] ship", "the panel stays on the renamed note, not Scratch")

        #expect(await rig.ask("note", "write", id).error?.code == .badRequest, "--text is needed")
        #expect(await rig.ask("note", "write", id, "--title", "x").error?.code == .unknownFlag)
        #expect(await rig.ask("note", "write", "gone.md", "--text", "x").error?.code == .badValue)
        #expect(rig.onDisk("gone.md") == nil, "no note is made by writing to one that is not there")
    }

    @Test("note append saves the line as a note of its own and Scratch stays empty; pin and unpin read back, never Scratch")
    func appendAndPin() async throws {
        let rig = Rig()
        rig.model.reload()
        let saved = Self.object(await rig.ask("note", "append", "buy", "milk").result)
        #expect(saved["id"] != .string("Scratch.md") && saved["text"] == .string("buy milk"))
        #expect(rig.onDisk("Scratch.md") == "", "Scratch stays empty")
        #expect(rig.model.current == "Scratch.md" && rig.model.text == "", "the open Scratch stays empty")
        // Writing to Scratch saves a note of its own and names it, so a retry never writes the words twice.
        let written = Self.object(await rig.ask("note", "write", "scratch", "--text", "call the bank").result)
        #expect(written["id"] != .string("Scratch.md") && written["text"] == .string("call the bank"))
        #expect(rig.onDisk("Scratch.md") == "")
        #expect(await rig.ask("note", "append").error?.code == .badRequest)

        let plan = await rig.add("Plan")
        #expect(Self.object(await rig.ask("note", "pin", plan).result)["pinned"] == .bool(true))
        #expect(rig.model.notes.first { $0.id == plan }?.pinned == true)
        #expect(Self.object(await rig.ask("note", "unpin", plan).result)["pinned"] == .bool(false))
        #expect(await rig.ask("note", "unpin", "scratch").error?.code == .badValue)
        #expect(await rig.ask("note", "pin", "scratch").error?.code == .badValue)
    }

    @Test("remove notes moves a note to the Trash only after Allow, with the page's words; Scratch never goes")
    func removeAsksAllow() async throws {
        let rig = Rig()
        let plan = await rig.add("Plan")
        let denied = await rig.ask("remove", "notes", plan)
        #expect(denied.error?.code == .denied)
        #expect(rig.asked == ["Move “Plan” to the Trash: Finder can put it back"])
        #expect(rig.onDisk(plan) != nil && rig.trashed.names.isEmpty, "a Deny moves nothing")

        rig.allow = true
        let removed = Self.object(await rig.ask("remove", "notes", plan).result)
        #expect(removed["id"] == .string(plan) && removed["trashed"] == .bool(true))
        #expect(rig.trashed.names == [plan] && rig.onDisk(plan) == nil)
        #expect(!Self.ids(await rig.ask("list", "notes")).contains(plan))
        #expect(!rig.model.notes.contains { $0.id == plan })

        rig.asked = []
        #expect(await rig.ask("remove", "notes", "scratch").error?.code == .badValue)
        #expect(rig.asked.isEmpty, "Scratch is refused before Sven is asked")
        #expect(await rig.ask("remove", "notes", "gone.md").error?.code == .badValue)
    }

    @Test("note attach copies a picture in after Allow and links it at the note's end; nothing is read before")
    func attach() async throws {
        let rig = Rig()
        let plan = await rig.add("Plan")
        let pictures = rig.root.appending(path: "pictures")
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let png = pictures.appending(path: "Screen Shot.png")
        try Self.writePNG(to: png)
        try Data("not a picture".utf8).write(to: pictures.appending(path: "fake.png"))
        try Data("text".utf8).write(to: pictures.appending(path: "notes.txt"))

        #expect(await rig.ask("note", "attach", plan, "notes.txt", cwd: pictures.path).error?.code == .badValue)
        #expect(rig.asked.isEmpty, "a file that is not a picture by its name is refused before asking")

        #expect(await rig.ask("note", "attach", plan, "Screen Shot.png", cwd: pictures.path).error?.code == .denied)
        #expect(rig.asked == ["Attach a picture to “Plan”: copy \(png.path(percentEncoded: false)) into the notes folder's attachments/"])
        #expect(!FileManager.default.fileExists(atPath: rig.folder.appending(path: "attachments").path), "a Deny copies nothing")

        rig.allow = true
        let attached = Self.object(await rig.ask("note", "attach", plan, "Screen Shot.png", cwd: pictures.path).result)
        #expect(attached["link"] == .string("![](attachments/screen-shot.png)"), "\(attached)")
        #expect(rig.onDisk(plan) == "Plan\n![](attachments/screen-shot.png)\n")
        #expect(Self.object(Self.array(attached["attachments"]).first)["exists"] == .bool(true))
        #expect(try Data(contentsOf: rig.folder.appending(path: "attachments/screen-shot.png")) == Data(contentsOf: png))

        #expect(await rig.ask("note", "attach", plan, pictures.appending(path: "fake.png").path).error?.code == .badValue)
        #expect(rig.onDisk(plan) == "Plan\n![](attachments/screen-shot.png)\n", "a file that does not read as a picture is not linked")
    }

    @Test("note open shows the panel on the note named; the schema names the subcommands and the row key")
    func openAndSchema() async throws {
        let rig = Rig()
        let plan = await rig.add("Plan")
        #expect(Self.object(await rig.ask("note", "open", plan).result)["opened"] == .bool(true))
        #expect(await rig.ask("note", "open", "gone.md").error?.code == .badValue)
        #expect(rig.shown == [plan])

        let entry = Self.object(try rig.verbs.schema(verb: "note"))
        let part = Self.object(entry["schema"])
        #expect(part["rowKey"] == .string("id"))
        #expect(Self.array(part["subcommands"]).count == 8)
        #expect(Self.array(entry["flags"]).map { Self.object($0)["name"] } == [.string("text")])
        #expect(try rig.verbs.verb("note").detail?("unpin")?.contains("Scratch is never pinned") == true)
    }

    /// A 2×2 PNG.
    static func writePNG(to url: URL) throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
