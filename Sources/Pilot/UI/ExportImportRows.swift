import AppKit
import PilotCore
import SwiftUI

/// Keys › More › Export and import (stories 41 and 58, wireframe mSEMT3YCZpU section 14; General › Data's until the page
/// map, Sven 2026-10-17, then Binds' tab until simplify-pages T14): the bind store's own JSON to a file or a
/// pilot://import link, read back as a preview first; shell, URL, Shortcuts and picker binds arrive switched off, shown
/// in full until each is turned on.
struct ExportImportRows: View {
    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink
    private let model = BindImport.shared

    var body: some View {
        KitBlock(title: "Export and import", symbol: "arrow.up.arrow.down") {
            BlockRow(first: true) {
                TitledText(title: "Export binds", detail: "Every bind in one file, the same JSON as binds.json").padding(.vertical, 4)
                InfoMark(text: "Copy link puts every bind in a pilot://import link to paste on another Mac; Export… saves them as a file.")
                Spacer()
                Button("Copy link") { copyLink() }.buttonStyle(.pilot)
                Button("Export…") { export() }.buttonStyle(.pilot)
            }
            BlockRow {
                TitledText(title: "Import binds", detail: "From a file; a pilot://import link opens here too").padding(.vertical, 4)
                InfoMark(text: "Reads an exported file and shows what it changes first; nothing changes until you press Apply.")
                Spacer()
                Button("Import…") { pick() }.buttonStyle(.pilot)
            }
            BlockRow {
                TitledText(title: "Keyboard map", detail: "Every layer and the mouse as one picture, to print or keep beside you").padding(.vertical, 4)
                InfoMark(text: "Saves a PNG of the active preset: a keyboard for each layer that has binds, every bound key with what it does, and the mouse's buttons.")
                Spacer()
                Button("Save map…") { BindsMapSave.run(engine: engine) { model.problem = $0 } }.buttonStyle(.pilot)
            }
            if let pending = model.pending {
                BlockRow {
                    Text(pending.plan.summary(name: pending.name)).fixedSize(horizontal: false, vertical: true)
                    InfoMark(text: "What this import changes, before it does.")
                    Spacer(minLength: 0)
                }
                ForEach(pending.plan.switchedOff, id: \.self) { id in
                    BlockRow {
                        command(id, detail: "arrives switched off")
                        InfoMark(text: Self.switchedOffInfo)
                        Spacer(minLength: 0)
                    }
                }
                BlockRow {
                    InfoMark(text: "Apply adds the new and changed binds to yours, keeping yours on a clash; Add as preset keeps the file as a preset of its own, beside yours.")
                    Spacer()
                    Button("Cancel") { model.pending = nil }.buttonStyle(.pilot)
                    Button("Add as preset") { model.addAsPreset() }.buttonStyle(.pilot)
                        .help("Keep these keys as a preset of their own, beside yours")
                    Button("Apply") { model.apply() }.buttonStyle(.pilotPrimary)
                }
            }
            if let problem = model.problem { BlockRow { FinePrint(text: problem, color: ink.red) } }
        }
        let off = engine.binds.store.switchedOff
        if !off.isEmpty {
            KitBlock(title: "Switched off", symbol: "pause.circle") {
                ForEach(Array(off.enumerated()), id: \.element) { i, id in
                    BlockRow(first: i == 0) {
                        command(id, detail: "Switched off: \(engine.binds.store.trigger(for: id)?.label ?? "No key") does nothing until you turn it on")
                        InfoMark(text: Self.switchedOffInfo)
                        Spacer()
                        Button("Turn on") { engine.binds.enable(id) }.buttonStyle(.pilot)
                    }
                }
            }
        }
    }

    /// The ⓘ on an imported bind that runs something: why it waits for a yes.
    static let switchedOffInfo = "A shell, URL, Shortcuts or picker bind from an import stays off until you read what it runs and turn it on."

    /// The bind's name, then its whole action id: the command or URL it runs, in plain text.
    private func command(_ id: String, detail: String) -> some View {
        TitledText(title: engine.action(id)?.label ?? id, detail: "\(id)\n\(detail)")
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BindStore.link(for: engine.binds.store.json()).absoluteString, forType: .string)
        log.notice("binds: export link copied")
    }

    /// Panels begin rather than run modal, so the main run loop and the tap keep going while one is open.
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pilot-export.json"
        panel.allowedContentTypes = [.json]
        let data = engine.binds.store.json()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic); log.notice("binds: exported to \(url.path, privacy: .public)") }
            catch { model.problem = "\(url.lastPathComponent) not written: \(error.localizedDescription)" }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.read(file: url)
        }
    }
}
