import AppKit
import PilotCore
import SwiftUI
import WebApps

// The workspace editor as mockup E (card agent-bo-95422980, Sven approved 2026-10-07), inline on the Workspaces page
// (WorkspaceEditorPanel, card agent-bo-95423003). Its popup over the window went with Home's board, its only opener
// (pilot-ui-redesign T6, coordinator 2026-11-19).

/// What the editor's parts share: where a render starts, the preview's spots, the picker's apps and the layouts' sizes.
enum WorkspaceEditor {
    /// Where a render or a test starts: a tile under the mouse, the picker open on a spot with words typed, the apps the
    /// picker lists (nil reads the Mac's).
    struct Start {
        var hovered: Int?
        var picking: Spot?
        var query = ""
        /// The picker row under the mouse.
        var pickerHover: Int?
        var apps: [AppChoice]?
    }

    /// A spot on the preview: a placed app's, one of the layout's empty ones or the strip where the next app goes (each
    /// adds the app, which lands in the first), or (on the page) the Add of the apps that always land on the workspace.
    enum Spot: Hashable { case app(Int), open(Int), rule }

    /// An app or a web app the picker offers; a web app shows its site.
    struct AppChoice: Hashable {
        let name: String
        let bundle: String
        var host: String?
    }

    nonisolated static let space = "workspaceEditor"
    /// How tall a layout picture is: the mockup's 52 while there is room, down to 32.
    static let pictures: ClosedRange<CGFloat> = 32...52
    /// The layouts' column: three pictures a row with their names, Main + stack the widest.
    static let layoutsWidth: CGFloat = 280
    /// The page's preview beside its layouts from this width: the layouts, the gap, the sides and a 260 pt preview, so the
    /// window's first size keeps them side by side (simplify-pages T18).
    static let pageBeside: CGFloat = layoutsWidth + 18 + 2 * 18 + 260
    /// Own sizes' name in the editor (Sven 2026-10-17: "what is own sizes"): the apps side by side at the widths you set.
    static let ownSizes = "Your widths"

    /// The Mac's apps by name, then Pilot's web apps with their sites; a web app is listed once, as a web app.
    @MainActor static func installedChoices() -> [AppChoice] {
        let web = WebAppDirectory.list().map { AppChoice(name: $0.name, bundle: $0.bundleID, host: $0.url.host) }
        let webIDs = Set(web.map(\.bundle))
        return AppsModule.pickableApps().filter { !webIDs.contains($0.bundle) }.map { AppChoice(name: $0.name, bundle: $0.bundle) } + web
    }
}

/// What the Workspaces page adds to the editor's right column: the apps that always land on the workspace (the Pilot
/// block's rules).
struct WorkspacePageExtras {
    /// The workspaces kept, which a rule can move an app to.
    let workspaces: [String]
    /// What the page calls a workspace: its name, else "Workspace 3".
    let title: (String) -> String
    /// The apps the tiler moves to the workspace whenever they open, by bundle id.
    let rules: [String]
    /// Every app that has a rule on any workspace: the picker leaves them out.
    let ruled: Set<String>
    let addRule: (String) -> Void
    let removeRule: (String) -> Void
    let moveRule: (String, String) -> Void
    /// The page's drag and the workspace shown: the preview's tiles and the rules' rows pick an app up (Sven, 2026-11-15).
    var drag: (WorkspaceDrag, workspace: String)?
}

/// The editor's parts (mockup E), inline on the Workspaces page (card agent-bo-95423003, Sven: "this should be how in
/// workspaces looks"): the workspace's number, its preset's name and
/// its key; the preview drawn as the screen, whose spots take an app or a web app; the layouts as pictures; the apps in
/// the order they open, each with At login; the workspace's two rules; Remove preset. Every change saves at once (Sven
/// 2026-10-17).
struct WorkspaceEditorPanel: View {
    @Environment(\.ink) private var ink
    typealias Spot = WorkspaceEditor.Spot
    typealias AppChoice = WorkspaceEditor.AppChoice

    let workspace: String
    let presets: WorkspacePresets
    @Binding var draft: WorkspacePresetDraft
    /// The page's front: the preview, the layouts with the rules and a preset under them, and what opens here (the rules
    /// on More until Sven's round 3 notes on build 2300, 2026-11-11).
    let extras: WorkspacePageExtras
    let remove: () -> Void
    @State private var hovered: Int?
    @State private var picking: Spot?
    @State private var query: String
    @State private var pickerHover: Int?
    @State private var choices: [AppChoice]
    private let start: WorkspaceEditor.Start
    /// Each spot's frame in the panel, for the picker to hang off.
    @State private var spots: [Spot: CGRect] = [:]
    /// The page's panel is wide enough for the right column beside the preview.
    @State private var pageWide = true

    init(workspace: String, presets: WorkspacePresets, draft: Binding<WorkspacePresetDraft>, extras: WorkspacePageExtras,
         start: WorkspaceEditor.Start = .init(),
         remove: @escaping () -> Void) {
        self.workspace = workspace
        self.presets = presets
        _draft = draft
        self.extras = extras
        self.remove = remove
        self.start = start
        _hovered = State(initialValue: start.hovered)
        _picking = State(initialValue: start.picking)
        _query = State(initialValue: start.query)
        _pickerHover = State(initialValue: start.pickerHover)
        _choices = State(initialValue: start.apps ?? [])
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                header
                ink.line.frame(height: 1)
                pageMiddle
            }
            .background(ink.surface, in: shape)
            .clipShape(shape)
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            if picking != nil { pickerLayer }
        }
        .coordinateSpace(.named(WorkspaceEditor.space))
        .task { if start.apps == nil { choices = WorkspaceEditor.installedChoices() } }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .trailing, spacing: 10) {
            headerRow
            // Narrow, the actions take their own row under the title (card agent-bo-95423182).
            if !pageWide { HStack(spacing: 8) { pageActions } }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            NumberBadge(text: workspace)
            VStack(alignment: .leading, spacing: 4) {
                // The name is the title (Sven 2026-10-17: a named workspace shows its name alone), "Workspace 3" until it has one.
                HStack(alignment: .center, spacing: 6) {
                    NameField(name: $draft.name, workspace: workspace)
                    InfoMark(text: Self.nameInfo)
                }
                // Wraps rather than cuts when the title and a long name field leave it short (760 pt window).
                Text("Pick a layout, then click the screen to put apps in it. Every change saves at once.").font(ink.ui(12)).foregroundStyle(ink.muted)
                    .lineLimit(1...2).fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if pageWide { pageActions }
            BindKey(action: "workspaces.go:\(workspace)")
        }
    }

    // MARK: Middle

    /// The page's middle: the front's preview takes the height the page gives it, the layouts down the right with the rules,
    /// and a preset under them (under 600 pt they stack, the preview 260 tall), then what opens here. The page
    /// scrolls, not the panel.
    private var pageMiddle: some View {
        VStack(alignment: .leading, spacing: 22) {
            if pageWide {
                HStack(alignment: .top, spacing: 18) {
                    previewColumn.frame(minHeight: 260, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 22) { layoutColumn; rules }.frame(width: WorkspaceEditor.layoutsWidth)
                }
            } else {
                previewColumn.frame(height: 260)
                layoutColumn
                rules
            }
            // Back on the front (Sven, 2026-11-11, after 2276): a link or the search scrolls here.
            bottom.id(AppSection.workspaceOpens)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: Bool.self) { $0.size.width >= WorkspaceEditor.pageBeside } action: { pageWide = $0 }
    }

    /// Under the layouts, where the page had room to spare (Sven's round 3 notes on build 2300, 2026-11-11; on More as
    /// Rules until then): the apps that always land here and a preset.
    private var rules: some View {
        VStack(alignment: .leading, spacing: 22) {
            RulesPart(extras: extras, picking: picking == .rule) { open(.rule) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WorkspaceEditor.space)) } action: { spots[.rule] = $0 }
            VStack(alignment: .leading, spacing: 6) {
                PartLabel(title: "From a preset", line: "a saved set of apps", info: Self.presetInfo)
                savedPresets
            }
        }
        .id(AppSection.workspaceRules)
    }

    private func open(_ spot: Spot) {
        query = ""
        pickerHover = nil
        withAnimation(Kit.change) { picking = spot }
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PartLabel(title: "Preview", line: draft.layout == nil && draft.spotWidths.count > 1 ? "drag a line between two spots to set their widths"
                                                                                                   : "click a spot to add an app, or drag one onto another to swap",
                          info: Self.previewInfo)
                if draft.layout == nil {
                    Spacer(minLength: 0)
                    spotsStepper
                }
            }
            WorkspacePreview(draft: $draft, hovered: $hovered, picking: picking, spots: $spots, open: open, drag: extras.drag?.0, workspace: workspace)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Your widths' spots, one more or one fewer: a new one halves the widest, an empty one going gives its width to the
    /// spot left of it (WorkspacePresetDraft.addSpot, removeSpot).
    private var spotsStepper: some View {
        HStack(spacing: 2) {
            Button("One spot fewer", systemImage: "minus") { withAnimation(Kit.change) { draft.removeSpot() } }
                .disabled(!draft.canRemoveSpot)
            Text("\(draft.spotWidths.count) spots").monospacedDigit().foregroundStyle(ink.text2)
            Button("One spot more", systemImage: "plus") { withAnimation(Kit.change) { draft.addSpot() } }
                .disabled(!draft.canAddSpot)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(PilotButtonStyle(ghost: true))
        .controlSize(.small)
        .font(ink.ui(11))
    }

    private var layoutColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            PartLabel(title: "Layout", line: "how the apps share the screen", info: Self.layoutInfo)
            // Three to a row, the rows sharing the height the column gets, each picture between 32 and 52 tall.
            VStack(spacing: 8) {
                ForEach(LayoutChoice.rows, id: \.self) { row in
                    HStack(spacing: 8) { ForEach(row, id: \.self, content: layoutCell) }
                }
            }
        }
    }

    private func layoutCell(_ choice: LayoutChoice) -> some View {
        LayoutPicture(choice: choice, on: draft.layout == choice.preset) {
            withAnimation(Kit.change) { draft.layout = choice.preset }
        }
    }

    private var savedPresets: some View {
        // A workspace's unnamed preset ("Workspace 3") is its own, not one to start another from.
        SavedPresets(presets: presets.contents.presets.values.filter { !WorkspacePreset.isUnnamed($0.name) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { saved in
            let row = WorkspaceLayout(preset: draft.layout, auto: draft.keepLayout)
            withAnimation(Kit.change) { draft = WorkspacePresetDraft(saved, workspace: workspace, row: row) }
        }
    }

    // MARK: Opens here and the rules

    private var bottom: some View {
        VStack(alignment: .leading, spacing: 0) {
            PartLabel(title: "Opens here", line: "drag to change the order; the first fills the first spot", info: Self.opensHereInfo)
                .padding(.bottom, 6)
            OpensHere(draft: $draft)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Toggle(isOn: $draft.openMissing) {
                        Text("Open what is missing when I switch here").font(ink.ui(13)).foregroundStyle(ink.text).lineLimit(1)
                    }
                    .toggleStyle(.pilotSwitchRow(info: Self.openMissingInfo))
                    ink.line.frame(width: 1, height: 18).padding(.horizontal, 4)
                    Button("Open now") { presets.openLayout(workspace) }
                        .buttonStyle(PilotButtonStyle(ghost: true))
                        .disabled(draft.apps.isEmpty)
                        .help(Self.openNowInfo)
                    BindKey(action: "workspaces.openLayout")
                    InfoMark(text: Self.openNowInfo)
                }
                .font(ink.ui(12))
                .frame(minHeight: 38)
                ink.line.frame(height: 1)
                Toggle(isOn: Binding(get: { draft.keepsLayout }, set: { draft.keepLayout = $0 })) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Keep this layout as windows come and go").font(ink.ui(13)).foregroundStyle(ink.text)
                        Text("today’s Auto").font(ink.ui(12)).foregroundStyle(ink.muted)
                    }
                    .lineLimit(1)
                }
                .toggleStyle(.pilotSwitchRow(info: Self.keepLayoutInfo))
                .disabled(draft.layout == nil)
                .frame(minHeight: 38)
            }
            .toggleStyle(.pilotSwitchRow)
            .padding(.horizontal, 10)
            .blockSurface()
            .padding(.top, 8)
            if draft.layout == nil {
                Text("\(WorkspaceEditor.ownSizes) keeps the widths you set, so Keep this layout stays off.")
                    .font(ink.ui(12.5)).foregroundStyle(ink.yellow)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    static let openMissingInfo = "Switching here also opens each of these apps that has no window yet, instead of only pulling in the windows already open."
    static let openNowInfo = "Opens what is missing from Opens here and puts every app in its spot, switch on or off."
    static let keepLayoutInfo = "On (the default): Pilot lays this workspace out again in this layout every time a window opens or closes on it. Off: a new window goes wherever the tiler puts it."
    static let nameInfo = "Name this workspace, e.g. Chat: the name shows instead of its number on this page and on Binds' keys. It saves when you press Return or click elsewhere."
    static let previewInfo = "This workspace as a screen. Click a spot to put an app there or swap it. With Your widths, drag the line between two spots to set how wide each is, before or after apps are in them, and − and + take a spot away or add one. Every change saves at once."
    static let layoutInfo = "How the apps share the screen. Your widths puts them side by side in spots at the widths you set: drag the lines on the preview, and each app you add takes the next spot's width. The others lay the apps out for you."
    static let opensHereInfo = "The apps this workspace opens with, in order: the first fills the first spot. At login opens that app once each time you log in."
    static let presetInfo = "A saved set of apps and a layout. Picking one fills this workspace with it; every change saves at once."

    /// The page's Remove preset and why an edit was not saved, in the header.
    @ViewBuilder private var pageActions: some View {
        problem
        removeButton
    }

    @ViewBuilder private var removeButton: some View {
        if presets.contents.preset(for: workspace) != nil {
            Button("Remove preset", action: remove).buttonStyle(PilotButtonStyle(destructive: true, ghost: true))
        }
    }

    /// A store failure, else why the draft cannot be saved as it stands.
    @ViewBuilder private var problem: some View {
        if let error = presets.lastError {
            Text(error).font(ink.ui(12)).foregroundStyle(ink.red).lineLimit(2).truncationMode(.middle)
        } else if let refusal = draft.sizesProblem {
            Text(refusal).font(ink.ui(12)).foregroundStyle(ink.yellow).lineLimit(1)
        }
    }

    // MARK: Picker

    /// The picker hung off its spot, 6 pt in and under it, or over it when the panel ends first; with room for neither,
    /// on the roomier side with its list cut to fit. A click beside it closes it.
    @ViewBuilder private var pickerLayer: some View {
        if let spot = picking, let frame = spots[spot] {
            let placed = Set(draft.apps.map(\.bundleId))
            let offered = switch spot {
            case .open: choices.filter { !placed.contains($0.bundle) }
            case .rule: choices.filter { !extras.ruled.contains($0.bundle) }
            case .app: choices
            }
            let matches = AppPicker.Matches(offered, query: query)
            // Only a placed app's picker marks the apps already here, which it trades spots with.
            let marked: Set<String> = if case .app = spot { placed } else { [] }
            GeometryReader { g in
                let natural = AppPicker.height(for: matches)
                let room = (below: g.size.height + 14 - frame.maxY - 6, above: frame.minY - 6 + 14)
                let under = natural <= room.below || (natural > room.above && room.below >= room.above)
                let height = min(natural, under ? room.below : room.above)
                ZStack(alignment: .topLeading) {
                    Color.clear.contentShape(.rect).onTapGesture { withAnimation(Kit.change) { picking = nil } }
                    AppPicker(matches: matches, height: height, placed: marked,
                              query: $query, hover: $pickerHover) { choice in
                        withAnimation(Kit.change) {
                            switch spot {
                            case .open: draft.add(bundleId: choice.bundle, name: choice.name)
                            case .app(let i): draft.replace(at: i, bundleId: choice.bundle, name: choice.name)
                            case .rule: extras.addRule(choice.bundle)
                            }
                            picking = nil
                        }
                    } close: {
                        withAnimation(Kit.change) { picking = nil }
                    }
                    .floating()
                    .offset(x: min(frame.minX + 6, g.size.width + 18 - AppPicker.width), y: under ? frame.maxY + 6 : frame.minY - 6 - height)
                    .transition(.opacity)
                }
            }
        }
    }
}

// MARK: - The page's parts

/// The apps that always land on the workspace: each with its icon, a menu moving it to another workspace or taking it
/// off; Add opens the picker.
private struct RulesPart: View {
    @Environment(\.ink) private var ink
    let extras: WorkspacePageExtras
    let picking: Bool
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PartLabel(title: "Always lands here", line: "wherever it opens",
                      info: "Apps whose windows always move to this workspace, wherever they open. Drag one onto another workspace above, or use the ⋯ menu, to move it there with its windows; the menu also takes it off.")
            VStack(spacing: 0) {
                ForEach(Array(extras.rules.enumerated()), id: \.element) { i, bundle in
                    let name = AppsModule.appName(bundle) ?? bundle
                    HStack(spacing: 8) {
                        AppLabel(name: name, bundle: bundle, size: 18)
                            .font(ink.ui(12.5)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Menu {
                            ForEach(extras.workspaces, id: \.self) { other in
                                Button("Move to \(extras.title(other))") { extras.moveRule(bundle, other) }
                            }
                            Divider()
                            Button("Take off this workspace") { extras.removeRule(bundle) }
                        } label: {
                            Image(systemName: "ellipsis").foregroundStyle(ink.muted).frame(width: 22, height: 22).contentShape(.rect)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("\(name) options")
                    }
                    .frame(minHeight: 32)
                    .overlay(alignment: .top) { if i > 0 { ink.line.frame(height: 1) } }
                    .opacity(extras.drag.map { $0.0.lifts(bundle, from: $0.workspace, .rule) } == true ? 0.35 : 1)
                    .contentShape(.rect)
                    // Dragged onto another workspace's card, the rule sends the app there.
                    .dragsInWorkspaces(extras.drag?.0) { _ in extras.drag.map { .init(kind: .rule, bundle: bundle, name: name, from: $0.workspace) } }
                }
                AddSpot(big: false, narrow: false, on: picking, open: add).frame(height: 30)
                .padding(.top, extras.rules.isEmpty ? 0 : 6)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .blockSurface()
        }
    }
}

// MARK: - Parts

/// A part's name, its one line and what it is for behind an ⓘ: "Preview  click a spot to add or swap an app ⓘ".
private struct PartLabel: View {
    @Environment(\.ink) private var ink
    let title: String
    let line: String
    var info: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Instrument's part label is its mono eyebrow (mockup A).
            InstrumentEyebrow(text: title)
            Text(line).lineLimit(1).truncationMode(.tail)
            if let info { InfoMark(text: info) }
        }
        .font(ink.ui(11)).foregroundStyle(ink.muted)
    }
}

/// The workspace's number: Instrument's mono tile.
private struct NumberBadge: View {
    @Environment(\.ink) private var ink
    let text: String

    var body: some View {
        // Instrument's: the number in mono on a raised tile, its signal kept for the live workspace.
        InstrumentAppIcon(bundle: nil, size: 34, letter: text)
    }
}

/// The workspace's name as its title, "Workspace 3" greyed until it has one: plain text in the page's own size, lined
/// up with the line under it, lit only while it is being typed in (Sven, Build 60: no box). Typing changes the field
/// alone: the name reaches the draft, and so the binds' keys, once Return is pressed or the field is left. As Finder's
/// rename (Sven, Build 62: a click elsewhere left the cursor in it): Return and a click anywhere else end it and save,
/// Esc ends it and puts the name back.
struct NameField: View {
    @Environment(\.ink) private var ink
    @Binding var name: String
    let workspace: String
    @State private var text: String
    @FocusState private var focused: Bool
    @State private var outside = ClickOutside()

    init(name: Binding<String>, workspace: String) {
        _name = name
        self.workspace = workspace
        _text = State(initialValue: Self.shown(name.wrappedValue))
    }

    /// What the field holds for a name: nothing while it is "Workspace 3" or blank.
    private static func shown(_ name: String) -> String { WorkspacePreset.isUnnamed(name) ? "" : name }

    var body: some View {
        let placeholder = WorkspacePreset.unnamed(workspace)
        ZStack(alignment: .leading) {
            // Sizes the field to its words, or the placeholder's while empty.
            Text(text.isEmpty ? placeholder : text).hidden().padding(.trailing, 4)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(ink.muted))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit(); focused = false }
                .onExitCommand { text = Self.shown(name); focused = false }
                .accessibilityLabel("Name of workspace \(workspace)")
        }
        .background(ScreenAnchor(box: outside.anchor))
        // The page's own text, not the display face: a plain field draws a display face taller than SwiftUI measures it,
        // so the outline cut the name and the line under it ran into it (Sven, Build 60).
        .font(ink.ui(15, .medium)).foregroundStyle(ink.text)
        .lineLimit(1)
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(alignment: .leading) {
            if focused { RoundedRectangle(cornerRadius: ink.radius(5), style: .continuous).fill(ink.text.opacity(0.06)).padding(-4) }
        }
        .help("Click to name this workspace")
        .onChange(of: name) { if !focused { text = Self.shown(name) } }
        .onChange(of: focused) { _, now in
            if now { outside.watch() } else { outside.stop(); commit() }
        }
        .onDisappear { outside.stop(); commit() }
    }

    private func commit() {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if typed != Self.shown(name) { name = typed }
    }

    /// While the name is typed in, a click in its window outside it takes the keyboard off it, which ends the typing; the
    /// click then lands where it was aimed. SwiftUI's buttons and text never take the keyboard, so without it the cursor
    /// stays.
    @MainActor final class ClickOutside {
        let anchor = ScreenAnchor.Box()
        private var monitor: Any?

        func watch() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.clicked(event) }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func clicked(_ event: NSEvent) {
            guard let view = anchor.view, let window = view.window, event.window === window,
                  !view.convert(view.bounds, to: nil).contains(event.locationInWindow) else { return }
            window.makeFirstResponder(nil)
        }
    }
}

/// The layout pictures' choices: the five ready layouts and own sizes (Your widths), three to a row.
private struct LayoutChoice: Hashable {
    let preset: LayoutPreset?
    var title: String { preset?.label ?? WorkspaceEditor.ownSizes }
    static let all = LayoutPreset.allCases.map { LayoutChoice(preset: $0) } + [LayoutChoice(preset: nil)]
    static let rows = stride(from: 0, to: all.count, by: 3).map { Array(all[$0..<min($0 + 3, all.count)]) }
}

/// One layout as a picture of a screen with its name under it: the picked one lit in the accent and its name bold, the
/// cell lit under the mouse.
private struct LayoutPicture: View {
    @Environment(\.ink) private var ink
    /// The space round each picture inside its cell, which From a preset's row lines up with.
    static let inset: CGFloat = 6

    let choice: LayoutChoice
    let on: Bool
    let pick: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 5) {
                MiniScreen(blocks: blocks, on: on)
                Text(choice.title).font(.system(size: 12, weight: on ? .semibold : .regular)).foregroundStyle(on ? ink.text : ink.text2)
                    .lineLimit(1)
            }
            .padding(Self.inset)
            .background(ink.text.opacity(hovered ? 0.06 : 0), in: .rect(cornerRadius: ink.radius(7)))
            .animation(Kit.change, value: hovered)
            .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .onHover { hovered = $0 }
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The picture's blocks in a unit square: a ready layout as it lays its spots (and for scrolling one more, which peeks
    /// in at the edge), own sizes three columns of their own widths.
    private var blocks: [CGRect] {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        switch choice.preset {
        case nil:
            let widths: [CGFloat] = [3, 1.2, 2], sum = widths.reduce(0, +)
            var x: CGFloat = 0
            return widths.map { w in defer { x += w / sum }; return CGRect(x: x, y: 0, width: w / sum, height: 1) }
        case let preset?:
            return preset.tiles(LayoutPreset.spots(preset) + (preset == .scrolling ? 1 : 0), in: unit)
        }
    }
}

/// A screen in miniature: its blocks 3 pt apart on the page's ground, lit when picked.
private struct MiniScreen: View {
    @Environment(\.ink) private var ink
    let blocks: [CGRect]
    let on: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(4), style: .continuous)
        GeometryReader { g in
            let area = CGRect(origin: .zero, size: g.size).insetBy(dx: -1.5, dy: -1.5)
            ForEach(blocks.indices, id: \.self) { i in
                let r = blocks[i]
                let rect = CGRect(x: area.minX + r.minX * area.width, y: area.minY + r.minY * area.height,
                                  width: r.width * area.width, height: r.height * area.height).insetBy(dx: 1.5, dy: 1.5)
                let block = RoundedRectangle(cornerRadius: ink.radius(2), style: .continuous)
                block.fill(on ? ink.accent.opacity(0.45) : ink.line2)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .padding(4)
        .frame(minHeight: WorkspaceEditor.pictures.lowerBound, maxHeight: WorkspaceEditor.pictures.upperBound)
        .background(ink.background, in: shape)
        .overlay { shape.strokeBorder(on ? ink.accent : ink.line2, lineWidth: on ? 1.5 : 1) }
        .accessibilityHidden(true)
    }
}

/// From a preset: a dashed row under the layout pictures, with the face of the next app's spot, whose menu lists the
/// saved presets; picking one starts the draft from it.
private struct SavedPresets: View {
    @Environment(\.ink) private var ink
    let presets: [WorkspacePreset]
    let pick: (WorkspacePreset) -> Void
    @State private var hovered = false

    var body: some View {
        Menu {
            ForEach(presets, id: \.name) { preset in Button(preset.name) { pick(preset) } }
        } label: {
            DashedFace(hovered: hovered) { Label("From a preset…", systemImage: "bookmark").labelStyle(.titleAndIcon).font(ink.ui(12)) }
                .frame(height: 30)
                .animation(Kit.change, value: hovered)
        }
        .menuStyle(.button).buttonStyle(.kitPress).menuIndicator(.hidden)
        .disabled(presets.isEmpty)
        .kitDimmed(!presets.isEmpty)
        .onHover { hovered = $0 && !presets.isEmpty }
        .accessibilityLabel("From a preset")
        .help(presets.isEmpty ? "No saved presets yet" : "Start from a saved preset")
    }
}

/// Opens here: the apps in the order they fill the spots, each with where it sits and its At login switch; dragging a
/// row reorders them. Empty, it says what to do first.
private struct OpensHere: View {
    @Environment(\.ink) private var ink
    @Binding var draft: WorkspacePresetDraft
    /// The row being dragged and how far.
    @State private var drag: (index: Int, offset: CGFloat)?
    private let rowHeight: CGFloat = 37

    var body: some View {
        Group {
            if draft.apps.isEmpty {
                VStack(spacing: 3) {
                    Text("Nothing placed yet").font(ink.ui(13, .semibold)).foregroundStyle(ink.text)
                    Text("Pick a layout, then click the screen to put an app in its first spot.").font(ink.ui(12)).foregroundStyle(ink.muted)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity).padding(.horizontal, 14).padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(draft.apps.enumerated()), id: \.element.bundleId) { i, app in
                        row(i, app)
                            .overlay(alignment: .top) { if i > 0 && drag?.index != i { ink.line.frame(height: 1) } }
                            .offset(y: offset(of: i))
                            .zIndex(drag?.index == i ? 1 : 0)
                    }
                }
            }
        }
        .blockSurface()
    }

    private func row(_ i: Int, _ app: WorkspacePreset.App) -> some View {
        let dragging = drag?.index == i
        let place = draft.place(of: i)
        return HStack(spacing: 10) {
            GripDots().foregroundStyle(ink.muted).frame(width: 14)
            Text("\(i + 1)").font(ink.mono(11)).foregroundStyle(ink.muted).frame(width: 16)
            AppLabel(name: app.name, bundle: app.bundleId, size: 22, symbol: "app.dashed", spacing: 10)
                .font(ink.ui(13, .medium)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.tail)
            Text(place).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            Toggle(isOn: Binding(get: { app.atLogin }, set: { draft.setAtLogin($0, at: i) })) {
                Text("At login").font(ink.ui(11.5)).foregroundStyle(ink.muted)
            }
            .toggleStyle(.pilotSwitchRow).fixedSize()
            .accessibilityLabel("Open \(app.name) at login")
        }
        .padding(.leading, 6).padding(.trailing, 10)
        .frame(height: rowHeight)
        .background {
            if dragging {
                RoundedRectangle(cornerRadius: ink.radius(6), style: .continuous).fill(ink.selected)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            }
        }
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { value in drag = (i, value.translation.height) }
            .onEnded { value in
                let target = min(max(i + Int((value.translation.height / rowHeight).rounded()), 0), draft.apps.count - 1)
                withAnimation(Kit.change) {
                    if target != i { draft.move(from: i, to: target) }
                    drag = nil
                }
            })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(i + 1). \(app.name), \(place)")
        .accessibilityAction(named: "Move up") { draft.move(from: i, to: i - 1) }
        .accessibilityAction(named: "Move down") { draft.move(from: i, to: i + 1) }
    }

    /// The dragged row follows the mouse; the rows it passes step aside by one.
    private func offset(of i: Int) -> CGFloat {
        guard let drag else { return 0 }
        if drag.index == i { return drag.offset }
        let target = drag.index + Int((drag.offset / rowHeight).rounded())
        if drag.index < i && i <= target { return -rowHeight }
        if target <= i && i < drag.index { return rowHeight }
        return 0
    }
}

/// A drag handle: two columns of three dots.
struct GripDots: View {
    var body: some View {
        Canvas { context, size in
            for column in 0..<2 {
                for row in 0..<3 {
                    let center = CGPoint(x: size.width / 2 + (CGFloat(column) - 0.5) * 5, y: size.height / 2 + CGFloat(row - 1) * 5)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 1.25, y: center.y - 1.25, width: 2.5, height: 2.5)), with: .foreground)
                }
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}
