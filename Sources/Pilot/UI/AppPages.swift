import AppKit
import PilotCore
import SwiftUI

/// A page's on/off card: the Menu bar page's top bar.
struct SwitchCard: View {
    @Environment(\.style) private var style
    @Environment(\.ink) private var ink
    let symbol: String, name: String, isOn: Bool, busy: Bool, detail: String
    let toggle: () -> Void

    var body: some View {
        if style.kind == .instrument {
            InstrumentSwitchCard(symbol: symbol, title: busy ? "Switching…" : "\(name) is \(isOn ? "on" : "off")", isOn: isOn, busy: busy,
                                 detail: detail, toggle: toggle)
        } else {
            current
        }
    }

    private var current: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(ink.ui(26)).foregroundStyle(isOn ? ink.green : ink.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(busy ? "Switching…" : "\(name) is \(isOn ? "on" : "off")").font(ink.ui(16, .semibold))
                    Text(detail).font(ink.ui(12)).foregroundStyle(ink.muted)
                }
                Spacer()
                Button(isOn ? "Switch off" : "Switch on", action: toggle).buttonStyle(.pilot).disabled(busy)
            }
            .padding(16)
        }
    }
}

/// The import waiting for Apply, filled from the page's Import… or a pilot://import link.
@Observable @MainActor
final class BindImport {
    static let shared = BindImport()

    var pending: (name: String, plan: BindStore.Import, data: Data)?
    var problem: String?

    /// pilot://import?pack=<base64url> (the shared link) or pilot://import?file=<path> (a fixture, without a panel).
    func open(_ url: URL) {
        if let data = BindStore.pack(in: url) { read(data, name: "The link") }
        else if let path = url.queryValue("file") { read(file: URL(fileURLWithPath: path)) }
        else { fail("pilot://import needs pack= or file=") }
    }

    func read(file url: URL) {
        do { read(try Data(contentsOf: url), name: url.lastPathComponent) }
        catch { fail("\(url.lastPathComponent) not read: \(error.localizedDescription)") }
    }

    private func read(_ data: Data, name: String) {
        guard let binds = Engine.shared?.binds else { return fail("Pilot's key engine is not running") }
        do {
            let plan = try binds.store.plan(importing: data)
            pending = (name, plan, data)
            problem = nil
            log.notice("binds: import preview, \(plan.summary(name: name), privacy: .public)")
        } catch {
            fail("\(name) not read: \(error)")
        }
    }

    func apply() {
        guard let pending, let binds = Engine.shared?.binds else { return }
        binds.apply(pending.plan)
        self.pending = nil
    }

    /// Add as preset (story 149): the file's preset becomes a new one, named for it or for the file.
    func addAsPreset() {
        guard let pending, let binds = Engine.shared?.binds else { return }
        do {
            try binds.importPreset(pending.data, name: (pending.name as NSString).deletingPathExtension)
            self.pending = nil
        } catch {
            fail("\(pending.name) not added as a preset: \(error)")
        }
    }

    private func fail(_ text: String) {
        pending = nil
        problem = text
        log.error("binds: \(text, privacy: .public)")
    }
}

/// Conflicts (stories 34, 35 and 101, wireframe mSEMT3YCZpU section 12): Pilot's actions whose default key another action
/// holds, each with Set key; the macOS shortcuts one of Pilot's plain combos lands on, turned off and put back with one
/// button each, and the private preference that does it, said plainly.
struct ConflictsPage: View {
    @Environment(\.ink) private var ink
    @Environment(Engine.self) private var engine
    private let conflicts = ShortcutConflicts.shared
    @State private var problem: String?
    /// Read from the preference when the page opens, the binds change or a button runs; never once per redraw.
    @State private var clashes: [SymbolicHotKeys.Clash] = []

    var body: some View {
        let binds = engine.binds.store.binds, off = conflicts.turnedOff
        PageBody {
            let refused = engine.binds.store.refused
            if !refused.isEmpty {
                PageSection(title: "Pilot actions without their key") {
                    Card {
                        ForEach(refused, id: \.action) { r in
                            CardRow {
                                Text(engine.action(r.action)?.label ?? r.action)
                                Spacer()
                                BindKey(action: r.action)
                            }
                        }
                    }
                }
            }
            PageSection(title: "macOS shortcuts") {
                Card {
                    if clashes.isEmpty && off.isEmpty { CardRow { Text("No macOS shortcut clashes with a Pilot bind.").foregroundStyle(ink.muted) } }
                    ForEach(clashes, id: \.hotkey.id) { c in
                        CardRow {
                            TitledText(title: "\(c.hotkey.name) · \(c.hotkey.key?.label ?? "")", detail: "Clashes with \(engine.action(c.action)?.label ?? c.action)")
                            Spacer()
                            Chip(text: "clashes", color: ink.yellow)
                        }
                    }
                    ForEach(off, id: \.self) { id in
                        CardRow { Text(SymbolicHotKeys.name(id)); Spacer(); Chip(text: "turned off", color: ink.green) }
                    }
                }
            }
            Text("Works by editing macOS's private shortcut settings (com.apple.symbolichotkeys), not a public Apple API. A macOS update can break it.")
                .font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Turn off every clash") { run { try conflicts.switchOff(binds: binds) } }.buttonStyle(.pilotPrimary).disabled(clashes.isEmpty)
                Button("Put all macOS shortcuts back") { run { try conflicts.restore() } }.buttonStyle(.pilot).disabled(!conflicts.hasBackup)
            }
            if let problem = problem ?? conflicts.problem { Text(problem).foregroundStyle(ink.red) }
            Text("Other apps' own shortcuts (Karabiner, yabai) come with story 102.").font(ink.ui(12)).foregroundStyle(ink.muted)
        }
        .task(id: binds) { clashes = conflicts.clashes(binds: binds) }
    }

    private func run(_ change: () throws -> Void) {
        do { try change(); problem = nil } catch { problem = error.localizedDescription; log.error("conflicts: \(error.localizedDescription, privacy: .public)") }
        clashes = conflicts.clashes(binds: engine.binds.store.binds)
    }
}
