/// Transparency (Sven, 2026-10-08, design round 15, artifact Eh93LMpjwRxNRWnc8VHN47 section c): one value from 0 %
/// (solid) to 100 % sets how strong each of the app window's surface roles stays over the layer it sits on, linearly
/// from 100 % to its own least. Translucent layers multiply, so only the ground and the cards carry body; what sits in a
/// card is a thin tint a step off it. The signal (accent fills, the Hyper switch, text) never goes see-through. It
/// replaces the Strength slider (40 to 100 %) for the window; the panels keep their material's strength
/// (strength(transparency:)).
public struct Layers: Equatable, Sendable {
    /// From 0 (solid) to 1.
    public let transparency: Double
    /// Each role's strength from 0 to 1: the window's ground over the blur, its sidebar, a card on the page, a well sunk
    /// into a card (Home's workspace screens, the keyboard tray), a raised tile, bound key cap or chip, an unbound key cap.
    public var ground, sidebar, card, well, raised, keyFree: Double
    /// Body text's contrast on a card over the wallpaper, and whether the floor lifted the card; 0 and false from the table
    /// alone (init(transparency:)).
    public private(set) var contrast = 0.0
    public private(set) var lifted = false

    /// Every role whole.
    public static let solid = Layers(transparency: 0)

    /// The table: each role's strength at `percent` (0 to 100), from 100 % at 0 to its least at 100.
    public init(transparency percent: Int) {
        let t = Double(min(100, max(0, percent))) / 100
        let at = { (least: Double) in 1 + (least - 1) * t }
        transparency = t
        (ground, sidebar, card, well, raised, keyFree) = (at(Self.leastGround), at(0.55), at(0.35), at(0.25), at(0.18), at(0.08))
    }

    /// The table with the contrast floor (round 4's, moved onto the card in round 15): the card lifts in 2 % steps until
    /// `text` reads at 4.5 : 1 on `card` over `ground` at its strength over the wallpaper's brightest `spot` (0 to 255);
    /// the roles inside keep their own step over it. Increase contrast makes every surface inside the window solid.
    public init(transparency percent: Int, text: UInt32, card: UInt32, ground: UInt32, spot: [Double], increaseContrast: Bool = false) {
        self.init(transparency: percent)
        if increaseContrast { (self.card, well, raised, keyFree) = (1, 1, 1, 1) }
        let behind = Contrast.mix(Contrast.rgb(ground), spot, self.ground)
        let ratio = { (strength: Double) in Contrast.ratio(Contrast.rgb(text), Contrast.mix(Contrast.rgb(card), behind, strength)) }
        contrast = ratio(self.card)
        while contrast < MaterialValues.floor && self.card < 1 {
            self.card = min(1, self.card + 0.02)
            lifted = true
            contrast = ratio(self.card)
        }
    }

    /// The Strength slider's value (40 to 100) as Transparency, for a saved setting: the one whose ground draws what that
    /// Strength drew on Glass (MaterialValues.windowAlpha, 55 % of it), so a carried-over window keeps its look. A ground
    /// thinner than the table's least (under 77) clamps to 100 %. 80 is 97 %, 100 78 %.
    public static func transparency(strength: Int) -> Int {
        let ground = Double(MaterialValues.windowAlpha(strength: min(100, max(40, strength))))
        return min(100, max(0, Int(((100 - ground) / (100 - 100 * leastGround) * 100).rounded())))
    }
    /// Transparency as the Strength the panels' Glass still reads (MaterialValues): transparency(strength:) undone, so a
    /// carried-over Strength comes back to the panels.
    public static func strength(transparency: Int) -> Int {
        let ground = 100 * (1 + (leastGround - 1) * Double(min(100, max(0, transparency))) / 100)
        return min(100, max(40, Int((ground / MaterialValues.glassShare).rounded())))
    }
    /// The ground's least, at 100 %.
    static let leastGround = 0.42

    /// A card's lit top hairline over a see-through window (Empryo's inset 0 1px 0 #ffffff0a): white at 4 % on a dark
    /// theme, at 50 % on a light one, where 4 % would not show; none while solid.
    public func highlight(dark: Bool) -> Paint? { transparency > 0 ? Paint(0xFFFFFF, dark ? 0.04 : 0.5) : nil }
}

extension StyleTokens {
    /// Instrument at `layers` (round 15): every see-through Instrument surface takes this one post-process, kept apart
    /// from the token constructor (which the theme-following Instrument rewrites). Each fill takes its role's strength,
    /// except the canvas: the window's ground draws once, as its backdrop's tint or fill (Theme.windowFill). Cards get the
    /// lit hairline. Over glass there are no soft shadows, and the muted text steps up one level, since grey on glass is
    /// the first thing to stop reading (Sven, Q356: readable through fills and ink, never shadows). Toybox stays solid, so
    /// it comes back as it is, as does anything while solid.
    public func seeThrough(_ layers: Layers) -> StyleTokens {
        guard kind == .instrument, layers.transparency > 0 else { return self }
        let at = { (paint: Paint, strength: Double) in Paint(paint.rgb, paint.alpha * strength) }
        var c = colors
        c.sidebar = at(c.sidebar, layers.sidebar)
        c.panel = at(c.panel, layers.card)
        (c.sunken, c.well, c.board) = (at(c.sunken, layers.well), at(c.well, layers.well), at(c.board, layers.well))
        (c.raised, c.tile, c.key) = (at(c.raised, layers.raised), at(c.tile, layers.raised), at(c.key, layers.raised))
        c.keyFree = at(c.keyFree, layers.keyFree)
        (c.text3, c.text4) = (c.text2, c.text3)
        var d = depth
        for role: WritableKeyPath<StyleDepths, StyleDepth> in [\.card, \.control, \.key, \.pop, \.board, \.boardKey] {
            // A shadow with no blur is a solid edge, not a soft shadow: it stays.
            d[keyPath: role].shadows = d[keyPath: role].shadows.filter { $0.radius == 0 }
        }
        d.card.highlight = layers.highlight(dark: dark)
        return StyleTokens(kind: kind, dark: dark, colors: c, type: type, radii: radii, depth: d, density: density)
    }
}
