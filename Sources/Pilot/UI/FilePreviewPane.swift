import AppKit
import PilotCore
import SwiftUI
import UniformTypeIdentifiers

/// What the preview pane shows of one file (spec file-search-v2 T2), read off the main thread: its kind, size, edit date
/// and, by kind, a picture (image, PDF, video: QuickLook's), its first lines (text and code), or how many items a folder
/// holds. Image sizes and PDF page counts come from the file's header, never a full read.
struct FilePreview: Equatable, Sendable {
    enum Look: Equatable, Sendable {
        /// QuickLook draws it: an image, a PDF or a video.
        case picture
        /// The first lines of a text file.
        case lines([String])
        /// A folder and how many visible items it holds, counted up to `itemLimit`.
        case folder(Int)
        /// Anything else: Finder's icon.
        case icon
    }

    let path: String
    let name: String
    let look: Look
    /// Kind, Size, Edited, then Dimensions or Pages when the file has them: label and value.
    let facts: [Fact]

    struct Fact: Equatable, Sendable {
        let label, value: String
    }

    /// Lines a text preview shows, and the most of the file read for them.
    static let lineLimit = 14
    static let readLimit = 8192
    /// A folder's items are counted up to this many: a selection never lists all of node_modules.
    static let itemLimit = 1000

    /// None when the file is gone.
    nonisolated static func read(_ path: String, now: Date = Date()) -> FilePreview? {
        let url = URL(filePath: path)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                                             .localizedTypeDescriptionKey, .contentTypeKey])
        else { return nil }
        let type = values.contentType
        let folder = values.isDirectory == true && values.isPackage != true
        var facts = [Fact(label: "Kind", value: values.localizedTypeDescription ?? (folder ? "Folder" : "Document"))]
        if !folder, let size = values.fileSize { facts.append(Fact(label: "Size", value: RemoveList.size(Int64(size)))) }
        if let edited = values.contentModificationDate { facts.append(Fact(label: "Edited", value: Self.edited(edited, now: now))) }
        let look: Look
        if folder {
            look = .folder(Self.items(url))
        } else if let type, FileThumbnails.shows(type) {
            look = .picture
            if type.conforms(to: .image), let pixels = Self.pixels(url) { facts.append(Fact(label: "Dimensions", value: pixels)) }
            if type.conforms(to: .pdf), let pages = CGPDFDocument(url as CFURL)?.numberOfPages { facts.append(Fact(label: "Pages", value: "\(pages)")) }
        } else if let lines = Self.lines(url, type: type) {
            look = .lines(lines)
        } else {
            look = .icon
        }
        return FilePreview(path: path, name: url.lastPathComponent, look: look, facts: facts)
    }

    /// The first `lineLimit` lines of a text file, tabs as spaces; nil for a file that is not text (a NUL byte or no
    /// UTF-8 in the first `readLimit` bytes) or a known type that is not text. An extension macOS does not know (.rs,
    /// .toml) is read to see.
    nonisolated static func lines(_ url: URL, type: UTType?) -> [String]? {
        if let type, !type.isDynamic, !type.conforms(to: .text) { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: readLimit), !data.isEmpty, !data.contains(0) else { return nil }
        // A read cut inside a character loses that character, not the preview.
        guard let text = (0...3).lazy.compactMap({ String(data: data.dropLast($0), encoding: .utf8) }).first else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).prefix(lineLimit)
            .map { $0.replacingOccurrences(of: "\t", with: "    ").trimmingCharacters(in: .newlines) }
    }

    /// The visible items in a folder, its own level only, stopping at `itemLimit`.
    nonisolated static func items(_ url: URL) -> Int {
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [],
                                                         options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants])
        else { return 0 }
        var count = 0
        while count < itemLimit, items.nextObject() != nil { count += 1 }
        return count
    }

    /// "1920 × 1080" from the image's header.
    nonisolated static func pixels(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return "\(width) × \(height)"
    }

    /// "today 14:05", "yesterday 09:12", else "12 Oct 2026".
    nonisolated static func edited(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time)"
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// The preview pane (spec file-search-v2 T2): the selected file's picture, first lines or folder count over its name and
/// facts, in the menu's own type and colours. Self-contained: give it a path (nil shows nothing) and a width, and any
/// menu layout can host it; Classic hosts it beside the Files view's list. The file is read off the main thread each
/// time the path changes, and a picture is QuickLook's at the pane's width, made by `FileThumbnails.shared.make` (a fake
/// in tests).
struct FilePreviewPane: View {
    @Environment(\.style) private var style
    let path: String?

    @State private var preview: FilePreview?
    @State private var picture: NSImage?
    /// Finder's icon for the file, looked up once per selection rather than on every redraw.
    @State private var icon: NSImage?

    /// The pane's width in the menu, and its picture's side in pixels (Retina).
    static let width: CGFloat = 250
    static let pixels = 440
    /// The tallest a picture draws.
    static let pictureHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preview {
                look(preview)
                Text(preview.name).styleText(\.strong).foregroundStyle(style.color(\.text)).lineLimit(2)
                facts(preview.facts)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: path) { await load(path) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(preview.map { "Preview of \($0.name)" } ?? "No preview")
    }

    @ViewBuilder private func look(_ preview: FilePreview) -> some View {
        switch preview.look {
        case .picture:
            if let picture {
                // As wide as the pane and as tall as its shape, up to `pictureHeight`: no band above the name.
                let side = picture.size, wide = Self.width - 28
                let height = side.width > 0 ? min(Self.pictureHeight, wide * side.height / side.width) : Self.pictureHeight
                Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: style.radii.card, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: height)
            } else {
                icon(preview.path)
            }
        case .lines(let lines):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line).styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(style.color(\.well), in: RoundedRectangle(cornerRadius: style.radii.card, style: .continuous))
        case .folder(let items):
            HStack(spacing: 10) {
                icon(preview.path, side: 40)
                let more = items >= FilePreview.itemLimit ? "+" : ""
                Text(items == 1 ? "1 item" : "\(items)\(more) items").styleText(\.body).foregroundStyle(style.color(\.text2))
            }
        case .icon:
            icon(preview.path)
        }
    }

    @ViewBuilder private func icon(_ path: String, side: CGFloat = 64) -> some View {
        if let icon { Image(nsImage: icon).resizable().frame(width: side, height: side) }
    }

    private func facts(_ facts: [FilePreview.Fact]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(facts, id: \.label) { fact in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(fact.label.lowercased()).styleText(\.caption).foregroundStyle(style.color(\.text3)).frame(width: 74, alignment: .leading)
                    Text(fact.value).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    /// Arrowing through rows reads only where the selection rests: a short wait, cancelled by the next row.
    private func load(_ path: String?) async {
        picture = nil
        guard let path else { return preview = nil }
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return }
        let read = await Task.detached(priority: .userInitiated) { FilePreview.read(path) }.value
        guard !Task.isCancelled else { return }
        icon = NSWorkspace.shared.icon(forFile: path)
        preview = read
        guard read?.look == .picture, let image = await FileThumbnails.shared.make(URL(filePath: path), Self.pixels), !Task.isCancelled
        else { return }
        picture = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
}
