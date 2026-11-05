#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Files › Folders, design round T63 (Sven on build 7: "the folders designs is a bit too much and save design is at the
/// very bottom"): five layouts of the whole page, each drawn from Pilot's own parts (KitBlock, BlockRow, SearchBox, Chip,
/// FolderArtView) over FolderDesignsModel with real designs, at the default window (1000 × 660) inside the real window
/// frame, in Void and Porcelain, and once with the catalogue scrolled. B, which Sven picked (Q873), is the page itself
/// (T64): also at the 760 pt minimum width, searched for "pour", and in Void once its Apply has dressed the folders.
/// The moved home holds Downloads, Documents and Pictures/Screenshots (ticked, so their kinds are suggested) and a git
/// repository left out; Your designs are the 20 PNGs in `<home>/yours-src`, so the catalogue is Pilot's 66, the 20 and
/// Your own: 87. Opt-in, `PILOT_RENDER_ONLY=b` for B alone:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> PILOT_RESOURCES=Packaging swift test --filter FolderPageRenders`
extension SharedLook {
@MainActor
@Suite("Folder page renders")
struct FolderPageRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    enum Layout: String, CaseIterable { case a, b, c, d, e }
    /// How a layout is drawn: as it opens, scrolled, searched, or after Apply.
    enum Shot: String { case open = "", scrolled = "-scrolled", searched = "-search", applied = "-applied" }

    @Test("Files › Folders in five layouts, Void and Porcelain, at the default window; B at the minimum width too",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_RESOURCES"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == URL(fileURLWithPath: home).resolvingSymlinksInPath(), "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("folder-page")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fm = FileManager.default
        let homeURL = URL(fileURLWithPath: home)

        // The folders being dressed: three of known kinds, and a git repository Pilot leaves out.
        let folders = ["Downloads", "Documents", "Pictures/Screenshots"].map { homeURL.appending(path: $0, directoryHint: .isDirectory) }
        let repo = homeURL.appending(path: "Code/pilot", directoryHint: .isDirectory)
        for url in folders + [repo.appending(path: ".git", directoryHint: .isDirectory)] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }

        // Your designs: the 20 in yours-src, added once.
        let store = YourFolderDesigns(folder: homeURL.appending(path: "Your folder designs", directoryHint: .isDirectory))
        if store.list().isEmpty {
            let src = homeURL.appending(path: "yours-src", directoryHint: .isDirectory)
            let pictures = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            store.add(pictures)
        }
        #expect(FolderDesign.all.count == 66 && store.list().count == 20, "Pilot's \(FolderDesign.all.count), yours \(store.list().count)")

        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !fm.fileExists(atPath: toml) { fm.createFile(atPath: toml, contents: Data()) }
        let engine = try SharedLook.HomeRenders.engine()
        let windowModel = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: windowModel).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)

        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.style = .instrument
        let only = Self.env["PILOT_RENDER_ONLY"]?.split(separator: ",").map(String.init)

        /// The window's frame at `size` in the theme, then each shot's page drawn into it.
        func draw(_ theme: String, _ size: NSSize, _ shots: [(Layout, Shot)], model: FolderDesignsModel) async throws {
            look.themeID = theme
            AppWindowController.applyLook(look, to: window)
            window.setContentSize(size)
            windowModel.go(AppPlace(.folders))
            try await Task.sleep(for: .milliseconds(900))
            frame.layoutSubtreeIfNeeded()
            let narrow = size.width < AppWindowController.size.width ? "-\(Int(size.width))" : ""
            let chrome = try #require(snapshot(frame, scale: 2))
            try #require(chrome.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("window-\(theme)\(narrow).png"))
            let page = Self.pageRect(window: size)
            for (layout, shot) in shots where only.map({ $0.contains(layout.rawValue) }) ?? true {
                let view = Self.view(layout, model: model, shot: shot)
                    .frame(width: page.width, height: page.height)
                    .background(Theme.background)
                    .styleLayout().styled(.page(.files)).pilotTheme(look: look).environment(engine)
                let drawn = try rendered(view, wait: 0.8)
                let out = try Self.composite(chrome, drawn, at: page, window: size)
                try #require(out.representation(using: .png, properties: [:]))
                    .write(to: dir.appendingPathComponent("\(layout.rawValue)-\(theme)\(narrow)\(shot.rawValue).png"))
            }
        }

        let model = FolderDesignsModel(yours: store)
        await model.load()
        await model.add(folders + [repo])
        if let pick = FolderDesign.named("documents-pour") { model.choice = .design(pick) }
        for theme in ["void", "porcelain"] {
            let shots = Layout.allCases.flatMap { layout in (theme == "void" ? [Shot.open, .scrolled] : [.open]).map { (layout, $0) } }
            try await draw(theme, AppWindowController.size, shots + (theme == "void" ? [(.b, .searched)] : []), model: model)
            try await draw(theme, NSSize(width: AppWindowController.minSize.width, height: AppWindowController.size.height), [(.b, .open)], model: model)
        }
        // Apply, as its button runs it: the three ticked folders dressed in Documents Pour, read back.
        if only.map({ $0.contains("b") }) ?? true {
            await model.applyNow()
            #expect(model.ticked.allSatisfy { $0.look == .pilot("documents-pour") }, "\(model.said ?? "nothing said")")
            try await draw("void", AppWindowController.size, [(.b, .applied)], model: model)
        }
    }

    /// The page's place in the window under Instrument's frame: past the 72 pt rail, the list when it shows (none under
    /// 900 pt) and their rules, under the toolbar (52 pt at the window's 14/13 scale, 56) and its rule (InstrumentFrame,
    /// RailLayout).
    static func pageRect(window: NSSize) -> CGRect {
        let list = RailLayout.showsList(.files, width: window.width, searching: false) ? RailLayout.listWidth(window.width) + 1 : 0
        let x = 72 + 1 + list, top = 56.0 + 1
        return CGRect(x: x, y: top, width: window.width - x, height: window.height - top)
    }

    /// `page` drawn over `chrome` at `rect` (points from the top left), both at 2x.
    static func composite(_ chrome: NSBitmapImageRep, _ page: NSBitmapImageRep, at rect: CGRect, window: NSSize) throws -> NSBitmapImageRep {
        let w = chrome.pixelsWide, h = chrome.pixelsHigh, scale = CGFloat(w) / window.width
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        context.interpolationQuality = .high
        context.draw(try #require(chrome.cgImage), in: CGRect(x: 0, y: 0, width: w, height: h))
        let target = CGRect(x: rect.minX * scale, y: CGFloat(h) - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale)
        context.draw(try #require(page.cgImage), in: target)
        return rep
    }

    @ViewBuilder static func view(_ layout: Layout, model: FolderDesignsModel, shot: Shot) -> some View {
        let scrolled = shot == .scrolled
        switch layout {
        case .a: LayoutA(model: model, scrolled: scrolled)
        case .b: FolderDesignsView(model: model, tab: scrolled ? .kinds : nil, search: shot == .searched ? "pour" : "",
                                   anchor: scrolled ? UnitPoint(x: 0.5, y: 0.5) : .top)
        case .c: LayoutC(model: model, scrolled: scrolled)
        case .d: LayoutD(model: model, scrolled: scrolled)
        case .e: LayoutE(model: model, scrolled: scrolled)
        }
    }
}
}

// MARK: - The catalogue, as the five layouts list it

/// One design in a layout's grid.
struct T63Item: Identifiable {
    enum Art { case pilot(String), yours(NSImage?), own }
    let id: String, title: String, art: Art, on: Bool
}

/// A run of designs under one title: a suggested kind, Pilot's twelve, another kind, or Your designs.
struct T63Section: Identifiable {
    enum Role { case suggested, pilot, kind, yours }
    let id: String, title: String, role: Role, items: [T63Item]
}

@MainActor
enum T63 {
    /// T61's order: the ticked folders' kinds, Pilot's twelve, every other kind, Your designs and Your own.
    static func sections(_ model: FolderDesignsModel) -> [T63Section] {
        let suggested = model.suggested
        func items(_ designs: [FolderDesign], kind: Bool) -> [T63Item] {
            designs.map { T63Item(id: $0.id, title: kind ? FolderDesignsView.treatment($0) : $0.title, art: .pilot($0.id), on: model.choice == .design($0)) }
        }
        return suggested.map { T63Section(id: $0.id, title: "For \($0.title)", role: .suggested, items: items($0.designs, kind: true)) }
            + [T63Section(id: "pilot", title: "Pilot", role: .pilot, items: items(FolderDesign.classic, kind: false))]
            + FolderDesign.kinds.filter { !suggested.contains($0) }.map { T63Section(id: $0.id, title: $0.title, role: .kind, items: items($0.designs, kind: true)) }
            + [T63Section(id: "yours", title: "Your designs", role: .yours,
                          items: model.yours.map { T63Item(id: $0.design.id, title: $0.design.title, art: .yours($0.icon), on: model.choice.design == $0.design) }
                            + [T63Item(id: "own", title: "Your own…", art: .own, on: model.choice.isOwn)])]
    }

    static func count(_ sections: [T63Section]) -> Int { sections.reduce(0) { $0 + $1.items.count } }

    static func summary(_ model: FolderDesignsModel) -> String {
        let names = model.toDress.map(\.url.lastPathComponent)
        guard !names.isEmpty else { return "Tick the folders to dress." }
        let list = names.count <= 3 ? ListFormatter.localizedString(byJoining: names) : "\(names.count) folders"
        return "\(list) \(names.count == 1 ? "becomes" : "become") \(model.choice.design.title)."
    }
}

/// A design's art: Pilot's, one of yours, or the plus for Your own.
struct T63Art: View {
    @Environment(\.ink) private var ink
    let art: T63Item.Art

    var body: some View {
        switch art {
        case .pilot(let id): FolderArtView(id: id)
        case .yours(let image?): Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        case .yours(nil): Image(systemName: "questionmark.folder").font(ink.ui(22)).foregroundStyle(ink.muted)
        case .own: Image(systemName: "plus.rectangle.on.folder").font(ink.ui(22)).foregroundStyle(ink.muted)
        }
    }
}

/// A design to pick: its art over its name, ringed in the signal colour when picked (today's cell).
struct T63Cell: View {
    @Environment(\.ink) private var ink
    let item: T63Item
    var side: CGFloat = 52
    var named = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(9), style: .continuous)
        VStack(spacing: 3) {
            T63Art(art: item.art).frame(width: side, height: side)
            if named { Text(item.title).font(ink.ui(11)).foregroundStyle(item.on ? ink.text : ink.muted).lineLimit(1) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 5)
        .background(item.on ? ink.accent.opacity(0.12) : .clear, in: shape)
        .overlay { if item.on { shape.strokeBorder(ink.accent, lineWidth: 1.5) } }
    }
}

/// A grid of cells, `columns` across.
struct T63Grid: View {
    let items: [T63Item]
    let columns: Int
    var side: CGFloat = 52

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
            ForEach(items) { T63Cell(item: $0, side: side) }
        }
    }
}

/// A folder being dressed, one line: its tick, icon, name, where it is and what it wears.
struct T63FolderLine: View {
    @Environment(\.ink) private var ink
    let row: FolderDesignsModel.Row
    var yours: [FolderDesign]
    var path = true

    var body: some View {
        HStack(spacing: 9) {
            Toggle("", isOn: .constant(row.ticked)).toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: row.icon).resizable().interpolation(.high).frame(width: 24, height: 24)
            Text(row.url.lastPathComponent).font(ink.ui(13)).lineLimit(1)
            if path {
                Text(AppConfigs.tilde(row.url.path, home: NSHomeDirectory())).font(ink.ui(12)).foregroundStyle(ink.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if row.git {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ink.yellow)
                    Text("git, left out").foregroundStyle(ink.muted)
                }
                .font(ink.ui(11.5))
            } else if let tag = FolderDesignsView.tag(row, yours: yours) {
                Chip(text: tag)
            }
        }
    }
}

/// The ticked folders and the pick, then Reset and Apply: the act of dressing, in one line.
struct T63ApplyBar: View {
    @Environment(\.ink) private var ink
    let model: FolderDesignsModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").font(ink.ui(18)).foregroundStyle(ink.muted)
            Image(systemName: "arrow.right").font(ink.ui(11)).foregroundStyle(ink.muted)
            FolderArtView(id: model.choice.design.id).frame(width: 34, height: 34)
            Text(T63.summary(model)).font(ink.ui(12)).foregroundStyle(ink.text2).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Button("Reset \(model.toReset.count)") {}.buttonStyle(.pilot).disabled(model.toReset.isEmpty)
            Button("Apply to \(ExtensionsPageView.plural(model.toDress.count, "folder"))") {}.buttonStyle(.pilotPrimary)
        }
    }
}

/// A section's head inside a scroll: its title, count and, for Your designs, Add designs.
struct T63SectionHead: View {
    @Environment(\.ink) private var ink
    let section: T63Section
    /// What it stands on when it is pinned over a scroll; clear on a panel.
    var ground: Color? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(section.title).font(ink.ui(12, .semibold))
            Text("\(section.items.count)").font(ink.ui(11.5)).foregroundStyle(ink.muted)
            if section.role == .suggested { Text("suggested").font(ink.ui(11.5)).foregroundStyle(ink.muted) }
            Spacer()
            if section.role == .yours { Button("Add designs…") {}.buttonStyle(.pilot).controlSize(.small) }
        }
        .padding(.vertical, 6).padding(.horizontal, 4)
        .background(ground ?? .clear)
    }
}

// MARK: - A: two panes

/// A: folders and the act on the left, always in view; the whole catalogue on the right, one scroll with sticky kind heads,
/// a jump row and a search over it.
struct LayoutA: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    let model: FolderDesignsModel
    let scrolled: Bool

    var body: some View {
        let sections = T63.sections(model)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    InstrumentEyebrow(text: "Folders · \(model.ticked.count) of \(model.rows.count)")
                    Spacer()
                    Button("Add…") {}.buttonStyle(.pilot).controlSize(.small)
                }
                .frame(height: 40)
                ForEach(model.rows) { row in
                    T63FolderLine(row: row, yours: model.yours.map(\.design), path: false).frame(height: 34)
                }
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").font(ink.ui(30)).foregroundStyle(ink.muted)
                        Image(systemName: "arrow.right").font(ink.ui(12)).foregroundStyle(ink.muted)
                        FolderArtView(id: model.choice.design.id).frame(width: 72, height: 72)
                    }
                    Text(model.choice.design.title).font(ink.ui(14, .semibold))
                    Text(T63.summary(model)).font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
                    Button { } label: { Text("Apply to \(ExtensionsPageView.plural(model.toDress.count, "folder"))").frame(maxWidth: .infinity) }
                        .buttonStyle(.pilotPrimary)
                    Button { } label: { Text("Reset \(model.toReset.count)").frame(maxWidth: .infinity) }.buttonStyle(.pilot).disabled(model.toReset.isEmpty)
                }
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 14)
            .frame(width: 236)
            .background(ink.sidebar)
            InstrumentRule(vertical: true)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    SearchBox(prompt: "Search \(T63.count(sections)) designs", text: .constant(""))
                    HStack(spacing: 6) {
                        Chip(text: "For your folders", on: !scrolled)
                        Chip(text: "Pilot")
                        Chip(text: "Kinds", on: scrolled)
                        Chip(text: "Yours", count: "\(model.yours.count)")
                    }
                }
                .padding(12)
                InstrumentRule()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section { T63Grid(items: section.items, columns: 5).padding(.bottom, 8) } header: { T63SectionHead(section: section, ground: Theme.background) }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .defaultScrollAnchor(scrolled ? UnitPoint(x: 0.5, y: 0.55) : .top)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
    }
}

// MARK: - C: a list of kinds beside one kind's designs

/// C: the folders on top; under them the catalogue as a list of kinds (yours and Pilot's among them) beside the designs of
/// the one picked; the act pinned at the foot.
struct LayoutC: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    let model: FolderDesignsModel
    let scrolled: Bool

    var body: some View {
        let sections = T63.sections(model)
        let picked = scrolled ? "all" : "documents"
        let shown = scrolled ? sections : sections.filter { $0.id == picked }
        VStack(alignment: .leading, spacing: 0) {
            KitBlock(title: "Folders", symbol: "folder", trailing: {
                HStack(spacing: 10) {
                    Text("\(model.ticked.count) to dress").font(ink.ui(12)).foregroundStyle(ink.muted)
                    Button("Add folders…") {}.buttonStyle(.pilot)
                }
            }) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                    BlockRow(first: i == 0) { T63FolderLine(row: row, yours: model.yours.map(\.design)) }
                }
            }
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        InstrumentEyebrow(text: "For your folders").padding(.bottom, 4)
                        ForEach(sections.filter { $0.role == .suggested }) { kindRow($0, on: $0.id == picked, name: String($0.title.dropFirst(4))) }
                        InstrumentEyebrow(text: "Designs").padding(.top, 10).padding(.bottom, 4)
                        kindRow(T63Section(id: "all", title: "All designs", role: .kind, items: sections.flatMap(\.items)), on: picked == "all")
                        ForEach(sections.filter { $0.role == .pilot || $0.role == .yours }) { kindRow($0, on: $0.id == picked) }
                        Button { } label: { Label("Add designs…", systemImage: "plus") }.buttonStyle(.plain)
                            .font(ink.ui(12)).foregroundStyle(ink.text2).padding(.leading, 8).frame(height: 24)
                        InstrumentEyebrow(text: "Every kind").padding(.top, 10).padding(.bottom, 4)
                        ForEach(sections.filter { $0.role == .kind }) { kindRow($0, on: false) }
                    }
                    .padding(10)
                }
                .frame(width: 176)
                .defaultScrollAnchor(scrolled ? UnitPoint(x: 0.5, y: 0.4) : .top)
                InstrumentRule(vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(shown) { section in
                            T63SectionHead(section: section)
                            T63Grid(items: section.items, columns: 5, side: 50).padding(.bottom, 6)
                        }
                    }
                    .padding(10)
                }
                .defaultScrollAnchor(scrolled ? UnitPoint(x: 0.5, y: 0.55) : .top)
            }
            .styleSurface(\.card)
            .padding(.top, style.density.padding)
            .frame(maxHeight: .infinity)
            InstrumentRule().padding(.top, 10)
            T63ApplyBar(model: model).frame(height: 54)
        }
        .padding(.horizontal, style.density.page).padding(.top, 0)
    }

    private func kindRow(_ section: T63Section, on: Bool, name: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let first = section.items.first { T63Art(art: first.art).frame(width: 18, height: 18) }
            Text(name ?? section.title).font(ink.ui(12.5)).foregroundStyle(on ? ink.text : ink.text2).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(section.items.count)").font(ink.ui(11.5)).foregroundStyle(ink.muted)
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(on ? ink.selected : .clear, in: RoundedRectangle(cornerRadius: ink.radius(6), style: .continuous))
    }
}

// MARK: - D: today's page, kinds folded, the act pinned

/// D: today's page kept, but every kind not suggested (Pilot's twelve and Your designs too) folds to one line with a strip
/// of its designs, and the act is pinned to the window's foot; scrolled, it shows the folded rows down to Your designs.
struct LayoutD: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    let model: FolderDesignsModel
    let scrolled: Bool

    var body: some View {
        let sections = T63.sections(model)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    KitBlock(title: "Folders", symbol: "folder", trailing: {
                        Button("Add folders…") {}.buttonStyle(.pilot)
                    }) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                            BlockRow(first: i == 0) { T63FolderLine(row: row, yours: model.yours.map(\.design)) }
                        }
                    }
                    KitBlock(title: "Design", symbol: "paintbrush", trailing: {
                        Text("\(T63.count(sections)) designs").font(ink.ui(12)).foregroundStyle(ink.muted)
                    }) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { i, section in
                            if section.role == .suggested {
                                open(section, first: i == 0)
                            } else {
                                folded(section)
                            }
                        }
                    }
                }
                .padding(.horizontal, style.density.page).padding(.bottom, 12)
            }
            .defaultScrollAnchor(scrolled ? .bottom : .top)
            InstrumentRule()
            T63ApplyBar(model: model).padding(.horizontal, style.density.page).frame(height: 56).background(ink.sidebar)
        }
    }

    private func open(_ section: T63Section, first: Bool) -> some View {
        BlockRow(first: first) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down").font(ink.ui(10, .semibold)).foregroundStyle(ink.muted)
                    T63SectionHead(section: section)
                }
                T63Grid(items: section.items, columns: 7, side: 46).padding(.bottom, 6)
            }
        }
    }

    private func folded(_ section: T63Section) -> some View {
        BlockRow {
            Image(systemName: "chevron.right").font(ink.ui(10, .semibold)).foregroundStyle(ink.muted)
            Text(section.title).font(ink.ui(12.5, .semibold)).frame(width: 120, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(section.items.prefix(7)) { T63Art(art: $0.art).frame(width: 26, height: 26) }
                if section.items.count > 7 { Text("+\(section.items.count - 7)").font(ink.ui(11.5)).foregroundStyle(ink.muted) }
            }
            Spacer(minLength: 6)
            Text("\(section.items.count)").font(ink.ui(11.5)).foregroundStyle(ink.muted)
            if section.role == .yours { Button("Add designs…") {}.buttonStyle(.pilot).controlSize(.small) }
        }
    }
}

// MARK: - E: one pick on the page, the gallery on demand

/// E: the page holds the folders, the pick with its kind's designs beside it, and the act; the full catalogue is a gallery
/// panel with search and kind filters, opened from the page.
struct LayoutE: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    let model: FolderDesignsModel
    let scrolled: Bool

    var body: some View {
        let sections = T63.sections(model)
        let suggested = sections.filter { $0.role == .suggested }.flatMap(\.items)
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                KitBlock(title: "Folders", symbol: "folder", trailing: { Button("Add folders…") {}.buttonStyle(.pilot) }) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                        BlockRow(first: i == 0) { T63FolderLine(row: row, yours: model.yours.map(\.design)) }
                    }
                }
                KitBlock(title: "Design", symbol: "paintbrush") {
                    HStack(alignment: .top, spacing: 16) {
                        FolderArtView(id: model.choice.design.id).frame(width: 104, height: 104)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.choice.design.title).font(ink.ui(15, .semibold))
                            Text("Suggested for Downloads, Documents and Screenshots").font(ink.ui(12)).foregroundStyle(ink.muted)
                            HStack(spacing: 4) {
                                ForEach(suggested.prefix(8)) { T63Cell(item: $0, side: 40, named: false).frame(width: 50) }
                                Text("+\(max(0, suggested.count - 8))").font(ink.ui(11.5)).foregroundStyle(ink.muted)
                            }
                            HStack(spacing: 8) {
                                Button { } label: { Label("All \(T63.count(sections)) designs…", systemImage: "square.grid.3x3") }.buttonStyle(.pilot)
                                Button { } label: { Label("Your designs · \(model.yours.count)", systemImage: "person.crop.square") }.buttonStyle(.pilot)
                                Button("Add designs…") {}.buttonStyle(.pilot)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                    BlockRow { T63ApplyBar(model: model) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, style.density.page)
            if scrolled {
                Color.black.opacity(0.35)
                gallery(sections).frame(width: 640, height: 540)
            }
        }
    }

    private func gallery(_ sections: [T63Section]) -> some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(14), style: .continuous)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Folder designs").font(ink.ui(14, .semibold))
                Spacer()
                SearchBox(prompt: "Search \(T63.count(sections)) designs", text: .constant("")).frame(width: 220)
            }
            .padding(.horizontal, 14).frame(height: 50)
            HStack(spacing: 6) {
                Chip(text: "All", on: true, count: "\(T63.count(sections))")
                Chip(text: "For your folders")
                Chip(text: "Pilot")
                Chip(text: "Yours", count: "\(model.yours.count)")
                Chip(text: "Kind: Any ▾")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
            InstrumentRule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section { T63Grid(items: section.items, columns: 7, side: 50).padding(.bottom, 6) } header: { T63SectionHead(section: section, ground: Theme.background) }
                    }
                }
                .padding(.horizontal, 14)
            }
            .defaultScrollAnchor(UnitPoint(x: 0.5, y: 0.5))
            InstrumentRule()
            HStack {
                Text("Picked: \(model.choice.design.title)").font(ink.ui(12)).foregroundStyle(ink.muted)
                Spacer()
                Button("Cancel") {}.buttonStyle(.pilot)
                Button("Use this design") {}.buttonStyle(.pilotPrimary)
            }
            .padding(.horizontal, 14).frame(height: 50)
        }
        .background(Theme.background, in: shape)
        .overlay { shape.strokeBorder(ink.line2) }
        .clipShape(shape)
    }
}
#endif
