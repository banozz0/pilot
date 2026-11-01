import Foundation

/// Define's synonyms (Q597): the Free Dictionary API, `api.dictionaryapi.dev`, keyless and free. Asked only in Define,
/// once typing pauses, the newest word winning (the panel cancels the last ask); English only, since it answers 404 for
/// Spanish (probe 2026-10-30: "happy" 14 synonyms, "serendipity" 0.55 s, "/es/madrugada" 404). A word it lacks, a
/// failure or no network leaves Define with the Mac's meanings and no synonyms. No pronunciation audio is fetched.
public enum FreeDictionary {
    static let host = "https://api.dictionaryapi.dev/api/v2/entries/en/"
    /// Short: the offline meanings already show, and a slow answer is a word Sven has moved past.
    static let timeout: TimeInterval = 6

    /// One session, no cache on disk or cookies: the words looked up stay off it.
    private static let session = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.urlCache = nil
        return c
    }())

    /// The request for `word`, which names Pilot and its version.
    public static func request(for word: String, version: String) -> URLRequest? {
        guard let path = word.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))),
              let url = URL(string: host + path) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Pilot/\(version) (+https://pilot-mac.vercel.app)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The word's synonyms in the order the dictionary gives them, each once; empty for a word it lacks or any failure.
    public static func synonyms(for word: String, version: String) async -> [String] {
        guard let request = request(for: word, version: version),
              let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return synonyms(in: data, word: word)
    }

    struct Entry: Decodable {
        struct Meaning: Decodable {
            struct Definition: Decodable { let synonyms: [String]? }
            let definitions: [Definition]?
            let synonyms: [String]?
        }
        let meanings: [Meaning]?
    }

    /// Every meaning's synonyms and its definitions' in turn, the word itself and repeats left out.
    public static func synonyms(in data: Data, word: String) -> [String] {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        var seen: Set<String> = [word.lowercased()]
        return entries.flatMap { $0.meanings ?? [] }
            .flatMap { ($0.synonyms ?? []) + ($0.definitions ?? []).flatMap { $0.synonyms ?? [] } }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
