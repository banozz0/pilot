import AppKit
import ImageIO
import Observation
import PilotCore

/// Install's one search on this Mac (N9; PilotCore's InstallSearch): brew in a child process, everything else over one
/// ephemeral URLSession, both through one cache. The network is asked only while a search runs: no polling, nothing on
/// disk, and a newer keystroke cancels the older search's requests and brew processes.
enum InstallSearcher {
    static let cache = InstallSearch.Cache()

    /// Made at the first search; no disk cache or cookies.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpMaximumConnectionsPerHost = 4
        // crates.io refuses an ask that does not say who it is from.
        c.httpAdditionalHeaders = ["User-Agent": "Pilot (dev.banozz.pilot)"]
        return URLSession(configuration: c)
    }()

    /// Every source for `text`; nil when it is too short to search (InstallSearch.Query).
    /// The sources this Mac's search asks besides the web, for the Searching row shown before the search starts.
    static var sources: [InstallSearch.Source] { InstallSearch.sources(tools: InstallSearch.tools(), brew: Homebrew.cli("brew") != nil) }

    /// Every source for `text`, each answer to `progress` as it lands; nil when it is too short to search
    /// (InstallSearch.Query).
    @concurrent static func search(_ text: String, progress: @escaping @Sendable (InstallSearch.Progress) async -> Void = { _ in })
        async -> (query: InstallSearch.Query, groups: [InstallSearch.Group])? {
        guard let query = InstallSearch.Query(text) else { return nil }
        let brew = Homebrew.cli("brew").map { cli -> InstallSearch.Brew in
            { arguments in await cache.brew(arguments) { (try? await ChildProcess.run(cli, $0, timeout: .seconds(30))) ?? "" } }
        }
        let groups = await InstallSearch.search(query, tools: InstallSearch.tools(), country: Locale.current.region?.identifier ?? "US", brew: brew,
                                                fetch: { url in await cache.fetch(url, via: fetch) }, progress: progress)
        guard !Task.isCancelled else { return nil }
        ilog.notice("""
            install search "\(query.text, privacy: .public)": \(groups.map { "\($0.source.rawValue) \($0.results.count)\($0.trouble.map { " (\($0))" } ?? "")" }.joined(separator: ", "), privacy: .public)
            """)
        return (query, groups)
    }

    /// One GET, read as InstallSearch reads an answer; no connection is offline.
    @Sendable static func fetch(_ url: URL) async -> InstallSearch.Response {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .trouble(.failed) }
            let headers = Dictionary(http.allHeaderFields.compactMap { k, v in (k as? String).map { ($0.lowercased(), "\(v)") } }) { a, _ in a }
            return InstallSearch.response(status: http.statusCode, headers: headers, data: data)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .dnsLookupFailed, .cannotFindHost]
            .contains(error.code) {
            return .trouble(.offline)
        } catch {
            return .trouble(.failed)
        }
    }

    /// A picture shrunk to `pixels` on its long side, off the main thread; nil on anything but a 200 with a picture at
    /// least 16 px, or one over half a megabyte.
    @concurrent static func picture(_ url: URL, pixels: Int = 64) async -> CGImage? {
        guard let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 512 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // The biggest of an .ico's sizes, drawn down; never drawn up.
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options), max(image.width, image.height) >= 16 else { return nil }
        return image
    }
}

/// The pictures Install's search results wear (App Store artwork, an avatar, a site's icon), fetched the first time a
/// row shows one, shrunk to 64 px off the main thread and kept for this run only, two hundred at most; a view reading
/// one redraws when it arrives. A site's apple-touch-icon that is not there falls back to its favicon.
@Observable @MainActor
final class RemoteIcons {
    static let shared = RemoteIcons()

    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    /// Off in the renders, which never reach the network.
    @ObservationIgnored var enabled = true

    /// Read in a view's body: it only asks, the picture lands later.
    func image(_ address: String) -> NSImage? {
        if let image = images[address] { return image }
        guard enabled, !asked.contains(address), let url = URL(string: address), url.scheme == "https" else { return nil }
        asked.insert(address)
        Task { await load(address, url) }
        return nil
    }

    private func load(_ address: String, _ url: URL) async {
        var tries = [url]
        if url.lastPathComponent == "apple-touch-icon.png", let host = url.host() { tries.append(URL(string: "https://\(host)/favicon.ico")!) }
        for candidate in tries {
            guard let picture = await InstallSearcher.picture(candidate) else { continue }
            if images.count >= 200 { images.removeAll(); asked = [address] }
            images[address] = NSImage(cgImage: picture, size: NSSize(width: 32, height: 32))
            return
        }
    }
}

/// The catalogues' own pictures in the app's Resources: Install's (`catalogue-icons/<id>.png`, made once by
/// Scripts/catalogue-icons.swift, C5) and the recommended web apps' (`webapp-icons/<id>.png`, Scripts/webapp-icons.swift),
/// each read once, which memory pressure may drop. An id with its own folder names a picture there, PNG, SVG or HEIC: a
/// folder design's preview, `folder-designs/kraft-preview` (P43, FolderDesign.preview).
@MainActor
enum CatalogueIcons {
    private static let read = NSCache<NSString, NSImage>()
    private static var missing: Set<String> = []

    static func image(_ id: String, in folder: String = "catalogue-icons") -> NSImage? {
        let key = id.contains("/") ? id : "\(folder)/\(id)"
        if let kept = read.object(forKey: key as NSString) { return kept }
        let (name, place) = ((key as NSString).lastPathComponent, (key as NSString).deletingLastPathComponent)
        guard !missing.contains(key),
              let image = ["png", "svg", "heic"].lazy.compactMap({ BundledJSON.url(name, $0, in: place).flatMap(NSImage.init(contentsOf:)) }).first else {
            missing.insert(key)
            return nil
        }
        read.setObject(image, forKey: key as NSString)
        return image
    }
}
