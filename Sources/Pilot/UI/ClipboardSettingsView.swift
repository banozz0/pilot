import AppKit
import Clipboard
import SwiftUI
import UniformTypeIdentifiers

/// Clipboard (story 89; on the kit, card agent-bo-95422898, design round 4 section 7): how long to keep and the apps
/// never recorded, what Return does, the sort, the tags and the bind, then the newest copies with the app each came from
/// and Clear history. Nothing folds (card agent-bo-95423004; Sven, 2026-10-07: "dont leave half empty").
struct ClipboardSettingsView: View {
    @Environment(\.ink) private var ink
    let history: ClipboardHistory
    @State private var settings: ClipboardSettings
    @State private var tags: [ClipTag]
    @State private var confirmingClear = false

    private static let dayChoices: [Int?] = [1, 7, 30, 90, 365, nil]

    init(history: ClipboardHistory = .shared) {
        self.history = history
        _settings = State(initialValue: history.settings)
        _tags = State(initialValue: history.tags())
    }

    static let intro = "What you copy is kept here; passwords never are."

    var body: some View {
        let kept = history.recent()
        KitPage(intro: Self.intro) {
            if ink.isInstrument {
                // Instrument's two columns, rows ending level.
                InstrumentPair { keepBlock } right: { neverBlock }
                InstrumentPair {
                    KitBlock(title: "In the panel", symbol: "doc.on.clipboard", fill: true) { panel }
                } right: {
                    KitBlock(title: "Tags", symbol: "tag", fill: true) { tagRows }
                }
            } else {
                keepBlock
                neverBlock
                KitBlock(title: "In the panel", symbol: "doc.on.clipboard") { panel }
                KitBlock(title: "Tags", symbol: "tag") { tagRows }
            }
            KitBlock(title: "Recent", symbol: "clock") {
                Text(kept.isEmpty ? "" : "\(kept.count) kept").font(ink.mono(11.5)).foregroundStyle(ink.muted)
            } content: { recent(kept.prefix(20)) }
            clear.padding(.top, 16)
        }
        // A sort changed in the panel while this page is open: take it, so a later edit here does not undo it.
        .onChange(of: history.settings.order) { settings.order = history.settings.order }
        .onChange(of: settings) {
            if settings.keepCount < 1 { settings.keepCount = 1; return }
            history.apply(settings)
        }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmingClear) {
            Button("Clear history", role: .destructive) { history.clear() }
        } message: {
            Text("Every item goes except the pinned ones.")
        }
    }

    // MARK: Kept

    private var keepBlock: some View {
        KitBlock(title: "Keep", symbol: "clock.arrow.circlepath", focused: true, fill: true) { keep }
    }

    private var neverBlock: some View {
        KitBlock(title: "Never record from", symbol: "nosign", fill: true) {
            Text("\(settings.ignoredApps.count)").font(ink.mono(11)).foregroundStyle(ink.muted)
        } content: {
            never
        }
    }

    @ViewBuilder private var keep: some View {
        BlockRow(first: true) {
            Text("Keep the last")
            InfoMark(text: "Older items are deleted; pinned ones stay and never count.")
            Spacer()
            TextField("Items", value: $settings.keepCount, format: .number).labelsHidden()
                .multilineTextAlignment(.trailing).font(ink.mono(12)).pilotField().frame(width: 70)
            Text("items, for").foregroundStyle(ink.muted)
            Picker("Days", selection: $settings.keepDays) {
                ForEach(Self.dayChoices, id: \.self) { Text(Self.label(days: $0)).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
        BlockRow { Toggle("Save images", isOn: $settings.saveImages).toggleStyle(.pilotSwitchRow(info: "Off, a copied picture is left out of the history; text and files are still kept.")) }
        // SPEC.md: a password manager's copies are never kept, so this is no switch.
        BlockRow {
            Text("Skip passwords")
            InfoMark(text: "Anything an app marks as secret is never stored.")
            Spacer()
            Chip(text: "always", color: ink.green)
        }
    }

    @ViewBuilder private var never: some View {
        ForEach(Array(settings.ignoredApps.enumerated()), id: \.element) { i, id in
            let name = AppsModule.appName(id) ?? id
            BlockRow(first: i == 0) {
                AppLabel(name: name, bundle: id, size: 18).lineLimit(1)
                Spacer()
                Button { settings.ignoredApps.removeAll { $0 == id } } label: { Image(systemName: "xmark").font(ink.ui(10, .bold)) }
                    .buttonStyle(.plain).foregroundStyle(ink.muted).accessibilityLabel("Remove \(name)")
            }
        }
        BlockRow(first: settings.ignoredApps.isEmpty) {
            if settings.ignoredApps.isEmpty { Text("Every app is recorded").foregroundStyle(ink.muted) }
            Spacer()
            InfoMark(text: "What you copy in an app on this list is never kept, as for a password manager.")
            Button("Add app…", action: addApps).buttonStyle(.pilot)
        }
    }

    // MARK: More

    @ViewBuilder private var panel: some View {
        BlockRow(first: true) {
            Text("Return")
            InfoMark(text: "What Return does in the panel; ⌘Return does the other.")
            Spacer()
            Segments(selection: $settings.returnAction, options: [(.paste, "Paste"), (.copy, "Copy only")], label: "Return in the panel")
        }
        // Card agent-bo-95422783: ⌘S and ⇧⌘S in the panel change it too.
        BlockRow {
            Text("Sort by")
            InfoMark(text: "The order the panel lists items in; ⌘S and ⇧⌘S change it there too.")
            Spacer()
            Picker("Sort by", selection: $settings.order.sort) {
                ForEach(ClipSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            Text("Reversed").foregroundStyle(ink.text2)
            Toggle("Reversed", isOn: $settings.order.reversed).toggleStyle(.pilotSwitch)
        }
        // Changed on the Binds screen.
        BlockRow {
            Text("Open with")
            InfoMark(text: "The key that opens the clipboard panel; change it on Binds.")
            Spacer()
            BindKey(action: "apps.clipboard")
        }
    }

    // Card agent-bo-95422782: made in the panel with ⌘T, renamed, recoloured and deleted here.
    @ViewBuilder private var tagRows: some View {
        if tags.isEmpty {
            BlockRow(first: true) { Text("No tags yet. In the panel, ⌘T tags the item.").foregroundStyle(ink.muted) }
        }
        ForEach($tags, id: \.id) { $tag in
            BlockRow(first: tag.id == tags.first?.id) {
                Menu {
                    ForEach(0..<ClipTag.colours, id: \.self) { index in
                        Button { tag.colour = index; history.editTag(tag) } label: {
                            Label("Colour \(index + 1)", systemImage: "circle.fill").foregroundStyle(ink.tag(index))
                        }
                    }
                } label: { Circle().fill(ink.tag(tag.colour)).frame(width: 12, height: 12) }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .accessibilityLabel("Colour of \(tag.name)")
                TextField("Name", text: $tag.name).labelsHidden().pilotField()
                    .onChange(of: tag.name) { if !ClipTag.name(tag.name).isEmpty { history.editTag(tag) } }
                    // Return shows the name as stored (spaces as dashes).
                    .onSubmit { tags = history.tags() }
                Button("Delete") {
                    history.deleteTag(tag.id)
                    tags = history.tags()
                }
                .buttonStyle(.pilot)
            }
        }
    }

    // MARK: Recent

    /// The newest copies as cards: the app each came from (its own icon), what it is, and when.
    @ViewBuilder private func recent(_ clips: ArraySlice<StoredClip>) -> some View {
        if clips.isEmpty {
            EmptyState(title: "Nothing copied yet", line: "What you copy shows here, newest first, with the app it came from.").padding(.vertical, 8)
        } else {
            CardGrid(minimum: 240, spacing: 8, stretch: true) {
                ForEach(clips, id: \.id) { clip in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            AppGlyph(bundles: clip.sourceApp.map { [$0] } ?? [], symbol: clip.kind.symbol, colour: .neutral, size: 20)
                            Text(clip.sourceApp.flatMap(AppsModule.appName) ?? clip.kind.label).foregroundStyle(ink.text2).lineLimit(1)
                            Image(systemName: clip.kind.symbol).font(ink.ui(10)).help(clip.kind.label)
                            if clip.pinned { Image(systemName: "pin.fill").font(ink.ui(9)).foregroundStyle(ink.mark(ink.accentInk)) }
                            Spacer(minLength: 4)
                            Text(Self.ago(clip.copiedAt)).lineLimit(1)
                        }
                        .font(ink.ui(11)).foregroundStyle(ink.muted)
                        Text(clip.title.trimmingCharacters(in: .whitespacesAndNewlines)).font(ink.ui(12.5)).foregroundStyle(ink.text)
                            .lineLimit(4).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 96, alignment: .top)
                    .padding(10)
                    .innerCard()
                }
            }
            .padding(.vertical, 10)
        }
    }

    private static let agoFormat: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static func ago(_ date: Date) -> String { agoFormat.localizedString(for: date, relativeTo: Date()) }

    private var clear: some View {
        HStack {
            Spacer()
            InfoMark(text: "Deletes every item but the pinned ones, after asking.")
            Button("Clear history…") { confirmingClear = true }.buttonStyle(.pilotDestructive)
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for id in panel.urls.compactMap({ Bundle(url: $0)?.bundleIdentifier }) where !settings.ignoredApps.contains(id) {
            settings.ignoredApps.append(id)
        }
    }

    private static func label(days: Int?) -> String {
        switch days {
        case nil: "ever"
        case 1: "1 day"
        case 365: "1 year"
        case let n?: "\(n) days"
        }
    }
}
