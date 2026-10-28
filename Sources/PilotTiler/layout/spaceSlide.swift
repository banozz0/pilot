// Pilot (space-switch slide, Sven's Q465, Q467 and Q468, 2026-10-25; ADR 0014's no-crossing rule): a display switching
// to another workspace slides the old one's tiled windows out and the new one's in, 180 ms eased out, each on its app's
// AX thread (GlideSet). A higher workspace comes in from the right and the old one leaves left; a lower one is the
// mirror. No frame ever reaches another display: on an edge one touches, a window goes only as far as that edge (it
// leaves to lie flush against it, then hides; it enters from flush against it), and past an open edge it goes until one
// point shows. A workspace another display showed switches without a slide, and every switch jumps under Reduce Motion,
// Low Power Mode or with Glide windows off. Floating windows hide and show as before.
import AppKit

/// Where one workspace's windows slide on a switch: in from `dx` along x, or out to it, for every tiling glide's 180 ms
/// (GlideSet.duration, Sven's Q468).
struct SpaceSlide {
    let dx: CGFloat
    let monitor: MonitorInfo
    /// The x its windows keep within: up to a display beside it, open where there is none (MonitorInfo.columnSpan).
    let span: ClosedRange<CGFloat>
    let screen: GlideScreen?
    /// Sliding in: the windows that wait in a hide corner, the ones that slide.
    var hidden: Set<UInt32> = []

    /// `frame` moved `dx` along x as far as the no-crossing rule lets it: flush against a bordered edge, one point
    /// showing past an open one (as in the hide corner).
    func shifted(_ frame: Rect) -> Rect {
        let low = max(span.lowerBound, monitor.rect.minX + 1 - frame.width)
        let high = max(low, min(span.upperBound - frame.width, monitor.rect.maxX - 1))
        return Rect(topLeftX: (frame.minX + dx).coerce(in: low ... high), topLeftY: frame.minY, width: frame.width, height: frame.height)
    }
}

/// The workspace each display showed at the last layout pass.
@MainActor private var shownLastPass: [CGPoint: Workspace] = [:]
/// Windows sliding out, until when: hideInCorner leaves them to their glide, which hides them as it lands. Not the
/// glider's gliding mark: the same pass hides right after it asks for the slide, before the app's AX thread starts it.
@MainActor private var slidingOut: [UInt32: ContinuousClock.Instant] = [:]

/// The slides of this layout pass, by workspace: on each display that switched since the last pass to a workspace no
/// display showed then, the one it shows now slides in and the one it left slides out.
@MainActor
func spaceSlides(_ monitors: [MonitorInfo]) -> [Workspace: SpaceSlide] {
    let shown = monitors.map { ($0.rect.topLeftCorner, $0.activeWorkspace) }
    defer { shownLastPass = Dictionary(shown, uniquingKeysWith: { first, _ in first }) }
    guard glidesAllowed, currentlyManipulatedWithMouseWindowId == nil else { return [:] }
    var slides: [Workspace: SpaceSlide] = [:]
    for (monitor, (point, now)) in zip(monitors, shown) {
        guard let left = shownLastPass[point], left != now, !left.isVisible, !shownLastPass.values.contains(now) else { continue }
        let dx = now > left ? monitor.width : -monitor.width, span = monitor.columnSpan(among: monitors), screen = GlideScreen(monitor)
        slides[now] = SpaceSlide(dx: dx, monitor: monitor, span: span, screen: screen,
                                 hidden: Set(now.allLeafWindowsRecursive.filter(\.isHiddenInCorner).map(\.windowId)))
        slides[left] = SpaceSlide(dx: -dx, monitor: monitor, span: span, screen: screen)
    }
    return slides
}

extension Workspace {
    /// Its tiled windows glide out and hide as each lands; the rest hide in `corner` as before (hideInCorner).
    @MainActor
    func slideOut(_ slide: SpaceSlide, hidingIn corner: OptimalHideCorner) {
        let now = ContinuousClock.now, until = now + GlideSet.duration + .milliseconds(50)
        slidingOut = slidingOut.filter { $0.value > now }
        for case let window as MacWindow in allLeafWindowsRecursive where window.slideOut(slide, hidingIn: corner) {
            slidingOut[window.windowId] = until
        }
    }
}

/// The tiler stopped: what the displays showed is no switch's start.
@MainActor
func forgetShownWorkspaces() { shownLastPass = [:] }

/// Whether `window` is still sliding out, so a hide now would cut its glide short.
@MainActor
func isSlidingOut(_ window: Window) -> Bool {
    slidingOut[window.windowId].map { $0 > .now } == true
}
