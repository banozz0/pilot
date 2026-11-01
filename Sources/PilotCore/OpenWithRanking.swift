import Foundation
import UniformTypeIdentifiers

/// Which apps Open With suggests for a file type (Sven 2026-10-30: "open with recommends random apps"). LaunchServices
/// lists every app that claims the type, `public.data`, `public.text` or any extension alike (Ghostex, Claude, Obsidian
/// and WhatsApp for a PNG), so each app is scored by its strongest claim in its Info.plist's document types: the type
/// itself or its extension over a parent type (`public.text` for Markdown), a parent over a catch-all, a claim at full
/// rank over an Alternate one, an editor over a viewer. The best-scored apps are suggested after the default and the
/// apps last picked for the type; the rest follow under Other apps, by name.
public enum OpenWithRanking {
    /// The claims that open anything, scored as no claim at all.
    static let catchAll: Set<String> = ["public.data", "public.item", "public.content", "public.composite-content"]

    /// The app's score for `type` (with its file extension `ext`): 4 per step of specificity (exact 2, parent 1,
    /// catch-all 0), 2 at full rank, 1 as an editor; nil when no document type claims it.
    public static func score(_ info: [String: Any]?, type: UTType, ext: String?) -> Int? {
        let ext = ext?.lowercased()
        var best: Int?
        for doc in info?["CFBundleDocumentTypes"] as? [[String: Any]] ?? [] {
            let rank = doc["LSHandlerRank"] as? String, role = doc["CFBundleTypeRole"] as? String
            guard rank != "None", role != "None" else { continue }
            var specific: Int?
            for id in doc["LSItemContentTypes"] as? [String] ?? [] {
                guard let claimed = UTType(id), type.conforms(to: claimed) else { continue }
                specific = max(specific ?? 0, claimed == type ? 2 : catchAll.contains(id) ? 0 : 1)
            }
            for e in doc["CFBundleTypeExtensions"] as? [String] ?? [] {
                if e.lowercased() == ext { specific = 2 } else if e == "*" { specific = max(specific ?? 0, 0) }
            }
            if (doc["CFBundleTypeOSTypes"] as? [String])?.contains("****") == true { specific = max(specific ?? 0, 0) }
            guard let specific else { continue }
            let score = specific * 4 + (rank == "Alternate" ? 0 : 2) + (role == "Editor" ? 1 : 0)
            best = max(best ?? score, score)
        }
        return best
    }

    /// `apps` (bundle ids in LaunchServices' order) split into the suggested and the rest: `first` (the default, then
    /// the apps last picked for the type) that are among them, then the best-scored tier of the scored apps that claim
    /// more than a catch-all, and the next tier too when the best holds one app, up to `most`. With no scores (a link's
    /// scheme), only `first` is suggested.
    public static func split(_ apps: [String], scores: [String: Int], first: [String], most: Int = 4) -> (suggested: [String], others: [String]) {
        var suggested: [String] = []
        for id in first where apps.contains(id) && !suggested.contains(id) { suggested.append(id) }
        let tiers = Set(scores.values.filter { $0 >= 4 }).sorted(by: >)
        let best = apps.filter { scores[$0] == tiers.first }
        let kept = Set(tiers.prefix(best.count == 1 ? 2 : 1))
        for id in apps where scores[id].map(kept.contains) == true && !suggested.contains(id) && suggested.count < most { suggested.append(id) }
        return (suggested, apps.filter { !suggested.contains($0) })
    }
}
