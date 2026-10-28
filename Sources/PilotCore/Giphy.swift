import Foundation

/// One GIF GIPHY found: its small preview the row animates, and the file Return downloads and pastes.
public struct WebGIF: Hashable, Sendable {
    public let id: String, title: String
    /// GIPHY's preview rendition (50 KB at most), else its 100-pixel-wide one; never the full file.
    public let preview: URL
    /// The downsized rendition (2 MB at most, what chats take), else the original.
    public let full: URL

    public init(id: String, title: String, preview: URL, full: URL) {
        self.id = id; self.title = title; self.preview = preview; self.full = full
    }
}

/// A login-Keychain secret, or a fake in tests: never UserDefaults, a file or the log.
public protocol StoredKey: Sendable {
    func read() -> String?
    /// Whether it is there, asked without the secret, so no prompt is raised.
    func exists() -> Bool
    /// Saves `value`, or removes it when nil.
    func write(_ value: String?) throws
}

extension KeychainItem: StoredKey {}

/// The network under GIPHY: URLSession in Pilot, a fake in tests. Answers the body and the HTTP status.
public struct GiphyHTTP: Sendable {
    public var get: @Sendable (URLRequest) async throws -> (Data, Int)

    public init(get: @escaping @Sendable (URLRequest) async throws -> (Data, Int)) { self.get = get }

    /// Ephemeral, with no URL cache: nothing on disk, and the previews are kept once, by the menu's own cache.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    public static let live = GiphyHTTP { request in
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Web GIF and sticker search in Stickers and GIFs (story 164): GIPHY's public API, trending before anything is typed,
/// with Sven's own key from the login Keychain, else a key shipped in Info.plist (`PilotGiphyKey`). Nothing is asked
/// without a key.
public enum Giphy {
    public enum Failure: Error, Equatable {
        /// GIPHY turned the key down (401 or 403).
        case refused
        case status(Int)
        /// The download was no GIF.
        case notGIF
    }

    /// What GIPHY is searched for: its GIFs, or its stickers (transparent GIFs); the API's path word for each.
    public enum Kind: String, CaseIterable, Sendable {
        case gifs, stickers
        public var title: String { self == .gifs ? "GIFs" : "Stickers" }
        /// A result's name when GIPHY gives it none.
        var untitled: String { self == .gifs ? "GIF" : "Sticker" }
        public var next: Kind { self == .gifs ? .stickers : .gifs }
    }

    /// GIPHY's content ratings, the most a search may show (Launcher › Abilities under Stickers and GIFs, `giphy.rating`);
    /// PG-13 unless Sven picks another.
    public enum Rating: String, CaseIterable, Sendable {
        case g, pg, pg13 = "pg-13", r
        public var title: String { rawValue.uppercased() }
        public static let standard = Rating.pg13
    }

    /// One page of an answer: its GIFs, and the offset of the next page while GIPHY has more within `most`.
    public struct Page: Equatable, Sendable {
        public let gifs: [WebGIF]
        public let next: Int?
    }

    /// GIPHY's attribution rule: shown wherever its results are.
    public static let attribution = "Powered by GIPHY"
    public static let keyPage = URL(string: "https://developers.giphy.com/dashboard/")!
    /// The results a page lists; scrolling to the end of the list asks for the next.
    public static let limit = 24
    /// The most results one search lists, four pages.
    public static let most = 96
    /// How near the list's end a row shown asks for the next page.
    public static let pageAhead = 6
    /// The most GIFs kept in the download cache; older picks go first.
    static let cacheLimit = 60

    public static let keychain = KeychainItem(service: "dev.banozz.pilot.giphy", account: "api-key", label: "Pilot GIPHY key")

    /// Sven's own key, else the one the build ships; nil when neither is set.
    public static func key(stored: some StoredKey = keychain, bundle: Bundle = .main) -> String? {
        for key in [stored.read(), bundle.object(forInfoDictionaryKey: "PilotGiphyKey") as? String] {
            if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty { return key }
        }
        return nil
    }

    /// An error as the log may hold it: a URLError's own description carries the URL, and with it the key, so only its
    /// code is told.
    public static func describe(_ error: any Error) -> String {
        if let failure = error as? Failure { return String(describing: failure) }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    /// The search for `query`, or trending when nothing is typed, among GIPHY's GIFs or its stickers, from `offset`.
    public static func request(_ query: String, key: String, kind: Kind = .gifs, rating: Rating = .standard, offset: Int = 0) -> URLRequest {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var url = URLComponents(string: "https://api.giphy.com/v1/\(kind.rawValue)/\(typed.isEmpty ? "trending" : "search")")!
        url.queryItems = [URLQueryItem(name: "api_key", value: key)]
            + (typed.isEmpty ? [] : [URLQueryItem(name: "q", value: typed), URLQueryItem(name: "lang", value: "en")])
            + [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "rating", value: rating.rawValue)]
            + (offset > 0 ? [URLQueryItem(name: "offset", value: String(offset))] : [])
        var request = URLRequest(url: url.url!, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            struct Rendition: Decodable { let url: String? }
            let id: String
            let title: String?
            let images: [String: Rendition]
        }
        struct Pagination: Decodable { let total_count: Int?, count: Int?, offset: Int? }
        let data: [Item]
        let pagination: Pagination?
    }

    /// The GIFs (or stickers) of a search's answer; one missing a preview or a file is left out.
    public static func parse(_ data: Data, kind: Kind = .gifs) throws -> [WebGIF] {
        try page(data, kind: kind).gifs
    }

    /// A search's answer as a page: its GIFs and where the next starts. GIPHY's pagination says whether more are
    /// there; without it a full page is taken to have more.
    static func page(_ data: Data, kind: Kind = .gifs, offset: Int = 0) throws -> Page {
        let answer = try JSONDecoder().decode(Response.self, from: data)
        let gifs = answer.data.compactMap { item -> WebGIF? in
            func url(_ names: String...) -> URL? {
                names.lazy.compactMap { item.images[$0]?.url.flatMap(URL.init(string:)) }.first { $0.scheme == "https" }
            }
            guard let preview = url("preview_gif", "fixed_width_small"), let full = url("downsized", "original") else { return nil }
            let title = item.title?.trimmingCharacters(in: .whitespaces) ?? ""
            return WebGIF(id: item.id, title: title.isEmpty ? kind.untitled : title, preview: preview, full: full)
        }
        let pages = answer.pagination
        let next = (pages?.offset ?? offset) + (pages?.count ?? answer.data.count)
        let more = pages?.total_count.map { next < $0 } ?? (answer.data.count >= limit)
        return Page(gifs: gifs, next: more && !answer.data.isEmpty && next < most ? next : nil)
    }

    /// A page of GIPHY's GIFs or stickers for `query` (trending when empty) from `offset`, rated `rating` at most; none,
    /// and nothing asked, without a key.
    public static func search(_ query: String, key: String?, kind: Kind = .gifs, rating: Rating = .standard, offset: Int = 0,
                              http: GiphyHTTP = .live) async throws -> Page {
        guard let key else { return Page(gifs: [], next: nil) }
        let (data, status) = try await http.get(request(query, key: key, kind: kind, rating: rating, offset: offset))
        if status == 401 || status == 403 { throw Failure.refused }
        guard status == 200 else { throw Failure.status(status) }
        return try page(data, kind: kind, offset: offset)
    }

    /// Each GIF's preview bytes by id, fetched at once; one that fails is left out, so its row wears the plain glyph.
    public static func previews(_ gifs: [WebGIF], http: GiphyHTTP = .live) async -> [String: Data] {
        await withTaskGroup(of: (String, Data?).self) { group in
            for gif in gifs {
                group.addTask {
                    var request = URLRequest(url: gif.preview, timeoutInterval: 6)
                    request.setValue("image/gif", forHTTPHeaderField: "Accept")
                    guard let (data, status) = try? await http.get(request), status == 200 else { return (gif.id, nil) }
                    return (gif.id, data)
                }
            }
            var out: [String: Data] = [:]
            for await (id, data) in group { out[id] = data }
            return out
        }
    }

    /// Where picked GIFs are kept: Pilot's own folder in Application Support.
    public static var cache: URL {
        PilotFolder.support.appending(path: "GIPHY")
    }

    /// The picked GIF as a file in `folder`, downloaded unless an earlier pick kept it; the oldest beyond `cacheLimit`
    /// are removed. A sticker is a GIF too, its transparency kept in the file as GIPHY sent it.
    public static func download(_ gif: WebGIF, to folder: URL = cache, http: GiphyHTTP = .live) async throws -> URL {
        let file = folder.appending(path: "\(gif.id.filter { $0.isLetter || $0.isNumber }).gif")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let (data, status) = try await http.get(URLRequest(url: gif.full, timeoutInterval: 30))
        guard status == 200 else { throw Failure.status(status) }
        guard data.starts(with: Data("GIF8".utf8)) else { throw Failure.notGIF }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        prune(folder)
        return file
    }

    static func prune(_ folder: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys),
              files.count > cacheLimit else { return }
        func date(_ url: URL) -> Date { (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast }
        for old in files.sorted(by: { date($0) > date($1) }).dropFirst(cacheLimit) { try? FileManager.default.removeItem(at: old) }
    }

    /// The rows of GIPHY's answer for `query`: the query is their keywords, so the branch's filter keeps them all.
    public static func entries(_ gifs: [WebGIF], query: String) -> [MenuEntry] {
        gifs.map { MenuEntry(title: $0.title, target: .sticker(.giphy($0)), home: .stickers, inSearch: false, keywords: query, subtitle: "GIPHY") }
    }

    /// The one row a picker without a key shows, or one GIPHY refused; Return opens Launcher › Abilities, which holds the key
    /// under Stickers and GIFs (page map, Sven 2026-10-17).
    public static func keyRow(refused: Bool, query: String) -> MenuEntry {
        MenuEntry(title: refused ? "GIPHY refused the key: replace it" : "Add a GIPHY key to search the web",
                  target: .openPage(AppPlace(.abilities)), home: .stickers, inSearch: false, keywords: query, ownKind: .sticker,
                  subtitle: "Launcher › Abilities", icon: .glyph("key", .neutral))
    }
}
