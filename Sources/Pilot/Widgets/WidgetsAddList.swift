import PilotCore
import SwiftUI

/// The Widgets page's list to add from (Sven, 2026-11-15, Q252 B): every widget, Pilot's then yours, each a row with
/// what it shows, how many are placed, its trust and Add; Add puts it on the map's display (on its first free cells) or
/// on Home, as the switch above says. Its menu holds Duplicate to edit, and for yours Show folder and Uninstall.
struct WidgetsAddList: View {
    @Environment(\.ink) private var ink
    let model: WidgetsPageModel
    /// Adding to Home, not the desktop.
    let home: Bool
    let add: (Widget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                WidgetsEyebrow(text: home ? "Add to Home" : "Add to the desktop")
                Spacer(minLength: 6)
                newWidget
            }
            .padding(.bottom, 6)
            ForEach(ReadyWidgets.all + model.installed, id: \.id) { row($0) }
            ForEach(model.broken, id: \.folder) { broken in
                BlockRow {
                    Chip(text: "doesn't read", color: ink.yellow)
                    Text("\(broken.folder): \(broken.why)").font(ink.ui(11.5)).foregroundStyle(ink.text2).lineLimit(2)
                }
            }
        }
    }

    private func row(_ widget: Widget) -> some View {
        let ready = ReadyWidgets.isReady(widget.id)
        let trust = model.trust[widget.id]
        let placed = model.placed(widget.id, home: home)
        return BlockRow {
            Text(widget.icon).font(.system(size: 16)).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(widget.title).font(ink.ui(12.5, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                    if placed > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            if placed > 1 { Text("\(placed)").font(ink.mono(10.5)) }
                        }
                        .foregroundStyle(ink.text2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(home ? "On Home \(placed) times" : "On the desktop \(placed) times")
                    }
                }
                if let description = widget.description {
                    Text(description).font(ink.ui(11)).foregroundStyle(ink.text2).lineLimit(1).help(description)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WidgetsTrust(trust: ready ? nil : trust)
            if !ready, trust == .locked, WidgetAsks.runsOnShow(widget) || WidgetAsks.acts(widget) {
                Button("Trust…") { model.asking = widget.id }.buttonStyle(.pilot).help("Trust this widget: what it may do, then Trust")
            }
            Button(placed > 0 ? "Add another" : "Add") { add(widget) }.buttonStyle(.pilot)
                .help(home ? "Put it on Home" : "Put it on the desktop, on the first free cells")
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

/// A small heading in the style: Instrument's mono eyebrow, Toybox's bold line.
struct WidgetsEyebrow: View {
    @Environment(\.ink) private var ink
    let text: String
    var body: some View {
        if ink.isInstrument { InstrumentEyebrow(text: text) } else { Text(text).font(ink.ui(13, .semibold)).foregroundStyle(ink.text) }
    }
}
