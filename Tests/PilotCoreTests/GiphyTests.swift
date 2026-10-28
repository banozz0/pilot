import AppKit
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import PilotCore

/// The secret store as a value in memory, so no test reads or writes the login Keychain.
final class FakeKeyStore: StoredKey, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read() -> String? { lock.withLock { value } }
    func exists() -> Bool { read() != nil }
    func write(_ value: String?) throws { lock.withLock { self.value = value } }
}

/// Web GIF search in Stickers and GIFs (story 164): GIPHY's API with the network faked, the requests it would send
/// recorded. Temp folders and private pasteboards only.
@Suite("GIPHY")
struct GiphyTests {
    /// GIPHY's answer cut down to the fields read, plus one GIF with no preview, which is left out.
    static let answer = Data(#"""
    {"data": [
      {"id": "3o7abKhOpu0NwenH3O", "title": "Happy Dance GIF by Mashable",
       "images": {"preview_gif": {"url": "https://media.giphy.com/media/3o7abKhOpu0NwenH3O/giphy-preview.gif"},
                  "fixed_width_small": {"url": "https://media.giphy.com/media/3o7abKhOpu0NwenH3O/100w.gif"},
                  "downsized": {"url": "https://media.giphy.com/media/3o7abKhOpu0NwenH3O/giphy-downsized.gif"},
                  "original": {"url": "https://media.giphy.com/media/3o7abKhOpu0NwenH3O/giphy.gif"}}},
      {"id": "xT9IgG50Fb7Mi0prBC", "title": "",
       "images": {"fixed_width_small": {"url": "https://media.giphy.com/media/xT9IgG50Fb7Mi0prBC/100w.gif"},
                  "original": {"url": "https://media.giphy.com/media/xT9IgG50Fb7Mi0prBC/giphy.gif"}}},
      {"id": "noPreview", "title": "Broken", "images": {"original": {"url": "https://media.giphy.com/media/noPreview/giphy.gif"}}}
    ], "pagination": {"count": 3}, "meta": {"status": 200}}
    """#.utf8)

    /// A fake network: answers each URL from `pages` (else 404) and records every request.
    final class Net: @unchecked Sendable {
        let asked = Mutex<[URLRequest]>([])
        let pages: [String: (Data, Int)]
        init(_ pages: [String: (Data, Int)] = [:]) { self.pages = pages }
        var http: GiphyHTTP {
            GiphyHTTP { [self] request in
                asked.withLock { $0.append(request) }
                let url = request.url!
                let page = url.host == "api.giphy.com" ? "api:" + url.path : url.absoluteString
                return pages[page] ?? (Data(), 404)
            }
        }
        var urls: [URL] { asked.withLock { $0.compactMap(\.url) } }
    }

    /// A two-frame GIF, as GIPHY sends; `clear`, a sticker's: a square on a transparent background.
    static func gif(clear: Bool = false) throws -> Data {
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for white in [0.0, 1.0] {
            let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(gray: white, alpha: 1))
            ctx.fill(clear ? CGRect(x: 2, y: 2, width: 4, height: 4) : CGRect(x: 0, y: 0, width: 8, height: 8))
            CGImageDestinationAddImage(dest, try #require(ctx.makeImage()),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func items(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test("A search asks /v1/gifs/search with the key, the text, 24 results and PG-13; nothing typed asks trending")
    func request() throws {
        let search = try #require(Giphy.request("  happy dance ", key: "k3y").url)
        #expect(search.host == "api.giphy.com" && search.path == "/v1/gifs/search" && search.scheme == "https")
        #expect(items(search) == ["api_key": "k3y", "q": "happy dance", "limit": "24", "rating": "pg-13", "lang": "en"])
        let trending = try #require(Giphy.request(" ", key: "k3y").url)
        #expect(trending.path == "/v1/gifs/trending")
        #expect(items(trending) == ["api_key": "k3y", "limit": "24", "rating": "pg-13"])
    }

    @Test("The rating picked and the next page's offset ride on every request, GIFs and stickers, search and trending")
    func ratingAndOffset() async throws {
        for kind in Giphy.Kind.allCases {
            let search = try #require(Giphy.request("cat", key: "k3y", kind: kind, rating: .g, offset: 24).url)
            #expect(items(search) == ["api_key": "k3y", "q": "cat", "lang": "en", "limit": "24", "rating": "g", "offset": "24"])
            let trending = try #require(Giphy.request("", key: "k3y", kind: kind, rating: .r, offset: 48).url)
            #expect(items(trending) == ["api_key": "k3y", "limit": "24", "rating": "r", "offset": "48"])
        }
        #expect(Giphy.Rating.allCases.map(\.rawValue) == ["g", "pg", "pg-13", "r"] && Giphy.Rating.standard == .pg13)
        #expect(Giphy.Rating.allCases.map(\.title) == ["G", "PG", "PG-13", "R"])
        // Through search: the fake network sees what the menu would send.
        let net = Net(["api:/v1/stickers/search": (Self.stickers, 200)])
        _ = try await Giphy.search("thumbs", key: "k", kind: .stickers, rating: .pg, offset: 72, http: net.http)
        let asked = try #require(net.urls.first)
        #expect(items(asked)["rating"] == "pg" && items(asked)["offset"] == "72")
    }

    /// An answer of `count` GIFs from `offset`, with GIPHY's pagination unless `total` is nil.
    static func paged(_ count: Int, offset: Int = 0, total: Int?) -> Data {
        let gifs = (0..<count).map { i in
            #"{"id": "g\#(offset + i)", "title": "GIF \#(offset + i)", "images": {"preview_gif": {"url": "https://media.giphy.com/p\#(offset + i).gif"}, "#
                + #""downsized": {"url": "https://media.giphy.com/d\#(offset + i).gif"}}}"#
        }
        let pages = total.map { #", "pagination": {"total_count": \#($0), "count": \#(count), "offset": \#(offset)}"# } ?? ""
        return Data(#"{"data": [\#(gifs.joined(separator: ","))]\#(pages)}"#.utf8)
    }

    @Test("A page says where the next starts while GIPHY has more, never past 96 results; without pagination a full page has more")
    func pages() throws {
        #expect(try Giphy.page(Self.paged(24, total: 500)).next == 24)
        #expect(try Giphy.page(Self.paged(24, offset: 24, total: 500), offset: 24).next == 48)
        #expect(try Giphy.page(Self.paged(24, offset: 48, total: 500), offset: 48).next == 72)
        #expect(try Giphy.page(Self.paged(24, offset: 72, total: 500), offset: 72).next == nil, "96 is the most one search lists")
        #expect(try Giphy.page(Self.paged(6, offset: 24, total: 30), offset: 24).next == nil, "GIPHY has no more")
        #expect(try Giphy.page(Self.paged(24, total: 24)).next == nil)
        #expect(try Giphy.page(Self.paged(24, total: nil)).next == 24, "a full page without pagination may have more")
        #expect(try Giphy.page(Self.paged(10, total: nil)).next == nil)
        #expect(try Giphy.page(Self.paged(0, total: 500)).next == nil, "an empty page ends it")
        #expect(try Giphy.page(Self.stickers, kind: .stickers).next == nil, "the fixture's three are all")
        #expect(try Giphy.page(Self.paged(24, offset: 24, total: 500), offset: 24).gifs.first?.id == "g24")
    }

    @Test("The answer becomes GIFs: the small preview for the row, the downsized file for the paste, a missing title says GIF")
    func parse() throws {
        let gifs = try Giphy.parse(Self.answer)
        #expect(gifs.map(\.id) == ["3o7abKhOpu0NwenH3O", "xT9IgG50Fb7Mi0prBC"], "one with no preview is left out")
        #expect(gifs[0].title == "Happy Dance GIF by Mashable")
        #expect(gifs[0].preview.lastPathComponent == "giphy-preview.gif" && gifs[0].full.lastPathComponent == "giphy-downsized.gif")
        #expect(gifs[1].title == "GIF")
        #expect(gifs[1].preview.lastPathComponent == "100w.gif" && gifs[1].full.lastPathComponent == "giphy.gif")
        #expect(throws: (any Error).self) { try Giphy.parse(Data("<html>".utf8)) }
    }

    /// GIPHY's sticker answer, kept in Fixtures: shaped as /v1/stickers/search answers (written to GIPHY's documented
    /// sticker object, not captured live), with one sticker on plain HTTP, which is left out.
    static let stickers = try! Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/giphy-stickers-search.json"))

    @Test("Stickers ask /v1/stickers/search and /v1/stickers/trending with the same key, 24 results and PG-13")
    func stickerRequest() throws {
        let search = try #require(Giphy.request(" thumbs up", key: "k3y", kind: .stickers).url)
        #expect(search.host == "api.giphy.com" && search.path == "/v1/stickers/search" && search.scheme == "https")
        #expect(items(search) == ["api_key": "k3y", "q": "thumbs up", "limit": "24", "rating": "pg-13", "lang": "en"])
        let trending = try #require(Giphy.request("", key: "k3y", kind: .stickers).url)
        #expect(trending.path == "/v1/stickers/trending")
        #expect(items(trending) == ["api_key": "k3y", "limit": "24", "rating": "pg-13"])
        #expect(Giphy.Kind(rawValue: "stickers")?.next == .gifs && Giphy.Kind.gifs.next == .stickers)
    }

    @Test("A sticker answer becomes stickers as GIFs do: preview and downsized GIF, a missing title says Sticker, HTTP left out")
    func stickerParse() async throws {
        let stickers = try Giphy.parse(Self.stickers, kind: .stickers)
        #expect(stickers.map(\.id) == ["l0HlvtIPzPdt2usKs", "kyLYXonQYYfwYDIeZl"])
        #expect(stickers[0].title == "Thumbs Up Sticker by Pudgy Penguins")
        #expect(stickers[0].preview.lastPathComponent == "giphy-preview.gif" && stickers[0].full.lastPathComponent == "giphy-downsized.gif")
        #expect(stickers[1].title == "Sticker")
        #expect(stickers[1].preview.lastPathComponent == "100w.gif" && stickers[1].full.lastPathComponent == "giphy.gif")
        let net = Net(["api:/v1/stickers/search": (Self.stickers, 200), "api:/v1/stickers/trending": (Self.stickers, 200)])
        #expect(try await Giphy.search("thumbs", key: "k", kind: .stickers, http: net.http).gifs.count == 2)
        #expect(try await Giphy.search("", key: "k", kind: .stickers, http: net.http).gifs.count == 2)
        #expect(net.urls.map(\.path) == ["/v1/stickers/search", "/v1/stickers/trending"])
    }

    @Test("A sticker downloads and pastes as a GIF, its transparent pixels kept on the pasteboard")
    @MainActor func stickerPaste() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-giphy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let sticker = try #require(try Giphy.parse(Self.stickers, kind: .stickers).first)
        let bytes = try Self.gif(clear: true)
        let file = try await Giphy.download(sticker, to: folder, http: Net([sticker.full.absoluteString: (bytes, 200)]).http)
        let board = NSPasteboard(name: .init("pilot.test.giphy.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        _ = try Stickers.put(.image(file.path), on: board)
        let pasted = try #require(board.pasteboardItems?.first?.data(forType: .init(UTType.gif.identifier)))
        #expect(pasted == bytes, "the GIF's own bytes, never redrawn")
        let source = try #require(CGImageSourceCreateWithData(pasted as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect([.premultipliedLast, .last, .premultipliedFirst, .first].contains(image.alphaInfo), "the frame keeps an alpha channel")
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let corner = try #require(ctx.data).load(as: UInt32.self)
        #expect(corner >> 24 == 0, "the clear corner stays clear")
    }

    @Test("Without a key nothing is asked; with one the search lists its GIFs; a refused key says so")
    func search() async throws {
        let net = Net(["api:/v1/gifs/search": (Self.answer, 200), "api:/v1/gifs/trending": (Self.answer, 200)])
        #expect(try await Giphy.search("cat", key: nil, http: net.http) == Giphy.Page(gifs: [], next: nil))
        #expect(try await Giphy.search("", key: nil, rating: .r, offset: 24, http: net.http).gifs.isEmpty)
        #expect(net.urls.isEmpty, "no request without a key")
        #expect(try await Giphy.search("cat", key: "k", http: net.http).gifs.count == 2)
        #expect(try await Giphy.search("", key: "k", http: net.http).gifs.count == 2)
        #expect(net.urls.map(\.path) == ["/v1/gifs/search", "/v1/gifs/trending"])
        let refused = Net(["api:/v1/gifs/search": (Data(#"{"message":"Unauthorized"}"#.utf8), 401)])
        await #expect(throws: Giphy.Failure.refused) { try await Giphy.search("cat", key: "bad", http: refused.http) }
        await #expect(throws: Giphy.Failure.status(500)) {
            try await Giphy.search("cat", key: "k", http: Net(["api:/v1/gifs/search": (Data(), 500)]).http)
        }
    }

    @Test("A failure is logged by its code alone, never the URL that holds the key")
    func describe() throws {
        let url = try #require(Giphy.request("cat", key: "s3cret").url)
        let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString])
        #expect(String(describing: error).contains("s3cret"), "the plain description would leak it")
        #expect(Giphy.describe(error) == "NSURLErrorDomain -1001")
        #expect(Giphy.describe(Giphy.Failure.refused) == "refused")
    }

    @Test("Previews fetch only the small renditions, never a full file; one that fails is left out")
    func previews() async throws {
        let gifs = try Giphy.parse(Self.answer)
        let net = Net([gifs[0].preview.absoluteString: (try Self.gif(), 200)])
        let got = await Giphy.previews(gifs, http: net.http)
        #expect(Set(got.keys) == [gifs[0].id])
        #expect(Set(net.urls) == Set(gifs.map(\.preview)))
        #expect(!net.urls.contains(where: { gifs.map(\.full).contains($0) }))
    }

    @Test("The user's key wins over the one the build ships; a blank one is no key")
    func key() throws {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "pilot-giphy-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: bundle.appending(path: "Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        func shipping(_ key: String) throws -> Bundle {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.giphy", "PilotGiphyKey": key],
                                                           format: .xml, options: 0)
            try plist.write(to: bundle.appending(path: "Contents/Info.plist"))
            return try #require(Bundle(url: bundle))
        }
        let shipped = try shipping("shipped")
        #expect(Giphy.key(stored: FakeKeyStore("mine"), bundle: shipped) == "mine")
        #expect(Giphy.key(stored: FakeKeyStore(nil), bundle: shipped) == "shipped")
        #expect(Giphy.key(stored: FakeKeyStore("  "), bundle: shipped) == "shipped")
        #expect(Giphy.key(stored: FakeKeyStore(nil), bundle: .main) == nil, "the test runner ships none")
    }

    @Test("A pick downloads the file once into the cache; a page that is no GIF is refused")
    func download() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-giphy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let gif = try #require(try Giphy.parse(Self.answer).first)
        let bytes = try Self.gif()
        let net = Net([gif.full.absoluteString: (bytes, 200)])
        let file = try await Giphy.download(gif, to: folder, http: net.http)
        #expect(file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL && file.lastPathComponent == "3o7abKhOpu0NwenH3O.gif")
        #expect(try Data(contentsOf: file) == bytes)
        _ = try await Giphy.download(gif, to: folder, http: net.http)
        #expect(net.urls == [gif.full], "a second pick reads the cache")
        let html = Net([gif.full.absoluteString: (Data("<html>".utf8), 200)])
        let other = WebGIF(id: "other", title: "x", preview: gif.preview, full: gif.full)
        await #expect(throws: Giphy.Failure.notGIF) { try await Giphy.download(other, to: folder, http: html.http) }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "other.gif").path))
    }

    @Test("The cache keeps the newest 60 GIFs")
    func prune() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-giphy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for i in 0..<63 {
            let file = folder.appending(path: "\(i).gif")
            try Data("GIF89a".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000 + i))], ofItemAtPath: file.path)
        }
        Giphy.prune(folder)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left.count == 60 && !left.contains("0.gif") && !left.contains("2.gif") && left.contains("62.gif"))
    }

    @Test("A downloaded GIF goes on the pasteboard as its GIF bytes and its file, marked transient")
    @MainActor func pasteboard() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-giphy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let gif = try #require(try Giphy.parse(Self.answer).first)
        let bytes = try Self.gif()
        let file = try await Giphy.download(gif, to: folder, http: Net([gif.full.absoluteString: (bytes, 200)]).http)
        let board = NSPasteboard(name: .init("pilot.test.giphy.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        _ = try Stickers.put(.image(file.path), on: board)
        let item = try #require(board.pasteboardItems?.first)
        #expect(item.data(forType: .init(UTType.gif.identifier)) == bytes)
        #expect(item.string(forType: .fileURL) == file.absoluteString)
        #expect(item.types.contains(.init("org.nspasteboard.TransientType")))
        #expect(throws: (any Error).self) { try Stickers.put(.giphy(gif), on: board) }
    }

    @Test("GIPHY's rows paste a GIF and stay listed for their text; the key row opens settings and is no pick")
    func rows() throws {
        let gifs = try Giphy.parse(Self.answer)
        let rows = Giphy.entries(gifs, query: "dance")
        #expect(rows.map(\.target) == gifs.map { .sticker(.giphy($0)) })
        #expect(rows.allSatisfy { $0.home == .stickers && !$0.inSearch && $0.keywords == "dance" && $0.subtitle == "GIPHY" })
        #expect(rows[0].kindWord == "GIF" && rows[0].returnLabel == "Paste" && rows[0].frecencyKey == "sticker:giphy:3o7abKhOpu0NwenH3O")
        let ask = Giphy.keyRow(refused: false, query: "")
        #expect(ask.title == "Add a GIPHY key to search the web" && ask.returnLabel == "Open" && ask.frecencyKey == nil)
        #expect(Giphy.keyRow(refused: true, query: "").title.contains("refused"))
        #expect(ask.target == .openPage(AppPlace(.menu, .abilities)) && ask.kind == .sticker, "listed with the stickers, so the next search replaces it")
        // The branch keeps every row GIPHY found, whatever its title, for the text it answered.
        var nav = MenuNavigator(entries: [], branch: .stickers)
        nav.query = "dance"
        nav.provide(.sticker, home: .stickers, rows + [Giphy.keyRow(refused: false, query: "dance")])
        #expect(nav.rows.count == 3)
        nav.provide(.sticker, home: .stickers, [Giphy.keyRow(refused: false, query: "dance")])
        #expect(nav.rows.count == 1, "the key row is replaced, never doubled")
    }
}
