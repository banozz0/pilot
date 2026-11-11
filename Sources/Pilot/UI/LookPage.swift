import AppKit
import PilotCore
import SwiftUI

/// Look (design round 4, card agent-bo-95422896): the style, the ten themes as Sven's theme cards, each drawn in its own
/// colours and display face over a small window in that theme; Glass with its Transparency; the wallpaper. The focused
/// window's border and Defocus are Tiling's Focused window block (page map, Sven 2026-10-17). Every
/// setting has an ⓘ saying what it does (Sven, 2026-10-09). A column of cards under the page's title; nothing folds
/// (card agent-bo-95423004). A pick restyles the window at once and Ghostty with it. The front holds the preview, Glass,
/// the wallpaper's Previous and Next, and Theme; the rest is on More (simplify-pages T20, T28).
struct LookPage: View {
    @Environment(\.ink) private var ink
    let look: Look
    /// Look › Wallpaper's store (story 160); a render passes its own.
    let wallpaper: WallpaperSettings
    /// Look › Cursor's store (P84): the shared one for the shared Look, an in-memory one for a render's.
    let cursors: CursorSets
    /// Look › Cursor's trail and halos (P84), the same way.
    let effects: CursorEffects
    /// The screens Wallpaper shows; nil reads this Mac's, a render passes its own so nothing is read meanwhile.
    let screens: [WallpaperScreen]?
    /// The theme columns, measured from the grid's width (calmColumns): only a change of count redraws the page.
    @State private var themeColumns = 4
    /// The place a link asked for (Wallpaper), scrolled to and then cleared through `landed`; the row Wallpaper lights.
    let section: AppSection?
    let focus: WallpaperBlock.Focus?
    let landed: () -> Void
    /// The More tab shows, not the front; a block a link or the search asked for comes from the window (blockLanding).
    let more: Bool

    init(look: Look = .shared, wallpaper: WallpaperSettings = .shared, cursors: CursorSets? = nil, effects: CursorEffects? = nil,
         screens: [WallpaperScreen]? = nil, more: Bool = false, section: AppSection? = nil, focus: WallpaperBlock.Focus? = nil,
         landed: @escaping () -> Void = {}) {
        self.more = more
        self.look = look
        self.wallpaper = wallpaper
        self.cursors = cursors ?? .of(look)
        self.effects = effects ?? .of(look)
        self.screens = screens
        self.section = section
        self.focus = focus
        self.landed = landed
    }

    var body: some View {
        if more { moreTab } else { front }
    }

    private var front: some View {
        ScrollViewReader { proxy in
            column.onChange(of: section, initial: true) {
                guard let section else { return }
                Task { @MainActor in
                    withAnimation(Kit.change) { proxy.scrollTo(section, anchor: .top) }
                    landed()
                }
            }
        }
    }

    /// What each setting does, the ⓘ's words: one or two plain lines.
    enum Info {
        static let style = "How Pilot is drawn: Instrument or Toybox. The theme still picks every colour."
        static let menuLayout = "How Hyper+Space draws the menu: Line, which opens as Omarchy's list and grows into a wide search on the first key; Classic, Omarchy's list in JetBrains Mono; or the Rail, with the kinds and their counts beside the hits. The keys and rows are the same in all three."
        static let windowShape = "How this window lays out its areas and pages: a rail with the area's pages beside it, or tabs in the toolbar."
        static let theme = "Click a theme to try it on Pilot; nothing else changes. Apply theme sends it to the apps Pilot finds on your Mac at once and then shows what changed; Restore default undoes it."
        static let glass = "Liquid Glass, the top bar's, behind Pilot's window, the Hyper+Space menu, clipboard history, quick notes and Quick AI. Off, they are solid."
        static let transparency = "How much of the desktop shows through the glass, here and on a Glass top bar, which goes solid at 0 %. Text stays readable however far you go."
        static let glassBlur = "How much the glass blurs the desktop behind it: Full, Light, or Off for a sharp desktop under the tint. Here, on a Glass top bar and on the widgets."
        static let cursor = "Pilot's pointer, I-beam, hands and the rest, everywhere: Quiet, Toybox, Duo or Classic. macOS keeps its own cursor. Restore puts macOS's back; if any stays, a restart clears it."
        static let cursorColours = "Theme follows the theme; Design's own keeps the design's colours; Custom paints any design in a fill and an outline you pick, badges too."
        static let effectColour = "The trail's, ring's and ripple's colour: the theme's, or one you pick. The right button's ripple keeps the theme's second colour."
        static let trail = "A fading line behind the pointer while it moves: Thread, Comet or Dots. Off while Reduce motion is on."
        static let ring = "A ring around the pointer that squeezes on a click; it hides after 3 s still and comes back as you move."
        static let ripple = "A ring that spreads from each click: the right button's in the theme's second colour."
        static let spotlight = "Dims the screen around the pointer while you hold its key. It has no key until you set one."
        static let appsShowAs = "How every list shows an app: its icon, its name or both. Icon only shows the name on hover; search still finds it by name."
    }

    /// The theme columns: four; in Instrument, every theme in two full rows once each card keeps 150 pt, so no row
    /// ends in an empty half.
    static func calmColumns(_ width: CGFloat, instrument: Bool) -> Int {
        let rows = (PilotTheme.designed.count + 1) / 2, gap: CGFloat = 8
        return instrument && width >= CGFloat(rows) * 150 + CGFloat(rows - 1) * gap ? rows : 4
    }

    /// More's index (simplify-pages T20): a block's rows, a heading not counted. A row added to or moved off a block changes
    /// its count here.
    static let entries = [
        MoreEntry(id: .lookStyle, symbol: "paintbrush", controls: 1),
        MoreEntry(id: .menuLayout, symbol: "text.magnifyingglass", controls: 1),
        MoreEntry(id: .windowLayout, symbol: "sidebar.left", controls: 1),
        MoreEntry(id: .appsShowAs, symbol: "square.grid.2x2", controls: 1),
        MoreEntry(id: .glassTuning, symbol: "drop", controls: 2),
        MoreEntry(id: .cursor, symbol: "cursorarrow", controls: 8),
        MoreEntry(id: .wallpaperCycle, symbol: "photo.on.rectangle", controls: 7),
    ]

    // MARK: The page

    /// The front: the preview beside Glass and the wallpaper's Previous, Next and On its own, then Theme, so Glass, Next and
    /// Apply theme show at the window's first size, 1000 by 660 (Sven's pick a, 2026-11-11; the prototype had Theme first).
    private var column: some View {
        @Bindable var look = look
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The preview takes the row's height, level with Glass and Wallpaper beside it (InstrumentPair's trick).
                HStack(alignment: .top, spacing: 14) {
                    LookPreview(look: look).padding(.top, ink.isInstrument ? ink.style.density.padding : Toy.blockGap)
                        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                    VStack(spacing: 0) {
                        // Glass alone; its Transparency and Blur are on More (page map, Sven 2026-10-17; Blur 2026-11-01).
                        KitBlock(title: "Glass") { switchRow("Glass", Info.glass, isOn: $look.glass, first: true) }
                            .disabled(look.themePressing)
                        WallpaperBlock(settings: wallpaper, screens: screens, focus: focus, part: .front).id(AppSection.wallpaper)
                    }
                    .frame(width: ink.isInstrument ? 290 : 330)
                }
                .fixedSize(horizontal: false, vertical: true)
                // With packs, ThemeSection draws the heading: Apply theme and Restore default sit on its line (Sven Q69).
                VStack(alignment: .leading, spacing: 0) {
                    if look.usesThemePacks { ThemePackControls(look: look, columns: themeColumns) }
                    else {
                        CalmHeading(title: "Theme") { InfoMark(text: Info.theme) }
                        ThemeGrid(look: look, columns: themeColumns)
                    }
                }
                .onGeometryChange(for: Int.self) { [instrument = ink.isInstrument] in
                    Self.calmColumns($0.size.width, instrument: instrument)
                } action: { themeColumns = $0 }
                errorLine.padding(.top, 12)
            }
            .padding(.horizontal, ink.pageInset).padding(.top, ink.pageTop(6)).padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// More: the style, the menu's and this window's layouts, how apps show, the glass's tuning, the cursor and the
    /// wallpaper's folders, each a place a link or the search lands on.
    private var moreTab: some View {
        @Bindable var look = look
        return KitMore(entries: Self.entries) {
            headed(.lookStyle, Info.style) { StylePicker(look: look).padding(14).blockSurface() }
            headed(.menuLayout, Info.menuLayout) { MenuLayoutPicker(look: look).padding(14).blockSurface() }
            headed(.windowLayout, Info.windowShape) { calmLine("Try each: the window redraws at once.") { windowShape } }
            headed(.appsShowAs, Info.appsShowAs) { calmLine("Every list: the menu, Binds, Open with, the top bar.") { appsShowAs } }
            KitBlock(title: "Transparency and blur", note: look.glass ? nil : "While Glass is on, on Look's front.") {
                calmRow(44, first: true) {
                    setting("Transparency", Info.transparency); Spacer()
                    transparencySlider
                    transparencyValue(11.5).frame(width: 38, alignment: .trailing)
                }
                calmRow(44) {
                    setting("Blur", Info.glassBlur); Spacer()
                    Segments(selection: $look.glassBlur, options: GlassBlur.allCases.map { ($0, $0.title) }, label: "Blur")
                }
            }
            .disabled(!look.glass || look.themePressing).moreBlock(.glassTuning)
            CursorBlock(look: look, cursors: cursors, effects: effects).moreBlock(.cursor)
            WallpaperBlock(settings: wallpaper, screens: screens, focus: focus, part: .more).moreBlock(.wallpaperCycle)
            errorLine.padding(.top, 12)
        }
    }

    /// A block on More under its place's title and ⓘ.
    private func headed(_ place: AppSection, _ info: String, @ViewBuilder _ card: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CalmHeading(title: place.title) { InfoMark(text: info) }
            card()
        }
        .moreBlock(place)
    }

    /// A card of one row: its line where the rows below have their labels, its control at the trailing edge.
    private func calmLine(_ line: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack(spacing: 16) {
            Text(line).foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            control()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .blockSurface()
    }

    /// One of the Glass rows, split from the one above by a hairline.
    private func calmRow(_ height: CGFloat, first: Bool = false, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .overlay(alignment: .top) { if !first { ink.line.frame(height: 1) } }
    }

    /// A switch row: its label and ⓘ, the switch at the right; a click on the label flips it, as .pilotSwitchRow's
    /// does, and one on the ⓘ opens its words.
    private func switchRow(_ title: String, _ info: String, isOn: Binding<Bool>, first: Bool = false) -> some View {
        calmRow(44, first: first) {
            setting(title, info)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect).onTapGesture { isOn.wrappedValue.toggle() }
            Toggle(title, isOn: isOn).toggleStyle(.pilotSwitch).labelsHidden()
        }
    }

    /// A row's label with its ⓘ beside it.
    private func setting(_ title: String, _ info: String) -> some View {
        HStack(spacing: 5) { Text(title); InfoMark(text: info) }
    }

    // MARK: Shared parts

    /// Window layout (window directions, Sven 2026-10-11: "can we have all 3 implemented, then I test and see which is
    /// best?"): the rail or toolbar tabs; the hub went on 2026-10-11.
    private var windowShape: some View {
        Segments(selection: Binding(get: { look.windowShape }, set: { look.windowShape = $0 }),
                 options: WindowShape.allCases.map { ($0, $0.title) }, label: "Window layout")
    }

    /// Apps show as (story 154): icon only, title only, or both, for every list that shows an app.
    private var appsShowAs: some View {
        @Bindable var look = look
        return Segments(selection: $look.appsShowAs, options: AppsShowAs.allCases.map { ($0, $0.label) }, label: "Apps show as")
    }

    /// Transparency from 0 % (solid) to 100 % (round 15; it was Strength, 40 to 100 %, the other way round), shown while
    /// Glass is on.
    private var transparencySlider: some View {
        KitSlider(value: Binding(get: { Double(look.transparency) }, set: { if Int($0) != look.transparency { look.transparency = Int($0) } }),
                  range: 0...100, step: 1, label: "Transparency")
    }

    private func transparencyValue(_ size: CGFloat) -> some View {
        Text("\(look.transparency)%").font(ink.mono(size)).foregroundStyle(ink.text2).fixedSize()
    }

    @ViewBuilder private var errorLine: some View {
        if let error = look.lastError { FinePrint(text: error, color: ink.red) }
    }
}

/// T1's library + inspector, reduced to T2's saved-pack / exact-plan / Apply / Restore path.
private struct ThemePackControls: View {
    let look: Look
    let columns: Int
    @State private var applied = false
    @State private var editor = ThemeDraftSession()
    private var draft: ThemePackStore.Draft? {
        get { editor.draft }
        nonmutating set { editor.draft = newValue }
    }
    @State private var revision: String?
    @State private var following = ThemeFollowing()
    @Environment(\.ink) private var ink
    @State private var packs: [ThemePack] = []
    @State private var selected = ""
    @State private var plan: ThemePlan?
    @State private var outcome = ""
    @State private var outcomeDetails = ""
    private var running: Bool { look.themePressing }
    @State private var apps: ThemeCoordinator.AppFollowing?

    /// Every theme this style can wear: Pilot's own in their designed order, then the ones a person made.
    private var cards: [PilotTheme] {
        let style = look.style.rawValue
        return PilotTheme.designed(for: style) + packs.filter { pack in pack.compatible(with: style) && !PilotTheme.designed.contains { $0.id == pack.id } }
            .map { $0.appearance(keeping: .standard) }
    }

    var body: some View {
        ThemeSection(themes: cards, picked: selected.isEmpty ? look.themeID : selected, columns: columns, applied: applied,
                     canApply: packs.contains { $0.id == selected }, running: running,
                     pick: { tryOn($0) }, apply: { press(selected) }, restore: { press(nil) },
                     mode: Binding(get: { following.mode != false }, set: { value in
                         do { following = try ThemeCoordinator.production().stageFollowing("mode", follow: value); plan = nil }
                         catch { outcome = String(describing: error) }
                     })) {
            if let plan { preview(plan) }
            if !outcome.isEmpty { Text(outcome).foregroundStyle(ink.text2).textSelection(.enabled) }
            if !outcomeDetails.isEmpty {
                KitFold(title: "Details") { Text(outcomeDetails).font(.caption).foregroundStyle(ink.text2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            if draft != nil {
                ThemePackEditor(session: editor,
                    save: { save(review: false) }, review: { save(review: true) }, cancel: { draft = nil })
            }
        } more: { more }
        .onDisappear { editor.invalidate(); look.endTrial(keep: !applied) }
        .task {
            do {
                let owner = try ThemeCoordinator.production(), store = owner.store
                packs = try await Task.detached { try store.list() }.value
                apps = try owner.appFollowing(); following = try owner.following()
                let now = try owner.appliedTheme()
                applied = now.any
                if selected.isEmpty { selected = now.id ?? look.themeID }
            }
            catch { outcome = String(describing: error) }
        }
    }

    private func tryOn(_ id: String) {
        selected = id; plan = nil; draft = nil; outcome = ""; outcomeDetails = ""
        look.tryOn(id: id, pack: packs.first { $0.id == id })
    }

    @ViewBuilder private var more: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // New… copies the theme picked, so no Duplicate beside it (W11).
                Button("New…") { edit(copy: true) }
                Button("Import…") { importPack() }
                Button("Edit") { edit(copy: false) }.disabled(selected.isEmpty)
                Button("Export…") { exportPack() }.disabled(selected.isEmpty)
            }
            KitFold(title: "Follow or keep personal") {
                ForEach(["palette", "wallpapers", "material", "bar", "cursor"], id: \.self) { component in
                    Toggle("Follow pack " + component, isOn: Binding(get: {
                        switch component { case "palette": following.palette; case "wallpapers": following.wallpapers; case "bar": following.bar == true; case "cursor": following.cursor != false; default: following.material }
                    }, set: { value in
                        do { following = try ThemeCoordinator.production().stageFollowing(component, follow: value); plan = nil; outcome = "Saved. Preview again before Apply." }
                        catch { outcome = String(describing: error) }
                    }))
                }
                Text("Bar geometry and fonts stay personal unless geometry follows a pack. Restore default puts back what the theme changed. Your own edits and saved packs stay.").font(.caption).foregroundStyle(ink.text2)
            }
            if let apps {
                if apps.zedFound { appSwitch("Zed follows", on: apps.zedOn, app: .zed) }
                if apps.ghostexFound { appSwitch("Ghostex follows", on: apps.ghostexOn, app: .ghostex) }
                ForEach(apps.apps, id: \.kind) { app in
                    if let kind = ThemeAppKind(rawValue: app.kind) { appSwitch("\(app.name) follows", on: app.on, app: .app(kind)) }
                }
                if !apps.vaults.isEmpty {
                    appSwitch("Obsidian follows", on: apps.obsidianOn, app: .obsidian)
                    ForEach(apps.vaults, id: \.root) { vault in
                        appSwitch(ThemeCoordinator.vaultLabel(vault.root, among: apps.vaults.map(\.root)), on: vault.on, app: .vault(vault.root))
                            .help(vault.root).padding(.leading, 18).disabled(!apps.obsidianOn)
                    }
                }
            }
        }
    }

    @ViewBuilder private func preview(_ plan: ThemePlan) -> some View {
                    let details = try? ThemeCoordinator.production().describe(plan)
                    ThemePreviewSummary(plan: details ?? .null) {
                        if let change = try? ThemeCoordinator.production().appearanceChange(plan),
                           let bytes = try? ThemeDigest.encoded(change) {
                            KitFold(title: "Pilot colours and glass") {
                                Text(String(decoding: bytes, as: UTF8.self))
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                        ForEach(Array(plan.wallpapers.enumerated()), id: \.offset) { _, change in
                            Text("Wallpaper before: \(themeWallpaperText(change.before))\nAfter: \(themeWallpaperText(change.after))")
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        if !plan.ghostex.isEmpty {
                            Text(plan.ghostex.map { "\(GhostexInterface.names[$0.key] ?? $0.key): \($0.before) → \($0.after)" }.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        if let details { ThemePlanReview(plan: details) }
                    }
                    Button(plan.packID == nil ? "Restore" : "Apply") { press(plan.packID, plan: plan.id) }.disabled(running)
    }

    private func edit(copy: Bool) {
        do {
            let owner = try ThemeCoordinator.production()
            let id = selected.isEmpty ? (packs.first?.id ?? "lagoon") : selected
            var value = try owner.store.draft(id)
            let loaded = try owner.store.load(id)
            if copy || loaded.factory {
                value.pack.id = "user-" + UUID().uuidString.lowercased()
                value.pack.title += " copy"; revision = nil
            } else { revision = loaded.revision }
            draft = value; plan = nil
        } catch { outcome = String(describing: error) }
    }
    private func save(review: Bool) {
        guard let draft else { return }
        do {
            let owner = try ThemeCoordinator.production(), saved = try owner.saveDraft(draft, replacing: revision)
            selected = saved.pack.id; revision = saved.revision; self.draft = nil
            packs = try owner.store.list(); plan = nil; outcome = "Draft saved. Nothing applied."
            if review { prepare(selected) }
        } catch { outcome = String(describing: error) }
    }
    private func importPack() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { answer in
            guard answer == .OK, let path = panel.url?.path else { return }
            do {
                let owner = try ThemeCoordinator.production()
                try owner.editorPath(path)
                let saved = try owner.saveDraft(ThemePackStore.readPortable(path))
                packs = try owner.store.list(); selected = saved.pack.id; plan = nil; draft = nil
                outcome = "Pack imported. Nothing applied."
            } catch { outcome = String(describing: error) }
        }
    }
    private func exportPack() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = selected + ".pilot-theme.json"
        panel.begin { answer in
            guard answer == .OK, let path = panel.url?.path else { return }
            do {
                let owner = try ThemeCoordinator.production()
                try owner.export(selected, to: path)
                outcome = "Portable pack exported. Existing destinations are never overwritten."
            } catch { outcome = String(describing: error) }
        }
    }

    private func appSwitch(_ title: String, on: Bool, app: ThemeCoordinator.AppSwitch) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { value in
            do { apps = try ThemeCoordinator.production().stageFollows(app, on: value); plan = nil; outcome = "Saved. Preview again before Apply." }
            catch { outcome = String(describing: error) }
        })).disabled(running)
    }

    /// One press applies or restores (Sven, after testing 2180): no second button and no Allow from Pilot's own window;
    /// what changed shows afterwards, with Restore to undo it. The review panel's button passes the plan it shows, which
    /// is spent as reviewed; a card's press plans afresh.
    private func press(_ id: String?, plan planID: String? = nil) {
        look.themePressing = true; plan = nil
        Task { @MainActor in
            defer { look.themePressing = false }
            do {
                let result = if let planID { try await ThemeCoordinator.production().apply(planID, peer: nil, pressed: true) }
                             else { try await ThemeCoordinator.production().press(id) }
                outcome = themeOutcomeText(result); outcomeDetails = themeOutcomeDetails(result)
                applied = (try? ThemeCoordinator.production().appliedTheme().any) ?? applied
                apps = try? ThemeCoordinator.production().appFollowing()
                look.endTrial(keep: false)
            }
            catch { outcome = String(describing: error) }
        }
    }
    private func prepare(_ id: String?) {
        Task {  // Preview waits on Ghostex off the main thread.
            do {
                plan = try await ThemeCoordinator.production().plan(id)
                apps = try ThemeCoordinator.production().appFollowing(); outcome = ""; outcomeDetails = ""
            }
            catch { plan = nil; outcome = String(describing: error) }
        }
    }
}

// MARK: - Preview

/// Look's preview (simplify-pages T28; Sven's pick A of the look-preview-design round and its tweak, 2026-11-11): this
/// Mac's wallpaper in small with a desk in the theme over it (LookDesk), an editor, a terminal and a notes graph with the
/// tiler's gaps between them. It reads the main screen's wallpaper as it shows and after each step.
struct LookPreview: View {
    let look: Look
    /// A render's wallpaper, so nothing is read; nil reads the main screen's.
    @Environment(\.lookPreviewStill) private var still
    @State private var image: NSImage?

    var body: some View {
        LookDesk(look: look, picture: (still ?? image).map { Image(nsImage: $0) })
            .task { await read() }
            .onReceive(NotificationCenter.default.publisher(for: WallpaperSwitch.changed)) { _ in Task { await read() } }
            .accessibilityHidden(true)
    }

    /// The main screen's wallpaper now, off the main thread, a picture big enough for the preview.
    private func read() async {
        guard still == nil, let screen = NSScreen.main, let url = WallpaperSwitch.current(on: screen) else { return }
        image = await Task.detached { WallpaperScreen.thumbnail(url, size: 640) }.value
    }
}

extension EnvironmentValues {
    /// Look's preview's wallpaper in a render; nil reads the main screen's.
    @Entry var lookPreviewStill: NSImage? = nil
}

// MARK: - Cursor

/// Look › Cursor (P84, spec §6; T33's mock, `Cursors 1.1/choices/cursor-designs.html`): the designs as tiles, each drawn
/// in the colours picked; Theme, Design's own or Custom with its fill and outline wells and a sample on a light window;
/// Restore with the last apply's line; the trail, its colour and the halos. While Accessibility's own pointer colours are
/// on, a pick first offers Reset Colors there, or the set would revert outside the front window.
private struct CursorBlock: View {
    @Environment(\.ink) private var ink
    let look: Look
    let cursors: CursorSets
    let effects: CursorEffects
    /// The set picked while Accessibility's colours are on, waiting on the offer.
    @State private var offered: CursorSetID?
    /// The pictures, made while the page shows.
    @State private var samples = CursorSamples()

    /// The light window the sample sits on, and the ground the weak-pair check was drawn for (the designer's).
    static let lightGround: UInt32 = 0xEEF1F5

    var body: some View {
        @Bindable var cursors = cursors
        @Bindable var effects = effects
        KitBlock(title: "Cursor") {
            BlockRow(first: true) {
                HStack(spacing: 5) { Text("Design"); InfoMark(text: LookPage.Info.cursor) }
                Spacer()
                Text(cursors.status ?? (cursors.set == .macOS ? "macOS's own cursor." : "\(cursors.set.title) is picked."))
                    .foregroundStyle(ink.text2).lineLimit(2).multilineTextAlignment(.trailing)
                Button("Restore") { offered = nil; cursors.restore() }.buttonStyle(.pilot).disabled(cursors.working)
            }
            tiles.padding(.bottom, 12)
            if let offered {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accessibility's pointer colours are on, so \(offered.title) would show only in the front window. Reset Colors in Pointer settings first.")
                        .foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Open Pointer settings") { NSWorkspace.shared.open(CursorSets.pointerSettings) }.buttonStyle(.pilotPrimary)
                        Button("Use it anyway") { self.offered = nil; cursors.set = offered }.buttonStyle(.pilot)
                        Button("Cancel") { self.offered = nil }.buttonStyle(.pilotSoft)
                    }
                }
                .padding(.vertical, 10)
                .overlay(alignment: .top) { ink.line.frame(height: 1) }
            }
            if cursors.set != .macOS {
                BlockRow {
                    HStack(spacing: 5) { Text("Colours"); InfoMark(text: LookPage.Info.cursorColours) }
                    Spacer()
                    Segments(selection: $cursors.colours, options: CursorColours.allCases.map { ($0, $0.title) }, label: "Cursor colours")
                        .disabled(look.themePressing)
                }
                if cursors.colours == .custom { custom }
            }
            BlockRow {
                HStack(spacing: 5) { Text("Trail"); InfoMark(text: LookPage.Info.trail) }
                Spacer()
                Segments(selection: $effects.trail, options: CursorTrail.allCases.map { ($0, $0.title) }, label: "Cursor trail")
            }
            BlockRow {
                HStack(spacing: 5) { Text("Effect colour"); InfoMark(text: LookPage.Info.effectColour) }
                Spacer()
                ColourChoicePicker(choice: $effects.colour, theme: ColourChoicePicker.effectTheme(look.themeID, resolved: look.packAppearance), label: "Effect colour")
            }
            halo("Ring", LookPage.Info.ring, isOn: $effects.ring)
            halo("Ripple", LookPage.Info.ripple, isOn: $effects.ripple)
            halo("Spotlight", LookPage.Info.spotlight, isOn: $effects.spotlight) {
                if effects.spotlight { BindKey(action: CursorEffects.spotlightID) }
            }
        }
    }

    // MARK: Designs

    /// One tile per design: its arrow and hand in the colours picked, macOS's in its own; the picked one framed.
    private var tiles: some View {
        HStack(spacing: 8) {
            ForEach(CursorSetID.allCases, id: \.self) { set in
                let picked = (offered ?? cursors.set) == set
                Button { pick(set) } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 0) {
                            if set == .macOS {
                                ForEach([NSCursor.arrow, NSCursor.pointingHand], id: \.self) {
                                    Image(nsImage: $0.image).resizable().scaledToFit().frame(width: 34, height: 34)
                                }
                            } else {
                                ForEach(Array(pair(set).enumerated()), id: \.offset) { picture($0.element, 30) }
                            }
                        }
                        .frame(height: 34)
                        Text(set.title).font(ink.ui(12)).foregroundStyle(picked ? ink.text : ink.text2)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(ink.raised))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(picked ? ink.accent : ink.line, lineWidth: picked ? 2 : 1))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(set.title) cursor")
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
    }

    /// A design's arrow and pointing hand, as the tile shows them.
    private func pair(_ set: CursorSetID) -> [CGImage?] {
        let palette = samples.palette(set, cursors.colours, theme: look.themeID, custom: cursors.custom(set), resolved: look.packAppearance)
        return ["arrow", "pointing-hand"].map { samples.image(set, $0, palette: palette) }
    }

    private func picture(_ image: CGImage?, _ side: CGFloat) -> some View {
        Group {
            if let image { Image(decorative: image, scale: 2).resizable().interpolation(.none) } else { Color.clear }
        }
        .frame(width: side, height: side)
    }

    // MARK: Custom

    /// Fill and outline wells with a swap, a sample of the picked design on a light window, and the pair's contrast.
    @ViewBuilder private var custom: some View {
        let custom = cursors.custom(cursors.set)
        let (fill, outline) = custom.colours(samples.palette(cursors.set, .theme, theme: look.themeID, custom: custom, resolved: look.packAppearance))
        BlockRow {
            Spacer()
            well("Fill", fill) { cursors.fill = .custom($0) }
            well("Outline", outline) { cursors.outline = .custom($0) }
            Button { (cursors.fill, cursors.outline) = (.custom(outline), .custom(fill)) } label: { Image(systemName: "arrow.left.arrow.right") }
                .buttonStyle(.pilot).help("Swap fill and outline").accessibilityLabel("Swap fill and outline")
        }
        let palette = samples.palette(cursors.set, .custom, theme: look.themeID, custom: custom, resolved: look.packAppearance)
        let ratio = Contrast.ratio(fill, outline), weak = ratio < CursorCustom.weakRatio
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(CursorSamples.shown, id: \.self) { picture(samples.image(cursors.set, $0, palette: palette), 32) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: Self.lightGround)))
            Text("Fill and outline \(String(format: "%.1f", ratio)):1 · "
                 + (weak ? "under 2:1, the shape may not read on every window. Your colours stay." : "reads on light and dark windows."))
                .foregroundStyle(weak ? ink.yellow : ink.text2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 12)
    }

    /// A colour well and its hex, as the page's other wells close their panel (`ColourPanelCloser`).
    private func well(_ title: String, _ rgb: UInt32, set: @escaping (UInt32) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(ink.text2)
            ColorPicker(title, selection: Binding(get: { Color(hex: rgb) }, set: { set($0.rgb) }), supportsOpacity: false)
                .labelsHidden()
                .onAppear { ColourPanelCloser.shared.wellAppeared() }
                .onHover { if $0 { ColourPanelCloser.shared.pointerOnWell() } }
                .onDisappear { ColourPanelCloser.shared.wellDisappeared() }
            Text(ColourAnswer.hex(rgb)).font(ink.mono(11.5)).foregroundStyle(ink.text2).fixedSize()
        }
    }

    /// A halo's row: its label and ⓘ, anything beside the switch, then the switch.
    private func halo(_ title: String, _ info: String, isOn: Binding<Bool>, @ViewBuilder beside: () -> some View = { EmptyView() }) -> some View {
        BlockRow {
            HStack(spacing: 5) { Text(title); InfoMark(text: info) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect).onTapGesture { isOn.wrappedValue.toggle() }
            beside()
            Toggle(title, isOn: isOn).toggleStyle(.pilotSwitch).labelsHidden()
        }
    }

    private func pick(_ set: CursorSetID) {
        if set != .macOS && set != cursors.set && CursorSets.accessibilityColoursOn {
            offered = set
        } else {
            offered = nil
            cursors.set = set
        }
    }
}

// MARK: - Style cards

/// The style picker (story 137, ADR 0008): Instrument and Toybox as two cards, each drawn in its own style's tokens in the
/// window's theme, the picked one with the window's 2 pt accent border. Dark or light is the theme's (Sven, 2026-10-09:
/// no switch).
struct StylePicker: View {
    let look: Look

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(PilotStyle.allCases, id: \.self) { style in
                StyleCard(tokens: .of(style, theme: look.theme), picked: look.style == style) {
                    look.style = style
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One style's card, drawn in that style: its name and line on its panel, a Hyper key and a plain key in its key caps,
/// on its canvas.
private struct StyleCard: View {
    @Environment(\.ink) private var ink
    let tokens: StyleTokens
    let picked: Bool
    let pick: () -> Void

    var body: some View {
        let kind = tokens.kind
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 8) {
                name
                // Narrow (a sidebar beside it at 760), the keys go onto two lines, so no word breaks (760 once broke Spac/e).
                Text(kind.tagline).styleText(\.caption).foregroundStyle(tokens.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) { keys }
                    VStack(alignment: .leading, spacing: 5) { keys }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .styleSurface(\.card)
            .padding(10)
            .background(tokens.color(\.canvas), in: .rect(cornerRadius: ink.blockRadius))
            .overlay {
                // Toybox: the ink outline, the picked one a 3 pt sun.
                RoundedRectangle(cornerRadius: ink.blockRadius)
                    .strokeBorder(picked ? ink.accent : ink.edge, lineWidth: picked ? ink.pickedStroke : ink.stroke)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .animation(Kit.change, value: picked)
        .style(tokens)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var name: some View {
        Text(tokens.kind.title).styleText(\.title).foregroundStyle(tokens.color(\.text)).fixedSize()
    }

    @ViewBuilder private var keys: some View {
        key("Hyper", fill: \.hyper, ink: \.onHyper)
        key("Space", fill: \.key, ink: \.text)
    }

    private func key(_ text: String, fill: KeyPath<StyleColors, Paint>, ink: KeyPath<StyleColors, Paint>) -> some View {
        Text(text).styleText(\.key).foregroundStyle(tokens.color(ink)).fixedSize()
            .padding(.horizontal, 7).frame(minHeight: 20)
            .styleSurface(\.key, fill: fill, radius: \.chip)
    }
}

// MARK: - Menu layout tiles

/// Hyper+Space menu (menu Rail and Classic T9, menu-morph T4): Line, the default (Q165), Classic and the Rail as three tiles,
/// each a small picture of its menu in the window's theme; a click writes `look.menuLayout`. Toybox keeps its own menu whatever
/// the pick (T13, the Rail half dropped after Q134), and says so under the tiles.
struct MenuLayoutPicker: View {
    @Environment(\.ink) private var ink
    let look: Look

    /// Each tile's line under its name.
    static func line(_ layout: MenuLayoutStyle) -> String {
        switch layout {
        case .rail: "The kinds down the left, each with its count as you type."
        case .classic: "Omarchy's list, bigger: JetBrains Mono, the keys on the left."
        case .line: "Opens as Classic's list; the first key grows it into a wide search that answers in its line."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(MenuLayoutStyle.allCases, id: \.self) { layout in
                    MenuLayoutTile(layout: layout, picked: look.menuLayout == layout) { look.menuLayout = layout }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if look.style == .toybox {
                Text("Toybox keeps its own menu; this choice shows under Instrument.")
                    .font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One layout's tile: its menu in miniature on a sunk well, its name (the default tagged) and its line; the picked one
/// ringed in the accent, as the style cards are.
private struct MenuLayoutTile: View {
    @Environment(\.ink) private var ink
    let layout: MenuLayoutStyle
    let picked: Bool
    let pick: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous)
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    switch layout {
                    case .rail: RailPicture()
                    case .classic: ClassicPicture()
                    case .line: LinePicture()
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 92)
                .background(ink.well, in: .rect(cornerRadius: ink.radius(7), style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: ink.radius(7), style: .continuous).strokeBorder(ink.line) }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(layout.title).font(ink.ui(14, .medium)).foregroundStyle(ink.text)
                        if layout == .line { Chip(text: "Default", tag: true) }
                    }
                    // As tall as the Default chip on both tiles, so the two names sit level.
                    .frame(minHeight: 24, alignment: .leading)
                    Text(MenuLayoutPicker.line(layout)).font(ink.ui(12)).foregroundStyle(ink.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ink.raised, in: shape)
            .overlay {
                shape.strokeBorder(picked ? ink.accent : ink.isInstrument ? ink.line2 : ink.edge,
                                   lineWidth: picked ? ink.pickedStroke : ink.stroke)
            }
            .contentShape(shape)
        }
        .buttonStyle(.kitPress)
        .animation(Kit.change, value: picked)
        .accessibilityLabel("\(layout.title) menu")
        .accessibilityValue(MenuLayoutPicker.line(layout))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The Rail in miniature: the search line, the rail on the sidebar colour with its hairline, the shown kind raised with
/// its accent tick and every kind's count, the hits beside it with the first one picked.
private struct RailPicture: View {
    @Environment(\.ink) private var ink

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Capsule().fill(ink.accent).frame(width: 2, height: 8)
                Capsule().fill(ink.text2).frame(width: 30, height: 3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).frame(height: 15)
            ink.line.frame(height: 1)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<5) { row in
                        HStack(spacing: 3) {
                            Circle().fill(row == 1 ? ink.accent : ink.muted).frame(width: 3.5, height: 3.5)
                            Capsule().fill(row == 1 ? ink.text : ink.text2.opacity(0.7)).frame(width: [16, 18, 22, 14, 20][row], height: 2.5)
                            Spacer(minLength: 2)
                            Capsule().fill(ink.muted.opacity(0.8)).frame(width: [4, 3, 5, 3, 4][row], height: 2.5)
                        }
                        .padding(.horizontal, 4).frame(height: 10)
                        .background(row == 1 ? ink.selected : .clear, in: .rect(cornerRadius: 2))
                        .overlay(alignment: .leading) { if row == 1 { ink.accent.frame(width: 1.5, height: 6) } }
                    }
                    Spacer(minLength: 0)
                }
                .padding(4)
                .frame(width: 66).frame(maxHeight: .infinity)
                .background(ink.sidebar)
                ink.line.frame(width: 1)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<5) { row in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1.5).fill(row == 0 ? ink.accent : ink.line2).frame(width: 6, height: 6)
                            Capsule().fill(row == 0 ? ink.text : ink.text2.opacity(0.7)).frame(maxWidth: [44, 36, 50, 30, 40][row]).frame(height: 2.5)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4).frame(height: 10)
                        .background(row == 0 ? ink.selected : .clear, in: .rect(cornerRadius: 2))
                    }
                    Spacer(minLength: 0)
                }
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ink.raised)
        .clipShape(.rect(cornerRadius: 5, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(ink.line2) }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// Classic in miniature: Omarchy's framed list in the accent's line, its search line, then rows with the key on the left
/// in the accent, the arrow and what it does; the picked row raised in the accent.
private struct ClassicPicture: View {
    @Environment(\.ink) private var ink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Capsule().fill(ink.accent).frame(width: 2, height: 8)
                Capsule().fill(ink.muted).frame(width: 14, height: 3)
            }
            .padding(.horizontal, 7).frame(height: 15)
            ink.line.frame(height: 1)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<5) { row in
                    HStack(spacing: 4) {
                        Capsule().fill(row == 1 ? ink.accent : ink.accent.opacity(0.55)).frame(width: [22, 18, 24, 16, 20][row], height: 2.5)
                            .frame(width: 26, alignment: .leading)
                        Capsule().fill(ink.muted).frame(width: 4, height: 1.5)
                        Capsule().fill(row == 1 ? ink.accent : ink.text2.opacity(0.7)).frame(maxWidth: [34, 40, 28, 38, 30][row]).frame(height: 2.5)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 5).frame(height: 10)
                    .background(row == 1 ? ink.selected : .clear, in: .rect(cornerRadius: 1.5))
                }
                Spacer(minLength: 0)
            }
            .padding(4)
        }
        .frame(width: 112).frame(maxHeight: .infinity)
        .background(ink.raised)
        .clipShape(.rect(cornerRadius: 3))
        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(ink.style.color(\.accentLine), lineWidth: 1.5) }
        .padding(.vertical, 10)
    }
}

/// Line in miniature: Classic's narrow framed list, an arrow, and the wide search it grows into, its line on top with
/// the caret in the accent and the best match picked.
private struct LinePicture: View {
    @Environment(\.ink) private var ink

    var body: some View {
        HStack(spacing: 6) {
            frame(width: 30) {
                ForEach(0..<5) { row in
                    Capsule().fill(row == 0 ? ink.accent : ink.text2.opacity(0.7)).frame(width: [16, 18, 14, 18, 12][row], height: 2.5)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).frame(height: 8)
                }
            }
            .frame(height: 70)
            Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(ink.muted)
            frame(width: 70) {
                ForEach(0..<3) { row in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5).fill(row == 0 ? ink.accent : ink.line2).frame(width: 5, height: 5)
                        Capsule().fill(row == 0 ? ink.text : ink.text2.opacity(0.7)).frame(width: [30, 24, 34][row], height: 2.5)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4).frame(height: 9)
                    .background(row == 0 ? ink.selected : .clear, in: .rect(cornerRadius: 1.5))
                }
            }
            .frame(height: 48)
        }
        .padding(.vertical, 10)
    }

    /// A framed menu `width` wide: its line (the caret, a stroke of mono text) over `rows`.
    private func frame(width: CGFloat, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Capsule().fill(ink.accent).frame(width: 1.5, height: 7)
                Capsule().fill(ink.muted).frame(width: width * 0.3, height: 2.5)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5).frame(height: 13)
            ink.line.frame(height: 1)
            VStack(alignment: .leading, spacing: 1) { rows() }.padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .frame(width: width)
        .background(ink.raised)
        .clipShape(.rect(cornerRadius: 3))
        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(ink.style.color(\.accentLine), lineWidth: 1.5) }
    }
}

// MARK: - Theme cards

/// The twelve theme cards, four across; Return picks the focused one and the arrows move between them.
private struct ThemeGrid: View {
    let look: Look
    var columns = 4

    var body: some View {
        ThemeCards(themes: PilotTheme.designed(for: look.style.rawValue),
                   picked: look.themeID, columns: columns) { look.pick($0) }
    }
}

/// Look › Theme as a new person meets it: the heading with Apply theme and Restore default on its line (Sven's pick A,
/// build 2276, Q69), the themes, and everything else behind More.
struct ThemeSection<Detail: View, More: View>: View {
    let themes: [PilotTheme]
    let picked: String
    let columns: Int
    let applied: Bool
    let canApply: Bool
    let running: Bool
    let pick: (String) -> Void
    let apply: () -> Void
    let restore: () -> Void
    /// Whether Apply also switches macOS to the theme's Light or Dark mode (Sven Q43, on by default).
    var mode: Binding<Bool>? = nil
    @ViewBuilder var detail: Detail
    @ViewBuilder var more: More

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CalmHeading(title: "Theme") {
                HStack(spacing: 10) {
                    InfoMark(text: LookPage.Info.theme)
                    if applied { Button("Restore default", action: restore).buttonStyle(.pilotSoft).disabled(running) }
                    Button("Apply theme", action: apply).buttonStyle(.pilotPrimary).disabled(!canApply || running)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ThemeCards(themes: themes, picked: picked, columns: columns, pick: pick).disabled(running)
                if let mode { Toggle("Switch macOS to light or dark with the theme", isOn: mode).disabled(running) }
                detail
                KitFold(title: "More") { more }
            }
        }
    }
}

/// The preview cards, moved between with the arrow keys.
struct ThemeCards: View {
    let themes: [PilotTheme]
    let picked: String
    let columns: Int
    let pick: (String) -> Void
    @FocusState private var focused: String?

    var body: some View {
        let taglines = Array(Set(themes.map(\.tagline)))
        // A Grid, not a lazy one: each row is as tall as its tallest card and every card fills it, so the rows' edges
        // line up whatever each display face's height.
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: themes.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(themes[start..<min(start + columns, themes.count)]) { theme in
                        ThemeCard(theme: theme, picked: picked == theme.id, focused: focused == theme.id,
                                  taglines: taglines) {
                            pick(theme.id)
                        }
                        .focusable()
                        .focused($focused, equals: theme.id)
                        .focusEffectDisabled()
                        .onKeyPress(.return) { pick(theme.id); return .handled }
                    }
                }
            }
        }
        .onMoveCommand { direction in
            guard let at = themes.firstIndex(where: { $0.id == focused }) else { return }
            let step = switch direction { case .left: -1; case .right: 1; case .up: -columns; case .down: columns; @unknown default: 0 }
            if themes.indices.contains(at + step) { focused = themes[at + step].id }
        }
    }
}

/// Sven's theme card: three palette dots, a small window in the theme, the name in the theme's own display face, its
/// line, on the theme's deeply tinted ground; the picked one ringed in the accent. Drawn in the card's own theme whatever
/// the window's is, only the corners following the window's.
struct ThemeCard: View {
    @Environment(\.ink) private var ink
    let theme: PilotTheme
    let picked: Bool
    var focused = false
    /// The lines of the cards beside it: its own line keeps the height of the longest wrapped, so the names stay level.
    var taglines: [String] = []
    let pick: () -> Void

    var body: some View {
        let t = theme
        let ground = t.dark ? t.sidebar : t.surface
        let shape = RoundedRectangle(cornerRadius: ink.radius(12) + 2, style: .continuous)
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: -6) {
                    ForEach([t.accent, t.second, t.third], id: \.self) { colour in
                        Circle().fill(Color(hex: colour)).frame(width: 17, height: 17)
                            .overlay { Circle().strokeBorder(Color(hex: ground), lineWidth: 2).padding(-2) }
                    }
                }
                .padding(.bottom, 10)
                // A window in the theme, growing with the card.
                ThemeWindow(theme: t).frame(minHeight: 58, idealHeight: 72, maxHeight: .infinity)
                Text(t.name).display(16, face: t.face).foregroundStyle(Color(hex: t.text)).lineLimit(1).minimumScaleFactor(0.75)
                .padding(.top, 10)
                // The line wraps rather than cuts (card agent-bo-95422970), as tall as the longest of the grid's lines wraps to
                // at this card's width, laid out hidden behind it, so the names stay level across a row. Held at that height:
                // beside the name, a stack otherwise squeezes a wrapped line back onto one and cuts it.
                ZStack(alignment: .topLeading) {
                    ForEach(taglines, id: \.self) { Text($0).hidden() }
                    Text(t.tagline).foregroundStyle(Color(hex: t.text2))
                }
                .font(ink.ui(11.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(hex: ground), in: shape)
            .overlay {
                // Toybox: the ink outline and solid edge (toyEdge), the picked one ringed in the sun inside it.
                if picked { shape.inset(by: ink.stroke).strokeBorder(ink.accent, lineWidth: ink.pickedStroke) }
            }
            .toyEdge(radius: ink.radius(12) + 2)
            .overlay { if focused && !picked { shape.inset(by: -3).strokeBorder(ink.accent.opacity(0.6), lineWidth: 1.5) } }
            .contentShape(shape)
        }
        .buttonStyle(.kitPress)
        .animation(Kit.change, value: picked)
        .accessibilityLabel(t.name)
        .accessibilityValue(t.tagline)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A small window drawn in `theme`: its title bar's three lights, a sidebar with the picked row, a prompt line and a few
/// lines of text, and the theme's graph colours as bars along the foot. Every colour is the theme's own.
private struct ThemeWindow: View {
    let theme: PilotTheme

    var body: some View {
        let t = theme
        let radius: CGFloat = 7
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) { ForEach([t.problem, t.amber, t.good], id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 5, height: 5) } }
                    .padding(.bottom, 3)
                ForEach(0..<4) { row in
                    Capsule().fill(Color(hex: row == 1 ? t.accent : t.text3).opacity(row == 1 ? 1 : 0.55))
                        .frame(maxWidth: [22, 26, 18, 24][row]).frame(height: 3)
                        .padding(.vertical, 2).padding(.horizontal, 3)
                        .background(row == 1 ? Color(hex: t.accent).opacity(t.dark ? 0.16 : 0.14) : .clear, in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(minWidth: 28, maxWidth: 44, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(hex: t.sidebar))
            Rectangle().fill(Color(hex: t.line)).frame(width: 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Capsule().fill(Color(hex: t.accent)).frame(width: 6, height: 3)
                    Capsule().fill(Color(hex: t.text)).frame(maxWidth: 34).frame(height: 3)
                    Capsule().fill(Color(hex: t.text3)).frame(maxWidth: 18).frame(height: 3)
                }
                ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 4) {
                        ForEach(Array(line.enumerated()), id: \.offset) { _, word in
                            Capsule().fill(Color(hex: Self.ink(word.ink, t))).frame(maxWidth: word.width).frame(height: 3)
                        }
                    }
                }
                .padding(.top, 1)
                // The graph grows with the card.
                GeometryReader { box in
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array([0.45, 0.8, 0.6, 1.0, 0.7, 0.9, 0.55].enumerated()), id: \.offset) { i, share in
                            let colour = t.graphs.isEmpty ? t.accent : t.graphs[i % t.graphs.count]
                            RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: colour)).frame(maxWidth: .infinity).frame(height: box.size.height * share)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(minHeight: 18, maxHeight: .infinity)
                .padding(.top, 4)
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(hex: t.ground))
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color(hex: t.line)) }
        .accessibilityHidden(true)
    }

    /// The window's text as words: which of the theme's inks, how long.
    private static let lines: [[(ink: Int, width: CGFloat)]] = [[(2, 46)], [(3, 22), (1, 30)], [(4, 18), (2, 26), (1, 12)], [(1, 38)]]

    private static func ink(_ index: Int, _ t: PilotTheme) -> UInt32 { [t.text3, t.text2, t.text, t.second, t.third][index] }
}

/// Text shared with the external lifecycle proof; keeps recovery visible without a second engine or view. One summary
/// line and what to do next; each change is behind Details (Sven, build 2276).
func themeOutcomeText(_ result: JSONValue) -> String {
    guard case .object(let values) = result else { return "" }
    func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let rows) = value else { return [] }
        return rows.compactMap(\.string)
    }
    let changed = strings(values["changed"]).joined(separator: ", ")
    var lines: [String] = []
    switch values["status"]?.string {
    case "applied": lines.append(changed.isEmpty ? "Theme applied." : "Theme applied: \(changed).")
    case "restored": lines.append(changed.isEmpty ? "Default appearance restored." : "Default appearance restored: \(changed).")
    case "unchanged": lines.append("Nothing needed changing.")
    case "failed":
        var state: String?
        if case .object(let recovery) = values["recovery"] { state = recovery["status"]?.string }
        lines.append(state == "recovery retained" ? "The theme was not applied, and Pilot could not put everything back. Pilot left those files alone and tries again next launch."
                                                  : "The theme was not applied. Everything went back as it was.")
    default: break
    }
    return (lines + strings(values["next"])).joined(separator: "\n")
}

/// The long form, behind Details: each change and what was kept, why something failed, custom reloads, and each file's
/// recovery.
func themeOutcomeDetails(_ result: JSONValue) -> String {
    guard case .object(let values) = result else { return "" }
    func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let rows) = value else { return [] }
        return rows.compactMap(\.string)
    }
    var lines = ["applied", "restored"].contains(values["status"]?.string) ? strings(values["changes"]).map { "Changed: \($0)" } + strings(values["kept"]) : []
    lines += ["error", "warning"].compactMap { values[$0]?.string }
    if case .array(let reloads) = values["reloads"] {
        for case .object(let reload) in reloads {
            lines.append("Reload \(reload["binding"]?.string ?? "custom app"): \(reload["outcome"]?.string ?? "no answer")")
        }
    }
    if case .object(let recovery) = values["recovery"], case .array(let rows) = recovery["rows"] {
        for case .object(let row) in rows {
            lines.append("\(row["path"]?.string ?? row["wallpaper"]?.string ?? row["ghostex"]?.string ?? "Pilot"): \(row["rollback"]?.string ?? row["native"]?.string ?? "no answer")")
        }
    }
    return lines.joined(separator: "\n")
}

func themeWallpaperText(_ value: ThemeWallpaperValue) -> String {
    switch value {
    case .sources(let paths): "\(paths.count) images"
    case .image(let path): path ?? "none"
    }
}

/// What Preview shows first: every change and skip in plain words, the long form behind Details.
struct ThemePreviewSummary<Extra: View>: View {
    let plan: JSONValue
    @ViewBuilder var extra: Extra
    @State private var expanded = false
    @Environment(\.ink) private var ink

    private func lines(_ key: String) -> [String] {
        guard case .object(let fields) = plan, case .object(let review) = fields["review"], case .array(let rows) = review[key] else { return [] }
        return rows.compactMap(\.string)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines("changes"), id: \.self) { Text($0).textSelection(.enabled) }
            ForEach(lines("next"), id: \.self) { Text($0).textSelection(.enabled) }
            ForEach(lines("skipped") + lines("kept"), id: \.self) { Text($0).foregroundStyle(ink.text2).textSelection(.enabled) }
            KitFold(title: "Details", open: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines("details"), id: \.self) { Text($0).font(.caption).foregroundStyle(ink.text2) }
                    extra
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}


/// The native Review and offscreen proof consume the same public plan as the CLI.
struct ThemePlanReview: View {
    let plan: JSONValue
    @State var expanded: Bool = false
    var body: some View {
        KitFold(title: "Exact file changes", open: $expanded) {
            Text(themePlanText(plan))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

func themePlanText(_ plan: JSONValue) -> String {
    guard case .object(let fields) = plan else { return "" }
    func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }
    var lines: [String] = []
    if case .array(let changes) = fields["changes"] {
        for case .object(let change) in changes {
            lines.append("File: " + (change["path"]?.string ?? "Unknown path"))
            if let id = change["bindingID"]?.string { lines.append("Custom mapping: " + id) }
            if let selector = change["selector"] { lines.append("Part of the file: " + json(selector)) }
            for (key, label) in [("before", "Before"), ("after", "After"), ("proposedBytes", "New file contents")] {
                lines.append(label + "\n" + (change[key]?.string ?? "Absent"))
            }
        }
    }
    if case .array(let reloads) = fields["reloads"] {
        for case .object(let binding) in reloads {
            guard case .object(let command) = binding["reload"], let executable = command["executable"] else { continue }
            let arguments: [JSONValue] = if case .array(let argv) = command["arguments"] { argv } else { [] }
            lines.append("Reload " + (binding["id"]?.string ?? "custom app") + ": " + (binding["app"]?.string ?? "unknown app"))
            lines.append("Runs: " + json(.array([executable] + arguments)))
            lines.append("Files change first. This reload asks for its own Allow.")
        }
    }
    return lines.joined(separator: "\n")
}
