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
    /// Home's blocks (CLI W20, Sven's D3 2026-10-11; P91's grid): `home-blocks` lists Home's rows, in their order, each
    /// shown or hidden (in edit mode's tray) with its cells and its Layout; add shows one and may place, size or pin it,
    /// remove hides one, remove --reset is edit mode's Reset. Every change saves as edit mode's Done does, the default as
    /// nothing saved.
    func registerHomeBlocks(_ s: HomeBlockStores = HomeBlockStores()) {
        register(ControlCollection("home-blocks", help: "Home's blocks in their order, hidden ones too (shown false), each with its cells on Home's "
                                   + "23-column grid and its layout; add shows one and may place, size or pin it, remove hides one, "
                                   + "remove --reset puts back the default Home.",
                                   fields: [.init("block", help: "one of \(Self.cases(HomeLayout.Block.self)), ext:<id> for an installed extension's page, or widget:<placement> for a widget on Home (pilot list widgets)"),
                                            .init("at", help: "its place in the list, 0 first, hidden blocks counted; where it is when left out", required: false),
                                            .init("cells", help: "x,y,w,h: its left column (0 to \(HomeGrid.columns - 1)), top row (at most the row under Home's lowest block), columns and rows (1 to \(HomeCell.tallest)); the blocks there move down. Its own when left out", required: false),
                                            .init("layout", help: "one of \(Widget.layoutWords.joined(separator: ", ")): auto picks by its size, a class keeps it; its own when left out", required: false)],
                                   rowKey: "block", list: { .array(await Self.editHome(s).rows.map(JSONValue.object)) },
                                   add: { args throws(ControlError) in
            let home = await Self.editHome(s)
            let block = try home.block(args.value("block")!)
            var next = home.layout
            var cell: HomeCell?
            if let word = args.value("cells") {
                // Its top row at most the one under Home's lowest block, so no gap opens above it.
                let lowest = home.layout.cells(home.drawn).filter { $0.key != block }.map(\.value.maxY).max() ?? 0
                guard let named = HomeCell(words: word), named.clamped == named, named.y <= lowest else {
                    throw ControlError(.badValue, "--cells: \(word) is not cells on the grid; x,y,w,h with x+w at most \(HomeGrid.columns), "
                                       + "y at most \(lowest) and h at most \(HomeCell.tallest)")
                }
                cell = named
            }
            if let word = args.value("layout") {
                guard Widget.layoutWords.contains(word) else {
                    throw ControlError(.badValue, "--layout: \(word) is not a layout; one of \(Widget.layoutWords.joined(separator: ", "))")
                }
                next.set(block, layout: Widget.SizeClass(rawValue: word))
            }
            if let at = args.value("at") {
                guard let index = Int(at), index >= 0 else { throw ControlError(.badValue, "--at: \(at) is not a place, 0 first") }
                let others = home.listed.filter { $0 != block }
                next.move(block, before: index < others.count ? others[index] : nil, listed: home.listed)
            }
            // As edit mode puts it: moved from where Home draws it, the blocks in its way moving down.
            next.put(block, on: cell, style: home.style, extensions: home.beyond, from: home.layout.cells(home.drawn)[block])
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
            next.hide(block, style: home.style, extensions: home.beyond)
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
/// offers and the cells it draws them at, read once per command.
private struct EditHomeList {
    let layout: HomeLayout
    let pages: [ExtensionPages.Link]
    let widgets: [(placement: String, title: String)]
    let style: PilotStyle

    /// The rows past Pilot's blocks, as HomeLayout.resolved takes them: the pages by id, Home's widgets by row.
    var beyond: [String] { HomeLayout.beyond(pages: pages.map(\.id), widgets: widgets.map(\.placement)) }

    var listedRows: [HomeLayout.Row] {
        layout.resolved(extensions: beyond).filter { HomeLayout.draws($0.id, in: style) }
    }

    var listed: [String] { listedRows.map(\.id) }

    /// The blocks Home draws in this style.
    var drawn: [String] { layout.drawn(style, extensions: beyond) }

    /// Each row with its cells as Home draws them (a shown block's), else as kept, and its Layout.
    var rows: [[String: JSONValue]] {
        let cells = layout.cells(drawn)
        return listedRows.enumerated().map { at, row in
            let title = HomeLayout.Block(rawValue: row.id)?.title ?? pages.first { $0.id == HomeLayout.extensionID(row.id) }?.title
                ?? widgets.first { $0.placement == HomeLayout.widgetID(row.id) }?.title ?? row.id
            let cell = cells[row.id] ?? row.cell
            return ["block": .string(row.id), "title": .string(title), "shown": .bool(row.shown),
                    "cells": cell.map { .string("\($0.x),\($0.y),\($0.w),\($0.h)") } ?? .null,
                    "layout": .string(row.layout?.rawValue ?? "auto"), "at": .number(Double(at))]
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
