import Foundation

/// The pill-first top bar (Sven's Q160 to Q165, 2026-11-12, a test on branch pill-first): a slim bar, Pilot and the
/// workspaces on the left, the pill in the centre, the status lights and the clock on the right, the readings living as
/// the pill's pages. A preset drawn over the saved bar, never written into it: switching back gives the bar back as it
/// was. Saved under its own key (`key`), which a Pilot without it never reads.
public enum PillFirst {
    /// The defaults key the bar store keeps it under.
    public static let key = "pill.first"

    /// What a page shows.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case media, calendar, stats, controls, activity, extensions

        public var title: String {
            switch self {
            case .media: "Media"
            case .calendar: "Calendar"
            case .stats: "Stats"
            case .controls: "Controls"
            case .activity: "Activity"
            case .extensions: "Extensions"
            }
        }
    }

    /// One of the pill's pages: a kind, and for an extensions page its name and up to `most` extensions (Q163).
    public struct Page: Codable, Equatable, Sendable {
        public var kind: Kind
        public var title: String
        /// The extensions whose bar items an extensions page shows, in order; empty on the other kinds.
        public var extensions: [String]

        public static let most = 3

        public init(_ kind: Kind, title: String? = nil, extensions: [String] = []) {
            self.kind = kind
            self.title = kind == .extensions ? title ?? kind.title : kind.title
            self.extensions = kind == .extensions ? Array(extensions.prefix(Self.most)) : []
        }

        /// Read leniently: an unknown kind fails this page alone (Settings drops it), a missing title takes the kind's,
        /// extensions past `most` are cut.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(Kind.self, forKey: .kind)
            self.init(kind, title: try? c.decode(String.self, forKey: .title), extensions: (try? c.decode([String].self, forKey: .extensions)) ?? [])
        }

        /// Q162's four, then one Extensions page (Q163).
        public static let standard: [Page] = [.init(.media), .init(.calendar), .init(.stats), .init(.controls), .init(.extensions)]
    }

    public struct Settings: Codable, Equatable, Sendable {
        /// The preset is on: the top bar draws `sides`, the pill these pages.
        public var on: Bool
        public var pages: [Page]
        /// The page the pill shows, by place; `current` keeps it in range.
        public var selected: Int

        public static let standard = Settings(on: false, pages: Page.standard, selected: 0)

        public init(on: Bool, pages: [Page], selected: Int) {
            self.on = on; self.pages = pages; self.selected = selected
        }

        /// Read leniently, so an older or newer file still opens: a page this Pilot cannot read is dropped, no page left
        /// gives the standard ones, a missing field takes the standard's.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            on = (try? c.decode(Bool.self, forKey: .on)) ?? false
            let read = ((try? c.decode([Lossy<Page>].self, forKey: .pages)) ?? []).compactMap(\.value)
            pages = read.isEmpty ? Page.standard : read
            selected = (try? c.decode(Int.self, forKey: .selected)) ?? 0
        }

        /// The page showing, in range.
        public var current: Int { min(max(selected, 0), pages.count - 1) }
    }

    /// The pages as `pill.pages` writes them: kinds by name, an extensions page as `Title=id+id+id` (`Title=` with none).
    public static func words(_ pages: [Page]) -> String {
        pages.map { $0.kind == .extensions ? "\($0.title)=\($0.extensions.joined(separator: "+"))" : $0.kind.rawValue }.joined(separator: ",")
    }

    /// `words`' pages: `extensions` alone is an empty page named Extensions. Refuses no page, an unknown word, a kind
    /// named twice (extensions pages excepted), two extensions pages of one name, an extension twice on a page or more
    /// than `Page.most` on one.
    public static func pages(_ typed: String) throws(ControlError) -> [Page] {
        var pages: [Page] = []
        for word in typed.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !word.isEmpty {
            let page: Page
            if let equals = word.firstIndex(of: "=") {
                let title = word[..<equals].trimmingCharacters(in: .whitespaces)
                let ids = word[word.index(after: equals)...].split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !title.isEmpty else { throw ControlError(.badValue, "an extensions page needs a name before =, as Dev=github+ci") }
                guard ids.count <= Page.most else { throw ControlError(.badValue, "\(title) holds \(ids.count) extensions; a page holds up to \(Page.most)") }
                guard Set(ids).count == ids.count else { throw ControlError(.badValue, "\(title) names an extension twice") }
                page = Page(.extensions, title: title, extensions: ids)
            } else if let kind = Kind(rawValue: word.lowercased()) {
                page = Page(kind)
            } else {
                throw ControlError(.badValue, "no page \(word); the pages are \(Kind.allCases.map(\.rawValue).joined(separator: ",")), or Name=id+id+id")
            }
            if page.kind == .extensions {
                guard !pages.contains(where: { $0.kind == .extensions && $0.title == page.title }) else { throw ControlError(.badValue, "two extensions pages are named \(page.title)") }
            } else if pages.contains(where: { $0.kind == page.kind }) {
                throw ControlError(.badValue, "\(page.kind.rawValue) is named twice")
            }
            pages.append(page)
        }
        guard !pages.isEmpty else { throw ControlError(.badValue, "the pill needs one page at least") }
        return pages
    }

    /// The bar the preset draws, from the saved bar's own entries so each keeps its style: Pilot and the workspaces left,
    /// the pill centred, the status lights and the clock right. Other apps' items stay, left of the lights, while the
    /// saved top bar shows them: they are other apps' menus, not readings a page could hold.
    public static func sides(_ settings: BarSettings) -> [TopBarSide: [BarSlot]] {
        func slot(_ kind: BarKind) -> BarSlot {
            var entry = settings.entry(kind)
            entry.on = true
            return .item(entry)
        }
        let saved = settings.preview(.topBar).top ?? [:]
        let otherApps = saved.values.joined().contains { $0.kinds.contains(.otherApps) }
        return [.left: [slot(.pilot), slot(.workspaces)], .centre: [slot(.pill)],
                .right: (otherApps ? [slot(.otherApps)] : []) + [slot(.modes), slot(.clock)]]
    }
}
