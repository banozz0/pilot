import AppKit
import PilotCore
import SwiftUI

/// Look (design round 4, card agent-bo-95422896): the style, the ten themes as Sven's theme cards, each drawn in its own
/// colours and display face over a small window in that theme; Glass with its Transparency; the wallpaper. The focused
/// window's border and Defocus are Tiling's Focused window block (page map, Sven 2026-10-17). Every
/// setting has an ⓘ saying what it does (Sven, 2026-10-09). A column of cards under the page's title; nothing folds
/// (card agent-bo-95423004). A pick restyles the window at once and Ghostty with it.
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

    init(look: Look = .shared, wallpaper: WallpaperSettings = .shared, cursors: CursorSets? = nil, effects: CursorEffects? = nil,
         screens: [WallpaperScreen]? = nil, section: AppSection? = nil, focus: WallpaperBlock.Focus? = nil, landed: @escaping () -> Void = {}) {
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
        static let theme = "Pilot's colours, and whether it is dark or light. Ghostty takes the theme's colours too."
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

    // MARK: The page

    private var column: some View {
        @Bindable var look = look
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Pilot and Ghostty change together.").font(ink.ui(13.5)).foregroundStyle(ink.text2)
                CalmHeading(title: "Style") { InfoMark(text: Info.style) }
                StylePicker(look: look).padding(14).blockSurface()
                CalmHeading(title: "Hyper+Space menu") { InfoMark(text: Info.menuLayout) }
                MenuLayoutPicker(look: look).padding(14).blockSurface()
                CalmHeading(title: "Window layout") { InfoMark(text: Info.windowShape) }
                calmLine("Try each: the window redraws at once.") { windowShape }
                CalmHeading(title: "Theme") { InfoMark(text: Info.theme) }
                ThemeGrid(look: look, columns: themeColumns)
                    .onGeometryChange(for: Int.self) { [instrument = ink.isInstrument] in
                        Self.calmColumns($0.size.width, instrument: instrument)
                    } action: { themeColumns = $0 }
                CalmHeading(title: "Apps show as") { InfoMark(text: Info.appsShowAs) }
                calmLine("Every list: the menu, Binds, Open with, the top bar.") { appsShowAs }
                // Glass, its Transparency and its Blur alone (page map, Sven 2026-10-17; Blur 2026-11-01); the rest went to Tiling › Focused window.
                KitBlock(title: "Glass") {
                    switchRow("Glass", Info.glass, isOn: $look.glass, first: true)
                    if look.glass {
                        calmRow(44) {
                            setting("Transparency", Info.transparency); Spacer()
                            transparencySlider
                            transparencyValue(11.5).frame(width: 38, alignment: .trailing)
                        }
                        calmRow(44) {
                            setting("Blur", Info.glassBlur); Spacer()
                            Segments(selection: $look.glassBlur, options: GlassBlur.allCases.map { ($0, $0.title) }, label: "Blur")
                        }
                    }
                }
                CursorBlock(look: look, cursors: cursors, effects: effects)
                WallpaperBlock(settings: wallpaper, screens: screens, focus: focus).id(AppSection.wallpaper)
                errorLine.padding(.top, 12)
            }
            .padding(.horizontal, ink.pageInset).padding(.top, ink.pageTop(6)).padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                ColourChoicePicker(choice: $effects.colour, theme: CursorEffectColours.of(look.themeID).effectRGB, label: "Effect colour")
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
        let palette = samples.palette(set, cursors.colours, theme: look.themeID, custom: cursors.custom(set))
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
        let (fill, outline) = custom.colours(samples.palette(cursors.set, .theme, theme: look.themeID, custom: custom))
        BlockRow {
            Spacer()
            well("Fill", fill) { cursors.fill = .custom($0) }
            well("Outline", outline) { cursors.outline = .custom($0) }
            Button { (cursors.fill, cursors.outline) = (.custom(outline), .custom(fill)) } label: { Image(systemName: "arrow.left.arrow.right") }
                .buttonStyle(.pilot).help("Swap fill and outline").accessibilityLabel("Swap fill and outline")
        }
        let palette = samples.palette(cursors.set, .custom, theme: look.themeID, custom: custom)
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
    @FocusState private var focused: String?

    var body: some View {
        let themes = PilotTheme.designed
        // A Grid, not a lazy one: each row is as tall as its tallest card and every card fills it, so the rows' edges
        // line up whatever each display face's height.
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: themes.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(themes[start..<min(start + columns, themes.count)]) { theme in
                        ThemeCard(theme: theme, picked: look.themeID == theme.id, focused: focused == theme.id,
                                  taglines: themes.map(\.tagline)) {
                            look.pick(theme.id)
                        }
                        .focusable()
                        .focused($focused, equals: theme.id)
                        .focusEffectDisabled()
                        .onKeyPress(.return) { look.pick(theme.id); return .handled }
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
