import AppKit
import PilotCore
import SwiftUI

/// Apps › Repos (Pilot 1.0.2, Sven Q716: "view all repos files etc from inside a pilot page with file trees and also file
/// previews"): own repos under ~/code with their branch and last commit, and a picked one's files as a tree beside a
/// preview. Read-only (Repos); a developer page, shown only while General's Developer switch is on (Q715). Everything is
/// read as the page shows and held in its own state, so nothing stays once it closes.
struct ReposPage: View {
    @Environment(\.ink) private var ink
    /// Where a render starts: a moved home read at once, a repo picked, folders open, a file previewed, a filter typed.
    struct Start {
        var home: URL?
        var repo: String?
        /// Folders open in the tree, by path inside the repo.
        var open: [String] = []
        var file: String?
        var query = ""
        /// A Markdown file shown as its source, not rendered.
        var source = false
        /// Each repo's last subject as a render shows it: a render's run loop never resumes the git read's await.
        var subjects: [String: String]?
    }

    var editor: EditorChoice = .shared
    var start = Start()
    @State private var repos: [RepoSummary] = []
    @State private var loaded = false
    @State private var picked: String?

    static let intro = "Your repos in ~/code, read-only: pick one to browse its files and preview them."
    static let introInfo = "Pilot never writes into a repo."

    init(editor: EditorChoice = .shared, start: Start = .init()) {
        self.editor = editor
        self.start = start
        _picked = State(initialValue: start.repo)
    }

    var body: some View {
        KitPage(intro: Self.intro, info: Self.introInfo) {
            if let repo = repos.first(where: { $0.name == picked }) {
                RepoBrowser(repo: repo, editor: editor, start: start) { withAnimation(Kit.change) { picked = nil } }.id(repo.name)
            } else if loaded {
                list
            }
        }
        .task(load)
    }

    private var list: some View {
        KitBlock(title: "Repos", symbol: "arrow.triangle.branch") {
            if repos.isEmpty {
                BlockRow(first: true) { FinePrint(text: "No repos in ~/code: Pilot lists each folder there with its own .git folder.") }
            }
            ForEach(repos.indices, id: \.self) { i in
                let repo = repos[i]
                BlockRow(first: i == 0) {
                    Button { withAnimation(Kit.change) { picked = repo.name } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder").font(ink.ui(14)).foregroundStyle(ink.muted).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repo.name).font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text)
                                Text(repo.subject ?? "No commits read").font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.tail)
                            }
                            Spacer(minLength: 8)
                            if let branch = repo.branch { Chip(text: branch, symbol: "arrow.triangle.branch", tag: true) }
                            Image(systemName: "chevron.right").font(ink.ui(11, .semibold)).foregroundStyle(ink.muted)
                        }
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.kitPress)
                    .accessibilityLabel([repo.name, repo.branch.map { "on \($0)" }, repo.subject].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityHint("Shows its files")
                }
            }
        }
    }

    /// The list and branches from the folders, then each repo's last subject from git, four at a time; a render's moved
    /// home is listed at once, so its first draw has the rows.
    private func load() async {
        if let home = start.home { repos = Repos.list(home: home) }
        else { repos = await Task.detached(priority: .userInitiated) { [home = ConfigsModule.home] in Repos.list(home: home) }.value }
        loaded = true
        let subjects = if let seeded = start.subjects { seeded } else { await Repos.subjects(repos) }
        for i in repos.indices { repos[i].subject = subjects[repos[i].name] }
    }
}

/// One repo: its header, a filter over its file names, the tree (a folder's children read as it opens) and the picked
/// file's preview.
private struct RepoBrowser: View {
    @Environment(\.ink) private var ink
    let repo: RepoSummary
    let editor: EditorChoice
    let start: ReposPage.Start
    let back: () -> Void

    @State private var query: String
    /// Build output and dependencies show too.
    @State private var everything = false
    @State private var ignored: Set<String> = []
    /// Each open folder's children by its path ("" the root), read as it opens.
    @State private var children: [String: [RepoEntry]] = [:]
    @State private var expanded: Set<String>
    @State private var selected: RepoEntry?
    /// The filter's walk of the repo, read once on the first letter typed.
    @State private var files: [RepoEntry]?
    @State private var capped = false
    @State private var preview: RepoPreview?
    /// A Markdown file's raw text in place of its rendering, kept as files are picked.
    @State private var source: Bool

    /// The tree and the preview's height.
    static let height: CGFloat = 620
    static let treeWidth: CGFloat = 280
    static let rowHeight: CGFloat = 24

    init(repo: RepoSummary, editor: EditorChoice, start: ReposPage.Start, back: @escaping () -> Void) {
        self.repo = repo
        self.editor = editor
        self.start = start
        self.back = back
        _query = State(initialValue: start.query)
        _source = State(initialValue: start.source)
        _expanded = State(initialValue: Set(start.open))
        _selected = State(initialValue: start.file.map {
            RepoEntry(url: repo.url.appendingPathComponent($0), path: $0, isFolder: false)
        })
    }

    private var hidden: Set<String> { everything ? [] : Repos.heavy.union(ignored) }
    private var editorName: String { AppsModule.appName(editor.app) ?? editor.app }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ink.line.frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    tools.padding(10)
                    ink.line.frame(height: 1)
                    tree
                }
                .frame(width: Self.treeWidth)
                ink.line.frame(width: 1)
                pane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: Self.height)
        }
        .blockSurface()
        .clipShape(RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous))
        .task(id: everything) { readTree() }
        .task(id: "\(everything) \(query)") { await walk() }
        .task(id: selected?.path) { await read() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Repos") }.font(ink.ui(12.5)).foregroundStyle(ink.link)
            }
            .buttonStyle(.kitPress).accessibilityLabel("Back to all repos")
            Text(repo.name).font(ink.ui(14, .semibold)).foregroundStyle(ink.text).lineLimit(1).fixedSize()
            if let branch = repo.branch { Chip(text: branch, symbol: "arrow.triangle.branch", tag: true) }
            Text(repo.subject ?? "").font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Show in Finder") { reveal(repo.url) }.buttonStyle(.pilot).fixedSize()
            Button("Open in \(editorName)") { ConfigsModule.edit(repo.url, editor: editor.app) }.buttonStyle(.pilot).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    // MARK: Tree

    private var tools: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(ink.ui(11)).foregroundStyle(ink.muted).accessibilityHidden(true)
                TextField("Filter files", text: $query, prompt: Text("Filter files").foregroundStyle(ink.muted))
                    .textFieldStyle(.plain).foregroundStyle(ink.text)
            }
            .font(ink.ui(12.5))
            .padding(.horizontal, 9).frame(height: 28)
            .background { Capsule().fill(ink.line).overlay { Capsule().fill(ink.selected).padding(1) } }
            Button { withAnimation(Kit.change) { everything.toggle() } } label: { Chip(text: "All", on: everything, tag: true) }
                .buttonStyle(.kitPress)
                .help("Show build output and dependencies too: node_modules, .build and the folders .gitignore names")
                .accessibilityLabel("Show every folder").accessibilityAddTraits(everything ? .isSelected : [])
        }
    }

    @ViewBuilder private var tree: some View {
        let typed = query.trimmingCharacters(in: .whitespaces)
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if typed.isEmpty {
                    ForEach(rows(""), id: \.entry.id) { row in self.row(row.entry, depth: row.depth) }
                } else if let files {
                    let found = Repos.filter(files, query: typed)
                    if found.isEmpty { FinePrint(text: "No file name holds “\(typed)”.").padding(10) }
                    ForEach(found) { self.row($0, depth: 0, showsPath: true) }
                    if capped { FinePrint(text: "Searched the first \(Repos.filterCap) files.").padding(10) }
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// The open folders' rows under `path`, depth first.
    private func rows(_ path: String, depth: Int = 0) -> [(entry: RepoEntry, depth: Int)] {
        (children[path] ?? []).flatMap { entry in
            [(entry, depth)] + (entry.isFolder && expanded.contains(entry.path) ? rows(entry.path, depth: depth + 1) : [])
        }
    }

    private func row(_ entry: RepoEntry, depth: Int, showsPath: Bool = false) -> some View {
        let open = expanded.contains(entry.path), picked = selected?.path == entry.path
        return Button { tap(entry) } label: {
            HStack(spacing: 5) {
                Group {
                    if entry.isFolder { Image(systemName: open ? "chevron.down" : "chevron.right") } else { Color.clear }
                }
                .font(ink.ui(9, .semibold)).foregroundStyle(ink.muted).frame(width: 10)
                Image(systemName: entry.isFolder ? "folder" : "doc.text").font(ink.ui(11.5)).foregroundStyle(entry.isFolder ? ink.accentInk : ink.muted)
                    .frame(width: 16)
                Text(showsPath ? entry.path : entry.name).font(ink.ui(12.5)).foregroundStyle(ink.text).lineLimit(1)
                    .truncationMode(showsPath ? .head : .tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10 + CGFloat(depth) * 14).padding(.trailing, 8)
            .frame(height: Self.rowHeight)
            .background(picked ? ink.selected : .clear, in: .rect(cornerRadius: ink.radius(5), style: .continuous))
            .padding(.horizontal, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { actions(entry) }
        .accessibilityLabel(entry.isFolder ? "\(entry.path), folder, \(open ? "open" : "closed")" : entry.path)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    @ViewBuilder private func actions(_ entry: RepoEntry) -> some View {
        Button("Show in Finder") { reveal(entry.url) }
        Button("Open in \(editorName)") { ConfigsModule.edit(entry.url, editor: editor.app) }
        Button("Copy path") { SystemModule.copy(entry.url.path, tip: "Copied the path") }
        if entry.isFolder { Button("Open as gallery") { GalleryWindow.shared.open(entry.url) } }
    }

    /// A folder opens or closes, its children read off the main thread the first time (the tap runs there); a file shows
    /// in the preview.
    private func tap(_ entry: RepoEntry) {
        guard entry.isFolder else { selected = entry; return }
        guard expanded.remove(entry.path) == nil else { return }
        guard children[entry.path] == nil else { expanded.insert(entry.path); return }
        let root = repo.url, hidden = hidden
        Task {
            children[entry.path] = await Task.detached(priority: .userInitiated) { Repos.children(of: entry.url, in: root, hidden: hidden) }.value
            expanded.insert(entry.path)
        }
    }

    /// The root and every open folder, again: the first draw, and All turned on or off.
    private func readTree() {
        ignored = Repos.ignored(repo.url)
        let hidden = everything ? [] : Repos.heavy.union(ignored)
        var read: [String: [RepoEntry]] = ["": Repos.children(of: repo.url, in: repo.url, hidden: hidden)]
        for path in expanded { read[path] = Repos.children(of: repo.url.appendingPathComponent(path), in: repo.url, hidden: hidden) }
        children = read
        files = nil
    }

    /// The filter's files, walked off the main thread once a letter is typed, and again after All changes; a render's at once.
    private func walk() async {
        guard files == nil, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let url = repo.url, hidden = hidden
        let walked = start.home != nil ? Repos.files(in: url, hidden: hidden)
            : await Task.detached(priority: .userInitiated) { Repos.files(in: url, hidden: hidden) }.value
        (files, capped) = (walked.files, walked.capped)
    }

    // MARK: Preview

    @ViewBuilder private var pane: some View {
        if let selected {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(selected.path).font(ink.mono(11.5)).foregroundStyle(ink.text2).lineLimit(1).truncationMode(.head).help(selected.path)
                    Spacer(minLength: 8)
                    if case .markdown = preview { MarkdownModeToggle(source: $source).padding(.trailing, 4) }
                    PaneButton(symbol: "folder", label: "Show in Finder") { reveal(selected.url) }
                    PaneButton(symbol: "arrow.up.forward.square", label: "Open in \(editorName)") { ConfigsModule.edit(selected.url, editor: editor.app) }
                    PaneButton(symbol: "doc.on.doc", label: "Copy path") { SystemModule.copy(selected.url.path, tip: "Copied the path") }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                ink.line.frame(height: 1)
                content(selected).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 4) {
                Text("Pick a file").font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text)
                Text("Its text, Markdown, picture or PDF shows here.").font(ink.ui(12)).foregroundStyle(ink.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func content(_ file: RepoEntry) -> some View {
        switch preview {
        case .text(let lines): CodeLines(lines: lines)
        case .markdown(let text):
            MarkdownPreview(text: text, file: file.url, root: repo.url, showsSource: $source) { CodeLines(lines: Repos.lines(text)) }
        case .quickLook: QuickLookView(url: file.url).id(file.url)
        case .large(let size): note("A large file (\(RemoveList.size(size)))", "Pilot shows files up to \(RemoveList.size(Repos.textCap)); open it in \(editorName).")
        case .binary: note("Not a text file", "Pilot previews text, Markdown, pictures and PDFs; open it in \(editorName).")
        case .unreadable(let why): note("Could not read it", why)
        case nil: EmptyView()
        }
    }

    private func note(_ title: String, _ line: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text)
            Text(line).font(ink.ui(12)).foregroundStyle(ink.muted).multilineTextAlignment(.center)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The picked file, read off the main thread; a render's at once.
    private func read() async {
        preview = nil
        guard let url = selected?.url else { return }
        preview = start.home != nil ? Repos.preview(url) : await Task.detached(priority: .userInitiated) { Repos.preview(url) }.value
    }

    private func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

/// A text file's lines in the mono face with their numbers, scrolled both ways; only the lines on screen are laid out.
private struct CodeLines: View {
    @Environment(\.ink) private var ink
    let lines: [String]
    /// 11.5 pt mono at 1.6.
    private static let line: CGFloat = 18.4

    var body: some View {
        let digits = CGFloat(String(lines.count).count)
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { i in
                    HStack(spacing: 14) {
                        Text("\(i + 1)").foregroundStyle(ink.muted.opacity(0.6)).frame(width: max(24, digits * 7.5), alignment: .trailing)
                        Text(lines[i]).foregroundStyle(ink.text2).fixedSize()
                    }
                    .frame(height: Self.line)
                }
            }
            .font(ink.mono(11.5))
            .padding(.vertical, 10).padding(.horizontal, 12)
            .textSelection(.enabled)
        }
        .accessibilityLabel("\(lines.count) lines")
    }
}

/// A 26 pt icon button over the preview, lit under the mouse.
private struct PaneButton: View {
    @Environment(\.ink) private var ink
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(ink.ui(13)).foregroundStyle(over ? ink.text : ink.muted)
                .frame(width: 26, height: 26)
                .background(over ? ink.text.opacity(0.08) : .clear, in: .rect(cornerRadius: ink.radius(6), style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .help(label).accessibilityLabel(label)
        .onHover { over = $0 }
    }
}
