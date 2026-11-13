import AppKit
import PilotCore
import SwiftUI
import WebApps

// The workspace editor as mockup E (card agent-bo-95422980, Sven approved 2026-10-07): a popup inside Pilot's window,
// about three quarters of it, over a dimmed page. Right-click a workspace on Home to open it; the Workspaces page shows
// the same editor inline (WorkspaceEditorPanel, card agent-bo-95423003).

/// The workspace the popup edits; `start` is where a render begins (the app never sets it). Each open is its own, so a
/// popup opened again on the same workspace starts fresh.
struct EditedWorkspace: Identifiable {
    let name: String
    var start = WorkspaceEditor.Start()
    let id = UUID()
}

private struct EditWorkspaceKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable (String) -> Void)? = nil }

extension EnvironmentValues {
    /// Opens the editor popup on a workspace: the app window sets it; nil elsewhere, where a right-click offers nothing.
    var editWorkspace: (@MainActor @Sendable (String) -> Void)? {
        get { self[EditWorkspaceKey.self] }
        set { self[EditWorkspaceKey.self] = newValue }
    }
}

extension View {
    /// Right-click → Edit workspace N…, which opens the editor popup over the window.
    func editsWorkspace(_ name: String) -> some View { modifier(EditsWorkspace(name: name)) }
}

private struct EditsWorkspace: ViewModifier {
    @Environment(\.editWorkspace) private var edit
    let name: String

    func body(content: Content) -> some View {
        content.contextMenu { if let edit { Button("Edit workspace \(name)…") { edit(name) } } }
    }
}

/// The popup over the whole window: the page dimmed under a scrim that cancels on a click, the editor centred on it.
struct WorkspacePopup: View {
    @Environment(Engine.self) private var engine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let edited: EditedWorkspace
    let close: () -> Void
    /// The height the editor's parts take with the preview at its least.
    @State private var ideal: CGFloat = 0

    /// Three quarters of each side, wider when the window is narrow (at least 680) and taller when the parts need it
    /// (`ideal`), while the window keeps 24 pt of scrim at each side and 20 above and below; past that the editor scrolls.
    static func size(in window: CGSize, ideal: CGFloat = 0) -> CGSize {
        CGSize(width: min(window.width - 48, max(window.width * 0.75, 680)), height: min(window.height - 40, max(window.height * 0.75, ideal)))
    }

    var body: some View {
        GeometryReader { g in
            let size = Self.size(in: g.size, ideal: ideal)
            ZStack {
                Color.black.opacity(0.42).contentShape(.rect).onTapGesture(perform: close).accessibilityHidden(true)
                WorkspaceEditor(workspace: edited.name, presets: engine.presets, layouts: engine.layouts, start: edited.start,
                                close: close) { ideal = $0 }
                    .floating()
                    .frame(width: size.width, height: size.height)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: Kit.pressScale)))
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .accessibilityAddTraits(.isModal)
    }
}

/// The editor (mockup E) as the popup: its working copy kept here, the panel drawing it with the popup's chrome. Every
/// change saves once it rests (Sven 2026-10-17, no Save button); Done, Esc and Return close it.
struct WorkspaceEditor: View {
    /// Where a render or a test starts: a tile under the mouse, the picker open on a spot with words typed, the apps the
    /// picker lists (nil reads the Mac's).
    struct Start {
        var hovered: Int?
        var picking: Spot?
        var query = ""
        /// The picker row under the mouse.
        var pickerHover: Int?
        var apps: [AppChoice]?
        /// Scrolled to the end, where the workspace's rules sit, as a short window shows them.
        var scrolled = false
        /// Hears whether the middle is taller than the popup shows, so a render can prove a window fits it whole.
        var overflows: ((Bool) -> Void)?
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

    let workspace: String
    let presets: WorkspacePresets
    let layouts: WorkspaceLayouts
    let close: () -> Void
    /// Hears the height the parts need with the preview at its least, so the popup can grow to it.
    let fit: (CGFloat) -> Void
    @State private var draft: WorkspacePresetDraft
    private let start: Start

    init(workspace: String, presets: WorkspacePresets, layouts: WorkspaceLayouts, start: Start = Start(),
         close: @escaping () -> Void, fit: @escaping (CGFloat) -> Void = { _ in }) {
        self.workspace = workspace
        self.presets = presets
        self.layouts = layouts
        self.close = close
        self.fit = fit
        self.start = start
        _draft = State(initialValue: WorkspacePageDrafts.baseline(workspace, saved: presets.contents.preset(for: workspace), row: layouts.layout(workspace)))
    }

    nonisolated static let space = "workspacePopup"
    /// How tall a layout picture is: the mockup's 52 while there is room, down to 32 in a short popup.
    static let pictures: ClosedRange<CGFloat> = 32...52
    /// The layouts' column, popup and page alike: three pictures a row with their names, Main + stack the widest.
    static let layoutsWidth: CGFloat = 280
    /// The page's preview beside its layouts from this width: the layouts, the gap, the sides and a 260 pt preview, so the
    /// window's first size keeps them side by side (simplify-pages T18).
    static let pageBeside: CGFloat = layoutsWidth + 18 + 2 * 18 + 260
    /// Own sizes' name in the editor (Sven 2026-10-17: "what is own sizes"): the apps side by side at the widths you set.
    static let ownSizes = "Your widths"

    var body: some View {
        WorkspaceEditorPanel(workspace: workspace, presets: presets, draft: $draft, mode: .popup(close: done, fit: fit), start: start) {
            presets.remove(from: workspace)
            guard presets.lastError == nil else { return }
            // Nothing left to write as it closes.
            draft = WorkspacePageDrafts.baseline(workspace, saved: nil, row: layouts.layout(workspace))
            close()
        }
        // A click on the scrim closes it too: what is still waiting is written then.
        .savesWhenResting(draft, write: write)
    }

    /// Writes what is still waiting, then closes.
    private func done() {
        write()
        close()
    }

    /// The draft once it differs from what is saved (WorkspacePresets.write).
    private func write() {
        let saved = presets.contents.preset(for: workspace)
        guard draft != WorkspacePageDrafts.baseline(workspace, saved: saved, row: layouts.layout(workspace)) else { return }
        _ = presets.write(draft, to: workspace, layouts: layouts)
    }

    /// The Mac's apps by name, then Pilot's web apps with their sites; a web app is listed once, as a web app.
    static func installedChoices() -> [AppChoice] {
        let web = WebAppDirectory.list().map { AppChoice(name: $0.name, bundle: $0.bundleID, host: $0.url.host) }
        let webIDs = Set(web.map(\.bundle))
        return AppsModule.pickableApps().filter { !webIDs.contains($0.bundle) }.map { AppChoice(name: $0.name, bundle: $0.bundle) } + web
    }
}

/// What the Workspaces page adds to the editor's right column: the apps that always land on the workspace (the Pilot
/// block's rules) and its snapshot.
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
    let snapshot: Snapshot?
    let restore: () -> Void
    let deleteSnapshot: () -> Void
    let reopenApps: Binding<Bool>
}

/// The editor's parts (mockup E), drawn as the popup over the window or inline on the Workspaces page (card
/// agent-bo-95423003, Sven: "this should be how in workspaces looks"): the workspace's number, its preset's name and
/// its key; the preview drawn as the screen, whose spots take an app or a web app; the layouts as pictures; the apps in
/// the order they open, each with At login; the workspace's two rules; Remove preset. Every change saves at once (Sven
/// 2026-10-17): the popup's Done closes it; the page has no button for it.
struct WorkspaceEditorPanel: View {
    @Environment(\.ink) private var ink
    enum Mode {
        case popup(close: () -> Void, fit: (CGFloat) -> Void)
        /// The page's front: the preview, the layouts with the rules, a preset and the snapshot under them, and what opens
        /// here (the rules on More until Sven's round 3 notes on build 2300, 2026-11-11).
        case page(extras: WorkspacePageExtras)
    }
    typealias Spot = WorkspaceEditor.Spot
    typealias AppChoice = WorkspaceEditor.AppChoice

    let workspace: String
    let presets: WorkspacePresets
    @Binding var draft: WorkspacePresetDraft
    let mode: Mode
    let remove: () -> Void
    @State private var hovered: Int?
    @State private var picking: Spot?
    @State private var query: String
    @State private var pickerHover: Int?
    @State private var choices: [AppChoice]
    private let start: WorkspaceEditor.Start
    /// Each spot's frame in the panel, for the picker to hang off.
    @State private var spots: [Spot: CGRect] = [:]
    @State private var bottomHeight: CGFloat = 0
    @State private var layoutsHeight: CGFloat = 0
    @State private var pictureHeight = WorkspaceEditor.pictures.upperBound
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    /// More of the middle sits under the footer, or scrolled up under the header: that edge fades.
    @State private var more = false
    @State private var scrolledUp = false
    /// The page's panel is wide enough for the right column beside the preview.
    @State private var pageWide = true

    init(workspace: String, presets: WorkspacePresets, draft: Binding<WorkspacePresetDraft>, mode: Mode, start: WorkspaceEditor.Start = .init(),
         remove: @escaping () -> Void) {
        self.workspace = workspace
        self.presets = presets
        _draft = draft
        self.mode = mode
        self.remove = remove
        self.start = start
        _hovered = State(initialValue: start.hovered)
        _picking = State(initialValue: start.picking)
        _query = State(initialValue: start.query)
        _pickerHover = State(initialValue: start.pickerHover)
        _choices = State(initialValue: start.apps ?? [])
    }

    private var popup: Bool { if case .popup = mode { true } else { false } }
    /// The page's Remove preset sits in the header (card agent-bo-95423182); the popup keeps its footer.
    private var actionsUp: Bool { !popup }
    private var extras: WorkspacePageExtras? { if case .page(let extras) = mode { extras } else { nil } }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: popup ? ink.radius(18) : ink.blockRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    ink.line.frame(height: 1)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                if popup { middle } else { pageMiddle }
                if !actionsUp {
                    VStack(spacing: 0) {
                        ink.line.frame(height: 1)
                        footer
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                }
            }
            .background(popup ? ink.background : ink.surface, in: shape)
            .clipShape(shape)
            .overlay { if popup { shape.strokeBorder(ink.windowLine, lineWidth: 1) } }
            .shadow(color: .black.opacity(popup ? 0.55 : 0), radius: 40, y: 30)
            .shadow(color: .black.opacity(popup ? 0 : 0.06), radius: 1, y: 1)
            .toyEdge(radius: popup ? 0 : ink.blockRadius)
            if picking != nil { pickerLayer }
        }
        .coordinateSpace(.named(WorkspaceEditor.space))
        .onChange(of: headerHeight + top(picture: WorkspaceEditor.pictures.upperBound) + bottomHeight + footerHeight, initial: true) { _, ideal in
            if case .popup(_, let fit) = mode { fit(ideal) }
        }
        .task { if start.apps == nil { choices = WorkspaceEditor.installedChoices() } }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .trailing, spacing: 10) {
            headerRow
            // Narrow, the actions take their own row under the title.
            if actionsUp && !pageWide { HStack(spacing: 8) { pageActions } }
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
            if actionsUp && pageWide { pageActions }
            BindKey(action: "workspaces.go:\(workspace)")
            if case .popup(let close, _) = mode { IconButton(symbol: "xmark", label: "Close", action: close) }
        }
    }

    // MARK: Middle

    /// The preview's row with the layout pictures `picture` tall and the preview at its least, 150 under its label, and
    /// the 14 pt above the row: with 52 the height the popup grows to when the window allows, with 32 the least before
    /// anything scrolls.
    private func top(picture: CGFloat) -> CGFloat {
        let rows = CGFloat(LayoutChoice.rows.count)
        let layouts = max(0, layoutsHeight - rows * pictureHeight) + rows * picture
        return max(layouts, 20 + 150) + 14
    }

    /// The popup's middle: the preview and the layouts, then what opens here. Short of room the preview and the layout
    /// pictures give way first (the preview to 150, the pictures to 32); past that the whole scrolls, its edge faded while
    /// more is out of sight.
    private var middle: some View {
        GeometryReader { g in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 18) {
                        previewColumn
                        layoutColumn
                            .frame(width: WorkspaceEditor.layoutsWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { layoutsHeight = $0 }
                    }
                    .padding(.horizontal, 18).padding(.top, 14)
                    .frame(height: max(top(picture: WorkspaceEditor.pictures.lowerBound), g.size.height - bottomHeight), alignment: .top)
                    bottom
                        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // A legacy scroller would take a gutter from the right edge only; the fade says there is more.
            .scrollIndicators(.never)
            .defaultScrollAnchor(start.scrolled ? .bottom : .top)
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.containerSize.height < $0.contentSize.height - 1 } action: { more = $1 }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 1 } action: { scrolledUp = $1 }
            .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height > $0.containerSize.height + 0.5 } action: { start.overflows?($1) }
            .overlay(alignment: .bottom) { if more { EdgeFade(towards: .bottom) } }
            .overlay(alignment: .top) { if scrolledUp { EdgeFade(towards: .top) } }
        }
    }

    /// The page's middle: the front's preview takes the height the page gives it, the layouts down the right with the rules,
    /// a preset and the snapshot under them (under 600 pt they stack, the preview 260 tall), then what opens here. The page
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
    /// Rules and snapshot until then): the apps that always land here, a preset and the window snapshot.
    @ViewBuilder private var rules: some View {
        if let extras {
            VStack(alignment: .leading, spacing: 22) {
                RulesPart(extras: extras, picking: picking == .rule) { open(.rule) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WorkspaceEditor.space)) } action: { spots[.rule] = $0 }
                VStack(alignment: .leading, spacing: 6) {
                    PartLabel(title: "From a preset", line: "a saved set of apps", info: Self.presetInfo)
                    savedPresets
                }
                SnapshotPart(extras: extras)
            }
            .id(AppSection.workspaceRules)
        }
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
                                                                                                   : "click a spot to add or swap an app",
                          info: Self.previewInfo)
                if draft.layout == nil {
                    Spacer(minLength: 0)
                    spotsStepper
                }
            }
            WorkspacePreview(draft: $draft, hovered: $hovered, picking: picking, spots: $spots, open: open)
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
            // Three to a row, the rows sharing the height the column gets, each picture between 32 and 52 tall; From a
            // preset under them, as wide as the pictures run.
            VStack(spacing: 8) {
                ForEach(LayoutChoice.rows, id: \.self) { row in
                    HStack(spacing: 8) { ForEach(row, id: \.self, content: layoutCell) }
                }
                // The page keeps From a preset on More (simplify-pages T18).
                if popup { savedPresets.padding(.horizontal, LayoutPicture.inset) }
            }
        }
    }

    private func layoutCell(_ choice: LayoutChoice) -> some View {
        LayoutPicture(choice: choice, on: draft.layout == choice.preset, measured: choice == LayoutChoice.all[0] ? { pictureHeight = $0 } : nil) {
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
    static let openNowInfo = "Opens what is missing from Opens here and puts every app in its spot, switch on or off. Restore is different: it puts back a window snapshot."
    static let keepLayoutInfo = "On (the default): Pilot lays this workspace out again in this layout every time a window opens or closes on it. Off: a new window goes wherever the tiler puts it."
    static let nameInfo = "Name this workspace, e.g. Chat: the name shows instead of its number on this page and on Home's keys. It saves when you press Return or click elsewhere."
    static let previewInfo = "This workspace as a screen. Click a spot to put an app there or swap it. With Your widths, drag the line between two spots to set how wide each is, before or after apps are in them, and − and + take a spot away or add one. Every change saves at once."
    static let layoutInfo = "How the apps share the screen. Your widths puts them side by side in spots at the widths you set: drag the lines on the preview, and each app you add takes the next spot's width. The others lay the apps out for you."
    static let opensHereInfo = "The apps this workspace opens with, in order: the first fills the first spot. At login opens that app once each time you log in."
    static let presetInfo = "A saved set of apps and a layout. Picking one fills this workspace with it; every change saves at once."

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            removeButton
            Spacer(minLength: 8)
            if case .popup(let close, _) = mode {
                problem
                Button(action: close) { Text("Done") }
                    .buttonStyle(.pilotPrimary)
                    .keyboardShortcut(picking == nil ? .defaultAction : nil)
                // Esc closes too; what is typed is saved either way.
                Button("Close", action: close).keyboardShortcut(picking == nil ? .cancelAction : nil)
                    .opacity(0).frame(width: 0).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
    }

    /// The page's Remove preset and why an edit was not saved, for the header (`actionsUp`).
    @ViewBuilder private var pageActions: some View {
        if case .page = mode {
            problem
            removeButton
        }
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
            case .rule: choices.filter { !(extras?.ruled.contains($0.bundle) ?? false) }
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
                            case .rule: extras?.addRule(choice.bundle)
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
                      info: "Apps whose windows always move to this workspace, wherever they open. The ⋯ menu moves one to another workspace or takes it off.")
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
                }
                AddSpot(big: false, narrow: false, on: picking, open: add).frame(height: 30)
                .padding(.top, extras.rules.isEmpty ? 0 : 6)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .blockSurface()
        }
    }
}

/// The workspace's window snapshot (Sven 2026-10-17: "what is snapshot?"): where its windows sat when it was saved and
/// what it holds, Restore and Delete; the keys that save and restore, and whether a restore reopens closed apps.
private struct SnapshotPart: View {
    @Environment(\.ink) private var ink
    let extras: WorkspacePageExtras

    static let info = "Saves where this workspace's windows sit and how big they are, so one key puts them all back. Splits inside splits come back side by side."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PartLabel(title: "Window snapshot", line: "one key puts windows back", info: Self.info)
            VStack(alignment: .leading, spacing: 8) {
                if let saved = extras.snapshot {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "camera.viewfinder").font(ink.ui(11)).foregroundStyle(ink.muted).accessibilityHidden(true)
                        Text("saved \(saved.savedAt.formatted(.relative(presentation: .named)))").font(ink.ui(12.5)).foregroundStyle(ink.text)
                    }
                    Text(WorkspacesBody.apps(saved)).font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(2)
                    HStack(spacing: 8) {
                        Button(action: extras.restore) { Label("Restore", systemImage: "arrow.uturn.backward").labelStyle(.titleAndIcon) }.buttonStyle(.pilot)
                        Button("Delete", action: extras.deleteSnapshot).buttonStyle(PilotButtonStyle(destructive: true, ghost: true))
                    }
                } else {
                    Text("None saved yet").font(ink.ui(12.5)).foregroundStyle(ink.text2)
                }
                ink.line.frame(height: 1)
                HStack(spacing: 6) {
                    Text("Save").foregroundStyle(ink.muted); BindKey(action: "workspaces.saveSnapshot")
                    InfoMark(text: "Saves where the windows on the workspace in front sit and how big they are, replacing its last snapshot.")
                }
                HStack(spacing: 6) {
                    Text("Restore").foregroundStyle(ink.muted); BindKey(action: "workspaces.restoreSnapshot")
                    InfoMark(text: "Puts the windows of the workspace in front back where its snapshot has them.")
                }
                Toggle("Restore reopens closed apps", isOn: extras.reopenApps)
                    .toggleStyle(.pilotSwitchRow(info: "A restore also opens the snapshot's apps that are not running, then puts their windows back."))
                    .font(ink.ui(12.5))
            }
            .font(ink.ui(12))
            .padding(.horizontal, 10).padding(.vertical, 10)
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
            if ink.isInstrument { InstrumentEyebrow(text: title) }
            else { Text(title).fontWeight(.semibold).accessibilityAddTraits(.isHeader) }
            Text(line).lineLimit(1).truncationMode(.tail)
            if let info { InfoMark(text: info) }
        }
        .font(ink.ui(11)).foregroundStyle(ink.muted)
    }
}

/// The popup's ground fading in over the middle's edge where more of it scrolls out of sight.
private struct EdgeFade: View {
    @Environment(\.ink) private var ink
    let towards: VerticalEdge

    var body: some View {
        LinearGradient(colors: [ink.background.opacity(0), ink.background], startPoint: towards == .bottom ? .top : .bottom,
                       endPoint: towards == .bottom ? .bottom : .top)
            .frame(height: 28).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The workspace's number: Instrument's mono tile, else a lit pebble on the accent.
private struct NumberBadge: View {
    @Environment(\.ink) private var ink
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if ink.isInstrument {
            // Instrument's: the number in mono on a raised tile, its signal kept for the live workspace.
            InstrumentAppIcon(bundle: nil, size: 34, letter: text)
        } else {
            Text(text).font(ink.mono(17, weight: .medium)).foregroundStyle(ink.onAccent).lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: 34, height: 34)
                .background(ink.accent, in: shape)
                .litEdge(shape, .white.opacity(0.25))
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                .accessibilityHidden(true)
        }
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
    /// Hears the picture's height, which the editor needs to know how far the column can shrink.
    var measured: ((CGFloat) -> Void)?
    let pick: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 5) {
                MiniScreen(blocks: blocks, on: on)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured?($0) }
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
