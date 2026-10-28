import PilotCore
import SwiftUI

/// The Files view's filters as chips under the kinds (N5): Kind, Where and When, each named and naming its value
/// ("Kind: Any", "Where: Home", "When: Any time" when unset), then Hidden files, each with its key on it (⌘1, ⌘2, ⌘3,
/// ⌘⇧.) so the keys explain themselves (Sven 2026-10-10: "Cmd+1/2/3 are not explained"). A click steps a chip as its key
/// does; a set one wears an × that drops it, typed (`kind:pdf`) or stepped. Chip draws each style's own face.
struct FileFilterBar: View {
    @Bindable var model: MenuModel

    var body: some View {
        let shown = model.nav.shownFileFilters
        HStack(spacing: 6) {
            chip(.kind, key: "⌘1", text: "Kind: \(shown.kind?.title ?? "Any")", steps: FileFilters.Kind.all.map(\.title),
                 symbol: "doc.on.doc", on: shown.kind != nil)
            chip(.place, key: "⌘2", text: "Where: \(shown.place?.title ?? "Home")", steps: FileFilters.Place.all.map(\.title),
                 symbol: "folder", on: shown.place != nil)
            chip(.when, key: "⌘3", text: "When: \(shown.when?.title ?? "Any time")", steps: FileFilters.When.allCases.map(\.title),
                 symbol: "calendar", on: shown.when != nil)
            Button { model.nav.fileFilters.hidden.toggle() } label: {
                Chip(text: "Hidden files", on: shown.hidden, count: "⌘⇧.", symbol: shown.hidden ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
            .help("⌘⇧. shows or hides dot files and what sits inside apps and bundles")
            .accessibilityLabel("Hidden files \(shown.hidden ? "shown" : "hidden"); Command Shift period")
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File filters")
    }

    /// One filter: its name and value, its key after them; the tip names the values the key steps through.
    private func chip(_ facet: FileFilters.Facet, key: String, text: String, steps: [String], symbol: String, on: Bool) -> some View {
        Button { model.nav.stepFilter(facet) } label: {
            Chip(text: text, on: on, count: key, symbol: symbol, remove: on ? { model.nav.clearFilter(facet) } : nil)
        }
        .buttonStyle(.plain)
        .help("\(key) steps through \(steps.joined(separator: ", ")); ⇧\(key) goes back")
        .accessibilityLabel("\(text); \(key) for the next")
    }
}
