import PilotCore
import SwiftUI

/// Update & Clean's Login and background items (Q386): each item's icon, name, app and kind, read as the page shows.
/// Each item but Pilot's own and macOS's gets Turn off (or Turn on), asked first in a confirm naming exactly what Pilot
/// does (Sven, Q412). What an app registered itself is macOS's to switch, so the block keeps Open Login Items….
struct LoginItemsBlock: View {
    @Environment(\.ink) private var ink
    /// Held only while the block shows, so the list is let go with the page.
    @State private var model = LoginItemsModel()
    /// The switch waiting on its confirm.
    @State private var asking: (item: LoginItems.Item, on: Bool)?

    var body: some View {
        KitBlock(title: "Login and background items", symbol: "power.circle",
                 note: "What starts at login or runs in the background. Turn each off or on here; what an app registered itself switches in Login Items.",
                 trailing: { Button("Open Login Items…") { LoginItemsModel.openSettings() }.buttonStyle(.pilot) }) {
            VStack(spacing: 0) {
                if let items = model.items {
                    if items.isEmpty { EmptyState(title: "Nothing starts at login", line: "No login items or launchd jobs were found.") }
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in BlockRow(first: i == 0) { row(item) } }
                } else {
                    EmptyState(title: "Reading…", line: "What starts at login shows in a moment.")
                }
                if let problem = model.problem { Text(problem).font(ink.ui(11.5)).foregroundStyle(ink.muted).padding(.vertical, 6) }
            }
        }
        .task { await model.reload() }
        .confirmationDialog(asking.map { "Turn \($0.on ? "on" : "off") \($0.item.label)?" } ?? "",
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), presenting: asking) { asked in
            Button(asked.on ? "Turn on" : "Turn off", role: asked.on ? nil : .destructive) { Task { await model.set(asked.item, on: asked.on) } }
            Button("Cancel", role: .cancel) {}
        } message: { asked in
            Text(Self.detail(asked.item, on: asked.on))
        }
    }

    /// What the confirm says the switch does, in System Events' or launchctl's own steps.
    static func detail(_ item: LoginItems.Item, on: Bool) -> String {
        switch (item.kind, on) {
        case (.loginItem, true): "Pilot adds \(item.label) back to Open at Login (System Events)."
        case (.loginItem, false): "Pilot takes \(item.label) out of Open at Login (System Events). Pilot remembers its app, so Turn on puts it back."
        case (.daemon, true): "macOS asks for an administrator password, then Pilot clears launchd's disabled flag and starts \(item.label) now (launchctl enable, then bootstrap, in the system domain)."
        case (.daemon, false): "macOS asks for an administrator password, then Pilot stops \(item.label) now and keeps it from starting (launchctl bootout, then disable, in the system domain). Its file stays, so Turn on puts it back."
        case (_, true): "Pilot clears launchd's disabled flag and starts \(item.label) now (launchctl enable, then bootstrap)\(Self.forYou(item))."
        case (_, false): "Pilot stops \(item.label) now and keeps it from starting at login (launchctl bootout, then disable)\(Self.forYou(item)). Its file stays, so Turn on puts it back."
        }
    }

    /// A shared agent runs in each user's own domain, so its switch holds for this account only.
    private static func forYou(_ item: LoginItems.Item) -> String { item.kind == .sharedAgent ? ", for your account" : "" }

    private func row(_ item: LoginItems.Item) -> some View {
        let app = item.appPath.map { AppsModule.appName(at: URL(filePath: $0)) }
        return HStack(spacing: 12) {
            IconTile(icon: MenuIcon(appPath: item.appPath, bundle: item.bundleID, symbol: Self.symbol(item.kind), tint: .neutral), size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(ink.ui(13, .semibold)).foregroundStyle(item.disabled ? ink.muted : ink.text).lineLimit(1).truncationMode(.middle)
                Text(([app, item.kind.title, item.disabled ? "Off" : nil] as [String?]).compactMap(\.self).joined(separator: " · "))
                    .font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.isPilot {
                Text("General › Launch at login").font(ink.ui(11.5)).foregroundStyle(ink.text2)
            } else if model.appHeld.contains(item.label), item.kind == .loginItem {
                Text("Its app keeps it: Open Login Items…").font(ink.ui(11.5)).foregroundStyle(ink.text2)
            } else if item.canSwitch {
                Button(item.disabled ? "Turn on…" : "Turn off…") { asking = (item, item.disabled) }
                    .buttonStyle(.pilot).disabled(model.busy != nil)
            }
        }
        .padding(.vertical, 6)
    }

    private static func symbol(_ kind: LoginItems.Kind) -> String {
        switch kind {
        case .loginItem: "person.crop.circle"
        case .agent: "gearshape"
        case .sharedAgent: "person.2"
        case .daemon: "gearshape.2"
        }
    }
}
