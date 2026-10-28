import Foundation
import PilotCore
import Testing
@testable import Pilot

/// CLI W13: Tools › Files through the registry the socket answers from. The files Convert is pointed at are empty ones
/// in a temp folder, the job is a fake that records what it was asked and answers a set outcome, and the index is a
/// fake reply: nothing converts, shows, reads Homebrew or starts the file helper.
@MainActor
@Suite("Control convert and files")
final class ControlConvertTests {
    let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "pilot-convert-\(UUID().uuidString)", directoryHint: .isDirectory)
    let convert = ControlConvert()
    let files = ControlFiles()
    let verbs = ControlVerbs()
    var tools: [ConvertTool: String] = [:]
    var started: [([URL], ConvertFormat)] = []
    var outcome = ConvertBatch.Outcome()
    var progress: String?
    var cancels = 0
    var asks: [FileSearch.Ask] = []
    var found: [(path: String, edited: Date?)]? = []
    var replies = true

    init() throws {
        try FileManager.default.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
        for name in ["a.png", "b.jpg", "c.png", "clip.mov", "notes.zip"] { FileManager.default.createFile(atPath: folder.appending(path: name).path, contents: Data()) }
        convert.converter = { [unowned self] in Converter(tools: tools) }
        convert.start = { [unowned self] urls, format, _ in
            started.append((urls, format))
            let outcome = outcome
            return Task { outcome }
        }
        convert.running = { [unowned self] in progress }
        convert.cancel = { [unowned self] in cancels += 1 }
        files.search = { [unowned self] ask, reply in
            asks.append(ask)
            if replies { reply(found?.map { FileSearch.Hit(path: $0.path, edited: $0.edited) }) }
        }
        files.running = { false }
        files.fullDiskAccess = { true }
        files.home = "/Users/test"
        files.deadline = .milliseconds(50)
        verbs.registerCore()
        verbs.registerFiles(files, convert: convert)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func ask(_ verb: String, _ args: String..., cwd: String? = nil) async -> ControlAnswer {
        await verbs.answer(ControlRequest(verb: verb, args: args, cwd: cwd ?? folder.path), peer: nil)
    }

    func object(_ verb: String, _ args: String...) async -> [String: JSONValue] {
        let answer = await verbs.answer(ControlRequest(verb: verb, args: args, cwd: folder.path), peer: nil)
        guard case .object(let o)? = answer.result else { Issue.record("not an object: \(answer)"); return [:] }
        return o
    }

    static func fields(_ value: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = value { o } else { [:] } }
    static func list(_ value: JSONValue?) -> [JSONValue] { if case .array(let a)? = value { a } else { [] } }
    static func strings(_ value: JSONValue?) -> [String] { list(value).compactMap { if case .string(let s) = $0 { s } else { nil } } }
    func path(_ name: String) -> String { folder.appending(path: name).standardizedFileURL.path }

    // MARK: convert

    @Test("convert --formats answers the Files page's catalogue and whether ffmpeg and webp are installed")
    func catalogue() async {
        tools = [.ffmpeg: "/opt/homebrew/bin/ffmpeg"]
        let answer = await object("convert", "--formats")
        let kinds = Self.list(answer["kinds"]).map(Self.fields)
        #expect(kinds.map { $0["kind"] } == Convert.catalogue.map { .string($0.kind) })
        #expect(Self.strings(kinds.first?["to"]) == ["png", "jpg", "heic", "webp", "pdf"])
        let rows = Self.list(answer["tools"]).map(Self.fields)
        #expect(rows.map { $0["tool"] } == [.string("ffmpeg"), .string("webp")])
        #expect(rows.map { $0["installed"] } == [.bool(true), .bool(false)])
        #expect(rows.last?["install"] == .string("pilot add packages --package formula:webp"))
    }

    @Test("convert <files> answers the formats they share, a format waiting for a tool naming it; relative paths are the caller's")
    func shared() async {
        let answer = await object("convert", "a.png", "b.jpg")
        #expect(Self.strings(answer["files"]) == [path("a.png"), path("b.jpg")])
        let formats = Self.list(answer["formats"]).map(Self.fields)
        #expect(formats.map { $0["format"] } == ["png", "jpg", "heic", "webp", "pdf"].map(JSONValue.string))
        #expect(formats.first { $0["format"] == .string("webp") }?["needs"] == .string("webp"))
        #expect(formats.first { $0["format"] == .string("png") }?["needs"] == .null)
        #expect(started.isEmpty, "a read converts nothing")
    }

    @Test("convert --to runs the job and answers what it wrote, what failed and what was already in the format")
    func converts() async {
        outcome.written = [folder.appending(path: "a.heic")]
        outcome.failed = [(folder.appending(path: "b.jpg"), "bad file")]
        let answer = await object("convert", "a.png", "b.jpg", "--to", "HEIC")
        #expect(started.map(\.0) == [[URL(fileURLWithPath: path("a.png")), URL(fileURLWithPath: path("b.jpg"))]])
        #expect(started.map(\.1) == [.heic])
        #expect(answer["format"] == .string("heic"))
        #expect(Self.strings(answer["written"]) == [folder.appending(path: "a.heic").path])
        #expect(Self.list(answer["failed"]).map(Self.fields).first?["error"] == .string("bad file"))
        #expect(answer["cancelled"] == .bool(false))
        #expect(answer["summary"] == .string("1 file converted to HEIC; b.jpg failed: bad file"))
    }

    @Test("Files already in the format are skipped, and jpeg names JPG")
    func skipped() async {
        outcome.written = [folder.appending(path: "a.jpg")]
        let answer = await object("convert", "a.png", "b.jpg", "--to", "jpeg")
        #expect(started.map(\.1) == [.jpg])
        #expect(Self.strings(answer["skipped"]) == [path("b.jpg")])
    }

    @Test("A format waiting for a tool is not-ready naming Install, and nothing starts")
    func needsTool() async {
        let answer = await ask("convert", "clip.mov", "--to", "mp3")
        #expect(answer.error?.code == .notReady)
        #expect(answer.error?.message.contains("pilot add packages --package formula:ffmpeg") == true)
        #expect(started.isEmpty)
    }

    @Test("A missing file, a folder, a file Convert cannot read, an unknown or unshared format: bad-value, nothing starts")
    func refusals() async {
        #expect(await ask("convert", "gone.png", "--to", "jpg").error?.message == "no file at \(path("gone.png"))")
        #expect(await ask("convert", "sub", "--to", "jpg").error?.code == .badValue)
        #expect(await ask("convert", "notes.zip").error?.message == "Pilot cannot convert notes.zip")
        #expect(await ask("convert", "a.png", "clip.mov").error?.message == "these files have no format in common to convert to")
        #expect(await ask("convert", "a.png", "--to", "bmp").error?.code == .badValue)
        #expect(await ask("convert", "a.png", "--to", "mp4").error?.message == "these files cannot become MP4; they can become jpg, heic, webp, pdf")
        #expect(await ask("convert", "a.png", "--into", "jpg").error?.code == .unknownFlag)
        #expect(await ask("convert", "a.png", "--formats").error?.code == .badRequest)
        #expect(started.isEmpty)
    }

    @Test("While a job runs: convert answers its progress, a second conversion is taken, and --cancel stops it")
    func oneJob() async {
        #expect(await object("convert") == ["running": .bool(false), "progress": .null])
        #expect(await object("convert", "--cancel")["cancelled"] == .bool(false))
        #expect(cancels == 0)
        progress = "Converting 2 of 3 to JPG…"
        #expect(await object("convert") == ["running": .bool(true), "progress": .string("Converting 2 of 3 to JPG…")])
        #expect(await ask("convert", "c.png", "--to", "jpg").error?.code == .taken)
        #expect(started.isEmpty)
        #expect(await object("convert", "--cancel")["cancelled"] == .bool(true))
        #expect(cancels == 1)
    }

    // MARK: files

    @Test("files <words> asks the index with the flags as the menu's filters and answers its files, best first")
    func search() async throws {
        let edited = Date(timeIntervalSince1970: 1_760_000_000)
        found = [("/Users/test/Documents/report.pdf", edited), ("/Users/test/report.pdf", nil)]
        let answer = await object("files", "report", "--kind", "pdf", "--in", "documents", "--when", "week", "--hidden")
        let ask = try #require(asks.first)
        #expect(ask.text == "report")
        #expect(ask.filters == FileFilters(kind: .ext("pdf"), place: .documents, when: .week, hidden: true))
        let rows = Self.list(answer["files"]).map(Self.fields)
        #expect(rows.map { $0["path"] } == [.string("/Users/test/Documents/report.pdf"), .string("/Users/test/report.pdf")])
        #expect(rows.first?["name"] == .string("report.pdf"))
        #expect(rows.first?["edited"] == .string(edited.ISO8601Format()))
        #expect(rows.last?["edited"] == .null)
    }

    @Test("Typed prefixes work as in the menu: kind:images in:~/code")
    func typed() async throws {
        _ = await object("files", "logo", "kind:images", "in:~/code")
        let ask = try #require(asks.first)
        #expect(ask.text == "logo")
        #expect(ask.filters == FileFilters(kind: .images, place: .folder("/Users/test/code")))
    }

    @Test("No Full Disk Access is not-ready; no answer by the deadline is timeout; a bad filter or a one-letter search is bad-value")
    func refusesSearch() async {
        found = nil
        #expect(await ask("files", "report").error?.code == .notReady)
        replies = false
        #expect(await ask("files", "report").error?.code == .timeout)
        #expect(await ask("files", "report", "--when", "yesterday").error?.code == .badValue)
        #expect(await ask("files", "r").error?.code == .badValue)
        #expect(await ask("files", "report", "--limit", "3").error?.code == .unknownFlag)
        #expect(asks.count == 2, "only the two well-formed searches reached the index")
    }

    @Test("files with no words answers the index's state")
    func state() async {
        let answer = await object("files")
        #expect(answer["fullDiskAccess"] == .bool(true))
        #expect(answer["running"] == .bool(false))
        #expect(answer["idleStop"] == .number(FileIndex.idleStop))
        #expect(asks.isEmpty, "reading the state starts no search")
    }

    @Test("Both verbs declare their flags and fill schema --index and help")
    func contract() throws {
        for name in ["files", "convert"] {
            let verb = try verbs.verb(name)
            #expect(verb.flags?.isEmpty == false)
            #expect(verb.index?() != nil)
        }
        #expect(try verbs.verb("convert").detail?("webp")?.contains("needs webp") == true)
        #expect(try verbs.verb("files").detail?("kind") != nil)
    }
}
