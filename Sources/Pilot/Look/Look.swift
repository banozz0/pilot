import AppKit
import Carbon
import Observation
import PilotCore
import PilotTiler
import SwiftUI

/// The look (design round 4, card agent-bo-95422890): the style, the theme every Pilot surface draws with (dark or light
/// as the theme is), and Glass for the window and the panels. A pick restyles Ghostty from the theme's
/// Omarchy palette and leaves the wallpaper alone (pick 8). Theme packages, the font picker and the Dark/Light switch
/// were taken out on 2026-10-09 (Sven; packages and fonts parked on branch parked/themes-fonts). Every setting is a
/// stored property saved as it changes, so the window follows at once.
@Observable @MainActor
final class Look {
    static let shared = Look()

    /// Instrument or Toybox (story 137, ADR 0008): a fresh install starts in Instrument. Current and the Tiling Rice layout
    /// were removed 2026-10-11 (parked on parked/current-style-tiling-rice): a saved Current loads as Instrument, and Calm is
    /// the one layout.
    var style: PilotStyle {
        didSet {
            guard oldValue != style else { return }
            var memory = defaults.data(forKey: "look.paletteMemory").flatMap { try? JSONDecoder().decode(ThemeStyleMemory.self, from: $0) } ?? .init()
            let chosen = (try? memory.select(from: oldValue.rawValue, to: style.rawValue, current: nativeAppearance.palette)) ?? .stock(PilotTheme.defaultID)
            defaults.set(try? ThemeDigest.encoded(memory), forKey: "look.paletteMemory")
            defaults.set(style.rawValue, forKey: Key.style)
            setNativePalette(chosen)
            resolve()
        }
    }
    /// The designed theme picked last (Lagoon by default); `pick` is how the Look page sets it.
    var themeID: String {
        didSet {
            defaults.set(themeID, forKey: Key.theme)
            if pack == nil { defaults.set(try? ThemeDigest.encoded(ThemeNativePalette.stock(themeID)), forKey: "look.appliedPalette") }
            resolve()
        }
    }
    /// Glass behind the window and every panel, popover and HUD, else Solid (Sven, 2026-10-09: off on a fresh install).
    var glass: Bool { didSet { defaults.set(glass, forKey: Key.glass) } }
    /// From 0 % (solid) to 100 % (33 by default): how see-through the window's surfaces are over Glass (Layers).
    var transparency: Int {
        didSet {
            if transparency != Self.clamped(transparency) { transparency = Self.clamped(transparency) }
            defaults.set(transparency, forKey: Key.transparency)
        }
    }
    /// How much the glass blurs the desktop behind it (Full by default, today's look): the window's, the panels', a Glass
    /// top bar's and the widgets'.
    var glassBlur: GlassBlur { didSet { defaults.set(glassBlur.rawValue, forKey: Key.glassBlur) } }
    /// A line in the accent around the focused window (card agent-bo-95422950: on, 2 points, from 1 to 8).
    var windowBorder: Bool { didSet { defaults.set(windowBorder, forKey: Key.windowBorder) } }
    var windowBorderWidth: Int {
        didSet {
            if windowBorderWidth != WindowBorder.clamped(windowBorderWidth) { windowBorderWidth = WindowBorder.clamped(windowBorderWidth) }
            defaults.set(windowBorderWidth, forKey: Key.windowBorderWidth)
        }
    }
    /// The border's colour: the theme's accent until another is picked (Sven, 2026-10-10).
    var windowBorderColour: ColourChoice { didSet { defaults.set(windowBorderColour.rawValue, forKey: Key.windowBorderColour) } }
    /// Defocus's blur, Off (0) or 1 to 5 (card agent-bo-95423220: 3); it set the dim too until 2026-10-16.
    var defocusStrength: Int {
        didSet {
            if defocusStrength != Defocus.clamped(defocusStrength) { defocusStrength = Defocus.clamped(defocusStrength) }
            defaults.set(defocusStrength, forKey: Key.defocusStrength)
        }
    }
    /// Defocus's dim, a percent of black from Off (0) to 80 (Sven, 2026-10-16): until moved, the dim the saved strength gave.
    var defocusDim: Int {
        didSet {
            if defocusDim != Defocus.clamped(dim: defocusDim) { defocusDim = Defocus.clamped(dim: defocusDim) }
            defaults.set(defocusDim, forKey: Key.defocusDim)
        }
    }
    /// Whether a mouse shake toggles Defocus (card agent-bo-95423220: on).
    var defocusShake: Bool { didSet { defaults.set(defocusShake, forKey: Key.defocusShake) } }
    /// The swings a shake takes, from 3 to 8, and the seconds they must fall within, 0.4 to 1.5 (C2, 2026-10-09: 5 and 0.7).
    var defocusShakeSwings: Int {
        didSet {
            if defocusShakeSwings != ShakeDetector.clamped(swings: defocusShakeSwings) {
                defocusShakeSwings = ShakeDetector.clamped(swings: defocusShakeSwings)
            }
            defaults.set(defocusShakeSwings, forKey: Key.defocusShakeSwings)
        }
    }
    var defocusShakeWithin: Double {
        didSet {
            if defocusShakeWithin != ShakeDetector.clamped(within: defocusShakeWithin) {
                defocusShakeWithin = ShakeDetector.clamped(within: defocusShakeWithin)
            }
            defaults.set(defocusShakeWithin, forKey: Key.defocusShakeWithin)
        }
    }
    /// How every list shows an app: icon, title or both (story 154: both).
    var appsShowAs: AppsShowAs { didSet { defaults.set(appsShowAs.rawValue, forKey: Key.appsShowAs) } }
    /// How the app window draws its areas (window directions, Sven 2026-10-11): the rail and page list by default. Its own
    /// key: `look.layout` held the removed Tiling Rice pick and is cleared at launch.
    var windowShape: WindowShape { didSet { defaults.set(windowShape.rawValue, forKey: Key.windowShape) } }
    /// How Hyper+Space draws the menu: the Rail by default, or Classic (menu Rail and Classic, Sven 2026-10-12).
    var menuLayout: MenuLayoutStyle { didSet { defaults.set(menuLayout.rawValue, forKey: Key.menuLayout) } }
    /// macOS's Reduce transparency and Increase contrast, followed live (followSystem).
    private(set) var reduceTransparency = false
    private(set) var increaseContrast = false
    /// The wallpaper's brightest spot, the floor's yardstick; the theme's own wallpaper stands in until it is read.
    private(set) var wallpaperSpot: [Double]?

    /// The theme drawn now, the picked one. Its colours are made once per theme; Theme reads them, so every surface
    /// redraws (the app window controller restyles the windows themselves).
    private(set) var theme = PilotTheme.standard { didSet { colors = ThemeColors(theme); paletteRevision += 1 } }
    private(set) var paletteRevision = 0
    var packAppearance: PilotTheme? { pack == nil ? nil : theme }
    private var pack: ThemePack?
    private(set) var colors = ThemeColors(PilotTheme.standard)

    /// Glass while it is on, Solid whenever macOS asks for less transparency, and at Transparency 0 %: the panels', and
    /// the app window's unless its style keeps it solid (windowMaterial).
    var effectiveMaterial: WindowMaterial { glass && !reduceTransparency && transparency > 0 ? .glass : .solid }
    /// The app window's own: Toybox's stays solid whatever the material (Sven, 2026-10-08), the rest take effectiveMaterial.
    var windowMaterial: WindowMaterial { material(on: .window) }
    /// `surface`'s material where it follows Glass in its own style (the app window, the AI chat): solid in Toybox.
    func material(on surface: StyleSurface) -> WindowMaterial { style == .toybox ? .solid : effectiveMaterial }
    /// The glass's tint: `ground` at the Transparency's strength, or at `alpha` percent.
    func glassTint(_ ground: Color, alpha: Int? = nil) -> NSColor {
        NSColor(ground).withAlphaComponent(CGFloat(alpha ?? materialValues.windowAlpha) / 100)
    }
    /// What the material means for this theme and wallpaper outside the app window: a panel's ground over the glass,
    /// and a block's surface strength (Theme.cardFill).
    var materialValues: MaterialValues {
        let material = effectiveMaterial, strength = Layers.strength(transparency: transparency)
        let key = ValuesKey(theme: theme.id, material: material, strength: strength, spot: wallpaperSpot, increaseContrast: increaseContrast)
        if let made = madeValues[key] { return made }
        if madeValues.count > 64 { madeValues = [:] }
        let made = MaterialValues(theme: theme, material: material, strength: strength, spot: wallpaperSpot, increaseContrast: increaseContrast)
        madeValues[key] = made
        return made
    }

    /// The app window's layers (round 15): solid while its material is (windowMaterial), else Transparency's table with
    /// the contrast floor on the window's style's card.
    var layers: Layers {
        let key = LayersKey(style: style, theme: theme.id, material: windowMaterial,
                            transparency: transparency, spot: wallpaperSpot, increaseContrast: increaseContrast)
        if let made = madeLayers[key] { return made }
        if madeLayers.count > 64 { madeLayers = [:] }
        let c = StyleTokens.of(style, theme: theme).colors
        let made = Layers(transparency: key.material == .solid ? 0 : transparency, text: c.text2.rgb, card: c.panel.rgb, ground: c.canvas.rgb,
                          spot: wallpaperSpot ?? theme.wallpaper.colour, increaseContrast: increaseContrast)
        madeLayers[key] = made
        return made
    }

    /// Every tile and card reads these as it draws, so the floor's maths runs once per change, not once per read.
    @ObservationIgnored private var madeValues: [ValuesKey: MaterialValues] = [:]
    @ObservationIgnored private var madeLayers: [LayersKey: Layers] = [:]
    /// What the window's layers are made from; hashed, not formatted, as every layered fill reads them as it draws.
    private struct LayersKey: Hashable {
        let style: PilotStyle, theme: String, material: WindowMaterial, transparency: Int
        let spot: [Double]?, increaseContrast: Bool
    }
    /// What a material's values are made from, hashed as LayersKey is (Theme.cardFill reads them as it draws).
    private struct ValuesKey: Hashable {
        let theme: String, material: WindowMaterial, strength: Int, spot: [Double]?, increaseContrast: Bool
    }

    /// Pilot's monospace faces by size and weight, made once.
    @ObservationIgnored private var monoFonts: [String: NSFont] = [:]
    /// The last failure (Ghostty's colours not written), shown on the Look page.
    private(set) var lastError: String?
    /// The last keyboard layout failure, shown on Setup apart from the look's own.
    private(set) var layoutError: String?
    /// macOS's enabled keyboard layouts (story 111), read once Setup or the top bar asks and again whenever the current or the
    /// enabled ones change, in Pilot or outside it.
    private(set) var layouts: [InputSource] = []

    @ObservationIgnored private let given: [OmarchyTheme]?
    @ObservationIgnored private let ghostty: any GhosttyWriting
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyboard: KeyboardLayouts
    @ObservationIgnored private var followingLayouts: [NSObjectProtocol] = []
    @ObservationIgnored private var followingSystem: NSObjectProtocol?

    private enum Key {
        static let layout = "look.layout", style = "look.style", theme = "look.theme", glass = "look.glass", transparency = "look.transparency",
                   glassBlur = "look.glassBlur"
        /// The Strength slider's and the material's (Solid, Tinted or Glass), read only to carry them over to Transparency
        /// and Glass; left in place, so an older Pilot still reads them.
        static let strength = "look.strength", material = "look.material"
        static let windowBorder = "look.windowBorder", windowBorderWidth = "look.windowBorderWidth", windowBorderColour = "look.windowBorderColour",
                   defocusStrength = "look.defocusStrength", defocusDim = "look.defocusDim",
                   defocusShake = "look.defocusShake", defocusShakeSwings = "look.defocusShakeSwings",
                   defocusShakeWithin = "look.defocusShakeWithin", appsShowAs = "look.appsShowAs",
                   windowShape = "look.windowLayout", menuLayout = "look.menuLayout", menuLayoutLine = "look.menuLayoutLine"
    }

    init(themes: [OmarchyTheme]? = nil, ghostty: any GhosttyWriting = GhosttyBridge.Writer(),
         inputSources: any InputSourceSystem = TextInputSources(), defaults: UserDefaults = .pilot()) {
        given = themes
        self.ghostty = ghostty
        self.defaults = defaults
        keyboard = KeyboardLayouts(system: inputSources)
        // A saved Current is saved again as Instrument, and the removed layout pick dropped; every other pref stands.
        let savedStyle = defaults.string(forKey: Key.style), style = PilotStyle(saved: savedStyle)
        self.style = style
        if let savedStyle, savedStyle != style.rawValue { defaults.set(style.rawValue, forKey: Key.style) }
        defaults.removeObject(forKey: Key.layout)
        let saved = defaults.string(forKey: Key.theme)
        themeID = PilotTheme.current(saved)
        // A saved Strength (80 where only a material was picked) is carried over once, under Transparency's own key, as
        // the Transparency whose ground draws what it drew.
        let material = defaults.string(forKey: Key.material)
        let strength = defaults.object(forKey: Key.strength) as? Int
        if defaults.object(forKey: Key.transparency) == nil, strength != nil || material != nil {
            defaults.set(Layers.transparency(strength: strength ?? 80), forKey: Key.transparency)
        }
        var transparency = defaults.object(forKey: Key.transparency) == nil ? 33 : Self.clamped(defaults.integer(forKey: Key.transparency))
        // The material is carried over once as Glass (Sven, 2026-10-09): Tinted and Glass on, Solid and Transparency 0 %
        // off, the slider then back at 33 % for the day Glass is turned on.
        if defaults.object(forKey: Key.glass) == nil, let material {
            defaults.set(material != "solid" && transparency > 0, forKey: Key.glass)
            if transparency == 0 { transparency = 33; defaults.set(33, forKey: Key.transparency) }
        }
        glass = defaults.bool(forKey: Key.glass)
        self.transparency = transparency
        glassBlur = defaults.string(forKey: Key.glassBlur).flatMap(GlassBlur.init(rawValue:)) ?? .full
        windowBorder = defaults.object(forKey: Key.windowBorder) as? Bool ?? true
        windowBorderWidth = defaults.object(forKey: Key.windowBorderWidth) == nil
            ? WindowBorder.defaultWidth : WindowBorder.clamped(defaults.integer(forKey: Key.windowBorderWidth))
        windowBorderColour = defaults.string(forKey: Key.windowBorderColour).flatMap(ColourChoice.init(rawValue:)) ?? .theme
        let defocusStrength = defaults.object(forKey: Key.defocusStrength) == nil ? Defocus.defaultStrength
            : Defocus.clamped(defaults.integer(forKey: Key.defocusStrength))
        self.defocusStrength = defocusStrength
        // The dim the saved strength gave is saved once as the dim, so moving the blur later leaves it where it was.
        if defaults.object(forKey: Key.defocusDim) == nil { defaults.set(Defocus.dim(strength: defocusStrength), forKey: Key.defocusDim) }
        defocusDim = Defocus.clamped(dim: defaults.integer(forKey: Key.defocusDim))
        defocusShake = defaults.object(forKey: Key.defocusShake) as? Bool ?? true
        defocusShakeSwings = (defaults.object(forKey: Key.defocusShakeSwings) as? Int).map(ShakeDetector.clamped(swings:))
            ?? ShakeDetector.defaultSwings
        defocusShakeWithin = (defaults.object(forKey: Key.defocusShakeWithin) as? Double).map(ShakeDetector.clamped(within:))
            ?? ShakeDetector.defaultWithin
        appsShowAs = defaults.string(forKey: Key.appsShowAs).flatMap(AppsShowAs.init(rawValue:)) ?? .standard
        windowShape = WindowShape(saved: defaults.string(forKey: Key.windowShape))
        // Line became the default (Q165): a Classic saved before Line existed moves to Line once; one picked after stays.
        let savedLayout = defaults.string(forKey: Key.menuLayout)
        var layout = MenuLayoutStyle(saved: savedLayout)
        if !defaults.bool(forKey: Key.menuLayoutLine), savedLayout == MenuLayoutStyle.classic.rawValue {
            layout = .line
            defaults.set(layout.rawValue, forKey: Key.menuLayout)
        }
        defaults.set(true, forKey: Key.menuLayoutLine)
        menuLayout = layout
        if themes == nil {
            if let data = defaults.data(forKey: "look.appliedPalette"),
               let palette = try? JSONDecoder().decode(ThemeNativePalette.self, from: data),
               (try? palette.validate()) != nil, palette.compatible(with: style.rawValue) {
                switch palette { case .stock(let id): themeID = id; case .pack(let value): pack = value }
            } else { pack = try? ThemeCoordinator.persistedPack() }
        }
        if !ThemeNativePalette.stock(themeID).compatible(with: style.rawValue) { themeID = PilotTheme.defaultID }
        resolve()
        colors = ThemeColors(theme)
        // A theme retired in round 15 starts as its successor, saved, and Ghostty follows as on a pick unless Pilot's look
        // was taken out of it; after this init, so a failure's tip never reads Look.shared while it is being made.
        if let saved, saved != themeID {
            defaults.set(themeID, forKey: Key.theme)
            looklog.notice("theme \(saved, privacy: .public) retired: \(self.themeID, privacy: .public)")
            if ghostty.isApplied { Task { self.restyleGhostty() } }
        }
    }

    private static func clamped(_ transparency: Int) -> Int { min(100, max(0, transparency)) }

    /// Omarchy's themes, read from the bundle the first time a pick needs them.
    var themes: [OmarchyTheme] { given ?? GhosttyBridge.themes }
    var usesThemePacks: Bool { given == nil && ghostty is GhosttyBridge.Writer }

    /// The main screen's wallpaper as macOS names it, whether or not its file is still there; a fake in the tests.
    @ObservationIgnored var desktopPicture: () -> URL? = { NSScreen.main.flatMap(NSWorkspace.shared.desktopImageURL) }
    /// The wallpaper the main screen shows now; nil when its file is gone.
    var currentWallpaper: URL? { desktopPicture().flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }

    /// Picks a designed theme, even the one picked already: the theme follows, and Ghostty takes its Omarchy palette
    /// (pick 8); the wallpaper stays.
    func pick(_ id: String) {
        guard ThemeNativePalette.stock(id).compatible(with: style.rawValue) else { lastError = "This palette requires Toybox"; return }
        if given == nil, !ThemeCoordinator.legacyAllowed() {
            lastError = "Restore the active theme pack before choosing a legacy colour theme"
            return
        }
        themeID = id
        restyleGhostty()
        looklog.notice("theme: \(self.theme.id, privacy: .public)")
    }

    /// Ghostty takes the theme's Omarchy palette: a pick, and Ghostty: use Pilot's look.
    func restyleGhostty() {
        do {
            try ghostty.apply(GhosttyLook(theme: themes.named(theme.source)))
            if lastError != nil { lastError = nil }
        } catch {
            let message = "Ghostty's colours not changed: \(error)"
            lastError = message
            looklog.error("\(message, privacy: .public)")
            HUD.tip(message)
        }
    }

    /// The picked theme, else the default.
    private func resolve() {
        let shown = (trial ?? (trialID == nil ? pack : nil)).flatMap { $0.compatible(with: style.rawValue) ? $0 : nil }
        // A designed theme keeps its own face and shape; any other pack takes the current theme's.
        let base = (trialID ?? shown?.id).flatMap(PilotTheme.named) ?? PilotTheme.named(themeID) ?? .standard
        let next = shown?.appearance(keeping: base) ?? base
        if next != theme { madeValues.removeAll(); madeLayers.removeAll(); theme = next }
    }

    /// Pack selection is persisted by the ownership engine; the legacy theme ID remains the pre-pack baseline.
    func packChanged(_ pack: ThemePack?) {
        madeValues.removeAll(); madeLayers.removeAll()
        self.pack = pack; resolve()
    }

    /// Tried on from Look › Theme: shown at once and written nowhere. What a plan reads stays `pack` and `themeID`.
    private(set) var trial: ThemePack?
    private(set) var trialID: String?

    func tryOn(id: String, pack: ThemePack?) { trialID = id; trial = pack; resolve() }
    /// Leaving the page. `keep` makes a designed theme Pilot's own, as a pick does, without touching Ghostty.
    func endTrial(keep: Bool) {
        let id = trialID
        trial = nil; trialID = nil
        if keep, let id, PilotTheme.named(id) != nil, themeID != id { themeID = id } else { resolve() }
    }

    /// An Apply or Restore press from Look is running. The controls for the parts a theme owns (theme, Glass, Transparency,
    /// Blur, cursor colours, bar layout) wait, so no edit lands during macOS's mode wait and trips recovery's "later
    /// personal appearance edit" (review 4 note).
    var themePressing = false

    var nativeBaseline: ThemeNativeAppearance {
        .init(palette: .stock(themeID), material: .init(glass: glass, transparency: transparency, blur: glassBlur.rawValue))
    }
    var nativeAppearance: ThemeNativeAppearance {
        .init(palette: pack.map(ThemeNativePalette.pack) ?? .stock(themeID),
              material: .init(glass: glass, transparency: transparency, blur: glassBlur.rawValue))
    }
    private func setNativePalette(_ palette: ThemeNativePalette) {
        switch palette {
        case .stock(let id): pack = nil; themeID = id
        case .pack(let value): pack = value; resolve()
        }
        defaults.set(try? ThemeDigest.encoded(palette), forKey: "look.appliedPalette")
    }
    /// The coordinator journals before this effect, then reads these same public values to verify it.
    func applyNative(_ value: ThemeNativeAppearance) {
        setNativePalette(value.palette)
        if glass != value.material.glass { glass = value.material.glass }
        if transparency != value.material.transparency { transparency = value.material.transparency }
        if glassBlur.rawValue != value.material.blur { glassBlur = GlassBlur(rawValue: value.material.blur) ?? .full }
    }

    #if DEBUG
    /// Tests and the gallery: shows a theme at once, saving nothing and leaving Ghostty alone.
    func preview(_ id: String) { theme = PilotTheme.named(id) ?? .standard }   // resolve()'s fallback
    /// Renders: a wallpaper's brightest spot without reading the Mac's wallpaper.
    func preview(spot: [Double]?) { wallpaperSpot = spot }
    #endif

    /// Follows Reduce transparency, Increase contrast and the wallpaper's brightness; the app does this once at launch.
    func followSystem() {
        readAccessibility()
        if followingSystem == nil {
            followingSystem = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readAccessibility() }
            }
        }
        readWallpaper()
    }

    private func readAccessibility() {
        let workspace = NSWorkspace.shared
        setAccessibility(reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                         increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
    }

    func setAccessibility(reduceTransparency: Bool, increaseContrast: Bool) {
        if self.reduceTransparency != reduceTransparency { self.reduceTransparency = reduceTransparency }
        if self.increaseContrast != increaseContrast { self.increaseContrast = increaseContrast }
    }

    /// The main screen's wallpaper, its brightest spot read off the main thread.
    func readWallpaper() {
        guard let url = currentWallpaper else { return }
        Task {
            let spot = await Task.detached { WallpaperBrightness.brightest(url) }.value
            if spot != wallpaperSpot { wallpaperSpot = spot }
        }
    }

    /// Reads the layouts and, the first time, follows macOS's notices that the selected or enabled ones changed.
    func followLayouts() {
        layouts = keyboard.choices
        guard followingLayouts.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        followingLayouts = [kTISNotifySelectedKeyboardInputSourceChanged, kTISNotifyEnabledKeyboardInputSourcesChanged].map { name in
            center.addObserver(forName: Notification.Name(name as String), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self.map { $0.layouts = $0.keyboard.choices } }
            }
        }
    }

    /// The layout in use, as macOS last said.
    var currentLayout: InputSource? { layouts.first(where: \.isCurrent) }

    /// The next enabled layout, wrapping round: Next in the keyboard layout's popover and its menu (card agent-bo-95422852).
    func pickNextLayout() {
        if let next = KeyboardLayouts.next(in: layouts) { pickLayout(next.id) }
    }

    /// The keyboard layout picked on Setup or the top bar; Pilot only selects among the enabled ones.
    func pickLayout(_ id: String) {
        do {
            guard try keyboard.pick(id, from: layouts) else { return }
            layoutError = nil
            looklog.notice("keyboard layout: \(id, privacy: .public)")
        } catch {
            layoutError = "keyboard layout not changed: \(error)"
            looklog.error("\(self.layoutError ?? "", privacy: .public)")
        }
        layouts = keyboard.choices
    }

    /// Pilot's monospace face: JetBrains Mono, else the system's.
    func monoFont(size: CGFloat, medium: Bool = false) -> NSFont {
        let key = "\(size)\(medium)"
        if let made = monoFonts[key] { return made }
        let (face, system): (String, NSFont.Weight) = medium ? ("JetBrainsMono-Medium", .medium) : ("JetBrainsMono-Regular", .regular)
        let made = NSFont(name: face, size: size) ?? .monospacedSystemFont(ofSize: size, weight: system)
        monoFonts[key] = made
        return made
    }
}

/// A theme's colours as SwiftUI draws them, by the theme's role names, made once per theme rather than on every read.
struct ThemeColors {
    let ground, sidebar, surface, raised, line, line2, text, text2, text3, accent, second, third, good, amber, problem: Color
    let selection, onAccent, accentText, windowLine, keyFill, keyHighlight: Color
    let graphs, modules: [Color]

    init(_ t: PilotTheme) {
        let c = { Color(hex: $0) }
        let p = { (paint: Paint) in Color(paint) }
        ground = c(t.ground); sidebar = c(t.sidebar); surface = c(t.surface); raised = c(t.raised)
        line = c(t.line); line2 = c(t.line2); text = c(t.text); text2 = c(t.text2); text3 = c(t.text3)
        accent = c(t.accent); second = c(t.second); third = c(t.third); good = c(t.good); amber = c(t.amber); problem = c(t.problem)
        selection = p(t.selection); onAccent = c(t.onAccent); accentText = c(t.accentText); windowLine = p(t.windowLine)
        keyFill = c(t.keyFill); keyHighlight = p(t.keyHighlight)
        graphs = t.graphs.map(c); modules = t.modules.map(c)
    }
}
