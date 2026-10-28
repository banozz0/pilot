import Testing
@testable import PilotCore

/// Card agent-bo-95422842 (Sven, 2026-10-05: "configure what app opens each kind of file"): the kinds the Default apps
/// page lists, grouped as Finder's Open With would meet them.
@Suite("File kinds")
struct FileKindsTests {
    @Test("The groups hold text, Markdown, data, source code, images, PDF, video, audio, archives and links, in that order")
    func groups() {
        #expect(FileKinds.groups.map(\.name) == ["Text", "Markdown", "JSON, YAML and TOML", "Source code", "Images", "PDF", "Video", "Audio",
                                                 "Archives", "Links"])
        let all = FileKinds.groups.flatMap(\.kinds)
        for id in ["public.plain-text", "net.daringfireball.markdown", "public.json", "public.yaml", "public.toml", "public.source-code",
                   "public.swift-source", "public.png", "public.jpeg", "com.adobe.pdf", "public.mpeg-4", "public.mp3", "public.zip-archive"] {
            #expect(all.contains { $0.handlers == [.contentType(id)] }, "\(id)")
        }
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test("Web links are http and https through the browser role, mail links mailto through the mail role; macOS confirms them")
    func links() throws {
        let links = try #require(FileKinds.groups.last).kinds
        #expect(links.map(\.handlers) == [[.url("https://example.com"), .url("http://example.com")], [.url("mailto:someone@example.com")]])
        #expect(links.map(\.roles) == [[.browser], [.mail]])
        #expect(links.allSatisfy { $0.confirmNote != nil })
        // Plain text and other source code feed the main editor; no other file kind feeds a role, and none asks.
        let files = FileKinds.groups.dropLast().flatMap(\.kinds)
        #expect(files.filter { !$0.roles.isEmpty }.map(\.handlers) == [[.contentType("public.plain-text")], [.contentType("public.source-code")]])
        #expect(files.allSatisfy { $0.roles.allSatisfy { $0 == .editor } && $0.confirmNote == nil })
    }
}
