import AppKit
import PilotCore
import SwiftUI

/// Story 160's folders, each under the ability it configures on Launcher › Abilities (page map, Sven 2026-10-17: a
/// command's settings under the command, as Raycast keeps them; Menu's Folders block until then): `.repos`, where
/// lazygit's repo picker looks, under lazygit; `.gifs`, the GIFs folder Stickers and GIFs lists, the GIPHY key that
/// searches the web's and the highest rating it shows (story 164), under Stickers and GIFs. Each folder has Change…,
/// Show and Reset. Rows alone, no block: the Abilities list draws them beneath their ability's row.
struct FoldersBlock: View {
    enum Part { case repos, gifs }

    @Environment(\.ink) private var ink
    let part: Part
    @Bindable var folders: PilotFolders
    /// Where the GIPHY key lives: the login Keychain, a fake in renders.
    let giphy: any StoredKey
    /// Read as the rows appear, not as they are built: the page rebuilds them on every pass.
    @State private var hasKey = false
    @State private var replacing = false
    @State private var draft = ""
    @State private var problem: String?

    init(_ part: Part, folders: PilotFolders = .shared, giphy: any StoredKey = Giphy.keychain) {
        self.part = part
        self.folders = folders
        self.giphy = giphy
    }

    var body: some View {
        VStack(spacing: 0) {
            switch part {
            case .repos:
                BlockRow {
                    row("Repos", info: "lazygit's picker lists the git repos directly inside this folder, newest first.",
                        path: $folders.repos, standard: PilotFolders.standardRepos)
                }
            case .gifs:
                BlockRow {
                    row("GIFs and pictures", info: "Trigger › Stickers and GIFs lists the pictures in this folder and its subfolders.",
                        path: $folders.gifs, standard: PilotFolders.standardGIFs)
                }
                giphyRows
                BlockRow {
                    HStack(spacing: 6) {
                        Text("GIPHY rating")
                        InfoMark(text: "The most GIPHY's GIFs and stickers may be rated, as GIPHY rates them: G, PG, PG-13 or R.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("GIPHY rating", selection: $folders.giphyRating) {
                        ForEach(Giphy.Rating.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
        .onAppear { hasKey = giphy.exists() }
    }

    /// The GIPHY key: saved (Replace…, Remove) or a field to paste one, with where to get one.
    @ViewBuilder private var giphyRows: some View {
        let info = "Stickers and GIFs searches GIPHY's GIFs or stickers as you type, and shows its trending ones first. Without a key it lists "
            + "your folder alone."
        let label = HStack(spacing: 6) { Text("GIPHY key"); InfoMark(text: info) }
        if hasKey && !replacing {
            BlockRow {
                label
                Text("Saved in your Keychain").font(ink.ui(12)).foregroundStyle(ink.muted)
                Spacer()
                Button("Replace…") { replacing = true }.buttonStyle(.pilot)
                Button("Remove") { save(nil) }.buttonStyle(.pilot)
            }
        } else {
            BlockRow {
                label
                SecureField("GIPHY key", text: $draft, prompt: Text(verbatim: "Paste your key").foregroundStyle(ink.muted))
                    .labelsHidden().pilotField().secureFieldTip().onSubmit { save(draft) }
                Button("Save") { save(draft) }.buttonStyle(.pilotPrimary)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if replacing { Button("Cancel") { replacing = false; draft = "" }.buttonStyle(.pilot) }
            }
            BlockRow {
                FinePrint(text: problem ?? "Searches the web's GIFs and stickers in Stickers and GIFs. It stays in your Keychain, never in a file.")
                Spacer()
                AccentLink(title: "Get a key") { NSWorkspace.shared.open(Giphy.keyPage) }
            }
        }
    }

    private func save(_ key: String?) {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try giphy.write(key?.isEmpty == true ? nil : key)
            hasKey = giphy.exists()
            problem = nil
            replacing = false
        } catch {
            problem = "The Keychain did not take the key (\(error))."
        }
        draft = ""
    }

    private func row(_ title: String, info: String, path: Binding<String>, standard: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) { Text(title); InfoMark(text: info) }
                Text(AppConfigs.tilde(path.wrappedValue, home: NSHomeDirectory())).font(ink.ui(12)).foregroundStyle(ink.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if path.wrappedValue != standard { Button("Reset") { path.wrappedValue = standard }.buttonStyle(.pilot) }
            Button("Show") { NSWorkspace.shared.open(URL(filePath: path.wrappedValue)) }.buttonStyle(.pilot)
            Button("Change…") { pick(title, path) }.buttonStyle(.pilot)
        }
        .padding(.vertical, 6)
    }

    private func pick(_ title: String, _ path: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(filePath: path.wrappedValue)
        panel.prompt = "Use"
        panel.message = "The folder for \(title.lowercased())."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path.wrappedValue = url.standardizedFileURL.path
    }
}
