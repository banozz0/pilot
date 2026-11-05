import AppKit
import Observation
import PilotCore
import SwiftUI

/// Tools › Captures › History (P73, after Snapzy's history): every capture and recording as a tile with its thumbnail,
/// the app it came from, its date and size, searchable by name or app and filtered by kind. A click opens a capture in
/// the editor (a recording in the video editor, P71); each tile's hover and right-click hold Edit, Copy, Show in Finder and Move to
/// the Trash. Picking two or more captures (the tile's circle, or ⌘-click) offers Combine: side by side or stacked, with
/// a gap, opened in the editor, whose Done saves it as a new capture. Keep sets the size cap.
struct CaptureHistoryPage: View {
    @Environment(\.ink) private var ink
    @Bindable var store: CaptureHistoryStore
    @State private var entries: [CaptureHistory.Entry] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var filter: CaptureHistory.Filter = .all
    /// Captures picked for Combine, in the order picked: the first sets the height or width.
    @State private var picked: [URL] = []
    @State private var direction: CombineLayout.Direction = .sideBySide
    @State private var gap = 16
    @State private var hovered: String?
    @State private var thumbnails = HistoryThumbnails()

    init(store: CaptureHistoryStore = .shared) { self.store = store }

    static let note = "Every capture and recording in Pilot's folders, on this Mac only. ⌘-click or the circle picks captures to combine."

    enum Info {
        static let cap = "Past the cap, Pilot's oldest captures and recordings go to the Trash: only files named as Pilot names them, or saved by Pilot."
    }

    var body: some View {
        KitPage {
            KitBlock(title: "History", symbol: "clock.arrow.circlepath", note: Self.note) {
                BlockRow(first: true) {
                    SearchBox(prompt: "Search by name or app", text: $query).frame(maxWidth: .infinity)
                    Segments(selection: $filter, options: [(.all, "All"), (.captures, "Captures"), (.recordings, "Recordings")], label: "Kind")
                }
                if !picked.isEmpty { BlockRow { combineBar } }
                BlockRow { list }
            }
            KitBlock(title: "Keep", symbol: "internaldrive") {
                BlockRow(first: true) {
                    HStack(spacing: 6) {
                        TitledText(title: Text("Size cap"), detail: used)
                        InfoMark(text: Info.cap)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("Size cap", selection: $store.capGB) {
                        ForEach(CaptureHistory.caps, id: \.self) { Text($0 == 0 ? "Keep everything" : "\($0) GB").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
        .task(id: store.revision) {
            entries = await store.entries()
            loaded = true
            let there = Set(entries.map(\.url))
            picked.removeAll { !there.contains($0) }
        }
    }

    private var used: String {
        let bytes = CaptureHistory.used(entries)
        return bytes == 0 ? "Pilot has saved nothing yet" : "Pilot's captures and recordings take \(Self.bytes(bytes))"
    }

    private var shown: [CaptureHistory.Entry] { CaptureHistory.matching(entries, query: query, filter: filter) }

    @ViewBuilder private var list: some View {
        let shown = shown
        if !loaded {
            FinePrint(text: "Reading the folders…").frame(maxWidth: .infinity, alignment: .leading)
        } else if shown.isEmpty {
            FinePrint(text: entries.isEmpty ? "Nothing captured yet." : "Nothing matches.").frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12, alignment: .top)], spacing: 14) {
                ForEach(shown) { tile($0) }
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: Tile

    private func tile(_ e: CaptureHistory.Entry) -> some View {
        let on = picked.contains(e.url), hover = hovered == e.id
        let shape = RoundedRectangle(cornerRadius: ink.radius(8), style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            ZStack {
                ink.raised
                if let image = thumbnails.image(e.url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: e.kind == .capture ? "photo" : "film").font(ink.ui(20)).foregroundStyle(ink.muted)
                }
            }
            .frame(height: 104).frame(maxWidth: .infinity)
            .clipShape(shape)
            .overlay { shape.strokeBorder(on ? ink.accent : ink.line, lineWidth: on ? 2 : 1) }
            .contentShape(shape)
            .onTapGesture { if NSEvent.modifierFlags.contains(.command) { pick(e) } else { open(e) } }
            .overlay(alignment: .bottomLeading) { if e.kind == .recording { badge } }
            .overlay(alignment: .topLeading) { if e.kind == .capture, on || hover { pickMark(e, on: on) } }
            .overlay(alignment: .topTrailing) { if hover { actions(e) } }
            Text(e.app ?? e.kind.word).font(ink.ui(12, .medium)).foregroundStyle(ink.text).lineLimit(1)
            Text("\(e.date.formatted(date: .abbreviated, time: .shortened)) · \(Self.bytes(e.bytes))")
                .font(ink.ui(11)).foregroundStyle(ink.muted).lineLimit(1)
        }
        .onHover { hovered = $0 ? e.id : (hovered == e.id ? nil : hovered) }
        .help(e.url.lastPathComponent)
        .contextMenu {
            Button(e.kind == .capture ? "Open in Editor" : "Edit Video…") { open(e) }
            Button("Copy") { copy(e) }
            Button("Show in Finder") { reveal(e) }
            if e.kind == .capture { Button(on ? "Unpick" : "Pick to Combine") { pick(e) } }
            Divider()
            Button("Move to Trash", role: .destructive) { trash(e) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(e.kind.word) from \(e.app ?? "an unknown app"), \(e.date.formatted())")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var badge: some View {
        Image(systemName: "film").font(ink.ui(10, .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.55), in: Capsule()).padding(6)
            .accessibilityHidden(true)
    }

    private func pickMark(_ e: CaptureHistory.Entry, on: Bool) -> some View {
        Button { pick(e) } label: {
            ZStack {
                Circle().fill(on ? ink.accent : Color.black.opacity(0.35))
                Circle().strokeBorder(.white, lineWidth: 1.5)
                if let n = picked.firstIndex(of: e.url) { Text("\(n + 1)").font(ink.ui(10, .bold)).foregroundStyle(ink.onAccent) }
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain).padding(6).help(on ? "Unpick" : "Pick to combine")
        .accessibilityLabel(on ? "Unpick" : "Pick to combine")
    }

    private func actions(_ e: CaptureHistory.Entry) -> some View {
        HStack(spacing: 2) {
            action("pencil", "Edit") { open(e) }
            action("doc.on.doc", "Copy") { copy(e) }
            action("folder", "Show in Finder") { reveal(e) }
            action("trash", "Move to Trash") { trash(e) }
        }
        .padding(3).background(.black.opacity(0.55), in: Capsule()).padding(6)
    }

    private func action(_ symbol: String, _ title: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: symbol).font(ink.ui(11, .semibold)).foregroundStyle(.white).frame(width: 22, height: 20) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    // MARK: Combine

    private var combineBar: some View {
        HStack(spacing: 10) {
            Text(picked.count == 1 ? "1 picked: pick one more" : "\(picked.count) picked").foregroundStyle(ink.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Segments(selection: $direction, options: CombineLayout.Direction.allCases.map { ($0, $0.title) }, label: "Layout")
            Picker("Gap", selection: $gap) {
                ForEach([0, 8, 16, 32, 64], id: \.self) { Text($0 == 0 ? "No gap" : "\($0) pt gap").tag($0) }
            }
            .labelsHidden().fixedSize()
            Button("Clear") { picked = [] }.buttonStyle(.pilot)
            Button("Combine") { combine() }.buttonStyle(.pilotPrimary).disabled(picked.count < 2)
        }
    }

    private func combine() {
        let urls = picked, direction = direction, gap = CGFloat(gap)
        Task { @MainActor in
            guard let (image, scale) = await CaptureCombine.combine(urls, direction: direction, gap: gap) else {
                return HUD.tip("Those captures could not be combined.")
            }
            picked = []
            CaptureEditor.show(image, scale: scale, file: nil, capture: .shared)
        }
    }

    // MARK: Actions

    private func pick(_ e: CaptureHistory.Entry) {
        guard e.kind == .capture else { return }
        if let i = picked.firstIndex(of: e.url) { picked.remove(at: i) } else { picked.append(e.url) }
    }

    private func open(_ e: CaptureHistory.Entry) {
        if e.kind == .capture { CapturesModule.edit(e.url.path(percentEncoded: false)) } else { VideoEditor.open(e.url) }
    }

    /// A recording goes with its pointer drawn in when it kept it out (Q821), under a progress tip while that is made.
    private func copy(_ e: CaptureHistory.Entry) {
        RecordingHandout.handOut([e.url]) { files in
            Task { @MainActor in
                await CaptureHistoryStore.copy(e, file: files.first ?? e.url)
                HUD.tip("Copied \(e.kind == .capture ? "the capture" : "the recording").")
            }
        }
    }

    private func reveal(_ e: CaptureHistory.Entry) { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }

    private func trash(_ e: CaptureHistory.Entry) {
        Task { @MainActor in
            let moved = await store.trash([e.url])
            HUD.tip(moved == 1 ? "Moved to the Trash." : "That file could not be moved to the Trash.")
        }
    }

    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}

/// The History tiles' pictures: QuickLook thumbnails at 336 pixels (a 168-point tile on Retina), made as a tile draws,
/// at most `limit` kept, oldest out first. The page's own, so it ends with the page.
@Observable @MainActor
final class HistoryThumbnails {
    static let limit = 240
    static let pixels = 336

    private var made: [URL: NSImage] = [:]
    @ObservationIgnored private var order: [URL] = []
    @ObservationIgnored private var asked: Set<URL> = []

    func image(_ url: URL) -> NSImage? {
        if let image = made[url] { return image }
        guard !asked.contains(url) else { return nil }
        asked.insert(url)
        Task { [weak self] in
            guard let image = await FileThumbnails.quickLook(url, Self.pixels) else { return }
            self?.keep(url, NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)))
        }
        return nil
    }

    private func keep(_ url: URL, _ image: NSImage) {
        made[url] = image
        order.append(url)
        while order.count > Self.limit {
            let old = order.removeFirst()
            made[old] = nil
            asked.remove(old)
        }
    }
}
