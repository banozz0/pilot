import PilotCore
import SwiftUI

/// Install › Hidden apps (Pilot 1.0.2, Sven Q713): apps Pilot never offers, picked from the installed ones; each row says
/// where it hides, Pilot and Finder or Pilot alone, with Unhide. A render passes its own store, rows and choices.
struct HiddenAppsPage: View {
    @Environment(\.ink) private var ink
    let store: HiddenApps
    private let given: [HiddenApps.Row]?
    @State private var choices: [(name: String, bundle: String)]
    private let reads: Bool

    init(store: HiddenApps = .shared, rows: [HiddenApps.Row]? = nil, choices: [(name: String, bundle: String)]? = nil) {
        self.store = store
        given = rows
        _choices = State(initialValue: choices ?? [])
        reads = choices == nil
    }

    static let intro = "Apps you never want offered: Pilot's search, Open with and app pickers leave them out. A hidden app that runs still shows and tiles."
    /// The one line of help: what macOS lets Pilot hide.
    static let help = "Apps in Applications hide in Finder too; built-in apps hide in Pilot only. Spotlight still finds every app."

    var body: some View {
        let rows = given ?? store.rows(name: AppsModule.appName)
        KitPage(intro: Self.intro) {
            KitBlock(title: "Hidden apps", symbol: "eye.slash", note: Self.help) {
                add
            } content: {
                if rows.isEmpty {
                    BlockRow(first: true) {
                        Text("No hidden apps. Hide one with Hide an app.").font(ink.ui(12.5)).foregroundStyle(ink.muted)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    BlockRow(first: i == 0) { line(row) }
                }
            }
        }
        .task {
            guard reads else { return }
            store.reflag()
            choices = AppsModule.pickableApps(hidden: true)
        }
    }

    /// Hide an app…: every installed app not hidden yet.
    private var add: some View {
        AppPickerField(bundle: nil, name: "Hide an app…", label: "Hide an app", compact: true, symbol: "plus") {
            ForEach(choices.filter { !store.isHidden($0.bundle) }, id: \.bundle) { app in
                Button { store.hide(app.bundle) } label: { AppMenuItem(name: app.name, bundle: app.bundle) }
            }
        }
        .frame(width: 220)
    }

    private func line(_ row: HiddenApps.Row) -> some View {
        HStack(spacing: 10) {
            AppIcon(name: row.name, bundle: row.bundle, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(ink.ui(13, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                Text(row.place).font(ink.ui(11.5)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Unhide") { store.unhide(row.bundle) }.buttonStyle(.pilot).accessibilityLabel("Unhide \(row.name)")
        }
    }
}
