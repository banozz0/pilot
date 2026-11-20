import AppKit
import PilotCore
import SwiftUI

// The capture box's views (pilot-ui-redesign T24, S5 B, shots 5c-*): the bar under the picked area with the box's
// mode, timer and action, each choice carrying its fixed letter (Q257); the held area's handles and its size; and the key
// sheet, the user's capture binds beside the box's own letters. Instrument only, ring and fill, no shadow (DESIGN.md).

/// The bar: how much of the screen (Area, Window, Full, Scroll), what the capture makes (Photo, Record, Text), the
/// timer, the action button that names what Return does, and Esc. The overlay draws it as a picture, so it takes no
/// clicks and no keys: the letters work through the overlay's own keys (T23).
struct CaptureBoxBar: View {
    @Environment(\.style) private var style
    let box: CaptureBox

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.pop, style: .continuous)
        HStack(spacing: 8) {
            group(CaptureBox.How.allCases.map { Choice(title: $0.title, symbol: $0.symbol, letter: $0.letter, on: box.how == $0) })
            group(CaptureBox.What.allCases.map { Choice(title: $0.title, symbol: $0.symbol, letter: $0.letter, on: box.what == $0) })
            timer
            action
            HStack(spacing: 6) {
                InstrumentKey(text: "Esc")
                Text("Close").styleText(\.caption).foregroundStyle(style.color(\.text3))
            }
            .padding(.trailing, 4)
        }
        .padding(8)
        .background(style.color(\.canvas), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line2)) }
        .fixedSize()
    }

    private struct Choice: Identifiable {
        let title: String, symbol: String
        let letter: CaptureBox.Letter?
        let on: Bool
        var id: String { title }
    }

    /// One choice of several, the picked one raised with its icon in the signal colour.
    private func group(_ choices: [Choice]) -> some View {
        HStack(spacing: 2) {
            ForEach(choices) { choice in
                HStack(spacing: 6) {
                    Image(systemName: choice.symbol).font(style.font(\.icon))
                        .foregroundStyle(style.color(choice.on ? \.accent : \.text3)).accessibilityHidden(true)
                    Text(choice.title).styleText(choice.on ? \.strong : \.body).foregroundStyle(style.color(choice.on ? \.text : \.text2))
                    if let letter = choice.letter { InstrumentKey(text: letter.cap) }
                }
                .padding(.horizontal, 9).frame(height: style.points(30))
                .instrumentRaised(choice.on, fill: \.panel, radius: style.radii.control - 2)
            }
        }
        .padding(2)
        .instrumentWell()
    }

    /// The timer: off, or the seconds it waits; T walks round them.
    private var timer: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer").font(style.font(\.icon)).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
            Text(box.timer == 0 ? "Off" : "\(box.timer) s").styleText(\.body).foregroundStyle(style.color(box.timer == 0 ? \.text2 : \.text))
                .monospacedDigit()
            InstrumentKey(text: CaptureBox.Letter.timer.cap)
        }
        .padding(.horizontal, 6)
    }

    /// What Return does, in words on the signal colour: Capture, Record (with its dot), Copy text or Start scrolling.
    private var action: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        let chip = RoundedRectangle(cornerRadius: style.radii.chip, style: .continuous)
        return HStack(spacing: 8) {
            if box.what == .record, box.how != .scroll { Circle().frame(width: 7, height: 7).accessibilityHidden(true) }
            Text(box.action).styleText(\.strong)
            InstrumentLegend(text: "↵")
                .padding(.horizontal, 5).frame(minWidth: style.points(19), minHeight: style.points(19))
                .overlay { chip.strokeBorder(style.color(\.onAccent).opacity(0.5)) }
        }
        .foregroundStyle(style.color(\.onAccent))
        .padding(.horizontal, 14).frame(height: style.points(34))
        .background(style.color(\.accent), in: shape)
    }
}

/// The key sheet (shot 5c-keys): on the left each capture bind with the user's own key from the bind store, "no key"
/// where it has none, and the mode it opens; on the right the box's fixed letters (Q257), whatever those binds are.
struct CaptureKeySheet: View {
    @Environment(\.style) private var style

    struct Bind: Identifiable {
        let action: String, title: String
        /// The user's key; nil when the bind has none or is switched off.
        let trigger: Key?
        let opens: CaptureBox
        var id: String { action }
    }

    let binds: [Bind]

    /// The six capture binds read from `store`, titled by `label` (the action registry's label).
    init(store: BindStore, label: (String) -> String?) {
        binds = CaptureBox.binds.map { bind in
            Bind(action: bind.action, title: label(bind.action) ?? bind.action,
                 trigger: store.isDisabled(bind.action) ? nil : store.trigger(for: bind.action), opens: bind.opens)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.pop, style: .continuous)
        HStack(alignment: .top, spacing: 0) {
            column("Each capture bind captures in its mode at once") {
                ForEach(Array(binds.enumerated()), id: \.element.id) { index, bind in
                    row(first: index == 0) {
                        Group {
                            if let trigger = bind.trigger { InstrumentKeys(trigger: trigger) } else { unset }
                        }
                        .frame(width: style.points(76), alignment: .leading)
                        Text(bind.title).styleText(\.body).foregroundStyle(style.color(\.text))
                        Spacer(minLength: 12)
                        Text("\(bind.opens.how.title) · \(bind.opens.what.title)").styleText(\.mono).foregroundStyle(style.color(\.text2))
                    }
                }
            }
            InstrumentRule(vertical: true)
            column("Inside the box") {
                ForEach(Array(Self.letters.enumerated()), id: \.offset) { index, pair in
                    row(first: index == 0) {
                        letter(pair.0.key, pair.0.does)
                        Spacer(minLength: 12)
                        if let second = pair.1 { letter(second.key, second.does) }
                    }
                }
                Text("Capture tool opens the box; pick a mode, then press Return.")
                    .styleText(\.caption).foregroundStyle(style.color(\.text3))
                    .padding(.top, 10)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: style.points(860))
        .background(style.color(\.canvas), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line2)) }
    }

    /// The box's letters in pairs, as the bar has them.
    static let letters: [((key: String, does: String), (key: String, does: String)?)] = [
        (("A", "Area"), ("W", "Window")),
        (("F", "Full screen"), ("S", "Scroll")),
        (("R", "Record, again for Photo"), ("O", "Text")),
        (("T", "Timer: off, 3 s, 5 s, 10 s"), nil),
        (("↵", "Capture, record or copy"), ("Esc", "Close")),
    ]

    /// A bind with no key: the words in a sunk chip, as a free key is sunk.
    private var unset: some View {
        Text("no key").styleText(\.key).foregroundStyle(style.color(\.text3))
            .padding(.horizontal, 6).frame(minHeight: style.points(19))
            .instrumentWell(radius: style.radii.chip)
            .accessibilityLabel("No key")
    }

    private func letter(_ key: String, _ does: String) -> some View {
        HStack(spacing: 10) {
            InstrumentKey(text: key).frame(minWidth: style.points(28))
            Text(does).styleText(\.body).foregroundStyle(style.color(\.text))
        }
        .accessibilityElement(children: .combine)
    }

    private func column(_ title: String, @ViewBuilder _ rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            InstrumentEyebrow(text: title).padding(.bottom, 10)
            rows()
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(first: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            if !first { InstrumentRule() }
            HStack(spacing: 12) { content() }.frame(minHeight: style.points(38))
        }
    }
}

extension CaptureBox.How {
    var title: String {
        switch self {
        case .area: "Area"
        case .window: "Window"
        case .full: "Full"
        case .scroll: "Scroll"
        }
    }

    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .full: "display"
        case .scroll: "arrow.down.doc"
        }
    }

    var letter: CaptureBox.Letter {
        switch self {
        case .area: .area
        case .window: .window
        case .full: .full
        case .scroll: .scroll
        }
    }
}

extension CaptureBox.What {
    var title: String {
        switch self {
        case .photo: "Photo"
        case .record: "Record"
        case .text: "Text"
        }
    }

    var symbol: String {
        switch self {
        case .photo: "camera"
        case .record: "video"
        case .text: "text.viewfinder"
        }
    }

    /// Photo has no letter: R or O again goes back to it.
    var letter: CaptureBox.Letter? {
        switch self {
        case .photo: nil
        case .record: .record
        case .text: .text
        }
    }
}

extension CaptureBox.Letter {
    /// The letter as its key cap.
    var cap: String { String(rawValue).uppercased() }
}

/// The box's parts the overlay draws with AppKit on the frozen still: the bar as a picture made once per mode, the held
/// area's handles, and a readout chip. In the theme's colours from `tokens`.
@MainActor
struct CaptureBoxChrome {
    let tokens: StyleTokens
    /// Points to pixels, so the bar's picture is sharp on the display it is drawn on.
    let scale: CGFloat
    private var nsColour: (KeyPath<StyleColors, Paint>) -> NSColor { { NSColor(tokens.color($0)) } }

    init(tokens: StyleTokens, scale: CGFloat) {
        self.tokens = tokens
        self.scale = scale
    }

    /// The bar for `box`, drawn once; nil if SwiftUI could not draw it.
    func bar(_ box: CaptureBox) -> NSImage? {
        let renderer = ImageRenderer(content: CaptureBoxBar(box: box).style(tokens))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        return NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    /// The held area's eight handles (shot 5c-area): white squares on a ring of the signal colour.
    func handles(_ rect: CGRect, accent: NSColor) {
        for point in CaptureBox.Grip.handles.compactMap({ $0.point(on: rect) }) {
            let square = NSBezierPath(roundedRect: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10), xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            square.fill()
            accent.setStroke()
            square.lineWidth = 1.5
            square.stroke()
        }
    }

    /// A readout on the theme's ground on a hairline ring: a muted name, then the figures in mono. Placed by `place`
    /// from its size; returns where it went.
    @discardableResult
    func chip(name: String?, figures: String, place: (CGSize) -> CGPoint) -> CGRect {
        let mono: [NSAttributedString.Key: Any] = [.font: StyleTokens.nsFont(retyped(tokens.type.mono, size: 12)), .foregroundColor: nsColour(\.text)]
        let words: [NSAttributedString.Key: Any] = [.font: StyleTokens.nsFont(retyped(tokens.type.caption, size: 12)), .foregroundColor: nsColour(\.text2)]
        let figureSize = (figures as NSString).size(withAttributes: mono)
        let nameSize = name.map { ($0 as NSString).size(withAttributes: words) } ?? .zero
        let gap: CGFloat = name == nil ? 0 : 8
        let size = CGSize(width: nameSize.width + gap + figureSize.width + 20, height: max(figureSize.height, nameSize.height) + 10)
        let frame = CGRect(origin: place(size), size: size)
        let shape = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: tokens.radii.control, yRadius: tokens.radii.control)
        nsColour(\.canvas).setFill()
        shape.fill()
        nsColour(\.line2).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        var x = frame.minX + 10
        if let name {
            (name as NSString).draw(at: CGPoint(x: x, y: frame.midY - nameSize.height / 2), withAttributes: words)
            x += nameSize.width + gap
        }
        (figures as NSString).draw(at: CGPoint(x: x, y: frame.midY - figureSize.height / 2), withAttributes: mono)
        return frame
    }

    private func retyped(_ role: TypeRole, size: Double) -> TypeRole {
        var role = role
        role.size = size
        return role
    }

    /// The pointer over a held area: a resize arrow on a handle, a hand on the area itself, nil elsewhere.
    static func cursor(for grip: CaptureBox.Grip?, dragging: Bool) -> NSCursor? {
        let position: NSCursor.FrameResizePosition
        switch grip {
        case nil: return nil
        case .move: return dragging ? .closedHand : .openHand
        case .topLeft: position = .topLeft
        case .top: position = .top
        case .topRight: position = .topRight
        case .right: position = .right
        case .bottomRight: position = .bottomRight
        case .bottom: position = .bottom
        case .bottomLeft: position = .bottomLeft
        case .left: position = .left
        }
        return .frameResize(position: position, directions: .all)
    }
}
