import Foundation

/// Trigger › Emoji as a grid (P39, Sven 2026-10-18; design launcher-ideas-2026-10-18, frames 1 to 4): ten across, the
/// emoji picked most first (two lines of them, P52), then gemoji's nine categories in its order, each a block under its heading; typed words list
/// what EmojiSearch finds as one Results block. Each cell is one of the navigator's rows, its block in `section`, so
/// Return, the pointer and the picks work as on any row; the grid only moves the selection in two dimensions.
public enum EmojiGrid {
    /// Ten across; the most used lead the grid on two lines of them (P52, Sven: "i want 2 rows of favourites/most used").
    public static let columns = 10
    public static let mostUsed = "Most used", results = "Results"

    /// gemoji's categories in its order, with how many emoji each holds.
    public static func categories(in list: [Emoji]) -> [(name: String, count: Int)] {
        var out: [(name: String, count: Int)] = []
        for e in list where !e.category.isEmpty {
            if out.last?.name == e.category { out[out.count - 1].count += 1 } else { out.append((e.category, 1)) }
        }
        return out
    }

    /// The emoji picked most, the newest pick breaking a tie, at most two lines of them; only ones the list holds. A
    /// count is the picks the frecency store keeps (at most 20), so until 20 were picked more than once the recent fill it.
    public static func mostUsed(in list: [Emoji], picks: Frecency) -> [Emoji] {
        let byGlyph = Dictionary(list.map { ($0.emoji, $0) }, uniquingKeysWith: { first, _ in first })
        return picks.picks.compactMap { key, dates -> (Emoji, Int, Date)? in
            guard key.hasPrefix("emoji:"), let e = byGlyph[String(key.dropFirst(6))], let last = dates.max() else { return nil }
            return (e, dates.count, last)
        }
        .sorted { ($0.1, $0.2) > ($1.1, $1.2) }.prefix(2 * columns).map(\.0)
    }

    /// The grid's rows. Nothing typed: the most used, then every category, or only `category` once one is picked
    /// (Most used is one too). Typed: what EmojiSearch finds, under Results, in the picked category alone.
    public static func entries(for query: String, in list: [Emoji], picks: Frecency, category: String? = nil) -> [MenuEntry] {
        func rows(_ emoji: [Emoji], _ section: String) -> [MenuEntry] {
            emoji.map { e in
                var row = EmojiSearch.entry(e, home: .emoji)
                row.section = section
                return row
            }
        }
        // One letter keeps the grid whole, as EmojiSearch finds nothing under two.
        let searching = query.trimmingCharacters(in: .whitespaces).count >= MenuNavigator.minimumQuery
        if category == mostUsed {
            let most = Self.mostUsed(in: list, picks: picks)
            return searching ? rows(EmojiSearch.matches(for: query, in: most), results) : rows(most, mostUsed)
        }
        let pool = category.map { c in list.filter { $0.category == c } } ?? list
        if searching { return rows(EmojiSearch.matches(for: query, in: pool), results) }
        let byCategory = Dictionary(grouping: pool, by: \.category)
        return rows(category == nil ? Self.mostUsed(in: list, picks: picks) : [], mostUsed)
            + categories(in: pool).flatMap { c in rows(byCategory[c.name] ?? [], c.name) }
    }

    /// The blocks of `sections` (each row's), as runs of rows that share one.
    public static func blocks(_ sections: [String?]) -> [Range<Int>] {
        var out: [Range<Int>] = [], start = 0
        for i in sections.indices.dropFirst() where sections[i] != sections[i - 1] {
            out.append(start..<i)
            start = i
        }
        if !sections.isEmpty { out.append(start..<sections.count) }
        return out
    }

    /// How many lines `blocks` fill.
    public static func lines(_ blocks: [Range<Int>]) -> Int { blocks.reduce(0) { $0 + ($1.count + columns - 1) / columns } }

    /// Where an arrow takes the selection from `index`: ← and → one cell, across blocks; ↑ and ↓ a line, to the same
    /// column, from a block's last line to the next block's first and back (a shorter line: its last cell). Nil when there
    /// is nowhere to go, or for any other key.
    public static func move(from index: Int, _ key: MenuNavigator.Key, sections: [String?]) -> Int? {
        let blocks = blocks(sections)
        guard let b = blocks.firstIndex(where: { $0.contains(index) }) else { return nil }
        let block = blocks[b], offset = index - block.lowerBound, line = offset / columns, column = offset % columns
        /// The cell at `column` on `line` of `block`, or its last cell when that line is shorter.
        func cell(_ block: Range<Int>, line: Int) -> Int { min(block.lowerBound + line * columns + column, block.upperBound - 1) }
        switch key {
        case .left: return index > 0 ? index - 1 : nil
        case .right: return index + 1 < sections.count ? index + 1 : nil
        case .down:
            if (line + 1) * columns < block.count { return cell(block, line: line + 1) }
            return b + 1 < blocks.count ? cell(blocks[b + 1], line: 0) : nil
        case .up:
            if line > 0 { return cell(block, line: line - 1) }
            guard b > 0 else { return nil }
            let above = blocks[b - 1]
            return cell(above, line: (above.count - 1) / columns)
        default: return nil
        }
    }
}
