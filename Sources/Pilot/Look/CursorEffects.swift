import AppKit
import Observation
import PilotCore
import QuartzCore

/// Cursor trails and halos (P84, Q737, Q738; builder spec vault `Projects/Pilot/Cursors 1.1/spec/cursor-effects.md` §2–§6,
/// numbers in `Packaging/Cursors/effects.json`). Sven's picks (Q787–Q790): a 1.5 pt edge under every stroke and dot, the
/// right-click ripple in the theme's second colour, the Ring hides after 3 s still, Spotlight shows only while
/// `cursor.spotlight` is held, which has no default key. Drawn in one click-through overlay per screen that exists only
/// while an effect is on; pointer events come from NSEvent monitors, never the bind tap (ADR 0001); the display link runs
/// only while something moves or fades, so a still pointer costs no wakeups.

enum CursorTrail: String, CaseIterable, Sendable {
    case off, thread, comet, dots
    var title: String { rawValue.capitalized }
    /// How long a sample stays drawn; a dot's life for Dots.
    var length: TimeInterval {
        switch self { case .off: 0; case .thread: 0.2; case .comet: 0.11; case .dots: 0.3 }
    }
}

// MARK: - What is alive

/// The pointer's recent history and every effect's fade, in global points and `CACurrentMediaTime` seconds. Pure: the
/// overlay feeds it events and draws it; the renders build one by hand.
struct CursorEffectState {
    /// `joined`: the trail draws the step from the sample before; false where a run starts (T45).
    struct Sample { var point: CGPoint; var time: TimeInterval; var joined = true }
    struct Ripple { var point: CGPoint; var time: TimeInterval; var right: Bool }

    /// A level between 0 and 1 easing to its target over `duration` (0 = at once).
    struct Fade {
        var from = 0.0, to = 0.0, start: TimeInterval = 0, duration = 0.0
        func level(_ now: TimeInterval) -> Double {
            duration <= 0 ? to : from + (to - from) * min(1, max(0, (now - start) / duration))
        }
        func moving(_ now: TimeInterval) -> Bool { duration > 0 && now - start < duration }
        mutating func go(_ target: Double, _ now: TimeInterval, instant: Bool) {
            guard target != to else { return }
            from = level(now); to = target; start = now; duration = instant ? 0 : CursorEffectState.fadeSeconds
        }
    }

    var trail: CursorTrail = .off
    var ring = false, ripple = false
    var reduceMotion = false

    var pointer = CGPoint.zero
    /// The trail's points: every pointer event for Thread and Comet, a point every 13 pt of travel for Dots.
    var samples: [Sample] = []
    /// Travel since the last dot.
    var travel: CGFloat = 0
    var ripples: [Ripple] = []
    var lastMove: TimeInterval = 0
    var squeeze: TimeInterval?
    var ringFade = Fade()
    var spotlight = Fade()
    /// Every screen's frame in global points: a step from one to another starts a new run. Empty draws across them.
    var screens: [CGRect] = []

    static let dotSpacing: CGFloat = 13, minSpan: CGFloat = 4, maxRipples = 6
    /// The longest step a trail draws: 600 pt between two events is 36,000 pt/s at 60 events a second, past any hand on a
    /// 3440 pt screen; only a warp, or moves the monitors missed, lands that far.
    static let maxJump: CGFloat = 600
    static let ringHideAfter: TimeInterval = 3, squeezeSeconds: TimeInterval = 0.22
    static let rippleSeconds: TimeInterval = 0.46, stillRippleSeconds: TimeInterval = 0.2, fadeSeconds: TimeInterval = 0.15

    mutating func move(to point: CGPoint, at now: TimeInterval) {
        let last = pointer, paused = now - lastMove
        pointer = point
        lastMove = now
        if ring { ringFade.go(1, now, instant: reduceMotion) }
        guard trail != .off, !reduceMotion else { return }
        let joined = joins(last, point, after: paused)
        guard trail == .dots else { samples.append(Sample(point: point, time: now, joined: joined)); return }
        // A dot every 13 pt of travel, placed along the step that crossed it; none along a jump.
        guard joined else { travel = 0; return }
        let step = hypot(point.x - last.x, point.y - last.y)
        guard step > 0 else { return }
        var along = Self.dotSpacing - travel
        while along <= step {
            let k = along / step
            samples.append(Sample(point: CGPoint(x: last.x + (point.x - last.x) * k, y: last.y + (point.y - last.y) * k), time: now))
            along += Self.dotSpacing
        }
        travel = step - (along - Self.dotSpacing)
    }

    /// The trail draws the step from `a` to `b`: no longer than `maxJump`, on one screen, and not after a pause the trail
    /// has faded through. A warp, moves the monitors missed or a stale pointer start a new run instead of a spike (T45).
    func joins(_ a: CGPoint, _ b: CGPoint, after pause: TimeInterval) -> Bool {
        pause <= trail.length && hypot(b.x - a.x, b.y - a.y) <= Self.maxJump && screen(of: a) == screen(of: b)
    }

    /// The first screen holding `p`, edges included; nil off every screen, or with none known.
    private func screen(of p: CGPoint) -> Int? {
        screens.firstIndex { p.x >= $0.minX && p.x <= $0.maxX && p.y >= $0.minY && p.y <= $0.maxY }
    }

    mutating func click(at point: CGPoint, right: Bool, at now: TimeInterval) {
        move(to: point, at: now)
        if ring && !reduceMotion { squeeze = now }
        if ripple {
            ripples.append(Ripple(point: point, time: now, right: right))
            if ripples.count > Self.maxRipples { ripples.removeFirst(ripples.count - Self.maxRipples) }
        }
    }

    /// Drops what has faded out, and starts the Ring's hide once the pointer has been still 3 s.
    mutating func prune(_ now: TimeInterval) {
        let length = trail.length
        samples.removeAll { now - $0.time >= length }
        let life = reduceMotion ? Self.stillRippleSeconds : Self.rippleSeconds
        ripples.removeAll { now - $0.time >= life }
        if let s = squeeze, now - s >= Self.squeezeSeconds { squeeze = nil }
        if ring && now - lastMove >= Self.ringHideAfter { ringFade.go(0, now, instant: reduceMotion) }
    }

    /// Something still changes on screen without a new event: the display link keeps running.
    func alive(_ now: TimeInterval) -> Bool {
        !samples.isEmpty || !ripples.isEmpty || squeeze != nil || ringFade.moving(now) || spotlight.moving(now)
    }
}

// MARK: - Drawing

/// The theme's three effect colours (effects.json › themes): the accent, the right-click colour and the edge.
struct CursorEffectColours: Equatable, Sendable {
    let effect: CGColor, rightClick: CGColor, edge: CGColor
    /// The effect colour as 0xRRGGBB: where Custom's well starts.
    let effectRGB: UInt32

    init(effect: UInt32, rightClick: CGColor, edge: CGColor) {
        (self.effect, self.rightClick, self.edge, effectRGB) = (CursorArt.colour(effect), rightClick, edge, effect)
    }

    /// The current theme's, or Lagoon's for a theme effects.json does not list. A custom colour (T33) takes the trail,
    /// ring and left ripple, with its edge by effects.py's rule (black on a colour over 0.45 luminance, else white); the
    /// right-click ripple stays the theme's second colour (Q818).
    static func of(_ theme: String, colour: ColourChoice = .theme, resolved: PilotTheme? = nil) -> CursorEffectColours {
        let themed = resolved.map { CursorEffectColours(effect: $0.accent, rightClick: CursorArt.colour($0.second),
            edge: CursorArt.colour(Contrast.luminance(Contrast.rgb($0.accent)) > 0.45 ? 0x000000 : 0xFFFFFF)) } ?? table[theme] ?? table["lagoon"] ?? lagoon
        guard case .custom(let rgb) = colour else { return themed }
        return CursorEffectColours(effect: rgb, rightClick: themed.rightClick,
                                   edge: CursorArt.colour(Contrast.luminance(Contrast.rgb(rgb)) > 0.45 ? 0x000000 : 0xFFFFFF))
    }

    private static let lagoon = CursorEffectColours(effect: 0x2BC4F0, rightClick: CursorArt.colour("#22C7A9"),
                                                    edge: CursorArt.colour("#000000"))
    private static let table = load(CursorCatalogue.folder)

    /// effects.json's themes from a Cursors folder; empty without one.
    static func load(_ folder: URL?) -> [String: CursorEffectColours] {
        struct File: Decodable { let themes: [String: [String: String]] }
        guard let url = folder?.appending(path: "effects.json"), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        return file.themes.compactMapValues { c in
            guard let e = c["effect"], let r = c["rightClick"], let edge = c["edge"] else { return nil }
            return CursorEffectColours(effect: Contrast.hex(e), rightClick: CursorArt.colour(r), edge: CursorArt.colour(edge))
        }
    }
}

/// Draws a state into a context whose user space is global points. Every stroke and dot sits on its edge: the same shape
/// 1.5 pt wider (a dot's radius 0.75 pt more) in `edge` at 0.35 of its own alpha (Q787).
enum CursorEffectPainter {
    static let edgeExtra: CGFloat = 1.5, edgeAlpha: CGFloat = 0.35
    static let ringRadius: CGFloat = 17, ringSqueeze: CGFloat = 4
    static let spotRadius: CGFloat = 140, spotClear: CGFloat = 0.66, spotDim: CGFloat = 0.55

    /// Where trails, the Ring (unless `ring` is false) and ripples draw, in global points; null when nothing does.
    static func bounds(_ s: CursorEffectState, _ now: TimeInterval, ring: Bool = true) -> CGRect {
        var box = CGRect.null
        if s.trail == .dots || trailShown(s) { for p in s.samples { box = box.union(CGRect(origin: p.point, size: .zero)) } }
        box = box.insetBy(dx: -6, dy: -6)
        if ring && s.ring && s.ringFade.level(now) > 0 { box = box.union(square(s.pointer, ringBox)) }
        for r in s.ripples { box = box.union(square(r.point, 36)) }
        return box.integral
    }

    /// Everything at `now`; the overlay passes `ring: false`, as it draws the Ring in a layer of its own (T31).
    static func draw(_ s: CursorEffectState, _ colours: CursorEffectColours, now: TimeInterval, ring withRing: Bool = true, in ctx: CGContext) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        trail(s, colours, now, ctx)
        for r in s.ripples { ripple(r, s.reduceMotion, colours, now, ctx) }
        let ringLevel = s.ringFade.level(now)
        if withRing && s.ring && ringLevel > 0 { ring(radius: ringRadius(s, now), level: CGFloat(ringLevel), colours, at: s.pointer, in: ctx) }
    }

    /// Thread and Comet draw nothing while the kept samples span under 4 pt.
    private static func trailShown(_ s: CursorEffectState) -> Bool {
        guard s.trail == .thread || s.trail == .comet, let first = s.samples.first?.point else { return false }
        var lo = first, hi = first
        for p in s.samples.lazy.map(\.point) {
            lo = CGPoint(x: min(lo.x, p.x), y: min(lo.y, p.y)); hi = CGPoint(x: max(hi.x, p.x), y: max(hi.y, p.y))
        }
        return max(hi.x - lo.x, hi.y - lo.y) >= CursorEffectState.minSpan
    }

    private static func trail(_ s: CursorEffectState, _ c: CursorEffectColours, _ now: TimeInterval, _ ctx: CGContext) {
        let length = s.trail.length
        if s.trail == .dots {
            for d in s.samples {
                let f = CGFloat(max(0, 1 - (now - d.time) / length)), r = 0.8 + 3 * f
                dot(d.point, r + edgeExtra / 2, c.edge, edgeAlpha * 0.75 * f, ctx)
                dot(d.point, r, c.effect, 0.75 * f, ctx)
            }
            return
        }
        guard trailShown(s) else { return }
        // Each segment at its own fade, drawn with .copy inside one transparency layer, so the round caps where two
        // segments meet do not double up; the edge pass goes first, under the accent's.
        for edge in [true, false] {
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setBlendMode(.copy)
            ctx.setStrokeColor(edge ? c.edge : c.effect)
            for (a, b) in zip(s.samples, s.samples.dropFirst()) where b.joined {
                let f = CGFloat(max(0, 1 - (now - (a.time + b.time) / 2) / length))
                let width: CGFloat = s.trail == .thread ? 1.5 : 0.8 + 6 * f
                let alpha: CGFloat = (s.trail == .thread ? 0.9 : 0.85) * f
                ctx.setLineWidth(width + (edge ? edgeExtra : 0))
                ctx.setAlpha(edge ? edgeAlpha * alpha : alpha)
                ctx.move(to: a.point); ctx.addLine(to: b.point); ctx.strokePath()
            }
            ctx.endTransparencyLayer()
        }
        ctx.setBlendMode(.normal)
        ctx.setAlpha(1)
    }

    /// The Ring's radius at `now`: 17 pt, less up to 4 pt while a click squeezes it.
    static func ringRadius(_ s: CursorEffectState, _ now: TimeInterval) -> CGFloat {
        guard let start = s.squeeze else { return ringRadius }
        return ringRadius - ringSqueeze * sin(.pi * CGFloat(min(1, (now - start) / CursorEffectState.squeezeSeconds)))
    }

    /// The Ring's half-side with its edge: what its layer and the bounds hold.
    static let ringBox = ringRadius + 4

    static func ring(radius r: CGFloat, level: CGFloat, _ c: CursorEffectColours, at centre: CGPoint, in ctx: CGContext) {
        let circle = square(centre, r)
        ctx.setFillColor(c.effect)
        ctx.setAlpha(0.14 * level)
        ctx.fillEllipse(in: circle)
        stroke(circle, 2, c.effect, 0.9 * level, c.edge, ctx)
    }

    private static func ripple(_ ripple: CursorEffectState.Ripple, _ still: Bool, _ c: CursorEffectColours, _ now: TimeInterval, _ ctx: CGContext) {
        let colour = ripple.right ? c.rightClick : c.effect
        let r: CGFloat, width: CGFloat, alpha: CGFloat
        if still {
            (r, width, alpha) = (18, 2.5, 0.6)
        } else {
            let t = CGFloat(min(1, (now - ripple.time) / CursorEffectState.rippleSeconds)), e = 1 - pow(1 - t, 3)
            (r, width, alpha) = (4 + 28 * e, 2.5 - 1.5 * t, 0.9 * (1 - t))
        }
        stroke(square(ripple.point, r), width, colour, alpha, c.edge, ctx)
    }

    /// A circle's stroke on its edge.
    private static func stroke(_ circle: CGRect, _ width: CGFloat, _ colour: CGColor, _ alpha: CGFloat, _ edge: CGColor, _ ctx: CGContext) {
        for (w, col, a) in [(width + edgeExtra, edge, edgeAlpha * alpha), (width, colour, alpha)] {
            ctx.setLineWidth(w)
            ctx.setStrokeColor(col)
            ctx.setAlpha(a)
            ctx.strokeEllipse(in: circle)
        }
        ctx.setAlpha(1)
    }

    private static func dot(_ p: CGPoint, _ r: CGFloat, _ colour: CGColor, _ alpha: CGFloat, _ ctx: CGContext) {
        ctx.setFillColor(colour)
        ctx.setAlpha(alpha)
        ctx.fillEllipse(in: square(p, r))
        ctx.setAlpha(1)
    }

    static func square(_ p: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r) }

    // MARK: Spotlight

    /// The Spotlight's hole, 2r across: clear out to 0.66 r, then a linear ramp to full black at r, and black outside
    /// the circle to the square's corners. The overlay shows it at 0.55 × its fade, ringed by four black rectangles.
    static let spotHole: CGImage? = {
        let scale = 2, side = Int(spotRadius) * 2 * scale
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let centre = CGPoint(x: spotRadius, y: spotRadius), black = CGColor(gray: 0, alpha: 1)
        ctx.setFillColor(black)
        ctx.addRect(square(centre, spotRadius))
        ctx.addEllipse(in: square(centre, spotRadius))
        ctx.fillPath(using: .evenOdd)
        let ramp = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(gray: 0, alpha: 0), black] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(ramp, startCenter: centre, startRadius: spotClear * spotRadius, endCenter: centre, endRadius: spotRadius,
                               options: [.drawsAfterEndLocation])
        return ctx.makeImage()
    }()

    /// The Spotlight over `screen` (global points) at `level`, as the overlay layers show it: the renders' path.
    static func spotlight(at pointer: CGPoint, level: CGFloat, screen: CGRect, in ctx: CGContext) {
        guard level > 0, let hole = spotHole else { return }
        let square = square(pointer, spotRadius)
        ctx.saveGState()
        ctx.clip(to: screen)
        ctx.setAlpha(spotDim * level)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for r in around(square, in: screen) { ctx.fill(r) }
        ctx.draw(hole, in: square)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// The four rectangles of `screen` outside `square`: below, above, left and right of it.
    static func around(_ square: CGRect, in screen: CGRect) -> [CGRect] {
        let big = screen.insetBy(dx: -1, dy: -1)
        return [CGRect(x: big.minX, y: big.minY, width: big.width, height: max(0, square.minY - big.minY)),
                CGRect(x: big.minX, y: square.maxY, width: big.width, height: max(0, big.maxY - square.maxY)),
                CGRect(x: big.minX, y: square.minY, width: max(0, square.minX - big.minX), height: square.height),
                CGRect(x: square.maxX, y: square.minY, width: max(0, big.maxX - square.maxX), height: square.height)]
    }
}

// MARK: - The setting

/// Look › Cursor's Trail and Halos, saved as they change. Only the shared store in Pilot.app draws: never a test, the
/// sandbox host or a render, so no agent run draws on Sven's screen.
@Observable @MainActor
final class CursorEffects {
    static let shared = CursorEffects()
    static let spotlightID = "cursor.spotlight"

    var trail: CursorTrail { didSet { defaults.set(trail.rawValue, forKey: Key.trail); refresh() } }
    var ring: Bool { didSet { defaults.set(ring, forKey: Key.ring); refresh() } }
    var ripple: Bool { didSet { defaults.set(ripple, forKey: Key.ripple); refresh() } }
    /// Spotlight is on: it shows while `cursor.spotlight`'s key is held.
    var spotlight: Bool { didSet { defaults.set(spotlight, forKey: Key.spotlight); if !spotlight { held = false }; refresh() } }
    /// The trail's, ring's and ripple's colour: the theme's, or one picked (T33, Q815).
    var colour: ColourChoice { didSet { defaults.set(colour.rawValue, forKey: Key.colour); refresh() } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var overlays: CursorOverlays?
    @ObservationIgnored private var held = false
    @ObservationIgnored private var started = false

    enum Key {
        static let trail = "look.cursorTrail", ring = "look.cursorRing", ripple = "look.cursorRipple", spotlight = "look.cursorSpotlight"
        static let colour = "look.cursorEffectColour"
    }

    /// A test run's store saves to a throwaway suite (`UserDefaults.pilot`); a fresh install has every effect off.
    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        trail = defaults.string(forKey: Key.trail).flatMap(CursorTrail.init(rawValue:)) ?? .off
        ring = defaults.bool(forKey: Key.ring)
        ripple = defaults.bool(forKey: Key.ripple)
        spotlight = defaults.bool(forKey: Key.spotlight)
        colour = defaults.string(forKey: Key.colour).flatMap(ColourChoice.init(rawValue:)) ?? .theme
    }

    /// The shared store for `Look.shared`, else one per Look (a test's or render's), as `CursorSets.of`.
    static func of(_ look: Look) -> CursorEffects {
        if look === Look.shared { return .shared }
        if let made = stores.object(forKey: look) { return made }
        let made = CursorEffects()
        stores.setObject(made, forKey: look)
        return made
    }
    private static let stores = NSMapTable<Look, CursorEffects>.weakToStrongObjects()

    private var mayDraw: Bool { self === Self.shared && defaults.isApp && !isTestRun && Bundle.main.bundleIdentifier == "dev.banozz.pilot" }

    /// At launch: the saved effects come back; with none on, nothing is made at all.
    func start() {
        started = true
        refresh()
    }

    /// `cursor.spotlight`: true as its key goes down, false as it comes up. Off in Look › Cursor, the key does nothing.
    func hold(_ down: Bool) {
        held = down && spotlight
        refresh()
    }

    static func register(into registry: inout ActionRegistry) {
        try? registry.register(Action(id: spotlightID, label: "Cursor spotlight while held", module: .system,
                                      hold: { CursorEffects.shared.hold($0) }))
    }

    private var wanted: Bool { trail != .off || ring || ripple || held }

    /// The overlays made and told what is on, or closed once nothing is.
    private func refresh() {
        guard started, mayDraw else { return }
        if wanted {
            let overlays = overlays ?? CursorOverlays { [weak self] in self?.closeIfDone() }
            self.overlays = overlays
            overlays.configure(trail: trail, ring: ring, ripple: ripple, spotlight: held, colour: colour)
        } else {
            overlays?.configure(trail: .off, ring: false, ripple: false, spotlight: false, colour: colour)
            closeIfDone()
        }
    }

    /// The display link stopped: with nothing on, the overlays go (after the Spotlight's fade out, which kept it running).
    private func closeIfDone() {
        guard !wanted, let overlays, !overlays.busy else { return }
        overlays.close()
        self.overlays = nil
    }
}

// MARK: - The overlays

/// One click-through window per screen, the monitors and the display link, alive only while the store has an effect on.
@MainActor
final class CursorOverlays: NSObject {
    private struct Screen {
        let window: NSWindow
        let paint: CALayer
        let painter: Painter
        let ring: CALayer
        let ringPainter: RingPainter
        let spot: CALayer
        let frame: CGRect
    }

    private var state = CursorEffectState()
    private var screens: [Screen] = []
    private var monitors: [Any] = []
    private var watched: NSEvent.EventTypeMask = []
    private var link: CADisplayLink?
    private var hideTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let idle: @MainActor () -> Void
    /// The effect colour picked, and the colours last drawn with the theme and pick they came from.
    private var colour: ColourChoice = .theme
    private var drawn: (theme: String, revision: Int, colour: ColourChoice, colours: CursorEffectColours)?

    init(idle: @escaping @MainActor () -> Void) {
        self.idle = idle
        super.init()
        state.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        state.pointer = NSEvent.mouseLocation
        state.lastMove = CACurrentMediaTime()
        observers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.build() }
            },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.state.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
            },
        ]
        build()
    }

    /// Something still fades: closing now would cut it.
    var busy: Bool { state.alive(CACurrentMediaTime()) }

    func configure(trail: CursorTrail, ring: Bool, ripple: Bool, spotlight: Bool, colour: ColourChoice) {
        let now = CACurrentMediaTime()
        self.colour = colour
        // A trail turned on starts where the pointer is: with only Ripple on, no move was watched to keep it current.
        if trail != state.trail { state.samples = []; state.travel = 0; state.pointer = NSEvent.mouseLocation }
        state.trail = trail
        state.ripple = ripple
        if ring != state.ring {
            state.ring = ring
            state.lastMove = now
            state.ringFade.go(ring ? 1 : 0, now, instant: true)
        }
        if (spotlight ? 1.0 : 0.0) != state.spotlight.to {
            state.pointer = NSEvent.mouseLocation
            state.spotlight.go(spotlight ? 1 : 0, now, instant: state.reduceMotion)
        }
        var mask: NSEvent.EventTypeMask = []
        if trail != .off || ring || spotlight { mask.formUnion([.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) }
        if ring || ripple { mask.formUnion([.leftMouseDown, .rightMouseDown, .otherMouseDown]) }
        watch(mask)
        if ring { armHide() } else { hideTimer?.invalidate(); hideTimer = nil }
        wake()
    }

    func close() {
        watch([])
        hideTimer?.invalidate(); hideTimer = nil
        link?.invalidate(); link = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        screens.forEach { $0.window.close() }
        screens = []
    }

    // MARK: Events

    private func watch(_ mask: NSEvent.EventTypeMask) {
        guard mask != watched else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        watched = mask
        guard !mask.isEmpty else { return }
        let handle: (NSEvent) -> Void = { [weak self] event in MainActor.assumeIsolated { self?.event(event) } }
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle) as Any?,
                    NSEvent.addLocalMonitorForEvents(matching: mask) { handle($0); return $0 } as Any?].compactMap { $0 }
    }

    private func event(_ event: NSEvent) {
        let now = CACurrentMediaTime(), at = Self.location(event)
        switch event.type {
        case .leftMouseDown, .otherMouseDown: state.click(at: at, right: false, at: now)
        case .rightMouseDown: state.click(at: at, right: true, at: now)
        default: state.move(to: at, at: now)
        }
        if state.ring {
            // The Ring moves here, from this event, committed at once: waiting for the display link's next frame (and
            // its restart, paused while nothing fades) left it a frame or two behind a fast pointer (T31).
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for screen in screens { placeRing(screen, now) }
            CATransaction.commit()
            armHide()
        }
        wake()
    }

    /// The event's own place in global points, from its CG location (top-left origin) flipped against the zero-origin
    /// screen: a local event's window point, converted through its window's frame at handling time, lands wherever that
    /// window has moved to since (T45).
    static func location(_ event: NSEvent) -> CGPoint {
        guard let cg = event.cgEvent?.location, let zero = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else {
            return event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        }
        return CGPoint(x: cg.x, y: zero.frame.maxY - cg.y)
    }

    /// One one-shot timer for the Ring's 3 s hide, re-armed only when it fires early: moves never reschedule it.
    private func armHide() {
        guard hideTimer == nil else { return }
        let due = max(0.05, state.lastMove + CursorEffectState.ringHideAfter - CACurrentMediaTime())
        let timer = Timer(timeInterval: due, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideTimer = nil
                guard self.state.ring else { return }
                if CACurrentMediaTime() - self.state.lastMove >= CursorEffectState.ringHideAfter { self.wake() } else { self.armHide() }
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    // MARK: Frames

    private func wake() {
        if link == nil, let view = screens.first?.window.contentView {
            let link = view.displayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)   // fades of 0.1 to 0.46 s
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    @objc private func tick(_: CADisplayLink) {
        let now = CACurrentMediaTime()
        state.prune(now)
        let colours = self.colours(Look.shared.themeID)
        let box = CursorEffectPainter.bounds(state, now, ring: false)
        let spotLevel = state.spotlight.level(now)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for screen in screens {
            let local = Self.stepped(box).intersection(screen.frame)
            if local.isEmpty {
                screen.paint.isHidden = true
            } else {
                screen.painter.frame = (state, colours, now)
                screen.paint.isHidden = false
                screen.paint.frame = local.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                screen.paint.setNeedsDisplay()
            }
            placeRing(screen, now)
            let under = NSMouseInRect(state.pointer, screen.frame, false)
            screen.spot.isHidden = !(under && spotLevel > 0)
            if !screen.spot.isHidden {
                place(screen)
                screen.spot.opacity = Float(CursorEffectPainter.spotDim * spotLevel)
            }
        }
        CATransaction.commit()
        if !state.alive(now) {
            link?.isPaused = true
            idle()
        }
    }

    /// The theme's or the picked colours, made again only when either changed.
    private func colours(_ theme: String) -> CursorEffectColours {
        if let drawn, drawn.theme == theme, drawn.revision == Look.shared.paletteRevision, drawn.colour == colour { return drawn.colours }
        let made = CursorEffectColours.of(theme, colour: colour, resolved: Look.shared.packAppearance)
        drawn = (theme, Look.shared.paletteRevision, colour, made)
        return made
    }

    /// `box` grown to whole 32 pt steps about its centre: a paint layer that changes size reallocates its backing store,
    /// so a moving trail keeps one size most frames.
    static func stepped(_ box: CGRect) -> CGRect {
        guard !box.isNull else { return box }
        let w = (box.width / 32).rounded(.up) * 32, h = (box.height / 32).rounded(.up) * 32
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h).integral
    }

    /// The Ring's layer on the pointer, on whole pixels, and redrawn only when its fade, squeeze, theme or colour changed: a move
    /// alone just moves it.
    private func placeRing(_ screen: Screen, _ now: TimeInterval) {
        let level = state.ring ? state.ringFade.level(now) : 0
        let box = CursorEffectPainter.square(state.pointer, CursorEffectPainter.ringBox)
        screen.ring.isHidden = level <= 0 || !box.intersects(screen.frame)
        guard !screen.ring.isHidden else { return }
        let scale = screen.ring.contentsScale
        screen.ring.position = CGPoint(x: ((state.pointer.x - screen.frame.minX) * scale).rounded() / scale,
                                       y: ((state.pointer.y - screen.frame.minY) * scale).rounded() / scale)
        let shape = RingPainter.Shape(radius: CursorEffectPainter.ringRadius(state, now), level: CGFloat(level),
                                      colours: colours(Look.shared.themeID))
        if screen.ringPainter.shape != shape {
            screen.ringPainter.shape = shape
            screen.ring.setNeedsDisplay()
        }
    }

    /// The Spotlight's hole on the pointer and its four rectangles around it.
    private func place(_ screen: Screen) {
        let local = CGRect(origin: .zero, size: screen.frame.size)
        let p = CGPoint(x: state.pointer.x - screen.frame.minX, y: state.pointer.y - screen.frame.minY)
        let square = CursorEffectPainter.square(p, CursorEffectPainter.spotRadius)
        let parts = screen.spot.sublayers ?? []
        if let hole = parts.last, hole.contents == nil { hole.contents = CursorEffectPainter.spotHole }   // made on first use
        for (layer, rect) in zip(parts, CursorEffectPainter.around(square, in: local) + [square]) { layer.frame = rect }
    }

    // MARK: Windows

    private func build() {
        screens.forEach { $0.window.close() }
        link?.invalidate(); link = nil
        screens = NSScreen.screens.map(makeScreen)
        state.screens = screens.map(\.frame)
        wake()
    }

    private func makeScreen(_ screen: NSScreen) -> Screen {
        let window = WindowBorderPanel.overlay()
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.sharingType = .none
        window.animationBehavior = .none
        window.setFrame(screen.frame, display: false)
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        window.contentView = view
        let root = view.layer!
        let painter = Painter(origin: screen.frame.origin)
        let paint = CALayer()
        paint.delegate = painter
        paint.contentsScale = screen.backingScaleFactor
        paint.isHidden = true
        let ringPainter = RingPainter()
        let ring = CALayer()
        ring.delegate = ringPainter
        ring.contentsScale = screen.backingScaleFactor
        ring.bounds = CGRect(x: 0, y: 0, width: 2 * CursorEffectPainter.ringBox, height: 2 * CursorEffectPainter.ringBox)
        ring.isHidden = true
        let spot = CALayer()
        spot.isHidden = true
        for _ in 0..<4 {
            let part = CALayer()
            part.backgroundColor = CGColor(gray: 0, alpha: 1)
            spot.addSublayer(part)
        }
        spot.addSublayer(CALayer())   // the hole, its image set when Spotlight first shows
        root.addSublayer(spot)
        root.addSublayer(paint)
        root.addSublayer(ring)
        window.orderFrontRegardless()
        return Screen(window: window, paint: paint, painter: painter, ring: ring, ringPainter: ringPainter, spot: spot, frame: screen.frame)
    }

    /// A screen's paint layer drawer: the frame the last tick set, in the layer's place on that screen (global points).
    private final class Painter: NSObject, CALayerDelegate, @unchecked Sendable {   // the main thread alone draws and sets it
        let origin: CGPoint
        var frame: (CursorEffectState, CursorEffectColours, TimeInterval)?
        init(origin: CGPoint) { self.origin = origin }

        func draw(_ layer: CALayer, in ctx: CGContext) {
            guard let (state, colours, now) = frame else { return }
            ctx.translateBy(x: -(layer.frame.minX + origin.x), y: -(layer.frame.minY + origin.y))
            CursorEffectPainter.draw(state, colours, now: now, ring: false, in: ctx)
        }

        func action(for layer: CALayer, forKey event: String) -> (any CAAction)? { NSNull() }
    }

    /// A screen's Ring layer drawer: the Ring centred in its layer, as the painter draws it.
    private final class RingPainter: NSObject, CALayerDelegate, @unchecked Sendable {   // the main thread alone draws and sets it
        struct Shape: Equatable { var radius: CGFloat, level: CGFloat, colours: CursorEffectColours }
        var shape: Shape?

        func draw(_ layer: CALayer, in ctx: CGContext) {
            guard let shape else { return }
            CursorEffectPainter.ring(radius: shape.radius, level: shape.level, shape.colours,
                                     at: CGPoint(x: layer.bounds.midX, y: layer.bounds.midY), in: ctx)
        }

        func action(for layer: CALayer, forKey event: String) -> (any CAAction)? { NSNull() }
    }
}
