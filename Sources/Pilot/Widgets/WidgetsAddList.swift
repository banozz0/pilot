import PilotCore
import SwiftUI

/// The Widgets page's list to add from (Sven, 2026-11-15, Q252 B; grouped 2026-11-22): every widget, Pilot's then yours,
/// in two columns once the panel is wide, each a row with its preview (as it will look; its icon until the previews
/// load), what it shows, how many are placed, its trust and Add; Add puts it on the map's display (on its first free
/// cells). Its menu holds Duplicate to edit, and for yours Show folder and Uninstall.
struct WidgetsAddList: View {
    @Environment(\.ink) private var ink
    let model: WidgetsPageModel
    var previews: WidgetPreviews = .shared
    let add: (Widget) -> Void

    /// Two columns from a panel this wide.
    private static let columns = [GridItem(.adaptive(minimum: 400), spacing: 24, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Add puts one on the map, on its first free cells.").font(ink.ui(12)).foregroundStyle(ink.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                newWidget
            }
            .padding(.bottom, 6)
            group("Pilot's", ReadyWidgets.all)
            if !model.installed.isEmpty || !model.broken.isEmpty {
                group("Yours", model.installed)
                ForEach(model.broken, id: \.folder) { broken in
                    BlockRow {
                        Chip(text: "doesn't read", color: ink.yellow)
                        Text("\(broken.folder): \(broken.why)").font(ink.ui(11.5)).foregroundStyle(ink.text2).lineLimit(2)
                    }
                }
            }
        }
    }

    /// A group's quiet label, then its rows, built as they scroll in (page-switch-3: the list was 47 of a first visit's
    /// 79 ms in a debug build).
    private func group(_ title: String, _ widgets: [Widget]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(ink.ui(12, .semibold)).foregroundStyle(ink.text2).padding(.top, 14).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 0) {
                ForEach(widgets, id: \.id) { row($0) }
            }
        }
    }

    private func row(_ widget: Widget) -> some View {
        let ready = ReadyWidgets.isReady(widget.id)
        let trust = model.trust[widget.id]
        let placed = model.placed(widget.id)
        return BlockRow {
            // The preview and its words as one part, so a row short of room keeps them together.
            HStack(spacing: 12) {
                thumbnail(widget)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(widget.title).font(ink.ui(12.5, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                        if placed > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                if placed > 1 { Text("\(placed)").font(ink.mono(10.5)) }
                            }
                            .foregroundStyle(ink.text2)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("On the desktop \(placed) times")
                        }
                    }
                    if let description = widget.description {
                        Text(description).font(ink.ui(11)).foregroundStyle(ink.text2).lineLimit(2).help(description)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            WidgetsTrust(trust: ready ? nil : trust)
            if !ready, trust == .locked, WidgetAsks.runsOnShow(widget) || WidgetAsks.acts(widget) {
                Button("Trust…") { model.asking = widget.id }.buttonStyle(.pilot).help("Trust this widget: what it may do, then Trust")
            }
            Button("Add") { add(widget) }.buttonStyle(.pilot)
                .help(placed > 0 ? "Put another on the desktop, on the first free cells" : "Put it on the desktop, on the first free cells")
            Menu {
                Button("Duplicate to edit") { model.duplicate(widget) }
                if !ready {
                    Button("Show folder") { model.showFolder(widget) }
                    Divider()
                    Button("Uninstall…", role: .destructive) { model.uninstalling = widget.id }
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More for \(widget.title)")
        }
        .padding(.vertical, 2)
    }

    /// The widget as it will look, small; its icon on the theme's wallpaper colours until the previews load.
    @ViewBuilder private func thumbnail(_ widget: Widget) -> some View {
        Group {
            if let tile = previews.models[widget.id] {
                WidgetPreview(widget: widget, model: tile, shot: previews.shots[widget.id], height: 54)
            } else {
                WidgetPreview.ground(Look.shared.theme)
                    .overlay { Text(widget.icon).font(.system(size: 18)) }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(width: 84, height: 54)
        .accessibilityHidden(true)
    }

    /// Every way to a widget of your own, in one menu: the AI chat, the builder, an import, the folder.
    private var newWidget: some View {
        Menu {
            Button("Create with AI") { AIChatPanel.shared.show(typing: WidgetMaker.command + " ") }
                .help("Opens the AI chat with /widget typed: describe the widget, or paste or drop a picture of one")
            Button("New widget…") { model.building = true }.help("Pick a look and a source; no AI needed")
            Button("Import…") { model.chooseFolder() }.help("A widget folder or .zip; or drop one on this page")
            Divider()
            Button("Show folder") { model.showFolder() }
        } label: {
            Label("New widget", systemImage: "plus")
        }
        .menuStyle(.button).buttonStyle(.pilot).fixedSize()
    }
}
