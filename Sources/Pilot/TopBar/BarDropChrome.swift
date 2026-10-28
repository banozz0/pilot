import AppKit
import Darwin
import PilotCore
import SwiftUI

/// How a bar drop moves (spec Bar drops T8, notes › Chrome and motion, design card 6): down 220 ms on the drawer curve,
/// out from behind the bar and cut at its foot, the contents fading in from 70 to 180 ms; up 160 ms on a quick ease-out.
/// The panel is on its frame and has the keyboard from frame 0: only its content slides. The Mac's Reduce Motion makes
/// it a 100 ms fade, the only switch; a test's still drops make it instant.
@MainActor
enum BarDropMotion {
    enum Mode: Equatable { case slide, fade, none }

    static let down: TimeInterval = 0.22
    static let up: TimeInterval = 0.16
    static let fade: TimeInterval = 0.1
    /// When the contents start to show and when they are whole, from the start of the slide.
    static let contentsFrom: TimeInterval = 0.07
    static let contentsTo: TimeInterval = 0.18
    /// `cubic-bezier(0.32, 0.72, 0, 1)`: the drawer's, quick out and a long settle.
    static let drawer = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    /// `cubic-bezier(0.23, 1, 0.32, 1)`: away fast.
    static let away = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    /// The contents' fade inside a sliding drop, as SwiftUI draws it (Ask AI's chat).
    static let contents = Animation.easeOut(duration: contentsTo - contentsFrom).delay(contentsFrom)

    /// True while BarDrops builds a drop's face that will slide in, so the face can fade its contents in under the slide.
    static var opening = false

    static func mode(still: Bool, reduce: Bool) -> Mode {
        if still { return .none }
        return reduce ? .fade : .slide
    }

    /// The mode the drops move in now: the Mac's Reduce Motion is the one switch (Sven, coordinator 13: no own setting).
    static func live() -> Mode {
        mode(still: false, reduce: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

/// A bar drop's header row, one in both drops (C frames): the drop's glyph in the accent, its name, what runs in it in
/// muted words, and at the end its keys as small caps chips with what they do; a hint with an action is a button.
struct BarDropHeader: View {
    struct Hint: Identifiable {
        /// The key as a chip ("esc", "⌘N", "⇪ T"); nil shows the words alone.
        var key: String?
        var label: String
        var action: (() -> Void)?
        var disabled = false
        var id: String { label }
    }

    @Environment(\.ink) private var ink
    let symbol: String
    let title: String
    let detail: String
    var hints: [Hint] = []

    static let height: CGFloat = 40
    /// The side inset, the chat's turns' and the shell's text's too, so the three line up.
    static let inset: CGFloat = 18

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.accentInk).accessibilityHidden(true)
            Text(title).font(ink.ui(13, .semibold)).foregroundStyle(ink.text).accessibilityAddTraits(.isHeader).fixedSize()
            Text(detail).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            HStack(spacing: 14) { ForEach(hints) { BarDropHint(hint: $0) } }.fixedSize()
        }
        .padding(.horizontal, Self.inset).frame(height: Self.height)
    }
}

/// One hint: its key chip and its words, a button when it acts.
private struct BarDropHint: View {
    @Environment(\.ink) private var ink
    let hint: BarDropHeader.Hint
    @State private var hover = false

    var body: some View {
        if let action = hint.action {
            Button(action: action) { face(lit: hover && !hint.disabled) }
                .buttonStyle(.plain).disabled(hint.disabled)
                .onHover { hover = $0 }
                .help(hint.key.map { "\(hint.label.prefix(1).uppercased())\(hint.label.dropFirst()) (\($0))" } ?? hint.label)
                .accessibilityLabel(hint.label)
        } else {
            face(lit: false).accessibilityElement(children: .combine)
        }
    }

    private func face(lit: Bool) -> some View {
        HStack(spacing: 6) {
            if let key = hint.key {
                Text(key).font(ink.mono(10.5, weight: .medium)).foregroundStyle(lit ? ink.text : ink.text2)
                    .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 18)
                    .background(ink.selected, in: .rect(cornerRadius: 4, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ink.line2, lineWidth: 1) }
                    .accessibilityHidden(true)
            }
            Text(hint.label).font(ink.ui(11.5)).foregroundStyle(lit ? ink.text : ink.muted)
        }
        .opacity(hint.disabled ? 0.55 : 1)
        .contentShape(.rect)
    }
}

/// A drop's edge: down the sides and round the bottom corners, none along the top, which meets the bar.
struct BarDropEdge: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX + r, y: rect.maxY), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// The drop's content inside its panel, cut at the panel's edges: the content slides within it, so it comes out from
/// behind the bar and is cut at the bar's foot, while the panel itself sits still on its frame.
final class BarDropClip: NSView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// The terminal's drop around its shell's view (C frames, design cards 6, 10, 11): the header (`>_ Terminal  zsh ·
/// ~/code/pilot`, its key and hide), a rule, the shell on the drop's ground, a hairline down the sides and round the
/// bottom, no shadow; square at the top under the bar and the style's pop corner at the bottom. The shell's view keeps
/// the keyboard: the header and the edge take no keys, and the edge no clicks.
@MainActor
final class TerminalDropChrome: NSView {
    @Observable @MainActor
    final class Header {
        var detail: String
        var key: String?
        init(detail: String, key: String?) { (self.detail, self.key) = (detail, key) }
    }

    let body: NSView
    let header: Header
    private let detail: @MainActor () -> String
    private let top: NSView
    private let rule = NSView()
    private let edge: Edge
    private var pending = false

    /// `body` (the shell's view) under the header; `detail` says what runs where, read again by `refresh`.
    init(_ body: NSView, look: Look = .shared, key: String?, detail: @escaping @MainActor () -> String, hide: @escaping @MainActor () -> Void) {
        self.body = body
        self.detail = detail
        header = Header(detail: detail(), key: key)
        let tokens = look.chromeTokens(.quickAI)
        let ink = Ink(style: tokens)
        let radius = CGFloat(tokens.radii.pop)
        let host = NSHostingView(rootView: TerminalDropHeader(header: header, hide: hide).styled(.quickAI, look: look).pilotTheme(look: look))
        host.sizingOptions = []
        top = host
        edge = Edge(radius: radius, colour: NSColor(ink.windowLine), width: ink.stroke)
        super.init(frame: body.frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(ink.surface).cgColor
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]   // the bottom ones: this view is not flipped
        layer?.masksToBounds = true
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor(ink.line).cgColor
        for view in [body, top, rule, edge] { addSubview(view) }
        place()
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The terminal's chrome around Pilot's shell: its shell's name and folder, Hyper+T's key as Sven bound it.
    convenience init(surface: TerminalSurface, look: Look = .shared, hide: @escaping @MainActor () -> Void) {
        self.init(surface, look: look, key: Self.key(), detail: { [weak surface] in surface.map(Self.detail) ?? "" }, hide: hide)
    }

    /// `zsh · ~/code/pilot`: the shell's name and the folder it is in now (its pid's working directory), home as `~`.
    static func detail(_ surface: TerminalSurface) -> String {
        let shell = surface.shellName
        guard let folder = directory(of: surface.shellPID) else { return shell }
        return "\(shell) · \(tilde(folder))"
    }

    static func tilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A process's working directory, nil when it has none to read (not started, gone).
    static func directory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// The terminal drop's key as the dropdown signs a bind ("⇪ T"); nil without the engine or a bind.
    static func key() -> String? {
        Engine.shared?.keyLabel(TerminalDrop.actionID)
    }

    /// Reads what runs where again, a moment after Return, once a `cd` has run.
    func refreshSoon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            pending = false
            refresh()
        }
    }

    func refresh() {
        let now = detail()
        if now != header.detail { header.detail = now }
    }

    /// The header and the shell fade in under the slide, from 70 to 180 ms; the ground and the edge come whole.
    func fadeIn() {
        for view in [top, body] {
            guard let layer = view.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + BarDropMotion.contentsFrom
            fade.duration = BarDropMotion.contentsTo - BarDropMotion.contentsFrom
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "barDrop.fadeIn")
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }

    private func place() {
        let h = BarDropHeader.height, w = bounds.width
        top.frame = CGRect(x: 0, y: bounds.height - h, width: w, height: h)
        rule.frame = CGRect(x: 0, y: bounds.height - h - 1, width: w, height: 1)
        // The shell's text in from the sides as the header's words are, a little air above and below it.
        let side = BarDropHeader.inset, air: CGFloat = 10
        body.frame = CGRect(x: side, y: air, width: max(0, w - side * 2), height: max(0, bounds.height - h - 1 - air * 2))
        edge.frame = bounds
    }

    /// The hairline down the sides and round the bottom, over everything; clicks go through it.
    private final class Edge: NSView {
        let radius: CGFloat
        let colour: NSColor
        let width: CGFloat

        init(radius: CGFloat, colour: NSColor, width: CGFloat) {
            (self.radius, self.colour, self.width) = (radius, colour, width)
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: width / 2, dy: 0).divided(atDistance: width / 2, from: .maxYEdge).remainder
            let path = NSBezierPath(cgPath: BarDropEdge(radius: radius).path(in: rect).cgPath)
            path.lineWidth = width
            colour.setStroke()
            path.stroke()
        }
    }
}

/// The terminal's header row: its name, what runs where, and its key to hide it.
private struct TerminalDropHeader: View {
    let header: TerminalDropChrome.Header
    let hide: @MainActor () -> Void

    var body: some View {
        BarDropHeader(symbol: BarParts.dropSymbol(.terminal), title: "Terminal", detail: header.detail,
                      hints: [.init(key: header.key, label: "hide", action: { hide() })])
    }
}
