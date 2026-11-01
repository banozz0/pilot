import AppKit
import PilotCore
import SwiftUI

/// The Folder widget's tile in the look kit (WidgetFolder), by class:
/// - Large, Sven's reference: the path bar with back and up, Places and Favourites at the left (from 460 points), the
///   list with Name, Size, Modified and Kind (Kind, then Size, leave a narrow list), and the status line.
/// - Wide: the path bar and the list with Name, Modified and Size.
/// - Square: the folder's name over a grid of its newest items' icons.
/// - Strip: the folder's name and its newest 3 items (fewer on a short strip).
/// In the list a folder's click goes into it and a file's double-click opens it; in Square and Strip a click opens either
/// (a folder in Finder, as they have no way back). Every item drags out as its file.
struct WidgetFolderView: View {
    @Environment(\.deskKit) private var kit
    @Environment(\.widgetFit) private var fit
    let model: WidgetFolderModel

    var body: some View {
        let strip = fit.size == .strip
        Group {
            switch fit.size {
            case .large: large
            case .wide: VStack(spacing: 0) { pathBar; rule; list(columns: fit.width >= 300 ? [.modified, .size] : [.modified]) }
            case .square: square
            case .strip: stripRow
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: strip ? .leading : .topLeading)
        .background(kit.veil)
        .overlay(RoundedRectangle(cornerRadius: DeskKit.radius, style: .continuous).strokeBorder(kit.edge, lineWidth: 1))
        .onChange(of: fit.size, initial: true) { model.newest = $1 == .square || $1 == .strip }
    }

    private var rule: some View { kit.edge.frame(height: 1) }

    // MARK: Large

    private var large: some View {
        VStack(spacing: 0) {
            pathBar
            rule
            HStack(spacing: 0) {
                let side = fit.width >= Self.sidebarFrom
                if side {
                    sidebar.frame(width: Self.sidebarWidth)
                    kit.edge.frame(width: 1)
                }
                list(columns: Self.columns(fit.width - (side ? Self.sidebarWidth + 1 : 0)))
            }
            rule
            HStack {
                Text(model.listing.map { $0.count == 1 ? "1 item" : "\($0.count) items" } ?? " ")
                Spacer(minLength: 8)
                if let free = model.listing?.free { Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free") }
            }
            .font(kit.mono(10)).foregroundStyle(kit.text3).lineLimit(1)
            .padding(.horizontal, 14).frame(height: 24)
        }
    }

    /// The sidebar shows from this width; the columns follow the list's own width, so a name keeps about 150 points.
    static let sidebarFrom: CGFloat = 460, sidebarWidth: CGFloat = 132

    static func columns(_ list: CGFloat) -> [Column] {
        list >= 500 ? [.size, .modified, .kind] : list >= 300 ? [.size, .modified] : [.modified]
    }

    private var sidebar: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) {
                heading("Places")
                ForEach(model.places) { place($0) }
                if !model.favourites.isEmpty {
                    heading("Favourites").padding(.top, 10)
                    ForEach(model.favourites) { place($0) }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
        }
        .scrollIndicators(.never)
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased()).font(kit.mono(9, .medium)).tracking(0.8).foregroundStyle(kit.text3)
            .padding(.horizontal, 6).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
    }

    private func place(_ place: WidgetFolderModel.Place) -> some View {
        let here = model.folder.standardizedFileURL == place.url.standardizedFileURL
        return Button { model.go(place.url) } label: {
            HStack(spacing: 7) {
                Image(systemName: place.symbol).font(.system(size: 10.5)).frame(width: 14).foregroundStyle(here ? kit.accent : kit.text2)
                Text(place.title).font(kit.mono(11)).foregroundStyle(kit.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(height: 21)
            .background { if here { RoundedRectangle(cornerRadius: 5).fill(kit.accent.opacity(0.18)) } }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(FolderListing.shown(place.url))
        .accessibilityAddTraits(here ? .isSelected : [])
    }

    // MARK: The path bar and the list

    private var pathBar: some View {
        HStack(spacing: 6) {
            bar("chevron.left", "Back", on: model.canGoBack) { model.back() }
            bar("arrow.up", "Enclosing folder", on: model.canGoUp) { model.up() }
            Text(FolderListing.shown(model.folder)).font(kit.mono(10.5)).foregroundStyle(kit.text2)
                .lineLimit(1).truncationMode(.head).padding(.leading, 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(height: 30)
    }

    private func bar(_ symbol: String, _ label: String, on: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 20).contentShape(.rect)
        }
        .buttonStyle(.plain).foregroundStyle(on ? kit.text : kit.text3.opacity(0.6)).disabled(!on)
        .help(label).accessibilityLabel(label)
    }

    enum Column { case size, modified, kind }

    private static func width(_ column: Column) -> CGFloat {
        switch column { case .size: 64; case .modified: 104; case .kind: 108 }
    }

    private func list(columns: [Column]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                header("Name", sort: .name).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns, id: \.self) { column in
                    Group {
                        switch column {
                        case .size: Text("Size").frame(maxWidth: .infinity, alignment: .trailing)
                        case .modified: header("Modified", sort: .modified).frame(maxWidth: .infinity, alignment: .leading)
                        case .kind: Text("Kind").frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(width: Self.width(column))
                }
            }
            .font(kit.mono(9.5)).foregroundStyle(kit.text3).lineLimit(1)
            .padding(.horizontal, 14).frame(height: 22)
            if let problem = model.problem {
                note(problem, symbol: "lock", finder: true)
            } else if let listing = model.listing {
                if listing.items.isEmpty {
                    note("Empty folder", symbol: "folder", finder: false)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) { ForEach(listing.items) { row($0, columns: columns) } }.padding(.horizontal, 6).padding(.bottom, 4)
                    }
                    .scrollIndicators(.automatic)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// A column's header: a click sorts by it, its mark showing the sort.
    private func header(_ title: String, sort: FolderListing.Sort) -> some View {
        Button { model.sort(by: sort) } label: {
            HStack(spacing: 3) {
                Text(title)
                if model.sort == sort { Image(systemName: sort == .name ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold)) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.sort == sort ? kit.text2 : kit.text3)
        .help(sort == .name ? "Sort by name" : "Sort by date modified, newest first")
    }

    private func row(_ item: FolderItem, columns: [Column]) -> some View {
        let picked = model.selected == item.id
        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                FolderItemIcon(item: item, side: 14)
                Text(item.name).font(kit.mono(11)).foregroundStyle(kit.text).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns, id: \.self) { column in
                Group {
                    switch column {
                    case .size: Text(FolderListing.size(item.size)).frame(maxWidth: .infinity, alignment: .trailing)
                    case .modified: Text(FolderListing.date(item.modified)).frame(maxWidth: .infinity, alignment: .leading)
                    case .kind: Text(item.kind).frame(maxWidth: .infinity, alignment: .leading).truncationMode(.tail)
                    }
                }
                .frame(width: Self.width(column))
            }
            .font(kit.mono(10)).foregroundStyle(kit.text2).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 22)
        .background {
            if picked { RoundedRectangle(cornerRadius: 5).fill(kit.accent.opacity(0.22)) }
            else if model.hovered == item { RoundedRectangle(cornerRadius: 5).fill(kit.text.opacity(0.06)) }
        }
        .contentShape(.rect)
        .modifier(FolderItemPress(item: item, model: model, inside: true))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.isFolder ? "\(item.name), folder" : "\(item.name), \(item.kind), \(FolderListing.size(item.size))")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// A quiet line in place of the list: an empty folder, or one that does not read (with Show in Finder).
    private func note(_ text: String, symbol: String, finder: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(kit.text3)
            Text(text).font(kit.sans(11.5)).foregroundStyle(kit.text2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if finder {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.folder]) }.buttonStyle(.plain)
                    .font(kit.sans(11.5, .medium)).foregroundStyle(kit.accent)
            }
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Square and Strip

    private var newestItems: [FolderItem] {
        FolderListing.sorted(model.listing?.items ?? [], by: .modified)
    }

    private var square: some View {
        let columns = max(2, Int((fit.width - 20) / 62))
        return VStack(alignment: .leading, spacing: 8) {
            DeskKitHead(title: model.title, meta: model.listing.map { "\($0.count)" })
            if let problem = model.problem {
                Text(problem).font(kit.sans(11)).foregroundStyle(kit.text2).fixedSize(horizontal: false, vertical: true)
            } else if model.listing?.items.isEmpty == true {
                Text("Empty folder").font(kit.sans(12)).foregroundStyle(kit.text2)
            } else {
                GeometryReader { box in
                    let rows = max(1, Int((box.size.height + 6) / 64))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 6) {
                        ForEach(newestItems.prefix(rows * columns)) { item in
                            VStack(spacing: 3) {
                                FolderItemIcon(item: item, side: 34, own: true)
                                Text(item.name).font(kit.sans(10)).foregroundStyle(kit.text).lineLimit(1).truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity).frame(height: 58)
                            .contentShape(.rect)
                            .modifier(FolderItemPress(item: item, model: model, inside: false))
                            .accessibilityElement(children: .ignore).accessibilityLabel(item.name)
                        }
                    }
                }
            }
        }
        .padding(.top, 12).padding(.bottom, 10).padding(.horizontal, 12)
    }

    private var stripRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(kit.text2)
                DeskKitHead(title: model.title, meta: nil)
            }
            .frame(maxWidth: 110, alignment: .leading).layoutPriority(2)
            if let problem = model.problem {
                Text(problem).font(kit.sans(11)).foregroundStyle(kit.text2).lineLimit(1)
            } else {
                // The newest 3, as many as keep about 100 points each beside the name.
                ForEach(newestItems.prefix(max(1, min(3, Int((fit.width - 140) / 100))))) { item in
                    HStack(spacing: 5) {
                        FolderItemIcon(item: item, side: 16, own: true)
                        Text(item.name).font(kit.sans(11.5)).foregroundStyle(kit.text).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: 150, alignment: .leading).layoutPriority(1)
                    .contentShape(.rect)
                    .modifier(FolderItemPress(item: item, model: model, inside: false))
                    .accessibilityElement(children: .ignore).accessibilityLabel(item.name)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// An item's presses: in the list a folder's click goes into it, a file's click picks it and its double-click opens
/// it; in Square and Strip (`inside` false) a click opens either. Each drags out as its file, tracks the pointer for
/// the desktop's right-click (WidgetFolder.sections), and has the file menu on Home's right-click.
private struct FolderItemPress: ViewModifier {
    let item: FolderItem
    let model: WidgetFolderModel
    let inside: Bool

    func body(content: Content) -> some View {
        Group {
            if inside && item.isFolder {
                content.onTapGesture { model.go(item.url) }
            } else if inside {
                content.onTapGesture(count: 2) { WidgetFolder.open(item.url) }
                    .simultaneousGesture(TapGesture().onEnded { model.selected = item.id })
            } else {
                content.onTapGesture { WidgetFolder.open(item.url) }
            }
        }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onHover { over in
            if over { model.hovered = item } else if model.hovered == item { model.hovered = nil }
        }
        .contextMenu { ForEach(WidgetFolder.actions(item), id: \.title) { action in Button(action.title, action: action.run) } }
        .help(item.name)
    }
}

/// An item's mark: an app's own icon; else, in the list, its type's glyph in the kit's ink, and in Square and Strip
/// (`own`) the icon Finder draws.
private struct FolderItemIcon: View {
    @Environment(\.deskKit) private var kit
    let item: FolderItem
    let side: CGFloat
    var own = false

    var body: some View {
        Group {
            if own || item.isApp {
                Image(nsImage: AppsModule.icon(file: item.url.path(percentEncoded: false))).resizable().interpolation(.high)
            } else {
                Image(systemName: FolderListing.symbol(item)).font(.system(size: side * 0.8))
                    .foregroundStyle(item.isFolder ? kit.accent : kit.text2)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Edit widget's Folder and Favourites (WidgetEditSheet, the Folder widget's text settings): the folder as a path with
/// Choose…, the favourites one per line, each removed by its ×, Add folder… picking more.
struct WidgetFolderField: View {
    @Environment(\.ink) private var ink
    let field: Widget.Field
    @Binding var text: String

    var body: some View {
        if field.name == WidgetFolder.favouritesName {
            let lines = WidgetFolder.Setting.lines(text)
            VStack(alignment: .leading, spacing: 4) {
                if lines.isEmpty { Text("None yet: Places always show.").font(ink.ui(11.5)).foregroundStyle(ink.muted) }
                ForEach(lines.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(ink.muted)
                        Text(lines[i]).font(ink.ui(12)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 0)
                        Button { text = lines.enumerated().filter { $0.offset != i }.map(\.element).joined(separator: "\n") } label: {
                            Image(systemName: "xmark").font(ink.ui(10, .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(ink.muted).accessibilityLabel("Remove \(lines[i])")
                    }
                }
                Button("Add folder…") {
                    let picked = Self.choose(many: true).map { FolderListing.shown($0) }.filter { !lines.contains($0) }
                    text = (lines + picked).joined(separator: "\n")
                }
                .buttonStyle(.pilot)
            }
        } else {
            HStack(spacing: 6) {
                TextField("~/Downloads", text: $text).pilotField()
                Button("Choose…") { if let url = Self.choose(many: false).first { text = FolderListing.shown(url) } }.buttonStyle(.pilot)
            }
        }
    }

    /// Folders picked in an open panel: none on Cancel.
    static func choose(many: Bool) -> [URL] {
        let panel = NSOpenPanel()
        (panel.canChooseDirectories, panel.canChooseFiles, panel.allowsMultipleSelection) = (true, false, many)
        panel.prompt = many ? "Add" : "Choose"
        panel.directoryURL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
        return panel.runModal() == .OK ? panel.urls : []
    }
}
