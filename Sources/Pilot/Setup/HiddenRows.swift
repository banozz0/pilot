import Foundation
import Observation
import SwiftUI

/// The rows hidden from a device list (spec hide-rows, Sven 2026-10-15, Q137), per list, by each row's stable id: a sound
/// device's UID, a Bluetooth address, a network's name, a display's UUID. Saved in Pilot's defaults; one store, so the
/// System page and the top bar's popovers hide the same rows.
@Observable @MainActor
final class HiddenRows {
    static let shared = HiddenRows()

    enum List: String, CaseIterable {
        case soundOutput, soundInput, bluetooth, wifi, displays

        static func sound(_ direction: AudioDirection) -> List { direction == .output ? .soundOutput : .soundInput }
    }

    private(set) var ids: [List: Set<String>]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        ids = Dictionary(uniqueKeysWithValues: List.allCases.map { ($0, Set(defaults.stringArray(forKey: Self.key($0)) ?? [])) })
    }

    func isHidden(_ id: String, in list: List) -> Bool { ids[list]?.contains(id) == true }

    func set(_ id: String, hidden: Bool, in list: List) {
        var kept = ids[list] ?? []
        guard hidden ? kept.insert(id).inserted : kept.remove(id) != nil else { return }
        ids[list] = kept
        defaults.set(kept.sorted(), forKey: Self.key(list))
    }

    /// A list's rows in their order: those that show, and those folded under Hidden (N). The row in use never folds,
    /// hidden or not; a row with no stable id never hides.
    func split<Item>(_ items: [Item], in list: List, id: (Item) -> String?, inUse: (Item) -> Bool) -> (shown: [Item], hidden: [Item]) {
        var shown: [Item] = [], hidden: [Item] = []
        for item in items {
            if !inUse(item), let key = id(item), isHidden(key, in: list) { hidden.append(item) } else { shown.append(item) }
        }
        return (shown, hidden)
    }

    private static func key(_ list: List) -> String { "hidden.\(list.rawValue)" }
}

/// A device list with Hide on each row that may hide (an eye on hover, or right-click), and the hidden rows folded under
/// one Hidden (N) toggle at its end, dimmed when open, each with Show. The page and the popovers draw their own rows;
/// `row` is told whether it is the list's first. `slot` puts Hide beside rows that end in their own button (Connect,
/// Join); otherwise it sits over the row's free end, where only the row in use has a check.
struct HidingList<Item, Row: View>: View {
    @Environment(\.ink) private var ink
    let list: HiddenRows.List
    let items: [Item]
    let id: (Item) -> String?
    let name: (Item) -> String
    let inUse: (Item) -> Bool
    var slot = false
    @ViewBuilder let row: (_ item: Item, _ first: Bool) -> Row
    @State private var open = false
    private let store = HiddenRows.shared

    var body: some View {
        let (shown, hidden) = store.split(items, in: list, id: id, inUse: inUse)
        ForEach(entries(shown)) { entry in
            let key = inUse(entry.item) ? nil : id(entry.item)
            HidingRow(control: key.map { key in (.hide, { store.set(key, hidden: true, in: list) }) }, name: name(entry.item), slot: slot) {
                row(entry.item, entry.first)
            }
        }
        if !hidden.isEmpty {
            Button { withAnimation(Kit.change) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).font(ink.system(9, weight: .bold))
                    Text("Hidden (\(hidden.count))")
                    Spacer()
                }
                .font(ink.ui(12, .semibold)).foregroundStyle(ink.muted).frame(minHeight: 24).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hidden, \(hidden.count)").accessibilityValue(open ? "shown" : "folded")
            if open {
                ForEach(entries(hidden, after: shown.count)) { entry in
                    let key = id(entry.item) ?? ""
                    HidingRow(control: (.show, { store.set(key, hidden: false, in: list) }), name: name(entry.item), slot: slot) {
                        row(entry.item, false).opacity(0.45)
                    }
                }
            }
        }
    }

    private struct Entry: Identifiable {
        let id: String
        let item: Item
        let first: Bool
    }

    /// Rows named by their stable id, so hiding one moves it instead of renaming every row under it; one with no id, or
    /// one whose id an earlier row holds, by its place.
    private func entries(_ items: [Item], after: Int = 0) -> [Entry] {
        var seen = Set<String>()
        return items.enumerated().map { i, item in
            let key = id(item).flatMap { seen.insert($0).inserted ? $0 : nil } ?? "#\(after + i)"
            return Entry(id: key, item: item, first: after + i == 0)
        }
    }
}

/// One row with its Hide or Show at the trailing edge: Hide shows on hover, Show always; both are in the row's right-click
/// menu. With `slot` every row keeps the room, so the rows' own trailing buttons line up.
private struct HidingRow<Content: View>: View {
    enum Verb: String { case hide = "Hide", show = "Show" }

    let control: (verb: Verb, run: () -> Void)?
    let name: String
    let slot: Bool
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        Group {
            if slot {
                HStack(spacing: 4) { content; button.frame(width: 22) }
            } else {
                content.overlay(alignment: .trailing) { button.padding(.trailing, 6) }
            }
        }
        .onHover { inside in withAnimation(Kit.change) { hovered = inside } }
        .contextMenu { if let control { Button("\(control.verb.rawValue) \(name)", action: control.run) } }
    }

    @ViewBuilder private var button: some View {
        if let control {
            let shows = control.verb == .show || hovered
            IconButton(symbol: control.verb == .hide ? "eye.slash" : "eye", label: "\(control.verb.rawValue) \(name)", size: 22, glyph: 12,
                       action: control.run)
                .opacity(shows ? 1 : 0).allowsHitTesting(shows).accessibilityHidden(!shows)
        }
    }
}
