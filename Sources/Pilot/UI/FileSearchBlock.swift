import AppKit
import PilotCore
import SwiftUI

/// Files › File search (N5, Sven 2026-10-09; on Defaults until C3, on Menu until 2026-10-10): Show hidden and system files, which the Files view opens with, and the
/// never-index list as chips, each with its × and a field that adds one; Reset brings the shipped list back. The list
/// is skipped by the file index entirely, so a change walks the home folder again at the next file search. Text in
/// images follows it.
struct FileSearchBlock: View {
    @Environment(\.ink) private var ink
    @Bindable var settings: FileSearchSettings
    @Bindable var text: ImageTextSettings = .shared
    /// The reader's counts and its Clear; a test passes its own, so nothing of Sven's index is read or deleted.
    var counts: () -> (read: Int, waiting: Int) = { (ImageTextReader.shared.read, ImageTextReader.shared.waiting) }
    var clear: () -> Void = { ImageTextReader.shared.clear() }
    @State private var typed = ""
    @State private var problem: String?

    static let note = "What the menu's Files view leaves out. Hidden files are dot files and what sits inside apps and bundles; ⌘⇧. in the Files view shows them for one search."
    static let listNote = "Never indexed, so never found, even with hidden files shown. A name leaves out every folder so named; ~/ means one folder in your home. iCloud Drive stays searchable inside ~/Library. A change reads your home folder again at the next file search."

    var body: some View {
        searchBlock
        ImageTextBlock(text: text, counts: counts, clear: clear)
    }

    private var searchBlock: some View {
        KitBlock(title: "File search", symbol: "doc.text.magnifyingglass", note: Self.note) {
            BlockRow(first: true) { Toggle("Show hidden and system files", isOn: $settings.showHidden).toggleStyle(.pilotSwitchRow(info: "On, the Files view always opens with them shown.")) }
            BlockRow {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Never search in")
                        InfoMark(text: "Worth adding a folder of build output you never look for, so searches stay quick.")
                        Spacer()
                        if settings.excluded != FileExclusions.defaults {
                            Button("Reset") { withAnimation(Kit.change) { settings.reset() } }.buttonStyle(.pilot)
                        }
                    }
                    Flow(spacing: 6, lineSpacing: 6) {
                        ForEach(settings.excluded, id: \.self) { entry in
                            Chip(text: entry, tag: true) { withAnimation(Kit.change) { settings.remove(entry) } }
                        }
                    }
                    field
                    if let problem { Text(problem).font(ink.ui(12)).foregroundStyle(ink.yellow) }
                    Text(Self.listNote).font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("", text: $typed, prompt: Text("Add a folder, e.g. Pods or ~/Movies").foregroundStyle(ink.muted))
                .frame(minHeight: 24).pilotField()
                .onSubmit(add)
                .onChange(of: typed) { problem = nil }
                .accessibilityLabel("Folder to leave out")
            Button(action: add) { Text("Add") }
                .buttonStyle(.pilot)
                .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        problem = settings.add(typed)
        if problem == nil { typed = "" }
    }
}

/// Text in images (Homy-style Files, Sven 2026-10-12): the switch, the folders read as chips with Add…, the count read
/// and waiting, and Clear text index.
private struct ImageTextBlock: View {
    @Environment(\.ink) private var ink
    @Bindable var text: ImageTextSettings
    let counts: () -> (read: Int, waiting: Int)
    let clear: () -> Void
    @State private var problem: String?
    @State private var confirmingClear = false

    static let note = "Finds a screenshot by the words in it. Everything stays on this Mac; the first reading waits for power."
    static let foldersNote = "Their png, jpg, heic and webp images are read, folders inside them too; the never-index list still applies."

    var body: some View {
        KitBlock(title: "Text in images", symbol: "text.viewfinder", note: Self.note) {
            BlockRow(first: true) { Toggle("Find images by the words in them", isOn: $text.enabled).toggleStyle(.pilotSwitchRow(info: "On, a file search also matches the words inside your screenshots and pictures.")) }
            if text.enabled {
                BlockRow {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Read in")
                            InfoMark(text: "Only images in these folders are read; Add… picks another.")
                            Spacer()
                            if text.folders != ImageTextSettings.standardFolders {
                                Button("Reset") { withAnimation(Kit.change) { text.reset() } }.buttonStyle(.pilot)
                            }
                            Button("Add…", action: pickFolder).buttonStyle(.pilot)
                        }
                        Flow(spacing: 6, lineSpacing: 6) {
                            ForEach(text.folders, id: \.self) { entry in
                                Chip(text: entry, tag: true) { withAnimation(Kit.change) { text.remove(entry) } }
                            }
                        }
                        if let problem { Text(problem).font(ink.ui(12)).foregroundStyle(ink.yellow) }
                        Text(Self.foldersNote).font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                }
            }
            BlockRow {
                ImageTextCount(counts: counts)
                Spacer()
                InfoMark(text: "Deletes the words read so far, after asking; they are read again at the next pass.")
                Button("Clear text index…") { confirmingClear = true }.buttonStyle(.pilotDestructive)
            }
        }
        .confirmationDialog("Clear the text index?", isPresented: $confirmingClear) {
            Button("Clear text index", role: .destructive, action: clear)
        } message: {
            Text("The words read from your images are deleted; they are read again at the next pass while Text in images is on.")
        }
    }

    /// Panels begin rather than run modal, so the tap keeps going while one is open.
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(filePath: NSHomeDirectory())
        panel.prompt = "Read"
        panel.message = "A folder whose images Files reads the words of."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            problem = withAnimation(Kit.change) { text.add(url.standardizedFileURL.path) }
        }
    }
}

/// The reader's counts on their own, so a pass's progress redraws this line and not the folder chips.
struct ImageTextCount: View {
    let counts: () -> (read: Int, waiting: Int)

    var body: some View { Text(Self.text(counts())) }

    /// "412 images read, 3 waiting".
    static func text(_ counts: (read: Int, waiting: Int)) -> String {
        let read = counts.read == 1 ? "1 image read" : "\(counts.read) images read"
        return counts.waiting == 0 ? read : "\(read), \(counts.waiting) waiting"
    }
}
