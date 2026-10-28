import AppKit
import Compression
import PilotCore

/// The default browser and its default search engine, read from the browser's own settings for Hyper+Space's Search the
/// web row (WebSearch). Off the main thread: a Chromium profile's Preferences is a few hundred kilobytes.
enum WebSearchReader {
    /// What Search the web opens: the engine and the browser it searches in, named for the row ("Google in Chrome").
    struct Choice: Equatable, Sendable {
        let engine: WebSearch.Engine
        let browser: String?

        /// The row's words: "Google in Chrome"; Safari's own engine is "Safari".
        var via: String {
            if engine == WebSearch.safari { return browser ?? "Safari" }
            return browser.map { "\(engine.name) in \($0)" } ?? engine.name
        }
    }

    /// The default browser for web links, its name and bundle id; nil when none is set.
    static func defaultBrowser() -> (name: String, bundleID: String)? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
              let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        return (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), id)
    }

    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// The file that holds `browser`'s engine (a Chromium profile's Preferences, a Firefox profile's search.json.mozlz4);
    /// nil for Safari and the rest, whose engine is not read from a file.
    nonisolated static func settingsFile(browser: (name: String, bundleID: String), support: URL = support) -> URL? {
        switch WebSearch.family(bundleID: browser.bundleID) {
        case .chromium(let folder, _):
            let root = support.appending(path: folder)
            return root.appending(path: WebSearch.chromiumProfile(localState: try? Data(contentsOf: root.appending(path: "Local State"))))
                .appending(path: "Preferences")
        case .firefox(let folder):
            let root = support.appending(path: folder)
            let path = WebSearch.firefoxProfile(installs: try? String(contentsOf: root.appending(path: "installs.ini"), encoding: .utf8),
                                                profiles: try? String(contentsOf: root.appending(path: "profiles.ini"), encoding: .utf8))
            return path.map { root.appending(path: $0).appending(path: "search.json.mozlz4") }
        case .safari, .other:
            return nil
        }
    }

    /// What decides the choice without reading it: the browser and its settings file's date, so the menu reads the
    /// engine again only when either changed (Pilot stays lean, story 142).
    nonisolated static func stamp(browser: (name: String, bundleID: String)?, support: URL = support) -> String {
        guard let browser else { return "" }
        let date = settingsFile(browser: browser, support: support)
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return "\(browser.bundleID) \(date?.timeIntervalSince1970 ?? 0)"
    }

    /// The default browser's engine, from its settings under `support` (Application Support); Google when it reads none.
    nonisolated static func read(browser: (name: String, bundleID: String)?, support: URL = support) -> Choice {
        guard let browser else { return Choice(engine: WebSearch.google, browser: nil) }
        let data = settingsFile(browser: browser, support: support).flatMap { try? Data(contentsOf: $0) }
        switch WebSearch.family(bundleID: browser.bundleID) {
        case .safari:
            return Choice(engine: WebSearch.safari, browser: browser.name)
        case .chromium(_, let standard):
            return Choice(engine: data.flatMap(WebSearch.chromium) ?? standard, browser: browser.name)
        case .firefox:
            return Choice(engine: data.flatMap(mozlz4).flatMap(WebSearch.firefox) ?? WebSearch.google, browser: browser.name)
        case .other:
            return Choice(engine: WebSearch.google, browser: browser.name)
        }
    }

    /// A Mozilla mozlz4 file's contents: an 8-byte magic, the decompressed length (4 bytes, little-endian), then one LZ4
    /// block; nil for anything else.
    nonisolated static func mozlz4(_ data: Data) -> Data? {
        let magic = Data("mozLz40\0".utf8)
        guard data.count > 12, data.prefix(8) == magic else { return nil }
        let length = data.subdata(in: 8..<12).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length > 0, length < 64 << 20 else { return nil }
        let block = data.subdata(in: 12..<data.count)
        var out = Data(count: length)
        let written = out.withUnsafeMutableBytes { dst in
            block.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, length,
                                          src.bindMemory(to: UInt8.self).baseAddress!, block.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        return written == length ? out : nil
    }

    /// Searches the web for `query` with `choice`, in the default browser (Safari's own link opens Safari).
    @MainActor static func open(_ query: String, with choice: Choice) {
        guard let url = choice.engine.url(for: query) ?? WebSearch.google.url(for: query) else { return }
        NSWorkspace.shared.open(url)
    }
}
