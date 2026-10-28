import Foundation

/// The Hyper+Space root as Sven arranged it (story 152, task N6): his order of the root's branches and the ones hidden
/// from the list before typing. A hidden branch still answers a root search by its name. Kept by branch id
/// (`MenuBranch.rawValue`), so a saved id no branch has any more is ignored, and a branch the saved order never named
/// (one added in a later build) stands where it stands by default, shown. Empty is today's root.
/// The extra rows Sven switched on (`extras`, Sven 2026-10-20) are off by default and stand after the branches until moved:
/// `order` holds them as `extra:<id>` among the branch ids, so they move like branches. The Hyper+Space root lists them,
/// and the Ring menu's Pilot ring reads the same `shownExtras()`, in his order.
public struct MenuRoot: Equatable, Sendable {
    public var order: [String]
    public var hidden: Set<String>
    /// The ids of the `Extra`s switched on; an id no extra has is ignored.
    public var extras: Set<String>

    public init(order: [String] = [], hidden: Set<String> = [], extras: Set<String> = []) {
        self.order = order
        self.hidden = hidden
        self.extras = extras
    }

    /// A row the root can list among its branches, off until switched on (Sven 2026-10-20): a branch that lives deeper
    /// (Trigger › Notes), which opens where it lives, or Config, which only this row lists; an action with no branch of
    /// its own (Dictation), which runs; a screen of its own in the menu (Activity, Stats), or the Files view.
    public struct Extra: Identifiable, Equatable, Sendable {
        public let id: String, title: String, symbol: String, target: MenuEntry.Target
    }

    /// Every extra, in the order the root lists them by default, after System. Config was a root branch until Sven
    /// 2026-10-21; its branch lives nowhere else, so it opens at the root.
    public static let extraRows: [Extra] = [
        Extra(id: "config", title: "Config", symbol: "doc.text", target: .branch(.config)),
        Extra(id: "files", title: "Files", symbol: "doc.text.magnifyingglass", target: .searchFiles),
        Extra(id: "notes", title: "Notes", symbol: "note.text", target: .branch(.notes)),
        Extra(id: "qr", title: "QR", symbol: "qrcode", target: .branch(.qr)),
        Extra(id: "reminders", title: "Reminders", symbol: "bell", target: .branch(.reminders)),
        Extra(id: "translate", title: "Translate", symbol: "character.bubble", target: .branch(.translate)),
        Extra(id: "capture", title: "Capture", symbol: "camera.viewfinder", target: .branch(.capture)),
        Extra(id: "emoji", title: "Emoji", symbol: "face.smiling", target: .branch(.emoji)),
        Extra(id: "stickers", title: "Stickers and GIFs", symbol: "photo.on.rectangle.angled", target: .branch(.stickers)),
        Extra(id: "clipboard", title: "Clipboard", symbol: "doc.on.clipboard", target: .action("apps.clipboard")),
        Extra(id: "dictation", title: "Dictation", symbol: "mic", target: .action("dictation.toggle")),
        Extra(id: "aiChat", title: "AI chat", symbol: "bubble.left.and.text.bubble.right", target: .action("ai.chat")),
        Extra(id: "activity", title: "Activity", symbol: AppPage.activity.symbol, target: .branch(.activity)),
        Extra(id: "stats", title: "Stats", symbol: AppPage.stats.symbol, target: .branch(.stats)),
    ]

    /// One row of the root as Sven arranges it: a branch, or an extra switched on.
    public enum Row: Equatable, Sendable {
        case branch(MenuBranch), extra(Extra)

        /// Its id in `order`: the branch's `rawValue`, `extra:<id>` for an extra, as extra ids can be branch names.
        public var id: String {
            switch self {
            case .branch(let b): b.rawValue
            case .extra(let e): Self.id(extra: e.id)
            }
        }

        static func id(extra: String) -> String { "extra:\(extra)" }

        public var title: String {
            switch self {
            case .branch(let b): b.title
            case .extra(let e): e.title
            }
        }

        public var branch: MenuBranch? { if case .branch(let b) = self { b } else { nil } }
        public var extra: Extra? { if case .extra(let e) = self { e } else { nil } }
    }

    public mutating func show(extra id: String, _ on: Bool) {
        if on {
            extras.insert(id)
        } else {
            // Off forgets its place: on again, it stands last.
            extras.remove(id)
            order.removeAll { $0 == Row.id(extra: id) }
        }
    }

    /// The root's rows in Sven's order, hidden branches too: the saved ones first as saved, each new branch after the
    /// branch it follows by default (first when nothing before it is placed), then each extra switched on and not yet
    /// placed, so Reset puts the extras after System.
    public func rows(_ branches: [MenuBranch] = MenuBranch.top) -> [Row] {
        let on = Self.extraRows.filter { extras.contains($0.id) }
        let all = branches.map(Row.branch) + on.map(Row.extra)
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var placed: [Row] = []
        for id in order { if let r = byID[id], !placed.contains(r) { placed.append(r) } }
        for (i, b) in branches.enumerated() where !placed.contains(.branch(b)) {
            let after = branches[..<i].reversed().lazy.compactMap { placed.firstIndex(of: .branch($0)) }.first
            placed.insert(.branch(b), at: after.map { $0 + 1 } ?? 0)
        }
        for e in on where !placed.contains(.extra(e)) { placed.append(.extra(e)) }
        return placed
    }

    /// What the root lists before typing: the shown branches and the extras switched on, in Sven's order.
    public func shownRows() -> [Row] { rows().filter(isShown) }

    /// `branches` in Sven's order, without the extras.
    public func arranged(_ branches: [MenuBranch] = MenuBranch.top) -> [MenuBranch] { rows(branches).compactMap(\.branch) }

    /// What the root lists before typing.
    public func shown() -> [MenuBranch] { shownRows().compactMap(\.branch) }

    public func isShown(_ branch: MenuBranch) -> Bool { !hidden.contains(branch.rawValue) }

    /// An extra is listed while it is on, so only a branch can be hidden.
    public func isShown(_ row: Row) -> Bool { row.branch.map(isShown) ?? true }

    /// A branch's switch hides or shows it; an extra's turns it off or on.
    public mutating func show(_ row: Row, _ on: Bool) {
        switch row {
        case .branch(let b): show(b, on)
        case .extra(let e): show(extra: e.id, on)
        }
    }

    public mutating func show(_ branch: MenuBranch, _ on: Bool) {
        if on { hidden.remove(branch.rawValue) } else { hidden.insert(branch.rawValue) }
    }

    /// Moves `branch` to `index` of the arranged branches, saving the whole order from then on.
    public mutating func move(_ branch: MenuBranch, to index: Int) {
        let others = arranged().filter { $0 != branch }
        move(.branch(branch), before: others.indices.contains(max(index, 0)) ? .branch(others[max(index, 0)]) : nil)
    }

    /// Moves `row` just before `target`, or after the last branch for nil, so the extras keep their places around it.
    public mutating func move(_ row: Row, before target: Row?) {
        guard rows().contains(row), row != target else { return }
        let others = rows().filter { $0 != row }
        move(row, to: target.flatMap(others.firstIndex) ?? (others.lastIndex { $0.branch != nil }.map { $0 + 1 } ?? 0))
    }

    /// Moves `row` to `index` of `rows()`, saving the whole order from then on.
    public mutating func move(_ row: Row, to index: Int) {
        var list = rows()
        guard let from = list.firstIndex(of: row) else { return }
        list.remove(at: from)
        list.insert(row, at: min(max(index, 0), list.count))
        order = list.map(\.id)
    }

    /// Whether it lists exactly today's branches with the extras switched on after them: unknown ids left in the store
    /// change nothing; which extras are on is their own switches.
    public func isDefault() -> Bool { rows() == MenuRoot(extras: extras).rows() && MenuBranch.top.allSatisfy(isShown) }
}
