import Foundation

/// The list a chip in the menu's line opens over the menu (launcher ideas, 2026-10-18): Emoji's categories on ⌘P (P39),
/// Translate's From and To languages on Return (P40). Its rows under their headings, the one in force checked, one
/// selected; a language list also filters by what is typed into it. The panel feeds it the keys while it is open.
public struct ChipMenu: Equatable, Sendable {
    public enum Purpose: Equatable, Sendable { case emojiCategory, translateFrom, translateTo }

    public struct Row: Equatable, Sendable {
        /// What a pick hands back: a category's name, a language's code, "" for All categories or Auto.
        public let value: String, title: String
        /// Muted at the right: a count, a language's code.
        public let detail: String?
        /// The heading over the rows that share it ("On this Mac"); nil runs under none.
        public let section: String?
        public let checked: Bool
        /// A rule under the row (under All categories and Most used).
        public let ruleAfter: Bool

        public init(value: String, title: String, detail: String? = nil, section: String? = nil, checked: Bool = false, ruleAfter: Bool = false) {
            self.value = value; self.title = title; self.detail = detail; self.section = section; self.checked = checked
            self.ruleAfter = ruleAfter
        }
    }

    public let purpose: Purpose
    /// Whether typing filters it: the languages, not the nine categories.
    public let filters: Bool
    private let all: [Row]
    public var query = "" {
        didSet {
            visible = query.isEmpty ? all : all.filter { FuzzyRanker.score(query, in: "\($0.title) \($0.value)") != nil }
            selection = 0
        }
    }
    public private(set) var visible: [Row]
    public private(set) var selection: Int

    /// Opens on the checked row.
    public init(_ purpose: Purpose, rows: [Row], filters: Bool = false) {
        self.purpose = purpose
        self.filters = filters
        all = rows
        visible = rows
        selection = rows.firstIndex(where: \.checked) ?? 0
    }

    public var selected: Row? { visible.indices.contains(selection) ? visible[selection] : nil }

    /// Whether visible row `index` heads a section: the first under a heading other than the row's before.
    public func startsSection(_ index: Int) -> Bool {
        visible[index].section != nil && (index == 0 || visible[index - 1].section != visible[index].section)
    }

    public mutating func move(_ by: Int) { selection = min(max(selection + by, 0), max(visible.count - 1, 0)) }
    public mutating func select(_ index: Int) { if visible.indices.contains(index) { selection = index } }

    /// Emoji's categories: All, Most used, then gemoji's nine with their counts, the one in force checked.
    public static func emojiCategories(_ categories: [(name: String, count: Int)], mostUsed: Int, picked: String?) -> ChipMenu {
        let rows = [Row(value: "", title: "All categories", checked: picked == nil),
                    Row(value: EmojiGrid.mostUsed, title: EmojiGrid.mostUsed, detail: "\(mostUsed)", checked: picked == EmojiGrid.mostUsed, ruleAfter: true)]
            + categories.map { Row(value: $0.name, title: $0.name, detail: "\($0.count)", checked: picked == $0.name) }
        return ChipMenu(.emojiCategory, rows: rows)
    }
}
