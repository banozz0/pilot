import AppKit
import PilotCore
import Testing
@testable import Pilot

/// Convert's ways in (card agent-bo-95423211): Finder's Convert with Pilot… and a file row's Convert to… open the
/// menu's picker on the formats the files share. Fakes throughout: nothing converts, installs or shows.
@MainActor
@Suite("Convert files")
struct ConvertFilesTests {
    final class Record {
        var picked: (rows: [MenuEntry], title: String, then: @MainActor (MenuEntry) -> Void)?
        var installed: [String] = []
        var started: [([URL], ConvertFormat)] = []
        var tips: [String] = []
    }

    func offer(_ urls: [URL], tools: [ConvertTool: String] = [:], _ record: Record) {
        ConvertFiles.offer(urls, converter: Converter(tools: tools), pick: { record.picked = ($0, $1, $2) },
                           install: { record.installed.append($0) }, start: { urls, format, _ in record.started.append((urls, format)) },
                           tip: { record.tips.append($0) })
    }

    @Test("Several files: the picker lists the formats they share, and a pick converts them all to it")
    func pick() throws {
        let record = Record()
        let urls = [URL(filePath: "/x/a.png"), URL(filePath: "/x/b.jpg")]
        offer(urls, record)
        let picked = try #require(record.picked)
        #expect(picked.title == "Convert 2 files to")
        #expect(picked.rows.map(\.title) == ["PNG", "JPG", "HEIC", "WebP", "PDF"])
        picked.then(try #require(picked.rows.first { $0.title == "HEIC" }))
        #expect(record.started.map(\.0) == [urls])
        #expect(record.started.map(\.1) == [.heic])
        #expect(record.installed.isEmpty)
    }

    @Test("A format that needs ffmpeg hands its formula to Install's confirm step and converts nothing")
    func needsTool() throws {
        let record = Record()
        offer([URL(filePath: "/x/clip.mov")], record)
        let picked = try #require(record.picked)
        #expect(picked.title == "Convert clip.mov to")
        let mp3 = try #require(picked.rows.first { $0.title == "MP3" })
        #expect(mp3.detail == "needs ffmpeg")
        picked.then(mp3)
        #expect(record.installed == ["formula:ffmpeg"])
        #expect(record.started.isEmpty)
    }

    @Test("Files that share no format get a tip, not an empty picker")
    func nothingShared() {
        let record = Record()
        offer([URL(filePath: "/x/a.png"), URL(filePath: "/x/b.wav")], record)
        #expect(record.picked == nil)
        #expect(record.tips == ["These files have no format in common to convert to"])
        offer([URL(filePath: "/x/a.zip")], record)
        #expect(record.tips.last == "Pilot cannot convert a.zip")
    }

    @Test("Convert asked for while a job runs brings its progress tip back with Cancel, at the line it reached")
    func cancelComesBack() {
        let record = Record()
        let saved = ConvertFiles.showLasting
        var shown: [(String, String)] = []
        ConvertFiles.showLasting = { text, action in shown.append((text, action.title)); return nil }
        ConvertFiles.job = Task {}
        defer { ConvertFiles.job = nil; ConvertFiles.showLasting = saved }
        ConvertFiles.updateProgress("Converting 2 of 3 to JPG…")
        offer([URL(filePath: "/x/a.png")], record)
        #expect(shown.map(\.0) == ["Converting 2 of 3 to JPG…"])
        #expect(shown.map(\.1) == ["Cancel"])
        #expect(record.picked == nil, "no second job")
    }

    @Test("The Finder service reads the files off its pasteboard and offers them; a pasteboard with no file does nothing")
    func service() {
        var offered: [[URL]] = []
        let service = PilotServices { offered.append($0) }
        let board = NSPasteboard(name: NSPasteboard.Name("dev.banozz.pilot.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([URL(filePath: "/x/a.png") as NSURL])
        var error: NSString?
        service.convertFiles(board, userData: nil, error: &error)
        board.clearContents()
        board.setString("hello", forType: .string)
        service.convertFiles(board, userData: nil, error: &error)
        #expect(offered == [[URL(filePath: "/x/a.png")]])
        #expect(error == "No files to convert")
    }

    @Test("Info.plist offers the Finder service under its own name, for the kinds of file Convert reads")
    func plist() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let service = try #require((plist["NSServices"] as? [[String: Any]])?.first)
        #expect((service["NSMenuItem"] as? [String: String])?["default"] == "Convert with Pilot…")
        #expect(service["NSMessage"] as? String == "convertFiles")
        #expect(service["NSPortName"] as? String == "Pilot")
        let types = try #require(service["NSSendFileTypes"] as? [String])
        #expect(Set(types).isSuperset(of: ["public.image", "public.audiovisual-content", "com.adobe.pdf", "public.text"]))
    }
}
