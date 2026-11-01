import AppKit
import PilotCore
import QuartzCore

/// One window's flight on the Fly (Q708): its still from one rect to another, in screen points, turned at the start as
/// its card is and flat where it lands.
struct ShelfLeg {
    let still: ShelfStill
    let from: CGRect
    let to: CGRect
    let turnFrom: Double
    let turnTo: Double
    /// Seconds after the Fly's start this leg leaves: a card's at once, the stage's window once its still is in.
    var delay: CFTimeInterval = 0
}

/// How a flying window wears its style: Instrument's soft shadow, Toybox's ink outline.
struct ShelfFlyLook {
    var outline: CGColor?
    var outlineWidth: CGFloat = 0
    var shadow = true

    @MainActor init(_ style: StyleTokens) {
        let depth = style.depth.card
        if depth.outline > 0 {
            outline = NSColor(style.color(\.outline)).cgColor
            outlineWidth = depth.outline
            shadow = false
        }
    }

    init(outline: CGColor? = nil, outlineWidth: CGFloat = 0, shadow: Bool = true) {
        self.outline = outline
        self.outlineWidth = outlineWidth
        self.shadow = shadow
    }
}

/// The Fly (Sven, Q708; the previews' Image open tilt): a click on a shelf card flies its window's still from the card
/// to the stage while the stage's window flies back to the card's place, as Stage Manager swaps; each lands flat and
/// fades onto the real window under it. Core Animation alone runs it: each leg is a layer with one animation group in its
/// own transaction, whose completion takes the layer away, and the last one orders the overlay out. No timer, no frame
/// loop; nothing on screen between flights. The overlay is a borderless panel over every window that never takes a
/// click. Reduce motion: nothing moves; the stage's window fades out over the one coming in.
@MainActor
final class ShelfFly {
    static let shared = ShelfFly()

    /// A leg's travel and its fade once landed: under 0.5 s together (a drawer's, Emil), on Krehel's curve.
    static let duration: CFTimeInterval = 0.34
    static let fade: CFTimeInterval = 0.14
    static let timing = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
    /// The flight's perspective: about the card's turn in the shelf (rotation3DEffect's 0.3 on a 204 pt card).
    static let depth: CGFloat = -1 / 700

    private var panel: NSPanel?
    /// Legs in the air, and what waits for the last of them to land.
    private var flying = 0
    private var whenLanded: [@MainActor () -> Void] = []

    /// Flies `legs` over `screen` (its frame, AppKit's coordinates); `landed` once no leg is in the air.
    func fly(_ legs: [ShelfLeg], over screen: CGRect, look: ShelfFlyLook, reduceMotion: Bool, landed: @escaping @MainActor () -> Void = {}) {
        let panel = panel ?? Self.makePanel()
        self.panel = panel
        guard !legs.isEmpty, let root = panel.contentView?.layer else { return landed() }
        whenLanded.append(landed)
        if panel.frame != screen { panel.setFrame(screen, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        let begin = CACurrentMediaTime()
        for leg in legs {
            flying += 1
            let layer = Self.layer(leg, origin: screen.origin, look: look, begin: begin + leg.delay, reduceMotion: reduceMotion)
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak layer] in
                MainActor.assumeIsolated {
                    layer?.removeFromSuperlayer()
                    self?.land()
                }
            }
            root.addSublayer(layer)
            CATransaction.commit()
        }
    }

    /// One leg down; with the last, the overlay goes and every waiting `landed` runs.
    private func land() {
        flying -= 1
        guard flying <= 0 else { return }
        flying = 0
        panel?.orderOut(nil)
        let waiting = whenLanded
        whenLanded = []
        waiting.forEach { $0() }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }

    /// A leg's layer in an overlay whose origin is `origin` on screen, its animation from media time `begin`: a holder
    /// that moves, turns, fades and casts the shadow, and the picture in it, clipped to the window's own corner. The
    /// model values are where it lands, faded, so nothing flashes when the animation is taken off.
    static func layer(_ leg: ShelfLeg, origin: CGPoint, look: ShelfFlyLook, begin: CFTimeInterval, reduceMotion: Bool) -> CALayer {
        let from = leg.from.offsetBy(dx: -origin.x, dy: -origin.y), to = leg.to.offsetBy(dx: -origin.x, dy: -origin.y)
        let corner = { (rect: CGRect) in max(3, leg.still.corner * rect.width) }
        let still = reduceMotion ? from : to
        let holder = CALayer(), picture = CALayer()
        holder.anchorPoint = CGPoint(x: 0, y: 0.5)
        holder.bounds = CGRect(origin: .zero, size: still.size)
        holder.position = CGPoint(x: still.minX, y: still.midY)
        holder.opacity = 0
        if look.shadow {
            holder.shadowColor = NSColor.black.cgColor
            holder.shadowOpacity = 0.45
            holder.shadowRadius = 14
            holder.shadowOffset = CGSize(width: 0, height: -8)
            holder.shadowPath = CGPath(roundedRect: holder.bounds, cornerWidth: corner(still), cornerHeight: corner(still), transform: nil)
        }
        picture.contents = leg.still.image
        picture.contentsGravity = .resizeAspectFill
        picture.minificationFilter = .trilinear
        picture.masksToBounds = true
        picture.cornerCurve = .continuous
        picture.cornerRadius = corner(still)
        picture.frame = holder.bounds
        if let outline = look.outline {
            picture.borderColor = outline
            picture.borderWidth = look.outlineWidth
        }
        holder.addSublayer(picture)

        let total = reduceMotion ? 0.2 : duration + fade
        let fadeOut = CAKeyframeAnimation(keyPath: "opacity")
        fadeOut.values = reduceMotion ? [1, 0] : [1, 1, 0]
        fadeOut.keyTimes = reduceMotion ? [0, 1] : [0, NSNumber(value: duration / total), 1]
        var moves: [CAAnimation] = [fadeOut], inner: [CAAnimation] = []
        if !reduceMotion {
            func turn(_ degrees: Double) -> CATransform3D {
                var t = CATransform3DIdentity
                t.m34 = depth
                // The card's near edge is its right one: a turn about y away from the shelf.
                return CATransform3DRotate(t, -degrees * .pi / 180, 0, 1, 0)
            }
            func basic(_ key: String, _ a: Any, _ b: Any) -> CABasicAnimation {
                let animation = CABasicAnimation(keyPath: key)
                animation.fromValue = a
                animation.toValue = b
                animation.duration = duration
                animation.timingFunction = timing
                animation.fillMode = .both
                return animation
            }
            let box = { (rect: CGRect) in NSValue(rect: CGRect(origin: .zero, size: rect.size)) }
            moves += [basic("position", NSValue(point: CGPoint(x: from.minX, y: from.midY)), NSValue(point: CGPoint(x: to.minX, y: to.midY))),
                      basic("bounds", box(from), box(to)),
                      basic("transform", NSValue(caTransform3D: turn(leg.turnFrom)), NSValue(caTransform3D: turn(leg.turnTo)))]
            if look.shadow {
                moves.append(basic("shadowPath", CGPath(roundedRect: CGRect(origin: .zero, size: from.size), cornerWidth: corner(from), cornerHeight: corner(from), transform: nil),
                                   CGPath(roundedRect: CGRect(origin: .zero, size: to.size), cornerWidth: corner(to), cornerHeight: corner(to), transform: nil)))
            }
            inner = [basic("position", NSValue(point: CGPoint(x: from.width / 2, y: from.height / 2)), NSValue(point: CGPoint(x: to.width / 2, y: to.height / 2))),
                     basic("bounds", box(from), box(to)),
                     basic("cornerRadius", corner(from), corner(to))]
        }
        for (layer, animations) in [(holder, moves), (picture, inner)] where !animations.isEmpty {
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = total
            group.beginTime = begin
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            layer.add(group, forKey: "fly")
        }
        return holder
    }
}
