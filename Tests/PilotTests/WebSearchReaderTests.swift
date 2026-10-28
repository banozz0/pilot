import Compression
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Search the web's engine read from a browser's own files (Sven 2026-10-16): a Chromium profile's Preferences and a
/// Firefox profile's LZ4-compressed search.json, in a made-up Application Support folder, never this Mac's.
@Suite("Web search reader")
struct WebSearchReaderTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pilot-websearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `data` as Mozilla writes search.json.mozlz4: the magic, the length little-endian, one raw LZ4 block.
    func mozlz4(_ data: Data) -> Data {
        var out = Data(count: data.count + 1024)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, data.count + 1024,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        var length = UInt32(data.count).littleEndian
        return Data("mozLz40\0".utf8) + Data(bytes: &length, count: 4) + out.prefix(written)
    }

    @Test("Chrome: the last-used profile's engine, the row naming it with the browser; Google's template made plain")
    func chrome() throws {
        let support = try folder()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = support.appending(path: "Google/Chrome")
        try FileManager.default.createDirectory(at: root.appending(path: "Profile 1"), withIntermediateDirectories: true)
        try Data(#"{"profile":{"last_used":"Profile 1"}}"#.utf8).write(to: root.appending(path: "Local State"))
        try Data(#"{"default_search_provider_data":{"template_url_data":{"short_name":"Ecosia","url":"https://www.ecosia.org/search?q={searchTerms}&tt={google:RLZ}"}}}"#.utf8)
            .write(to: root.appending(path: "Profile 1/Preferences"))
        let choice = WebSearchReader.read(browser: ("Google Chrome", "com.google.Chrome"), support: support)
        #expect(choice.via == "Ecosia in Google Chrome")
        #expect(choice.engine.url(for: "trees")?.absoluteString == "https://www.ecosia.org/search?q=trees&tt=")
        // A browser with nothing saved searches with its own first engine; one Pilot does not know, Google.
        #expect(WebSearchReader.read(browser: ("Microsoft Edge", "com.microsoft.edgemac"), support: support).engine.name == "Bing")
        #expect(WebSearchReader.read(browser: ("Orion", "com.kagi.kagimacOS"), support: support).engine == WebSearch.google)
        #expect(WebSearchReader.read(browser: ("Safari", "com.apple.Safari"), support: support).via == "Safari")
    }

    @Test("Zen: installs.ini's profile, its search.json.mozlz4 decompressed, the default engine; the stamp follows the file")
    func zen() throws {
        let support = try folder()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = support.appending(path: "zen")
        try FileManager.default.createDirectory(at: root.appending(path: "Profiles/abc.Default (release)"), withIntermediateDirectories: true)
        try "[6F193CCC56814779]\nDefault=Profiles/abc.Default (release)\nLocked=1\n".write(to: root.appending(path: "installs.ini"), atomically: true, encoding: .utf8)
        let json = #"{"version":11,"engines":[{"id":"google","_name":"Google"},{"id":"ddg","_name":"DuckDuckGo"}],"metaData":{"defaultEngineId":"ddg","defaultEngineIdHash":"x"}}"#
        let file = root.appending(path: "Profiles/abc.Default (release)/search.json.mozlz4")
        try mozlz4(Data(json.utf8)).write(to: file)
        #expect(WebSearchReader.mozlz4(try Data(contentsOf: file)) == Data(json.utf8))
        let browser = (name: "Zen", bundleID: "app.zen-browser.zen")
        let choice = WebSearchReader.read(browser: browser, support: support)
        #expect(choice.via == "DuckDuckGo in Zen")
        let stamp = WebSearchReader.stamp(browser: browser, support: support)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: file.path)
        #expect(WebSearchReader.stamp(browser: browser, support: support) != stamp, "a changed engine is read again")
        #expect(WebSearchReader.mozlz4(Data("not lz4".utf8)) == nil)
    }
}
