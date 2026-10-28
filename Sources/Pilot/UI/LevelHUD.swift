import AppKit
import PilotCore
import SwiftUI

/// What a screen's level HUD shows (story 144, card agent-bo-95423314): the screen's name and its level, or why it has
/// none. A held key changes the reading in place, so the HUD never flickers.
@Observable @MainActor
final class LevelModel {
    enum Reading: Equatable {
        /// 0 to 1.
        case level(Double)
        /// The screen answers neither Apple's call nor DDC/CI.
        case noControl
        /// Its route is still being read (just connected or woken).
        case reading
    }

    private var systemName: String
    var displayUUID: String?
    var identityIsUnique: Bool
    let nicknames: DisplayNicknames
    var screen: String {
        get { nicknames.label(systemName: systemName, displayUUID: identityIsUnique ? displayUUID : nil) }
        set { systemName = newValue }
    }
    var reading: Reading

    init(screen: String, reading: Reading, displayUUID: String? = nil, nicknames: DisplayNicknames = .shared, identityIsUnique: Bool = true) {
        self.systemName = screen
        self.reading = reading
        self.displayUUID = displayUUID
        self.identityIsUnique = identityIsUnique
        self.nicknames = nicknames
    }

    /// The level, 0 to 1; nil without one.
    var level: Double? {
        guard case .level(let level) = reading else { return nil }
        return level
    }

    /// The level as a whole percentage, for the words and VoiceOver; nil without one.
    var percent: Int? { level.map { Int(($0 * 100).rounded()) } }

    /// The line a HUD without a level says.
    var status: String? {
        switch reading {
        case .level: nil
        case .noControl: "No brightness control"
        case .reading: "Still reading brightness"
        }
    }
}

/// The brightness level HUD, one per changed screen, on that screen and never taking a click (card agent-bo-95423314).
/// A step on a screen whose HUD shows changes it in place and starts its fade over, so a held key keeps one panel up.
@MainActor
enum LevelHUD {
    private final class Shown {
        let panel: KeyPanel
        let model: LevelModel
        var fade: Timer

        init(panel: KeyPanel, model: LevelModel, fade: Timer) { self.panel = panel; self.model = model; self.fade = fade }
    }

    /// Seconds a HUD stays after the last step, as macOS's own.
    static let seconds: TimeInterval = 1.5
    private static var shown: [UInt32: Shown] = [:]

    /// Shows `reading` for the screen `id` on `screen`, or updates the HUD already there.
    static func show(_ reading: LevelModel.Reading, screen: NSScreen, id: UInt32) {
        let uuid = DisplayIdentity.uuid(for: id)
        let unique = NSScreen.screens.filter { WallpaperScreen.number($0).flatMap(DisplayIdentity.uuid(for:)) == uuid }.count == 1
        if let hud = shown[id] {
            hud.model.screen = screen.localizedName
            hud.model.displayUUID = uuid
            hud.model.identityIsUnique = unique
            hud.model.reading = reading
            hud.fade.invalidate()
            hud.fade = fade(id)
            // Through the animator, so a fade under way is replaced rather than left to finish.
            NSAnimationContext.runAnimationGroup { $0.duration = 0; hud.panel.animator().alphaValue = 1 }
            return
        }
        let model = LevelModel(screen: screen.localizedName, reading: reading, displayUUID: uuid, identityIsUnique: unique)
        let panel = HUD.makePanel(LevelView(model: model).fixedSize())
        panel.ignoresMouseEvents = true
        place(panel, on: screen)
        panel.orderFrontRegardless()
        shown[id] = Shown(panel: panel, model: model, fade: fade(id))
    }

    /// Where a HUD sits: centred low on its screen, a sixth of the way up its visible frame, as macOS's own level HUD
    /// was, clear of the Dock and of the tips in the middle.
    static func origin(for size: CGSize, in visible: CGRect) -> CGPoint {
        CGPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.minY + visible.height / 6 - size.height / 2).rounded())
    }

    private static func place(_ panel: NSPanel, on screen: NSScreen) {
        panel.setFrameOrigin(origin(for: panel.frame.size, in: screen.visibleFrame))
    }

    /// The fade, then the close; a step during the fade brings the panel back to 1, and it stays. Timers and the
    /// animation's end both run on the main run loop.
    private static func fade(_ id: UInt32) -> Timer {
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let panel = shown[id]?.panel else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
                    MainActor.assumeIsolated {
                        guard panel.alphaValue == 0 else { return }
                        panel.orderOut(nil)
                        shown[id] = nil
                    }
                }
            }
        }
    }
}

/// The level HUD's face in the picked style: Instrument's or Toybox's.
struct LevelView: View {
    @Environment(\.style) private var style
    let model: LevelModel

    var body: some View {
        switch style.kind {
        case .instrument: InstrumentLevel(model: model)
        case .toybox: ToyLevel(model: model)
        }
    }
}

// MARK: - The faces (card agent-bo-95423314)

/// What the faces share. Each is one fixed size whatever it shows, so a held key changing the number, or a reading
/// turning into a status, never refits the panel: the screen's name over the level's bar (or the status in its place), the
/// percentage at the right in the room "100 %" takes, a sun leading them whose rays grow with the level.
enum LevelFace {
    /// The steps a held key takes over the whole range: Instrument's segments.
    static let steps = Int(Brightness.steps)

    /// The level held to 0...1; nil without one.
    @MainActor static func level(_ model: LevelModel) -> Double? { model.level.map { min(max($0, 0), 1) } }

    /// The one element VoiceOver reads: "CU34G4Z brightness 56 %", or "CU34G4Z, No brightness control".
    @MainActor static func label(_ model: LevelModel) -> String {
        if let percent = model.percent { return "\(model.screen) brightness \(percent) %" }
        return [model.screen, model.status].compactMap(\.self).joined(separator: ", ")
    }

    /// A step's change: Kit's 150 ms, retargeted by the next step of a held key; none under Reduce Motion.
    static func motion(_ reduce: Bool) -> Animation? { reduce ? nil : Kit.change }
}

/// The sun's eight rays round its core, as long as the level: stubs at 0 (sun.min), full at 1 (sun.max). Animatable, so a
/// step grows them with the bar.
struct SunRays: Shape {
    var level: Double
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    /// Where a ray starts and its shortest and longest reach, as shares of the box's side; `longest` leaves room for a
    /// round cap.
    static let start = 0.31, shortest = 0.035, longest = 0.15

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height), centre = CGPoint(x: rect.midX, y: rect.midY)
        let inner = side * Self.start, outer = inner + side * (Self.shortest + (Self.longest - Self.shortest) * level)
        var path = Path()
        for ray in 0..<8 {
            let angle = Double(ray) * .pi / 4
            path.move(to: CGPoint(x: centre.x + cos(angle) * inner, y: centre.y + sin(angle) * inner))
            path.addLine(to: CGPoint(x: centre.x + cos(angle) * outer, y: centre.y + sin(angle) * outer))
        }
        return path
    }
}

/// A slash through the sun, top left to bottom right, as SF Symbols strike a glyph.
private struct SunSlash: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.16))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.16, y: rect.maxY - rect.height * 0.16))
        return path
    }
}

/// The level's sun, `size` square: a core of `fill` (outlined in `ink` where `outlined`) and rays of `ink` at `weight`,
/// growing with the level; a screen without a level shows it short and, with no control at all, struck through, the
/// slash cut clear of the sun so it reads on any ground.
struct LevelSun: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let level: Double?
    var slashed = false
    let size: CGFloat
    let weight: CGFloat
    let fill: Color
    let ink: Color
    var outlined = false
    /// The core's width as a share of `size`.
    var core = 0.4

    var body: some View {
        let core = size * core
        let line = StrokeStyle(lineWidth: weight, lineCap: .round)
        ZStack {
            SunRays(level: level ?? 0.3).stroke(ink, style: line)
            Circle().fill(fill).frame(width: core, height: core)
            if outlined { Circle().strokeBorder(ink, lineWidth: weight).frame(width: core, height: core) }
        }
        .frame(width: size, height: size)
        // The slash's gap is cut from the sun alone, so what is under the HUD never shows through it.
        .mask {
            ZStack {
                Rectangle()
                if slashed { SunSlash().stroke(.black, style: StrokeStyle(lineWidth: weight * 3.2, lineCap: .round)).blendMode(.destinationOut) }
            }
            .compositingGroup()
        }
        .overlay { if slashed { SunSlash().stroke(ink, style: line) } }
        .animation(LevelFace.motion(reduceMotion), value: level)
        .accessibilityHidden(true)
    }
}

/// The percentage, right-aligned in the room "100 %" takes, so the name beside it never moves as the number changes or
/// goes; the number tabular, the sign quieter.
struct LevelPercent: View {
    let percent: Int?
    let number: Font
    let sign: Font
    let numberColor: Color
    let signColor: Color

    var body: some View {
        ZStack(alignment: .trailing) {
            parts("100").hidden()
            if let percent { parts("\(percent)") }
        }
        .fixedSize()
    }

    private func parts(_ digits: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(digits).font(number).monospacedDigit().foregroundStyle(numberColor)
            Text("%").font(sign).foregroundStyle(signColor)
        }
    }
}
