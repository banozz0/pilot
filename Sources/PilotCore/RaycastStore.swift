import Foundation

/// Raycast's store as Pilot reads it (raycast-extensions T24; Sven, 2026-11-20, Q279 "github"): the folders under
/// github.com/raycast/extensions/extensions, never Raycast's own service. The list is one unauthenticated GitHub tree
/// listing of that folder, not recursive, refused when GitHub says it is truncated, and kept on disk a day. A folder's
/// `package.json` (its title, description, author and icon) is fetched from raw.githubusercontent.com only when that
/// folder is picked, and kept beside the list under the folder's git tree hash, so a folder changed upstream is read
/// again and an unchanged one never is. Nothing about the user is sent: no token, no cookie, no query. An install goes
/// through ADR 0017's GitHub route (T6), `github:raycast/extensions/extensions/<folder>`.
///
/// Every remote word is held here before anything shows it: a folder name to letters, digits, `.`, `_` and `-` (a name
/// that is not is dropped, never shown), the title cut to 80 Unicode scalars, the description to 300 and the author to
/// 64, each with its breaks folded to spaces and every control or hidden scalar written out (ControlGate.Ask.visible).
public enum RaycastStore {
    public static let repo = "raycast/extensions", root = "extensions"
    /// The one listing: the tree of `extensions/` at HEAD, its folders and files, not their insides.
    public static let listingURL = URL(string: "https://api.github.com/repos/\(repo)/git/trees/HEAD:\(root)")!
    /// How long a listing is kept before the next open reads it again.
    public static let fresh: TimeInterval = 86_400
    /// The most each read may take: the listing (about 3,600 folders), a manifest, an icon.
    static let listingLimit = 8 << 20, manifestLimit = 256 << 10, iconLimit = 1 << 20

    public static func manifestURL(_ folder: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(repo)/HEAD/\(root)/\(folder)/package.json")!
    }

    public static func iconURL(_ folder: String, _ icon: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(repo)/HEAD/\(root)/\(folder)/assets/\(icon)")!
    }

    /// The folder on GitHub, for Open on GitHub.
    public static func pageURL(_ folder: String) -> URL { URL(string: "https://github.com/\(repo)/tree/main/\(root)/\(folder)")! }

    /// What `pilot ext install` and the store's Install take: T6's route.
    public static func spec(_ folder: String) -> String { "github:\(repo)/\(root)/\(folder)" }

    /// One folder the listing names: its name and its git tree hash.
    public struct Folder: Codable, Equatable, Hashable, Sendable {
        public let name: String, sha: String
        public init(name: String, sha: String) { self.name = name; self.sha = sha }
    }

    /// The folders, A to Z as GitHub lists them, and when they were read.
    public struct Listing: Codable, Equatable, Sendable {
        public let fetched: Date
        public let folders: [Folder]
        /// How many entries the answer held that are not shown: files, links, and folders whose name breaks the rule.
        public let dropped: Int

        public func folder(_ name: String) -> Folder? { folders.first { $0.name == name } }
    }

    /// What a folder's package.json says, held to the rules above.
    public struct Info: Codable, Equatable, Sendable {
        /// The tree hash it was read at; a listing with another one reads it again.
        public let sha: String
        /// Raycast's `name`, the id an install takes (Extension.isName), nil when it breaks that rule.
        public let name: String?
        public let title: String, description: String
        public let author: String?
        /// The icon's file name in the folder's `assets/`, a bare name ending .png, .jpg or .jpeg; nil otherwise.
        public let icon: String?
        public let commands: Int
    }

    public enum Problem: Error, Equatable, Sendable {
        /// GitHub cut the listing short, so it is not the whole store.
        case truncated
        /// GitHub's hourly limit for unauthenticated calls (60) is spent.
        case rateLimited
        case unreachable(String)
        case unreadable(String)

        public var reason: String {
            switch self {
            case .truncated: "GitHub's listing of raycast/extensions came back truncated, so it was not used"
            case .rateLimited: "GitHub's hourly limit of 60 listings without an account is spent; try again within the hour"
            case .unreachable(let why): "GitHub could not be reached: \(why)"
            case .unreadable(let why): "GitHub's answer could not be read: \(why)"
            }
        }
    }

    // MARK: Reading GitHub's answers

    /// A folder name the store shows and puts in a URL.
    public static func isFolder(_ name: String) -> Bool {
        name.count <= 100 && !name.contains("..") && name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]*/) != nil
    }

    private struct Tree: Decodable {
        struct Entry: Decodable { let path: String, type: String, sha: String }
        let tree: [Entry]
        let truncated: Bool?
    }

    /// The listing from GitHub's tree answer: refused when truncated; only folders (`tree`) kept, each held to the rule.
    public static func listing(_ data: Data, at date: Date) throws(Problem) -> Listing {
        let tree: Tree
        do { tree = try JSONDecoder().decode(Tree.self, from: data) } catch { throw .unreadable("not a git tree") }
        guard tree.truncated != true else { throw .truncated }
        let folders = tree.tree.filter { $0.type == "tree" && isFolder($0.path) && $0.sha.wholeMatch(of: /[0-9a-f]{40}/) != nil }
            .map { Folder(name: $0.path, sha: $0.sha) }
        return Listing(fetched: date, folders: folders, dropped: tree.tree.count - folders.count)
    }

    private struct Manifest: Decodable {
        let name: String?, title: String?, description: String?, icon: String?, commands: [JSONValue]?
        let author: JSONValue?
    }

    /// A folder's package.json, held to the rules; its title falls back on the folder's name.
    public static func info(_ data: Data, folder: Folder) throws(Problem) -> Info {
        let m: Manifest
        do { m = try JSONDecoder().decode(Manifest.self, from: data) } catch { throw .unreadable("\(folder.name)'s package.json") }
        let author: String? = switch m.author {
        case .string(let s): s
        case .object(let o): if case .string(let s)? = o["name"] { s } else { nil }
        default: nil
        }
        let name = m.name.flatMap { Extension.isName($0) ? $0 : nil }
        let icon = m.icon.flatMap { $0.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._@-]*\.(png|jpg|jpeg)/.ignoresCase()) == nil || $0.contains("..") ? nil : $0 }
        return Info(sha: folder.sha, name: name, title: shown(m.title, 80) ?? folder.name, description: shown(m.description, 300) ?? "",
                    author: shown(author, 64), icon: icon, commands: m.commands?.count ?? 0)
    }

    /// Remote text as the store shows it: breaks and runs of space folded to one space, cut to `most` Unicode scalars,
    /// every control or hidden scalar written out; nil when nothing is left.
    static func shown(_ text: String?, _ most: Int) -> String? {
        guard let folded = text?.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " "), !folded.isEmpty else { return nil }
        return ControlGate.Ask.visible(String(String.UnicodeScalarView(folded.unicodeScalars.prefix(most))))
    }

    /// Whether `folder` (with what its package.json said, once read) matches every word typed, in its name, title,
    /// description or author, ignoring case and accents.
    public static func matches(_ folder: Folder, _ info: Info?, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = [folder.name, info?.title, info?.description, info?.author].compactMap { $0 }.joined(separator: " ")
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    // MARK: Fetching and keeping

    /// One GET: the URL and the most bytes it may answer.
    public typealias Fetch = @Sendable (URL, Int) async throws(Problem) -> Data

    /// Where the store keeps its reads, and how it fetches: GitHub itself, or a sandbox's folder.
    /// What typed words and a folder are compared on: letters and digits alone, case and accents folded, so "killprocess"
    /// and "kill process" both find kill-process.
    public static func compact(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Hyper+Space's root search's store rows (raycast-extensions T25), from the listing already held, never GitHub: at
    /// most `most` folders `installed` does not take whose name, or title once read, holds what was typed, those that
    /// start with it first, then A to Z. Each is its title once read (its folder's name until then), "Raycast Store"
    /// beside it, its icon once fetched; Return opens the store on it. `compacted` holds each folder's name already
    /// compared form, made once per listing, so a keystroke folds only what was typed and the titles read.
    public static func rootRows(_ query: String, listing: Listing?, infos: [String: Info], icons: [String: String],
                                compacted: [String: String] = [:], installed: (String) -> Bool, most: Int = 3) -> [MenuEntry] {
        let typed = compact(query)
        guard typed.count >= 2, let listing else { return [] }
        let found = listing.folders.compactMap { folder -> (Bool, String)? in
            let name = compacted[folder.name] ?? compact(folder.name), title = infos[folder.name].map { compact($0.title) } ?? ""
            guard name.contains(typed) || title.contains(typed), !installed(folder.name) else { return nil }
            return (name.hasPrefix(typed) || title.hasPrefix(typed), folder.name)
        }
        return found.sorted { ($0.0 ? 0 : 1, $0.1) < ($1.0 ? 0 : 1, $1.1) }.prefix(most).map { _, name in
            var icon = MenuIcon.glyph("puzzlepiece.extension", .accent)
            icon.file = icons[name]
            let title = infos[name]?.title ?? name
            return MenuEntry(title: title, target: .storeFolder(name), detail: "Return opens it in Raycast's store",
                             keywords: "\(name) \(compact(name)) \(compact(title))", subtitle: "Raycast Store", icon: icon)
        }
    }

    public struct Source: Sendable {
        public let cache: URL
        public let fetch: Fetch

        public init(cache: URL, fetch: @escaping Fetch) { self.cache = cache; self.fetch = fetch }

        /// Pilot's caches, a test run's own folder.
        public static let cacheFolder = isIsolatedTestRun ? PilotFolder.support.appending(path: "Caches/RaycastStore", directoryHint: .isDirectory)
            : URL.cachesDirectory.appending(path: "dev.banozz.pilot/RaycastStore", directoryHint: .isDirectory)

        public static let live = Source(cache: cacheFolder, fetch: RaycastStore.get)

        /// A sandbox's stand-in for GitHub (PILOT_SANDBOX_RAYCAST_STORE=<folder>): the listing is `<folder>/tree.json`, a
        /// folder's manifest `<folder>/<name>/package.json` and its icon `<folder>/<name>/assets/<icon>`; a missing file
        /// answers as a 404 would, and each read is a line in `<folder>/reads.log`. Only the store's reads; an install
        /// still goes to GitHub.
        public static func standIn(_ folder: URL, cache: URL = cacheFolder) -> Source {
            Source(cache: cache) { url, limit throws(Problem) in
                let path: String
                if url == listingURL { path = "tree.json" } else {
                    let prefix = "/\(repo)/HEAD/\(root)/"
                    guard url.host() == "raw.githubusercontent.com", url.path().hasPrefix(prefix) else { throw .unreachable("not a store URL") }
                    path = String(url.path().dropFirst(prefix.count))
                }
                let log = folder.appending(path: "reads.log")
                if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
                if let handle = try? FileHandle(forWritingTo: log) {
                    handle.seekToEndOfFile()
                    handle.write(Data("GET \(url.absoluteString)\n".utf8))
                    try? handle.close()
                }
                guard let data = FileManager.default.contents(atPath: folder.appending(path: path).path) else {
                    throw .unreachable("\(url.host() ?? "") answered 404 for \(url.path())")
                }
                guard data.count <= limit else { throw .unreadable("\(url.path()) runs past \(limit) bytes") }
                return data
            }
        }

        var listingFile: JSONFile<Listing?> { JSONFile(url: cache.appending(path: "listing.json")) }
        var infoFolder: URL { cache.appending(path: "info", directoryHint: .isDirectory) }
        func infoFile(_ folder: String) -> JSONFile<Info?> { JSONFile(url: infoFolder.appending(path: "\(folder).json")) }
        func iconFile(_ folder: String, _ info: Info) -> URL? {
            info.icon.map { cache.appending(path: "icons/\(folder)-\(info.sha.prefix(12)).\(($0 as NSString).pathExtension.lowercased())") }
        }

        /// A folder's info as the store keeps it: what its package.json said, and its icon's path once fetched.
        public typealias Read = (info: Info, icon: String?)

        /// The kept listing, fresh or not; nil when none is kept or it does not read.
        public func kept() -> Listing? { (try? listingFile.load(or: nil)) ?? nil }

        /// Every kept info whose folder `listing` still has at the same tree hash: the info folder listed once, then only the
        /// files in it read.
        public func keptInfos(_ listing: Listing) -> [String: Read] {
            let sha = Dictionary(listing.folders.map { ($0.name, $0.sha) }) { a, _ in a }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: infoFolder.path)) ?? []).filter { $0.hasSuffix(".json") }
            return Dictionary(names.compactMap { file -> (String, Read)? in
                let name = String(file.dropLast(5))
                guard let want = sha[name], let info = (try? infoFile(name).load(or: nil)) ?? nil, info.sha == want else { return nil }
                return (name, (info, iconPath(name, info)))
            }) { a, _ in a }
        }

        /// The listing read from GitHub now and kept.
        public func read(at date: Date = .now) async throws(Problem) -> Listing {
            let listing = try RaycastStore.listing(try await fetch(listingURL, listingLimit), at: date)
            try? listingFile.save(listing)
            return listing
        }

        /// The folder's package.json read and kept, then its icon fetched once into the cache; an icon that will not
        /// come is left out, never a failure.
        public func readInfo(_ folder: Folder) async throws(Problem) -> Read {
            let info = try RaycastStore.info(try await fetch(manifestURL(folder.name), manifestLimit), folder: folder)
            try? infoFile(folder.name).save(info)
            if let icon = info.icon, let file = iconFile(folder.name, info), !FileManager.default.fileExists(atPath: file.path),
               let data = try? await fetch(iconURL(folder.name, icon), iconLimit) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            return (info, iconPath(folder.name, info))
        }

        private func iconPath(_ folder: String, _ info: Info) -> String? {
            iconFile(folder, info).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil }
        }
    }

    /// A session with nothing of the user's: no cookies, no cache, no credentials.
    private static let session = URLSession(configuration: .ephemeral)

    /// One GET to GitHub with no token: Pilot's name as the agent GitHub asks for, a 403 or 429 with no calls left read as
    /// the hourly limit, any status but 200 refused, and a body past `limit` refused.
    @Sendable static func get(_ url: URL, limit: Int) async throws(Problem) -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Pilot", forHTTPHeaderField: "User-Agent")
        if url.host() == "api.github.com" { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw .unreachable(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if [403, 429].contains(status), (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" { throw .rateLimited }
        guard status == 200 else { throw .unreachable("\(url.host() ?? "") answered \(status) for \(url.path())") }
        guard data.count <= limit else { throw .unreadable("\(url.path()) is \(data.count) bytes, past \(limit)") }
        return data
    }
}
