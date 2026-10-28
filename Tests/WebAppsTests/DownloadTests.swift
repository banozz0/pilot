import Foundation
import Testing
@testable import WebApps

/// Downloads in a web app (card agent-bo-95422810): where a file lands, how it is marked, what the bar says.
@Suite("Web app downloads")
struct DownloadTests {
    @Test("A free name in the folder: name, name (1), name (2) before the extension; unsafe characters made safe")
    func freeName() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Downloads.destination(for: "report.pdf", in: folder).lastPathComponent == "report.pdf")
        for name in ["report.pdf", "report (1).pdf"] { try Data().write(to: folder.appending(path: name)) }
        #expect(Downloads.destination(for: "report.pdf", in: folder).lastPathComponent == "report (2).pdf")
        #expect(Downloads.destination(for: "a/b:c.txt", in: folder).lastPathComponent == "a-b-c.txt")
        #expect(Downloads.destination(for: "  ", in: folder).lastPathComponent == "download")
        #expect(Downloads.destination(for: "", in: folder).lastPathComponent == "download")
        #expect(Downloads.destination(for: ".hidden", in: folder).lastPathComponent == "hidden")
        try Data().write(to: folder.appending(path: "archive.tar.gz"))
        #expect(Downloads.destination(for: "archive.tar.gz", in: folder).lastPathComponent == "archive (1).tar.gz")
        try Data().write(to: folder.appending(path: "README"))
        #expect(Downloads.destination(for: "README", in: folder).lastPathComponent == "README (1)")
    }

    @Test("A download that failed before the site answered is named after its link, or download")
    func unansweredName() {
        #expect(Downloads.unansweredName(URL(string: "https://example.com/files/report.pdf")) == "report.pdf")
        #expect(Downloads.unansweredName(URL(string: "https://example.com/")) == "download")
        #expect(Downloads.unansweredName(URL(string: "https://example.com")) == "download")
        #expect(Downloads.unansweredName(nil) == "download")
    }

    @Test("The file is marked as a web download from the page, with the web app as the agent, as Safari marks it")
    func quarantine() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "pilot-quarantine-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let source = try #require(URL(string: "https://example.com/files/x.txt"))
        let page = try #require(URL(string: "https://example.com/files"))
        let properties = Downloads.quarantine(agent: "Example", source: source, page: page)
        #expect(properties[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
        #expect(properties[kLSQuarantineAgentNameKey as String] as? String == "Example")
        #expect(properties[kLSQuarantineDataURLKey as String] as? URL == source)
        #expect(properties[kLSQuarantineOriginURLKey as String] as? URL == page)
        try Downloads.mark(file, with: properties)
        let read = try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(read?[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
    }

    @Test("The bar says the percent, the size when the total is unknown, done, or why it failed")
    func barText() {
        #expect(Downloads.status(name: "a.pdf", .progress(received: 42, total: 100)) == "a.pdf — 42 %")
        #expect(Downloads.status(name: "a.pdf", .progress(received: 1_200_000, total: -1)) == "a.pdf — 1.2 MB")
        #expect(Downloads.status(name: "a.pdf", .done) == "a.pdf — downloaded")
        #expect(Downloads.status(name: "a.pdf", .unmarked("Permission denied")) == "a.pdf — downloaded, not marked as from the web: Permission denied")
        #expect(Downloads.status(name: "a.pdf", .failed("The network connection was lost.")) == "a.pdf — failed: The network connection was lost.")
    }

    @Test("A finished download offers Open and Show in Finder; one without its web mark only Show in Finder")
    func rowActions() {
        #expect(Downloads.actions(.done) == [.open, .showInFinder])
        #expect(Downloads.actions(.unmarked("Permission denied")) == [.showInFinder])
        #expect(Downloads.actions(.progress(received: 1, total: 2)).isEmpty)
        #expect(Downloads.actions(.failed("lost")).isEmpty)
        #expect(Downloads.Action.allCases.map(\.rawValue) == ["Open", "Show in Finder"])
    }

    @Test("Content-Disposition attachment means save; inline or none means show")
    func attachment() throws {
        func response(_ disposition: String?) throws -> URLResponse {
            let url = try #require(URL(string: "https://example.com/f"))
            return try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                headerFields: disposition.map { ["Content-Disposition": $0] } ?? [:]))
        }
        #expect(Downloads.isAttachment(try response(#"attachment; filename="a.pdf""#)))
        #expect(Downloads.isAttachment(try response(" Attachment")))
        #expect(!Downloads.isAttachment(try response("inline")))
        #expect(!Downloads.isAttachment(try response(nil)))
    }
}
