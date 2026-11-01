import Foundation
import PilotCore

/// What `home-blocks` reads and writes: Home's saved layout, the installed extensions with a page, the widgets on Home
/// and the style picked, which together make Home's rows, shown or hidden. A test fills its own.
struct HomeBlockStores: Sendable {
    var layout: @Sendable @MainActor () -> HomeLayoutStore = { .shared }
    /// Read again first, as the app window does when it opens: a command may come before the window ever has.
    var pages: @Sendable @MainActor () async -> [ExtensionPages.Link] = {
        await ExtensionPages.shared.reload()
        return ExtensionPages.shared.links
    }
    var style: @Sendable @MainActor () -> PilotStyle = { Look.shared.style }
    /// The widgets on Home, each its placement's id and its widget's title, as the placements file holds them.
    var widgets: @Sendable @MainActor () -> [(placement: String, title: String)] = {
        let store = WidgetStore.live
        return store.placements().filter(\.onHome).map { ($0.id, store.widget($0.widget)?.title ?? $0.widget) }
    }
}

extension ControlVerbs {
    /// Home's blocks (CLI W20, Sven's D3 2026-10-11): `home-blocks` lists Home's rows, in their order, each shown or
    /// hidden (in edit mode's tray) with its size; add shows one and may move or size it, remove hides one, remove
    /// --reset is edit mode's Reset. Every change saves as edit mode's Done does, the default as nothing saved.
    func registerHomeBlocks(_ s: HomeBlockStores = HomeBlockStores()) {
        register(ControlCollection("home-blocks", help: "Home's blocks in their order, hidden ones too (shown false); add shows one and may "
                                   + "move or size it, remove hides one, remove --reset puts back the default Home.",
                                   fields: [.init("block", help: "one of \(Self.cases(HomeLayout.Block.self)), ext:<id> for an installed extension's page, or widget:<placement> for a widget on Home (pilot list widgets)"),
                                            .init("at", help: "its place in the list, 0 first, hidden blocks counted; where it is when left out", required: false),
                                            .init("size", help: "one of \(Self.cases(HomeLayout.Size.self)); its own when left out", required: false)],
                                   rowKey: "block", list: { .array(await Self.editHome(s).rows.map(JSONValue.object)) },
                                   add: { args throws(ControlError) in
            let home = await Self.editHome(s)
            let block = try home.block(args.value("block")!)
            var next = home.layout
            next.set(block, shown: true)
            if let word = args.value("size") {
                guard let size = HomeLayout.Size(rawValue: word) else {
                    throw ControlError(.badValue, "--size: \(word) is not a size; one of \(Self.cases(HomeLayout.Size.self))")
                }
                next.set(block, size: size)
            }
            if let at = args.value("at") {
                guard let index = Int(at), index >= 0 else { throw ControlError(.badValue, "--at: \(at) is not a place, 0 first") }
                let others = home.listed.filter { $0 != block }
                next.move(block, before: index < others.count ? others[index] : nil, listed: home.listed)
            }
            return Self.save(next, block, home, s)
        }, remove: { args throws(ControlError) in
            if let refusal = ControlVerb.unknownFlag(args.flags, known: ["reset"], in: "pilot remove home-blocks") { throw refusal }
            if args.flags.contains("reset") {
                s.layout().reset()
                return .array(await Self.editHome(s).rows.map(JSONValue.object))
            }
            let home = await Self.editHome(s)
            let block = try home.block(try args.word(0, "block"))
            guard home.listedRows.contains(where: { $0.id == block && $0.shown }) else { throw ControlError(.badValue, "\(block) is already hidden") }
            var next = home.layout
            next.set(block, shown: false)
            return Self.save(next, block, home, s)
        }))
    }

    @MainActor
    private static func editHome(_ s: HomeBlockStores) async -> EditHomeList {
        EditHomeList(layout: s.layout().layout, pages: await s.pages(), widgets: s.widgets(), style: s.style())
    }

    /// Saves as edit mode's Done (HomeEditSession.done): a layout Home draws as the default saves as nothing, so a later
    /// default is the one read. Answers the block's row as the store now holds it.
    @MainActor
    private static func save(_ layout: HomeLayout, _ block: String, _ home: EditHomeList, _ s: HomeBlockStores) -> JSONValue {
        let store = s.layout()
        if layout.isStandard(extensions: home.beyond) { store.reset() } else if layout != store.layout { store.save(layout) }
        let after = EditHomeList(layout: store.layout, pages: home.pages, widgets: home.widgets, style: home.style)
        return after.rows.first { $0["block"] == .string(block) }.map(JSONValue.object) ?? .null
    }
}

/// Home's rows as they stand: the ones the style draws, shown or not, in their order, with the extension pages it
/// offers, read once per command.
private struct EditHomeList {
    let layout: HomeLayout
    let pages: [ExtensionPages.Link]
    let widgets: [(placement: String, title: String)]
    let style: PilotStyle

    /// The rows past Pilot's blocks, as HomeLayout.resolved takes them: the pages by id, Home's widgets by row.
    var beyond: [String] { HomeLayout.beyond(pages: pages.map(\.id), widgets: widgets.map(\.placement)) }

    var listedRows: [HomeLayout.Row] {
        layout.resolved(extensions: beyond).filter { HomeLayout.Block(rawValue: $0.id)?.drawn(in: style) ?? true }
    }

    var listed: [String] { listedRows.map(\.id) }

    var rows: [[String: JSONValue]] {
        listedRows.enumerated().map { at, row in
            let title = HomeLayout.Block(rawValue: row.id)?.title ?? pages.first { $0.id == HomeLayout.extensionID(row.id) }?.title
                ?? widgets.first { $0.placement == HomeLayout.widgetID(row.id) }?.title ?? row.id
            return ["block": .string(row.id), "title": .string(title), "shown": .bool(row.shown),
                    "size": .string(layout.size(of: row.id).rawValue), "at": .number(Double(at))]
        }
    }

    /// A block Home lists now, else why not.
    func block(_ word: String) throws(ControlError) -> String {
        guard listed.contains(word) else {
            let why = HomeLayout.Block(rawValue: word) != nil ? "\(word) is not drawn in this style"
                : HomeLayout.extensionID(word).map { "no installed extension with a page is \($0)" }
                ?? HomeLayout.widgetID(word).map { "no widget on Home is placement \($0)" } ?? "no block \(word)"
            throw ControlError(.badValue, "\(why); pilot list home-blocks lists them")
        }
        return word
    }
}
