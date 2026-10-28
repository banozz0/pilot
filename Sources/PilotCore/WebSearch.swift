import Foundation

/// Search the web for what was typed in Hyper+Space (Sven 2026-10-16): in the default browser, with that browser's own
/// default search engine, read from its settings. Safari's engine is Safari's to pick (its `x-web-search:` link); a
/// Chromium browser keeps its engine as a template in its profile's Preferences; a Firefox one in its profile's
/// search.json (mozlz4, which the app decompresses before this reads it). Anything unread searches Google, as Install's
/// web search does. Pure: the app reads the files (WebSearchReader).
public enum WebSearch {
    /// A search engine: its name for the row, and its address with `{query}` where the words go.
    public struct Engine: Equatable, Sendable {
        public let name: String
        public let template: String

        public init(name: String, template: String) {
            self.name = name
            self.template = template
        }

        /// The address for `query`: its words percent-encoded in place of `{query}`; nil when that is no link.
        public func url(for query: String) -> URL? {
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?/"))
            let words = query.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            guard let url = URL(string: template.replacingOccurrences(of: WebSearch.placeholder, with: words)), url.scheme != nil else { return nil }
            return url
        }
    }

    public static let placeholder = "{query}"

    public static let google = Engine(name: "Google", template: "https://www.google.com/search?q={query}")
    /// Safari searches with the engine Safari's settings pick.
    public static let safari = Engine(name: "Safari's search engine", template: "x-web-search://?{query}")

    /// Firefox's own engines carry no address in search.json; these are theirs, by id or name.
    static let builtIn: [(match: String, engine: Engine)] = [
        ("google", google),
        ("ddg", Engine(name: "DuckDuckGo", template: "https://duckduckgo.com/?q={query}")),
        ("duckduckgo", Engine(name: "DuckDuckGo", template: "https://duckduckgo.com/?q={query}")),
        ("bing", Engine(name: "Bing", template: "https://www.bing.com/search?q={query}")),
        ("ecosia", Engine(name: "Ecosia", template: "https://www.ecosia.org/search?q={query}")),
        ("qwant", Engine(name: "Qwant", template: "https://www.qwant.com/?q={query}")),
        ("startpage", Engine(name: "Startpage", template: "https://www.startpage.com/sp/search?query={query}")),
        ("perplexity", Engine(name: "Perplexity", template: "https://www.perplexity.ai/search?q={query}")),
        ("brave", Engine(name: "Brave Search", template: "https://search.brave.com/search?q={query}")),
        ("wikipedia", Engine(name: "Wikipedia", template: "https://en.wikipedia.org/w/index.php?search={query}")),
    ]

    /// A browser's family, by bundle id: where its settings live and how its engine is read.
    public enum Family: Equatable, Sendable {
        case safari
        /// A Chromium browser, its profiles under Application Support/`folder`; `standard` is its engine before Sven
        /// picks one.
        case chromium(folder: String, standard: Engine)
        /// A Firefox browser, its profiles under Application Support/`folder`.
        case firefox(folder: String)
        case other
    }

    public static func family(bundleID: String) -> Family {
        let bing = Engine(name: "Bing", template: "https://www.bing.com/search?q={query}")
        let brave = Engine(name: "Brave Search", template: "https://search.brave.com/search?q={query}")
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview": return .safari
        case "com.google.Chrome": return .chromium(folder: "Google/Chrome", standard: google)
        case "com.google.Chrome.beta": return .chromium(folder: "Google/Chrome Beta", standard: google)
        case "com.google.Chrome.canary": return .chromium(folder: "Google/Chrome Canary", standard: google)
        case "org.chromium.Chromium": return .chromium(folder: "Chromium", standard: google)
        case "com.brave.Browser": return .chromium(folder: "BraveSoftware/Brave-Browser", standard: brave)
        case "com.microsoft.edgemac": return .chromium(folder: "Microsoft Edge", standard: bing)
        case "com.vivaldi.Vivaldi": return .chromium(folder: "Vivaldi", standard: google)
        case "company.thebrowser.Browser": return .chromium(folder: "Arc/User Data", standard: google)
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly": return .firefox(folder: "Firefox")
        case "app.zen-browser.zen": return .firefox(folder: "zen")
        case "org.mozilla.librewolf", "io.gitlab.librewolf-community": return .firefox(folder: "librewolf")
        case "one.ablaze.floorp": return .firefox(folder: "Floorp")
        case "net.waterfox.waterfox": return .firefox(folder: "Waterfox")
        default: return .other
        }
    }

    // MARK: Chromium

    /// The profile Chromium opened last, from its Local State; "Default" when none is named.
    public static func chromiumProfile(localState: Data?) -> String {
        guard let localState, let json = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
              let profile = json["profile"] as? [String: Any], let last = profile["last_used"] as? String, !last.isEmpty else { return "Default" }
        return last
    }

    /// The engine a Chromium profile's Preferences name: its template's address made plain; nil when none is saved.
    public static func chromium(preferences: Data) -> Engine? {
        guard let json = try? JSONSerialization.jsonObject(with: preferences) as? [String: Any],
              let data = json["default_search_provider_data"] as? [String: Any] else { return nil }
        let template = (data["template_url_data"] as? [String: Any]) ?? (data["mirrored_template_url_data"] as? [String: Any])
        guard let template, let raw = template["url"] as? String, raw.contains("{searchTerms}") else { return nil }
        let name = (template["short_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "your search engine"
        return Engine(name: name, template: chromiumTemplate(raw))
    }

    /// A Chromium template as a plain address: `{searchTerms}` the words, `{google:baseURL}` Google's, every other
    /// `{…}` of Chrome's own dropped with the `&` it leaves.
    public static func chromiumTemplate(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "{searchTerms}", with: placeholder)
            .replacingOccurrences(of: "{google:baseURL}", with: "https://www.google.com/")
            .replacing(/\{(?!query\})[^}]*\}/, with: "")
        while text.contains("&&") { text = text.replacingOccurrences(of: "&&", with: "&") }
        text = text.replacingOccurrences(of: "?&", with: "?")
        while text.hasSuffix("&") || text.hasSuffix("?") { text.removeLast() }
        return text
    }

    // MARK: Firefox

    /// The profile folder a Firefox browser's installs.ini or profiles.ini names as the default, relative to its folder.
    public static func firefoxProfile(installs: String?, profiles: String?) -> String? {
        if let installs, let path = ini(installs).lazy.compactMap({ $0["Default"] }).first { return path }
        guard let profiles else { return nil }
        let sections = ini(profiles)
        let chosen = sections.first { $0["Default"] == "1" && $0["Path"] != nil } ?? sections.first { $0["Path"] != nil }
        return chosen?["Path"]
    }

    /// An ini file's sections, each its keys and values.
    static func ini(_ text: String) -> [[String: String]] {
        var sections: [[String: String]] = []
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") { sections.append([:]); continue }
            guard !sections.isEmpty, let eq = line.firstIndex(of: "=") else { continue }
            sections[sections.count - 1][String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return sections
    }

    /// The engine a decompressed search.json picks as the default: one Sven added with its own address, or one of
    /// Firefox's own by its id or name; with none picked, the browser's own (`appDefaultEngineId`, Zen's); nil when it
    /// names none at all.
    public static func firefox(searchJSON: Data) -> Engine? {
        guard let json = try? JSONSerialization.jsonObject(with: searchJSON) as? [String: Any] else { return nil }
        let meta = json["metaData"] as? [String: Any] ?? [:]
        let named = [meta["defaultEngineId"], meta["current"], meta["appDefaultEngineId"]].compactMap { $0 as? String }
        guard let chosen = named.first(where: { !$0.isEmpty }) else { return nil }
        let engines = json["engines"] as? [[String: Any]] ?? []
        let engine = engines.first { ($0["id"] as? String) == chosen || ($0["_name"] as? String) == chosen }
        let name = engine?["_name"] as? String ?? chosen
        if let urls = engine?["_urls"] as? [[String: Any]],
           let page = urls.first(where: { ($0["type"] as? String ?? "text/html") == "text/html" && ($0["rels"] as? [String] ?? []).isEmpty })
            ?? urls.first(where: { ($0["type"] as? String ?? "text/html") == "text/html" }),
           let template = page["template"] as? String {
            var address = template.replacingOccurrences(of: "{searchTerms}", with: placeholder)
            let params = (page["params"] as? [[String: Any]] ?? []).compactMap { p -> String? in
                guard let key = p["name"] as? String, let value = p["value"] as? String else { return nil }
                return "\(key)=\(value.replacingOccurrences(of: "{searchTerms}", with: placeholder))"
            }
            if !params.isEmpty { address += (address.contains("?") ? "&" : "?") + params.joined(separator: "&") }
            if address.contains(placeholder) { return Engine(name: name, template: address) }
        }
        let key = (chosen + " " + name).lowercased()
        return builtIn.first { key.contains($0.match) }?.engine
    }
}
