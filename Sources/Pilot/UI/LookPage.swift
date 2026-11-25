import AppKit
import PilotCore
import SwiftUI

/// Look (design round 4, card agent-bo-95422896): the ten themes as Sven's theme cards, each drawn in its own
/// colours and display face over a small window in that theme; Glass with its Transparency and Blur; the wallpaper. The focused
/// window's border and Defocus are Tiling's Focused window block (page map, Sven 2026-10-17). Every
/// setting has an ⓘ saying what it does (Sven, 2026-10-09). A column of cards under the page's title; nothing folds
/// (card agent-bo-95423004). A pick restyles the window at once and Ghostty with it. The front holds the preview, Glass
/// with its Transparency and Blur (pages round 5), the wallpaper's Previous and Next, and Theme, then the cursor and the
/// wallpaper's folders (pages round 4, Sven's Q99), with Pilot's Font above the cursor (Sven, 2026-11-23). Look has no More: this window's layout went with the panel
/// (pilot-ui-redesign T3) and the style in the feature trim. The Hyper+Space menu's layout and how apps show went to Launcher's More (Sven's notes on build 19).
struct LookPage: View {
    @Environment(\.ink) private var ink
    let look: Look
    /// Look › Wallpaper's store (story 160); a render passes its own.
    let wallpaper: WallpaperSettings
    /// Look › Cursor's store (P84): the shared one for the shared Look, an in-memory one for a render's.
    let cursors: CursorSets
    /// Look › Cursor's trail and halos (P84), the same way.
    let effects: CursorEffects
    /// Material's stores (W77): the top bar's Background, the dock's style and this look's Glass and Blur.
    let material: LookMaterialStores
    /// The screens Wallpaper shows; nil reads this Mac's, a render passes its own so nothing is read meanwhile.
    let screens: [WallpaperScreen]?
    /// The theme columns, measured from the grid's width (calmColumns): only a change of count redraws the page.
    @State private var themeColumns = 4
    /// The place a link asked for (Wallpaper), scrolled to and then cleared through `landed`; the row Wallpaper lights.
    let section: AppSection?
    let focus: WallpaperBlock.Focus?
    let landed: () -> Void

    init(look: Look = .shared, wallpaper: WallpaperSettings = .shared, cursors: CursorSets? = nil, effects: CursorEffects? = nil,
         material: LookMaterialStores? = nil, screens: [WallpaperScreen]? = nil, section: AppSection? = nil,
         focus: WallpaperBlock.Focus? = nil, landed: @escaping () -> Void = {}) {
        self.look = look
        self.wallpaper = wallpaper
        self.cursors = cursors ?? .of(look)
        self.effects = effects ?? .of(look)
        self.material = material ?? .of(look)
        self.screens = screens
        self.section = section
        self.focus = focus
        self.landed = landed
    }

    var body: some View {
        front
    }

    private var front: some View {
        // Wallpaper by its own link; a place on the front (Transparency and blur, Cursor, Wallpaper folders) by the window's.
        KitLanding { ScrollViewReader { proxy in
            column.onChange(of: section, initial: true) {
                guard let section else { return }
                Task { @MainActor in
                    withAnimation(Kit.change) { proxy.scrollTo(section, anchor: .top) }
                    landed()
                }
            }
        } }
    }

    /// What each setting does, the ⓘ's words: one or two plain lines.
    enum Info {
        static let theme = "Click a theme to try it on Pilot; nothing else changes, and it goes when you leave Look. Apply theme keeps it and sends it to the apps Pilot finds on your Mac at once and then shows what changed; Restore default undoes it."
        static let material = "Glass, Solid or Clear for everything at once: the top bar and its dropdowns, the dock, this window, the panels and the desktop widgets. Glass puts this window, the panels and widgets on regular glass (Blur Full), Clear on clear glass (Blur Light), still readable; the bar's dropdowns stay glass. Custom shows once you change one of them on its own."
        static let glass = "Liquid Glass, the top bar's, behind Pilot's window, the Hyper+Space menu, clipboard history, quick notes and the desktop widgets. Off, they are solid. The top bar's dropdowns and drops follow its own Background."
        static let transparency = "How much of the desktop shows through the glass here, and on a Glass top bar in a colour you picked. In the theme's colour a Glass top bar and dock wear macOS's own clear glass. Both go solid at 0 %. Text stays readable however far you go."
        static let glassBlur = "How much the glass blurs the desktop behind it: Full, Light, or Off for a sharp desktop under the tint. Here and on the widgets; a Glass top bar and the dock wear the macOS Dock's clear glass at Full and Light."
        static let appsShowAs = "How every list shows an app: its icon, its name or both. Icon only shows the name on hover; search still finds it by name."
    }

    /// The theme columns: four; in Instrument, every theme in two full rows once each card keeps 150 pt, so no row
    /// ends in an empty half.
    static func calmColumns(_ width: CGFloat, instrument: Bool) -> Int {
        let rows = (PilotTheme.designed.count + 1) / 2, gap: CGFloat = 8
        return instrument && width >= CGFloat(rows) * 150 + CGFloat(rows - 1) * gap ? rows : 4
    }

    // MARK: The page

    /// The front: the preview beside Glass with its Transparency and Blur and the wallpaper's Previous, Next and On its own,
    /// then Theme, so Glass, Next and Apply theme show at the window's first size (1000 by 660 then; Sven's pick a, 2026-11-11;
    /// the prototype had Theme first); under them the cursor and the wallpaper's folders (pages round 4).
    private var column: some View {
        @Bindable var look = look
        // Cursor and the wallpaper's folders under the fold held the switch ~50 ms (page-perf): built as they scroll in.
        return ScrollView {
            PageStack(asked: section != nil || focus != nil) {
                // The preview takes the row's height, level with Glass and Wallpaper beside it (InstrumentPair's trick).
                HStack(alignment: .top, spacing: 14) { Staged(inView: false) {
                    LookPreview(look: look).padding(.top, ink.style.density.padding)
                        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                    VStack(spacing: 0) {
                        // Glass with its Transparency and Blur under the switch, greyed while Glass is off (pages round 5,
                        // Sven on build 2354: "transparency and blur should maybe be with glass on main look page").
                        KitBlock(title: "Material") {
                            // The label over its four segments, as Transparency's: the column is too narrow for both on one line.
                            calmRow(44, first: true) {
                                VStack(alignment: .leading, spacing: 6) {
                                    setting("Material", Info.material)
                                    Segments(selection: materialPick, options: LookMaterial.allCases.map { ($0, $0.title) }, label: "Material")
                                }
                                .padding(.vertical, 8)
                            }
                            switchRow("Glass", Info.glass, isOn: $look.glass)
                            Group {
                                // The label and value on one line, the slider under them: the column is too narrow for
                                // all three on one.
                                calmRow(44) {
                                    VStack(spacing: 2) {
                                        HStack {
                                            setting("Transparency", Info.transparency).fixedSize(); Spacer(minLength: 8)
                                            transparencyValue(11.5)
                                        }
                                        transparencySlider
                                    }
                                    .padding(.vertical, 8)
                                }
                                calmRow(44) {
                                    setting("Blur", Info.glassBlur); Spacer(minLength: 8)
                                    Segments(selection: $look.glassBlur, options: GlassBlur.allCases.map { ($0, $0.title) }, label: "Blur")
                                }
                            }
                            .disabled(!look.glass)
                        }
                        .disabled(look.themePressing).moreBlock(.glassTuning)
                        WallpaperBlock(settings: wallpaper, screens: screens, focus: focus, part: .front).id(AppSection.wallpaper)
                    }
                    .frame(width: ink.isInstrument ? 290 : 330)
                } }
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
                CursorBlock(look: look, cursors: cursors, effects: effects).id(AppSection.cursor)
                WallpaperBlock(settings: wallpaper, screens: screens, focus: focus, part: .more).id(AppSection.wallpaperCycle)
                errorLine.padding(.top, 12)
            }
            .padding(.horizontal, ink.pageInset).padding(.top, ink.pageTop(6)).padding(.bottom, 30)
            // The pages' measure in a big window, centred under the bar (wide-pages).
            .pageMeasure(side: ink.pageInset)
        }
    }

    /// One of the Glass rows, split from the one above by a hairline.
    private func calmRow(_ height: CGFloat, first: Bool = false, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .overlay(alignment: .top) { if !first { ink.line.frame(height: 1) } }
    }

    /// Material's pick: Glass, Solid or Clear sets every surface; Custom is only read, so picking it changes nothing.
    private var materialPick: Binding<LookMaterial> {
        Binding(get: { material.material }, set: { try? material.pick($0) })
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
    /// The pack the Delete confirmation asks about.
    @State private var deleting: ThemePack?
    /// Delete removes a pack you made; one of Pilot's own is hidden, as Look › Catalogue's Remove does (Sven's
    /// coordinator, after build 2445). The theme in use, and the last one, are refused with their reason.
    @State private var store: ThemePackStore?
    private var deletable: Bool { packs.contains { $0.id == selected } }
    /// Whether the pack Delete asks about is one of Pilot's own, which is only hidden.
    private var deletingOwn: Bool { deleting.map { store?.isPilots($0.id) == true } ?? false }
    @State private var plan: ThemePlan?
    @State private var outcome = ""
    @State private var outcomeDetails = ""
    private var running: Bool { look.themePressing }
    @State private var apps: ThemeCoordinator.AppFollowing?

    /// Every theme this style can wear: Pilot's own in their designed order, then the ones a person made.
    private var cards: [PilotTheme] {
        let style = look.style.rawValue
        return look.shownThemes(for: style) + packs.filter { pack in pack.compatible(with: style) && !PilotTheme.designed.contains { $0.id == pack.id } }
            .map { $0.appearance(keeping: .standard) }
    }

    var body: some View {
        ThemeSection(themes: cards, picked: selected.isEmpty ? look.themeID : selected, columns: columns, applied: applied,
                     canApply: packs.contains { $0.id == selected }, running: running,
                     pick: { tryOn($0) }, apply: { press(selected) }, restore: { press(nil) },
                     mode: Binding(get: { following.mode != false }, set: { value in
                         do { following = try ThemeCoordinator.production().stageMode(follow: value); plan = nil }
                         catch { outcome = String(describing: error) }
                     }),
                     // Right-click: Apply theme's press on that card, and Delete…'s question, so refusals read the same.
                     menu: ThemeCardMenu(apply: { id in tryOn(id); press(id) },
                                         remove: { id in deleting = packs.first { $0.id == id } },
                                         isFavourite: { WallpaperSettings.shared.themeFavourites.contains($0) },
                                         favourite: { WallpaperSettings.shared.toggleThemeFavourite($0) })) {
            if let plan { preview(plan) }
            ThemeOutcome(line: outcome, details: outcomeDetails)
            if draft != nil {
                ThemePackEditor(session: editor,
                    save: { save(review: false) }, review: { save(review: true) }, cancel: { draft = nil })
            }
        } more: { more }
        // On the section, not inside More's fold: a card's right-click Remove… asks it with More folded too.
        .confirmationDialog("\(deletingOwn ? "Remove" : "Delete") \(deleting?.title ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(deletingOwn ? "Remove" : "Delete", role: .destructive) { deletePack() }
        } message: {
            Text(deletingOwn ? ThemeCatalogueGallery.removeNote(.builtIn) : "Its folder and pictures are removed. This can't be undone.")
        }
        // A theme tried on goes when Look is hidden behind another page too (page-switch-3).
        .onPageLeave { editor.invalidate(); look.endTrial() }
        .task {
            do {
                let owner = try ThemeCoordinator.production(), store = owner.store
                packs = try await Task.detached { try store.list() }.value; self.store = store
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
                Button("Delete…") { deleting = packs.first { $0.id == selected } }.disabled(!deletable)
            }
            if let apps {
                // Off is Pilot only (Sven, 2026-11-17): Pilot's own look takes the theme and no other app's files change.
                appSwitch("Themes recolour other apps", on: apps.othersOn, app: .others)
                    .help("Off: Pilot only. A theme changes Pilot's own look, and no other app's files.")
                Group {
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
                }.padding(.leading, 18).disabled(!apps.othersOn)
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
            let id = selected.isEmpty ? (packs.first?.id ?? PilotTheme.defaultID) : selected
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
    private func deletePack() {
        guard let pack = deleting else { return }
        deleting = nil
        do {
            let owner = try ThemeCoordinator.production()
            let hidden = try owner.delete(pack.id)
            packs = try owner.store.list()
            if selected == pack.id { selected = look.themeID }
            plan = nil; draft = nil; outcomeDetails = ""
            outcome = hidden ? "\(pack.title) removed. Look › Catalogue's Get brings it back." : "\(pack.title) deleted."
        } catch { outcome = String(describing: error) }
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
                look.endTrial()
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
        LookDesk(colors: look.colors, picture: (still ?? image).map { Image(nsImage: $0) })
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

// MARK: - Theme cards

/// The twelve theme cards, four across; Return picks the focused one and the arrows move between them.
private struct ThemeGrid: View {
    let look: Look
    var columns = 4

    var body: some View {
        ThemeCards(themes: look.shownThemes(for: look.style.rawValue),
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
    /// The cards' right-click Apply, Favourite and Remove….
    var menu: ThemeCardMenu? = nil
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
                ThemeCards(themes: themes, picked: picked, columns: columns, pick: pick, menu: menu).disabled(running)
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
    /// A card's right-click Apply, Favourite and Remove… (Sven: "i should be able to right click a theme in look and
    /// remove or apply"); none without them.
    var menu: ThemeCardMenu? = nil
    @FocusState private var focused: String?

    var body: some View {
        // The two longest lines stand for all of them: one hidden line a theme on every card was a grid's worth of text laid
        // out per card (page-instant: Look's first visit, 9 ms a card).
        let taglines = Array(Set(themes.map(\.tagline)).sorted { $0.count > $1.count }.prefix(2))
        // A Grid, not a lazy one: each row is as tall as its tallest card and every card fills it, so the rows' edges
        // line up whatever each display face's height.
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: themes.count, by: columns)), id: \.self) { start in
                // Two cards a turn while the page is built ahead (Staged); in view the row at once, as a card added resizes the rest.
                GridRow { Staged(by: 2, inView: false) {
                    ForEach(themes[start..<min(start + columns, themes.count)]) { theme in
                        ThemeCard(theme: theme, picked: picked == theme.id, focused: focused == theme.id,
                                  taglines: taglines) {
                            pick(theme.id)
                        }
                        .focusable()
                        .focused($focused, equals: theme.id)
                        .focusEffectDisabled()
                        .onKeyPress(.return) { pick(theme.id); return .handled }
                        .contextMenu {
                            if let menu {
                                Button("Apply") { menu.apply(theme.id) }
                                Button(menu.isFavourite(theme.id) ? "Remove from Favourites" : "Favourite") { menu.favourite(theme.id) }
                                Button("Remove…", role: .destructive) { menu.remove(theme.id) }
                            }
                        }
                    }
                } }
            }
        }
        .onMoveCommand { direction in
            guard let at = themes.firstIndex(where: { $0.id == focused }) else { return }
            let step = switch direction { case .left: -1; case .right: 1; case .up: -columns; case .down: columns; @unknown default: 0 }
            if themes.indices.contains(at + step) { focused = themes[at + step].id }
        }
    }
}

/// A theme card's right-click menu: Apply, as Apply theme does, and Remove…, as More's Delete… asks; both through
/// ThemeCoordinator, which refuses the theme in use and the last one, as Look › Catalogue's tiles do. Favourite marks
/// or unmarks it in the theme favourites the Carousel's Themes mode shows with Tab (Sven, build 2564).
struct ThemeCardMenu {
    let apply: (String) -> Void
    let remove: (String) -> Void
    var isFavourite: (String) -> Bool = { _ in false }
    var favourite: (String) -> Void = { _ in }
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
                if picked { shape.inset(by: ink.stroke).strokeBorder(ink.accent, lineWidth: ink.pickedStroke) }
            }
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
/// lines of text, and the theme's graph colours as bars along the foot. Every colour is the theme's own. One Canvas, laid
/// out as the stacks it replaced (page-instant: about 40 views a card made Look's first visit).
private struct ThemeWindow: View {
    let theme: PilotTheme
    static let radius: CGFloat = 7

    var body: some View {
        let t = theme
        Canvas { context, size in Self.draw(t, size, &context) }
            // As tall as the stacks were at least: their padding, rows and the graph's least height.
            .frame(minHeight: 80)
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color(hex: t.line)) }
            .accessibilityHidden(true)
    }

    private static func draw(_ t: PilotTheme, _ size: CGSize, _ context: inout GraphicsContext) {
        func fill(_ rect: CGRect, _ hex: UInt32, _ opacity: Double = 1, radius: CGFloat = 0) {
            let path = radius > 0 ? Path(roundedRect: rect, cornerRadius: radius) : Path(rect)
            context.fill(path, with: .color(Color(hex: hex).opacity(opacity)))
        }
        func capsule(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ hex: UInt32, _ opacity: Double = 1) {
            fill(CGRect(x: x, y: y, width: max(0, width), height: 3), hex, opacity, radius: 1.5)
        }
        // The sidebar: 28 to 44 pt, padded 6; its lights, then four rows 12 pt apart, the second picked.
        let side = min(44, max(28, (size.width - 1) / 2))
        fill(CGRect(x: side + 1, y: 0, width: size.width - side - 1, height: size.height), t.ground)
        fill(CGRect(x: 0, y: 0, width: side, height: size.height), t.sidebar)
        for (i, light) in [t.problem, t.amber, t.good].enumerated() {
            context.fill(Path(ellipseIn: CGRect(x: 6 + CGFloat(i) * 8, y: 6, width: 5, height: 5)), with: .color(Color(hex: light)))
        }
        for (row, most) in [22, 26, 18, 24].enumerated() {
            let y = 19 + CGFloat(row) * 12, width = min(CGFloat(most), side - 18)
            if row == 1 { fill(CGRect(x: 6, y: y, width: width + 6, height: 7), t.accent, t.dark ? 0.16 : 0.14, radius: 3.5) }
            capsule(9, y + 2, width, row == 1 ? t.accent : t.text3, row == 1 ? 1 : 0.55)
        }
        fill(CGRect(x: side, y: 0, width: 1, height: size.height), t.line)
        // The pane: padded 7; a prompt line, four lines of words 9 pt apart, then the graph down to the foot.
        let x = side + 1 + 7, room = size.width - side - 1 - 14
        capsule(x, 7, 6, t.accent)
        capsule(x + 10, 7, min(34, room - 32), t.text)
        capsule(x + 48, 7, min(18, room - 52), t.text3)
        for (k, line) in lines.enumerated() {
            var left = x
            for word in line {
                capsule(left, 16 + CGFloat(k) * 9, min(word.width, x + room - left), ink(word.ink, t))
                left += word.width + 4
            }
        }
        let top: CGFloat = 55, height = max(18, size.height - 7 - top)
        let shares = [0.45, 0.8, 0.6, 1.0, 0.7, 0.9, 0.55], bar = (room - 18) / 7
        for (i, share) in shares.enumerated() {
            let colour = t.graphs.isEmpty ? t.accent : t.graphs[i % t.graphs.count]
            let h = height * share
            fill(CGRect(x: x + CGFloat(i) * (bar + 3), y: top + height - h, width: bar, height: h), colour, radius: 1.5)
        }
    }

    /// The window's text as words: which of the theme's inks, how long.
    private static let lines: [[(ink: Int, width: CGFloat)]] = [[(2, 46)], [(3, 22), (1, 30)], [(4, 18), (2, 26), (1, 12)], [(1, 38)]]

    private static func ink(_ index: Int, _ t: PilotTheme) -> UInt32 { [t.text3, t.text2, t.text, t.second, t.third][index] }
}

/// Apply's result under the theme cards: the short line, then the apps and steps in a fold, folded until opened.
struct ThemeOutcome: View {
    let line: String
    let details: String
    var open: Binding<Bool>? = nil
    @Environment(\.ink) private var ink

    var body: some View {
        if !line.isEmpty { Text(line).foregroundStyle(ink.text2).textSelection(.enabled) }
        if !details.isEmpty {
            KitFold(title: "Apps and steps", open: open) {
                Text(details).font(.caption).foregroundStyle(ink.text2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Text shared with the external lifecycle proof; keeps recovery visible without a second engine or view. One short
/// line, how many apps and how many need a step; which apps and each step are behind the fold, with each change
/// (Sven, build 2962: "this should be inside a toggle"; the line and Details were build 2276's). `steps` puts the steps
/// under the line, where there is no fold: Look › Catalogue's HUD line.
func themeOutcomeText(_ result: JSONValue, steps withSteps: Bool = false) -> String {
    guard case .object(let values) = result else { return "" }
    func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let rows) = value else { return [] }
        return rows.compactMap(\.string)
    }
    let changed = strings(values["changed"]).count, steps = strings(values["next"]).count
    func count(_ done: String) -> String {
        var line = changed == 0 ? done : "\(done) to \(changed) \(changed == 1 ? "app" : "apps")"
        if steps > 0 { line += " · \(steps) \(steps == 1 ? "needs" : "need") a step" }
        return line + "."
    }
    var lines: [String] = []
    switch values["status"]?.string {
    case "applied": lines.append(count("Theme applied"))
    case "restored": lines.append(count("Default appearance restored"))
    case "unchanged": lines.append("Nothing needed changing.")
    case "failed":
        var state: String?
        if case .object(let recovery) = values["recovery"] { state = recovery["status"]?.string }
        lines.append(state == "recovery retained" ? "The theme was not applied, and Pilot could not put everything back. Pilot left those files alone and tries again next launch."
                                                  : "The theme was not applied. Everything went back as it was.")
    default: break
    }
    // A failure has no fold of steps to hide them in.
    let folded = !withSteps && ["applied", "restored"].contains(values["status"]?.string)
    return (folded ? lines : lines + strings(values["next"])).joined(separator: "\n")
}

/// The long form, behind the fold: the apps and each step to take, then each change and what was kept, why something
/// failed, custom reloads, and each file's recovery.
func themeOutcomeDetails(_ result: JSONValue) -> String {
    guard case .object(let values) = result else { return "" }
    func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let rows) = value else { return [] }
        return rows.compactMap(\.string)
    }
    let done = ["applied", "restored"].contains(values["status"]?.string), changed = strings(values["changed"])
    var lines = done && !changed.isEmpty ? ["Apps: \(changed.joined(separator: ", "))."] : []
    if done { lines += strings(values["next"]) }
    lines += done ? strings(values["changes"]).map { "Changed: \($0)" } + strings(values["kept"]) : []
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

/// Launcher's More: Apps show as (story 154), icon only, title only, or both, for every list that shows an app (Look's More
/// until Sven's notes on build 19; `look.appsShowAs` as before).
struct AppsShowAsBlock: View {
    @Environment(\.ink) private var ink
    @Bindable var look: Look

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CalmHeading(title: AppSection.appsShowAs.title) { InfoMark(text: LookPage.Info.appsShowAs) }
            HStack(spacing: 16) {
                Text("Every list: the menu, Binds, Open with, the top bar.").foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Segments(selection: $look.appsShowAs, options: AppsShowAs.allCases.map { ($0, $0.label) }, label: "Apps show as")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .blockSurface()
        }
        .moreBlock(.appsShowAs)
    }
}
