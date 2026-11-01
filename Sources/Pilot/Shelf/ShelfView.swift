import AppKit
import PilotCore
import SwiftUI

/// One screen's Window shelf (the previews' round 2, Q681, Q690; the Deck, Q704): this workspace's shelved and minimized
/// windows on top as turned cards, every other workspace below as one fanned stack with its number. A card is the
/// window's picture (ShelfPictures) or, with pictures Off or not allowed, its app's icon and its title; without Screen
/// Recording the shelf offers it once, above the cards.
struct ShelfView: View {
    let shelf: WindowShelf
    let screen: String
    let top: @MainActor () -> CGFloat

    var body: some View {
        let shown = shelf.screens.first { $0.id == screen }
        GeometryReader { room in
            ScrollView(.vertical, showsIndicators: false) {
                ShelfColumn(shown: shown, pictures: shelf.pictures, flying: shelf.flying,
                            open: { shelf.open($0) }, openWorkspace: { shelf.open($0) },
                            face: { [screen] id, frame, flat in shelf.place(id, at: frame, flat: flat, on: screen) })
                    .padding(.top, top() + 14)
                    .padding(.bottom, 20)
                    .padding(.leading, 14)
                    // Centred down the screen as Stage Manager's strip is; a long shelf scrolls from the top.
                    .frame(width: CGFloat(PilotBlock.shelfWidth), alignment: .leading)
                    .frame(minHeight: room.size.height)
            }
        }
        .onHover { shelf.pictures.hovering($0, on: screen) }
        .styled(.hud)
        .pilotTheme()
    }
}

/// The shelf's places, top to bottom: the offer, this workspace's cards, then the other workspaces'. The renders draw it
/// alone; `face` hears where each card's front window is drawn, for its Fly.
struct ShelfColumn: View {
    let shown: ShelfScreen?
    let pictures: ShelfPictures
    /// The card whose window is flying to the stage: its place is empty until the shelf refreshes.
    var flying: Int?
    var open: (ShelfItem) -> Void = { _ in }
    var openWorkspace: (ShelfWorkspace) -> Void = { _ in }
    var face: (Int, CGRect, Bool) -> Void = { _, _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if pictures.offering { ShelfOffer(pictures: pictures) }
            ForEach(shown?.items ?? []) { item in
                Button { open(item) } label: {
                    ShelfGroup(windows: item.windows, pictures: pictures, face: { face(item.id, $0, $1) }) { ShelfItemLabel(item: item) }
                }
                .buttonStyle(.plain)
                .opacity(flying == item.id ? 0 : 1)
                .help(item.isMinimized ? "\(item.label) (minimized)" : item.label)
            }
            if let others = shown?.others, !others.isEmpty {
                ShelfHeading()
                ForEach(others) { workspace in
                    Button { openWorkspace(workspace) } label: {
                        ShelfGroup(windows: workspace.stack, pictures: pictures, compact: true) {
                            HStack(spacing: 6) { Kbd(text: workspace.name, small: true); Text(workspace.label).shelfLabel() }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Workspace \(workspace.name): \(workspace.label)")
                }
            }
        }
    }
}

/// The shelf's one offer of Screen Recording (Q690): pictures are on but not allowed, so the cards are icons until
/// Allow; Not now leaves it to Settings.
private struct ShelfOffer: View {
    @Environment(\.ink) private var ink
    let pictures: ShelfPictures

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("See your windows here, not only their icons.").font(.system(size: 11, weight: .medium)).foregroundStyle(ink.text)
            Text("Pictures need Screen Recording.").font(.system(size: 10)).foregroundStyle(ink.muted)
            HStack(spacing: 6) {
                Button("Allow") { pictures.allow() }.buttonStyle(PilotButtonStyle(primary: true))
                Button("Not now") { pictures.answerOffer() }.buttonStyle(PilotButtonStyle(ghost: true))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(width: ShelfGroup<EmptyView>.width, alignment: .leading)
        .background(ink.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ink.line2, lineWidth: 1))
    }
}

/// "Other workspaces" over the folded stacks, in the cards' labels' type, a step quieter.
private struct ShelfHeading: View {
    @Environment(\.style) private var style

    var body: some View {
        Text("Other workspaces").font(style.font(\.strong, size: 12)).foregroundStyle(style.color(style.dark ? \.text2 : \.text))
            .shelfLabel().padding(.top, 4).padding(.leading, 4)
    }
}

/// A card's words: "Pilot · Settings"; one app's joined windows as its name and their count on the signal's soft chip;
/// a minimized window quieter, "Notes · minimized" (the Deck mock).
private struct ShelfItemLabel: View {
    @Environment(\.style) private var style
    let item: ShelfItem

    var body: some View {
        let apps = Set(item.windows.map(\.appName))
        if item.isMinimized {
            Text("\(item.windows[0].appName) · minimized").foregroundStyle(style.color(style.dark ? \.text2 : \.text)).shelfLabel()
        } else if item.windows.count > 1, apps.count == 1 {
            HStack(spacing: 6) {
                Text(item.windows[0].appName).shelfLabel()
                ShelfCount(count: item.windows.count)
            }
        } else {
            Text(item.label).shelfLabel()
        }
    }
}

/// A joined group's window count: Instrument's soft signal chip, Toybox's sun pill.
private struct ShelfCount: View {
    @Environment(\.style) private var style
    let count: Int

    var body: some View {
        let toy = style.kind == .toybox
        let shape = RoundedRectangle(cornerRadius: toy ? 9 : style.radii.chip, style: .continuous)
        Text("\(count)").font(style.font(\.mono, size: 10.5)).monospacedDigit()
            .foregroundStyle(style.color(toy ? \.onAccent : \.accentText))
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 17)
            // The soft fill over the theme's panel, so the wallpaper never shows through the digit.
            .background { ZStack { shape.fill(style.color(\.panel)); shape.fill(style.color(toy ? \.accent : \.accentSoft)) } }
    }
}

extension View {
    /// Words on the wallpaper, which no theme colours: in a dark theme the theme's text lifted by a small shadow, as the
    /// Deck mock has it; in a light theme, whose text is dark, on a plate of the theme's panel, so they read on any
    /// wallpaper (readability from fills and ink, Q356).
    func shelfLabel() -> some View { modifier(ShelfLabelInk()) }
}

private struct ShelfLabelInk: ViewModifier {
    @Environment(\.style) private var style

    func body(content: Content) -> some View {
        if style.dark {
            content.shadow(color: .black.opacity(0.55), radius: 2, y: 1)
        } else {
            content.padding(.horizontal, 7).padding(.vertical, 3)
                .background(style.color(\.panel).opacity(0.94), in: Capsule())
                .overlay { if style.depth.card.outline > 0 { Capsule().strokeBorder(style.color(\.outline), lineWidth: 1.5) } }
        }
    }
}

/// A place on the shelf, as Stage Manager draws one (Q690, the Deck Q704): its front window's picture filling a card of
/// its own shape and rounding as the window does, the windows behind fanned up and right, each turned 4° more and
/// darker, the front app's icon on the card's corner and the label under it, all turned 10° about the left edge (Q705;
/// the previews' `.smg` turned 24°). The pointer on it turns it flat and lifts it 1.04 with the signal's ring.
struct ShelfGroup<Label: View>: View {
    @Environment(\.style) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    let windows: [AeroWindow]
    let pictures: ShelfPictures
    /// The other workspaces' stacks: a fifth narrower, as the mock folds them.
    var compact = false
    /// Where the front window's card is drawn, in the panel's coordinates, and whether the pointer has it flat (the Fly's
    /// start): flat, the frame as drawn, lifted 1.04; turned, its frame before the turn, which the Fly turns itself.
    var face: ((CGRect, Bool) -> Void)?
    @ViewBuilder let label: () -> Label

    /// The card's width: the shelf's room less its margins.
    static var width: CGFloat { ShelfPictures.cardWidth }
    /// The turn about the card's leading edge (Q705: 10°) and its perspective.
    static var turn: Double { 10 }
    static var perspective: CGFloat { 0.3 }
    /// The windows behind the front one, nearest first: each a step up and right, turned and darkened (the mock's .b1, .b2).
    static var fan: [(offset: CGSize, angle: Double, dim: Double)] {
        [(CGSize(width: 14.4, height: -12), 4, 0.45), (CGSize(width: 25.6, height: -22.4), 8, 0.6)]
    }

    /// A card `width` across takes its picture's shape, between square and a wide strip (a tall window is cropped to
    /// its top); 16:10 without one.
    static func height(_ width: CGFloat, picture: CGImage?) -> CGFloat {
        let aspect = picture.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1.6
        return (width / min(max(aspect, 1), 2.2)).rounded()
    }

    /// How far a fan of `behind` windows reaches past a `width` card: right and up, its turn's corners included.
    static func reach(_ behind: Int, width: CGFloat) -> CGSize {
        guard behind > 0 else { return .zero }
        let step = fan[behind - 1], a = step.angle * .pi / 180, h = width / 1.6
        let grow = CGSize(width: (width * cos(a) + h * sin(a) - width) / 2, height: (width * sin(a) + h * cos(a) - h) / 2)
        return CGSize(width: step.offset.width + grow.width, height: -step.offset.height + grow.height)
    }

    var body: some View {
        let behind = Array(windows.dropLast().suffix(2))
        let full = compact ? (Self.width * 0.8).rounded() : Self.width
        let reach = Self.reach(behind.count, width: full)
        // The fan may spill 12 pt into the room's right margin; past that the front card narrows.
        let across = full - max(0, reach.width - 12)
        let front = windows.last
        let size = CGSize(width: across, height: Self.height(across, picture: front.flatMap { pictures.image(of: $0.id) }))
        let flat = hovered && !reduceMotion
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(behind.enumerated()), id: \.element.id) { i, window in
                    let step = Self.fan[behind.count - 1 - i]
                    ShelfFace(window: window, pictures: pictures, size: size, dim: step.dim)
                        .rotationEffect(.degrees(step.angle))
                        .offset(step.offset)
                }
                if let front {
                    ShelfFace(window: front, pictures: pictures, size: size, lit: hovered)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            face?(flat ? $0 : CGRect(origin: $0.origin, size: size), flat)
                        }
                    ShelfIcon(window: front)
                        .offset(x: -12, y: size.height - 28)
                }
            }
            .padding(.top, reach.height)
            .frame(width: full, height: size.height + reach.height, alignment: .topLeading)
            label()
                .font(style.font(\.strong, size: 12.5)).foregroundStyle(style.color(\.text)).lineLimit(1).truncationMode(.tail)
                .padding(.leading, 38).frame(width: full + 12, alignment: .leading)
        }
        .contentShape(.rect)
        .scaleEffect(flat ? 1.04 : 1, anchor: .leading)
        .rotation3DEffect(.degrees(flat ? 0 : Self.turn), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: Self.perspective)
        .animation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0), value: hovered)
        .onHover { hovered = $0 }
    }
}

/// One window's face: its picture, rounding as the window does, or its app's icon and title on the style's panel; in the
/// style's depth (Instrument's pure hairline and a soft shadow, Toybox's ink outline and solid bottom edge), the signal's
/// ring while the pointer is on it.
private struct ShelfFace: View {
    @Environment(\.style) private var style
    let window: AeroWindow
    let pictures: ShelfPictures
    let size: CGSize
    /// The fan's darkening, 0 on the front window.
    var dim: Double = 0
    var lit = false

    /// The corner of a face `width` across showing window `id`: the window's own, read off its still, at least 3 pt, since
    /// a card a fifteenth of its window's width would round it to a point; the style's card corner with no picture.
    static func radius(_ pictures: ShelfPictures, _ id: Int, width: CGFloat, style: StyleTokens) -> CGFloat {
        pictures.image(of: id) == nil ? style.radii.card : max(3, pictures.corner(of: id) * width)
    }

    var body: some View {
        let image = pictures.image(of: window.id)
        let radius = Self.radius(pictures, window.id, width: size.width, style: style)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let depth = style.depth.card
        let toy = depth.outline > 0
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).antialiased(true).aspectRatio(contentMode: .fill)
            } else {
                VStack(spacing: 6) {
                    AppIcon(name: window.appName, bundle: window.bundleId, size: 44)
                    Text(window.title.isEmpty ? window.appName : window.title)
                        .font(style.font(\.caption, size: 11.5)).foregroundStyle(style.color(\.text2)).lineLimit(2).multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(style.color(\.panel))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .overlay { if dim > 0 { shape.fill(.black.opacity(dim)) } }
        // Instrument: a picture's outline in pure white or black at a tenth (Krehel), never a tinted line on its edge.
        .overlay { if !toy { shape.strokeBorder(style.dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12), lineWidth: 1) } }
        .overlay { if lit && !toy { shape.strokeBorder(style.color(\.accent), lineWidth: 2) } }
        .background {
            if toy {
                // The ink outline round the face and its solid edge below (the mock's two box-shadows), the sun's while lit.
                let o = depth.outline + (lit ? 0.25 : 0)
                let ring = RoundedRectangle(cornerRadius: radius + o, style: .continuous)
                ZStack {
                    ring.fill(style.color(lit ? \.accentEdge : \.outline)).padding(-o).offset(y: depth.edge)
                    ring.fill(style.color(lit ? \.accent : \.outline)).padding(-o)
                }
            } else {
                // A soft lift off the wallpaper and a tight contact line under it, on the shape, so a live frame never
                // recomputes it.
                shape.fill(.black)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            }
        }
    }
}

/// The front app's icon on the card's corner: a soft shadow in Instrument; Toybox's ink outline and edge round its
/// squircle (an icon's artwork is 824 of its 1,024 points, so the ring sits inside the frame).
private struct ShelfIcon: View {
    @Environment(\.style) private var style
    let window: AeroWindow
    static let size: CGFloat = 40

    var body: some View {
        let depth = style.depth.card
        let art = Self.size * 824 / 1024, inset = (Self.size - art) / 2, o = depth.outline
        let ring = RoundedRectangle(cornerRadius: art * 0.225 + o, style: .continuous)
        AppIcon(name: window.appName, bundle: window.bundleId, size: Self.size)
            .background {
                if o > 0 {
                    ZStack {
                        ring.fill(style.color(\.outline)).padding(inset - o).offset(y: depth.edge - 1)
                        ring.fill(style.color(\.outline)).padding(inset - o)
                    }
                }
            }
            .shadow(color: .black.opacity(o > 0 ? 0 : 0.35), radius: 3, y: 1)
    }
}
