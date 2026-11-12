import AppKit
import PilotCore
import SwiftUI

/// The desktop controls' shared parts (spec desktop-controls T2, the native design round): the motion values, the press,
/// a slider, a card and the small marks the Dropdown panel, the pill and the Carousel all draw. Faces take plain values and
/// read colour and type only from the style (`@Environment(\.style)`), so they follow the theme; builders wire live
/// sources around them (T3, T5, T7, T8, T9) and never edit them.
enum DesktopMotion {
    /// A surface opening or growing: a spring with no bounce (Krehel); under Reduce Motion a short fade, no travel.
    static func open(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.14) : .spring(duration: 0.34, bounce: 0)
    }

    /// One browse step in the Carousel, a view switch in the pill: quicker, still no bounce; a cross-fade under Reduce
    /// Motion.
    static func step(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.26, bounce: 0)
    }

    /// A pressed control's scale (Krehel's 0.96); 1 under Reduce Motion.
    static func press(_ pressed: Bool, reduceMotion: Bool) -> CGFloat { pressed && !reduceMotion ? 0.96 : 1 }
}

/// A plain press for a face's own buttons: scaled to 0.96 while held, dimmed a little, no other chrome.
struct FacePress: ButtonStyle {
    var reduceMotion = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(DesktopMotion.press(configuration.isPressed, reduceMotion: reduceMotion))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.16, bounce: 0), value: configuration.isPressed)
    }
}

/// A block's card: the raised fill on a hairline at the card radius (the reference panel's grouped boxes).
struct FaceCard<Content: View>: View {
    @Environment(\.style) private var style
    var padding: CGFloat = 12
    var lit = false
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.card, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.color(\.raised), in: shape)
            .overlay { shape.strokeBorder(style.color(lit ? \.accentLine : \.line)) }
    }
}

/// A level from 0 to 1 drawn the Instrument way: a sunken track, the fill in the second text colour (the signal is for
/// Hyper, live and selected alone), a white knob on a hairline. Empty while `muted`.
struct FaceSlider: View {
    @Environment(\.style) private var style
    let value: Double
    var muted = false
    var height: CGFloat = 6
    /// What VoiceOver calls it ("Sound", "Brightness").
    var label = ""
    /// The new level as the knob is dragged or stepped by VoiceOver; nil draws a reading only.
    var onChange: ((Double) -> Void)? = nil

    var body: some View {
        GeometryReader { space in
            let level = muted ? 0 : min(max(value, 0), 1)
            let knob: CGFloat = 14
            let x = (space.size.width - knob) * level
            ZStack(alignment: .leading) {
                Capsule(style: .circular).fill(style.color(\.sunken))
                    .overlay { Capsule(style: .circular).strokeBorder(style.color(\.line)) }
                    .frame(height: height)
                Capsule(style: .circular).fill(style.color(\.text2)).frame(width: x + knob / 2, height: height)
                Circle().fill(style.color(\.knob))
                    .overlay { Circle().strokeBorder(style.color(\.line2)) }
                    .frame(width: knob, height: knob)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onChange?(min(max((drag.location.x - knob / 2) / max(space.size.width - knob, 1), 0), 1))
            })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(muted ? "Muted" : "\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange?(min(value + 0.1, 1))
            case .decrement: onChange?(max(value - 0.1, 0))
            @unknown default: break
            }
        }
    }
}

/// A round glyph well: a symbol on the sunken fill, or on the raised one with the text colour while `on`.
struct FaceGlyph: View {
    @Environment(\.style) private var style
    let symbol: String
    var on = true
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(style.color(on ? \.text : \.text3))
            .frame(width: size, height: size)
            .background(style.color(on ? \.panel : \.sunken), in: Circle())
            .overlay { Circle().strokeBorder(style.color(on ? \.line2 : \.line)) }
            .accessibilityHidden(true)
    }
}

/// Live: a small dot in the signal colour, the one thing on a face that says something is running.
struct FaceLiveDot: View {
    @Environment(\.style) private var style
    var size: CGFloat = 6
    var body: some View { Circle().fill(style.color(\.accent)).frame(width: size, height: size).accessibilityHidden(true) }
}

/// A picture in a rounded frame with the image hairline; a quiet fill with `placeholder`'s glyph when there is none.
struct FaceArt: View {
    @Environment(\.style) private var style
    let image: NSImage?
    var size: CGSize
    var radius: CGFloat = 6
    var placeholder = "music.note"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                style.color(\.sunken)
                Image(systemName: placeholder).font(.system(size: min(size.width, size.height) * 0.38, weight: .regular))
                    .foregroundStyle(style.color(\.text3))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay { shape.strokeBorder(style.color(\.imageOutline)) }
        .accessibilityHidden(true)
    }
}

/// A key hint: the keys as chips and what they do, in the caption face.
struct FaceHint: View {
    @Environment(\.style) private var style
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) { ForEach(Array(keys.enumerated()), id: \.offset) { InstrumentKey(text: $1) } }
            Text(label).styleText(\.small).foregroundStyle(style.color(\.text2)).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(keys.joined(separator: " ")): \(label)")
    }
}

/// An empty state: a glyph, what is missing in one line, what to do in a second, and an optional button.
struct FaceEmpty: View {
    @Environment(\.style) private var style
    let symbol: String
    let title: String
    let detail: String
    var button: String?
    var compact = false
    /// The button wears the keyboard's focus ring (the pill's lit row).
    var lit = false
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: compact ? 6 : 9) {
            FaceGlyph(symbol: symbol, on: false, size: compact ? 30 : 38)
            VStack(spacing: 3) {
                Text(title).styleText(\.strong).foregroundStyle(style.color(\.text))
                Text(detail).styleText(\.caption).foregroundStyle(style.color(\.text2))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if let button {
                Button(button, action: action).buttonStyle(InstrumentButtonStyle(kind: .raised))
                    // focusBorder draws rounded rectangles only; the button is a capsule.
                    .overlay { if lit { Capsule(style: .circular).strokeBorder(style.color(\.accent), lineWidth: InstrumentBar.ring).padding(-3) } }
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity)
    }
}

/// A few tiles in `columns` equal columns, drawn at once (a LazyVGrid resolves its cells lazily, and six tiles gain
/// nothing from it); a short last row keeps its tiles at the full rows' width.
struct FaceColumns<Item: Hashable, Cell: View>: View {
    let items: [Item]
    let columns: Int
    var spacing: CGFloat = 6
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        VStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { cell($0).frame(maxWidth: .infinity) }
                    ForEach(0..<(columns - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }
}
