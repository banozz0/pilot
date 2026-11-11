import AppKit
import PilotCore
import SwiftUI

/// What the Carousel shows (spec desktop-controls T2, T8, T9), as plain values: the mode, the items in order, the one in
/// the centre. T8 fills Wallpapers mode from the current theme's images (or the cycling folders), T9 Themes mode from the
/// compatible packs. No item reads a file here: images arrive as thumbnails, made off the main thread for the visible
/// window only.
struct CarouselValues {
    enum Mode: Hashable {
        case wallpapers, themes
        var title: String { self == .wallpapers ? "Wallpapers" : "Themes" }
    }

    /// A theme's colours for its drawn preview (Q26): the ground, a window's fill, its raised parts, words, the accent.
    struct ThemeLook: Hashable {
        var dark: Bool
        var ground: Color
        var window: Color
        var raised: Color
        var line: Color
        var text: Color
        var muted: Color
        var accent: Color
        var second: Color
        var third: Color
    }

    struct Item: Hashable {
        var title: String
        var image: NSImage?
        /// The applied wallpaper or theme.
        var current = false
        var favourite = false
        /// Themes mode: the line under its name, its colours, the apps found on this Mac (nil draws generic windows).
        var tagline: String?
        var palette: [Color] = []
        var look: ThemeLook?
        var apps: ThemePreview.Apps?
    }

    var mode = Mode.wallpapers
    var items: [Item] = []
    var index = 0
    /// Typed after `/`; nil while search is closed.
    var query: String?
    var favouritesOnly = false
    /// Wallpapers mode: the current theme's palette (none for the cycling folders); Themes mode uses each item's.
    var palette: [Color] = []
    /// Where the wallpapers come from, said under the name in Wallpapers mode ("Lagoon's wallpapers", "Your folders").
    var source = ""
}

/// The Carousel (spec desktop-controls T2): reference 1794159331540's large centre with its neighbours cut by the panel's
/// edges, the name and palette dots at the foot and the keys at the right; one look for both modes, the mode in the
/// header. 1000 by 390 pt on the pop radius, centred on the screen by T8's KeyPanel. The neighbours keep the centre's
/// height as narrow slices, so more of the row shows (Sven's pick B, 2026-11-10, over the reference's smaller pictures).
struct CarouselFace: View {
    /// What a click asks for; the keys are T8's (HUD.showSearchPanel). A click on a neighbour brings it to the centre,
    /// on the centre applies it.
    enum Action: Hashable { case select(Int), apply, mode(CarouselValues.Mode), openLook }

    @Environment(\.style) private var style
    let values: CarouselValues
    var reduceMotion = false
    var act: (Action) -> Void = { _ in }

    static let size = CGSize(width: 1000, height: 390)
    static let centre = CGSize(width: 432, height: 243)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.pop + 4, style: .continuous)
        VStack(spacing: 0) {
            header.padding(.horizontal, 22).padding(.top, 18)
            Group {
                if values.items.isEmpty { empty } else { row }
            }
            .frame(height: Self.centre.height + 36)
            footer.padding(.horizontal, 22).padding(.bottom, 18)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(style.color(\.panel), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line2)) }
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Carousel, \(values.mode.title)")
    }

    // MARK: Header

    /// The two modes as one segmented pair, the live one raised (its bind and S switch here too), S's key beside it;
    /// search while typing; the place in the row at the right.
    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach([CarouselValues.Mode.wallpapers, .themes], id: \.self) { mode in
                    let on = mode == values.mode
                    Button { act(.mode(mode)) } label: {
                    Text(mode.title).styleText(on ? \.strong : \.caption)
                        .foregroundStyle(style.color(on ? \.text : \.text2))
                        .padding(.horizontal, 11).frame(height: 26)
                        .background { if on { Capsule(style: .circular).fill(style.color(\.raised)) } }
                        .overlay { if on { Capsule(style: .circular).strokeBorder(style.color(\.line2)) } }
                        .contentShape(Capsule(style: .circular))
                    }
                    .buttonStyle(FacePress(reduceMotion: reduceMotion))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(2)
            .background(style.color(\.sunken), in: Capsule(style: .circular))
            .overlay { Capsule(style: .circular).strokeBorder(style.color(\.line)) }
            if values.query == nil { FaceHint(keys: ["S"], label: "Switch") }  // While searching, S types.

            if values.favouritesOnly {
                HStack(spacing: 5) {
                    Image(systemName: "heart.fill").font(.system(size: 9, weight: .semibold))
                    Text("Favourites")
                }
                .styleText(\.caption).foregroundStyle(style.color(\.text2))
            }
            Spacer(minLength: 0)
            if let query = values.query { search(query) }
            Text(values.items.isEmpty ? "0" : "\(values.index + 1) / \(values.items.count)")
                .font(style.font(\.mono, size: 11.5)).monospacedDigit().foregroundStyle(style.color(\.text2))
        }
    }

    private func search(_ query: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(style.color(\.text3))
            Text(query).styleText(\.body).foregroundStyle(style.color(\.text))
            Rectangle().fill(style.color(\.text)).frame(width: 1.5, height: 14)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(width: 220, height: 28)
        .background(style.color(\.sunken), in: Capsule(style: .circular))
        .overlay { Capsule(style: .circular).strokeBorder(style.color(\.line2)) }
    }

    // MARK: Row

    /// The centre picture ringed in the signal colour, two neighbours each side; the outer ones run under the panel's
    /// edge, faded. Browsing moves the row (DesktopMotion.step); under Reduce Motion the row cross-fades in place.
    private var row: some View {
        GeometryReader { space in
            let mid = space.size.width / 2
            ZStack {
                ForEach(Array(values.items.enumerated()), id: \.offset) { i, item in
                    let distance = i - values.index
                    if abs(distance) <= 3 {
                        let frame = Self.slot(distance)
                        card(item, size: frame.size, centre: distance == 0)
                            .onTapGesture { act(distance == 0 ? .apply : .select(i)) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { act(distance == 0 ? .apply : .select(i)) }
                            .position(x: mid + frame.x, y: space.size.height / 2)
                            .zIndex(Double(10 - abs(distance)))
                    }
                }
            }
            .frame(width: space.size.width, height: space.size.height)
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                       .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .id(reduceMotion ? values.index : 0)
        .transition(.opacity)
    }

    /// Where an item `distance` from the centre sits and how big it is.
    /// Three slices each side; the third runs under the panel's edge.
    static func slot(_ distance: Int) -> (x: CGFloat, size: CGSize) {
        if distance == 0 { return (0, centre) }
        let gap: CGFloat = 10, size = CGSize(width: 104, height: centre.height)
        let side: CGFloat = distance < 0 ? -1 : 1
        return (side * (centre.width / 2 + gap + size.width / 2 + CGFloat(abs(distance) - 1) * (size.width + gap)), size)
    }

    private func card(_ item: CarouselValues.Item, size: CGSize, centre: Bool) -> some View {
        let radius = centre ? style.radii.card + 2 : style.radii.card
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // A theme's badge sits at the foot, clear of its preview's bar; a wallpaper's at the top, as the reference has it.
        return ZStack(alignment: values.mode == .themes ? .bottomLeading : .topLeading) {
            picture(item, size: size)
                .frame(width: size.width, height: size.height)
                .clipShape(shape)
                .overlay { if !centre { shape.fill(style.color(\.panel).opacity(style.dark ? 0.42 : 0.34)) } }
            HStack(spacing: 5) {
                if item.current { badge("Current") }
                Spacer(minLength: 0)
                if item.favourite, values.mode == .wallpapers {
                    Image(systemName: "heart.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(style.color(\.text))
                        .frame(width: 22, height: 22)
                        .background(style.color(\.panel).opacity(0.88), in: Circle())
                        .accessibilityLabel("Favourite")
                }
            }
            .padding(8)
            .frame(width: size.width)
        }
        .overlay {
            RoundedRectangle(cornerRadius: centre ? radius + 3 : radius, style: .continuous)
                .strokeBorder(style.color(centre ? \.accent : \.imageOutline), lineWidth: centre ? 2 : 1)
                .padding(centre ? -3 : 0)
                .opacity(centre ? 1 : 0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title + (item.current ? ", current" : "") + (item.favourite && values.mode == .wallpapers ? ", favourite" : ""))
        .accessibilityAddTraits(centre ? .isSelected : [])
    }

    @ViewBuilder private func picture(_ item: CarouselValues.Item, size: CGSize) -> some View {
        if values.mode == .themes, let look = item.look {
            ThemePreview(look: look, wallpaper: item.image, apps: item.apps, title: item.title)
                .frame(width: CarouselFace.centre.width, height: CarouselFace.centre.height)
                .scaleEffect(max(size.width / CarouselFace.centre.width, size.height / CarouselFace.centre.height))
                .frame(width: size.width, height: size.height)
        } else if let image = item.image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            style.color(\.sunken)
        }
    }

    private func badge(_ words: String) -> some View {
        Text(words).styleText(\.small).foregroundStyle(style.color(\.text))
            .padding(.horizontal, 7).frame(height: 20)
            .background(style.color(\.panel).opacity(0.9), in: Capsule(style: .circular))
            .overlay { Capsule(style: .circular).strokeBorder(style.color(\.line2)) }
    }

    private var empty: some View {
        FaceEmpty(symbol: values.mode == .wallpapers ? "photo.on.rectangle.angled" : "paintpalette",
                  title: values.query != nil ? "Nothing matches “\(values.query ?? "")”"
                      : values.favouritesOnly ? "No favourites yet" : values.mode == .wallpapers ? "No wallpapers yet" : "No themes yet",
                  detail: values.query != nil ? "Try another word, or press Escape to see them all."
                      : values.favouritesOnly ? "Press F on a wallpaper to keep it here."
                      : values.mode == .wallpapers ? "Add a folder in Look › Wallpaper, or attach images to this theme."
                      : "Make a theme in Look › Themes, or add a pack with pilot theme.",
                  button: values.query == nil && !values.favouritesOnly ? "Open Look" : nil, action: { act(.openLook) })
            .frame(maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        let item = values.items.indices.contains(values.index) ? values.items[values.index] : nil
        let palette = values.mode == .themes ? item?.palette ?? [] : values.palette
        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item?.title ?? " ").font(style.font(\.title, size: 15)).foregroundStyle(style.color(\.text)).lineLimit(1).help(item?.title ?? "")
                    if let tagline = values.mode == .themes ? item?.tagline : values.source.isEmpty ? nil : values.source {
                        Text(tagline).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1)
                    }
                }
                HStack(spacing: 4) {
                    ForEach(Array(palette.prefix(8).enumerated()), id: \.offset) { _, colour in
                        Capsule(style: .circular).fill(colour).frame(width: 16, height: 8)
                            .overlay { Capsule(style: .circular).strokeBorder(style.color(\.imageOutline)) }
                    }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 13) {
                FaceHint(keys: ["←", "→"], label: "Browse")
                FaceHint(keys: ["↵"], label: values.mode == .wallpapers ? "Apply" : "Apply theme")
                if values.mode == .wallpapers {
                    FaceHint(keys: ["R"], label: "Random")
                    FaceHint(keys: ["F"], label: "Favourite")
                    FaceHint(keys: ["⇥"], label: "Favourites")
                }
                FaceHint(keys: ["/"], label: "Search")
                FaceHint(keys: ["Esc"], label: "Close")
            }
            .opacity(values.items.isEmpty ? 0.45 : 1)
        }
    }
}

/// A theme drawn as a desktop (Q26): its wallpaper, a bar, an editor, a terminal showing an About-like screen, Pilot and a
/// notes app, all in the theme's colours on fixed sample text; generic windows where an app is not found. A pack's own
/// picture (its manifest's `preview`, desktop-controls T14) replaces it: such an item has no look, so `picture` draws its
/// image. Drawn at the Carousel's centre size; neighbours scale it down.
struct ThemePreview: View {
    /// Which apps were found on this Mac, by the name they show; nil draws a generic window in that place.
    struct Apps: Hashable {
        var editor: String?
        var terminal: String?
        var notes: String?
    }

    let look: CarouselValues.ThemeLook
    let wallpaper: NSImage?
    var apps: Apps?
    var title: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let wallpaper {
                Image(nsImage: wallpaper).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: CarouselFace.centre.width, height: CarouselFace.centre.height).clipped()
            } else {
                LinearGradient(colors: [look.ground, look.raised], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            VStack(spacing: 0) {
                bar
                HStack(alignment: .top, spacing: 7) {
                    editor.frame(width: 206)
                    VStack(spacing: 7) {
                        terminal
                        notes
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 18)
            }
        }
        .frame(width: CarouselFace.centre.width, height: CarouselFace.centre.height)
    }

    private var bar: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(look.accent).frame(width: 6, height: 6)
            ForEach(1...4, id: \.self) { i in
                Text("\(i)").font(.system(size: 6, weight: .semibold, design: .monospaced)).foregroundStyle(i == 1 ? look.accent : look.muted)
            }
            Spacer()
            Text("14:30").font(.system(size: 6, weight: .semibold, design: .monospaced)).foregroundStyle(look.text)
        }
        .padding(.horizontal, 8).frame(height: 13)
        .background(look.window.opacity(0.92))
    }

    private func window<Content: View>(_ name: String?, generic: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(look.line).frame(width: 4, height: 4) }
                Text(name ?? generic).font(.system(size: 5.5, weight: .medium)).foregroundStyle(look.muted).padding(.leading, 3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(height: 11)
            content().padding(.horizontal, 7).padding(.bottom, 6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(look.window.opacity(0.94), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(look.line, lineWidth: 0.5) }
    }

    /// Code in the theme's syntax colours.
    private var editor: some View {
        window(apps?.editor, generic: "Editor") {
            VStack(alignment: .leading, spacing: 3.5) {
                ForEach(Array(Self.code.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 2.5) {
                        Color.clear.frame(width: CGFloat(line.indent) * 7, height: 1)
                        ForEach(Array(line.parts.enumerated()), id: \.offset) { _, part in
                            Capsule(style: .circular).fill(colour(part.1)).frame(width: part.0, height: 3)
                        }
                    }
                }
            }
            .padding(.top, 3)
        }
        .frame(height: 199)
    }

    /// An info screen like Pilot's About page: the mark beside key and value lines, in mono.
    private var terminal: some View {
        window(apps?.terminal, generic: "Terminal") {
            HStack(alignment: .top, spacing: 8) {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow { RoundedRectangle(cornerRadius: 2).fill(look.accent); RoundedRectangle(cornerRadius: 2).strokeBorder(look.text, lineWidth: 1) }
                    GridRow { RoundedRectangle(cornerRadius: 2).strokeBorder(look.text, lineWidth: 1); RoundedRectangle(cornerRadius: 2).strokeBorder(look.text, lineWidth: 1) }
                }
                .frame(width: 22, height: 22)
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1.5) {
                    line("pilot", "1.3", key: look.accent)
                    line("theme", title)
                    line("hyper", "caps lock")
                    line("tiling", "on")
                    HStack(spacing: 2) {
                        ForEach([look.accent, look.second, look.third, look.text, look.muted], id: \.self) {
                            RoundedRectangle(cornerRadius: 1).fill($0).frame(width: 9, height: 4)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.top, 2)
        }
        .frame(height: 96)
    }

    private func line(_ key: String, _ value: String, key colour: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Text(key).foregroundStyle(colour ?? look.second)
            Text(value).foregroundStyle(look.text)
        }
        .font(.system(size: 6.5, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }

    private var notes: some View {
        window(apps?.notes, generic: "Notes") {
            VStack(alignment: .leading, spacing: 3.5) {
                Capsule(style: .circular).fill(look.text).frame(width: 60, height: 4)
                ForEach([118, 96, 124, 70], id: \.self) { Capsule(style: .circular).fill(look.muted.opacity(0.7)).frame(width: CGFloat($0), height: 2.5) }
                HStack(spacing: 3) {
                    Capsule(style: .circular).fill(look.accent).frame(width: 26, height: 2.5)
                    Capsule(style: .circular).fill(look.muted.opacity(0.7)).frame(width: 64, height: 2.5)
                }
            }
            .padding(.top, 3)
        }
        .frame(height: 96)
    }

    enum Run { case keyword, name, text, string, comment }

    private func colour(_ ink: Run) -> Color {
        switch ink {
        case .keyword: look.accent
        case .name: look.second
        case .text: look.text.opacity(0.85)
        case .string: look.third
        case .comment: look.muted.opacity(0.7)
        }
    }

    /// Fixed sample code as runs of (width, ink), never the user's files.
    static let code: [(indent: Int, parts: [(CGFloat, Run)])] = [
        (0, [(40, .comment), (70, .comment)]),
        (0, [(22, .keyword), (34, .name), (10, .text)]),
        (1, [(16, .keyword), (28, .name), (8, .text), (40, .string)]),
        (1, [(16, .keyword), (22, .name), (8, .text), (30, .name)]),
        (1, []),
        (1, [(20, .keyword), (30, .name), (12, .text)]),
        (2, [(26, .name), (14, .text), (48, .string)]),
        (2, [(16, .keyword), (24, .name), (32, .text)]),
        (1, [(6, .text)]),
        (1, []),
        (1, [(20, .keyword), (26, .name), (12, .text)]),
        (2, [(18, .keyword), (40, .text), (22, .name)]),
        (2, [(30, .name), (12, .text), (36, .string)]),
        (1, [(6, .text)]),
        (0, [(6, .text)]),
        (0, []),
        (0, [(52, .comment), (40, .comment)]),
        (0, [(22, .keyword), (40, .name), (10, .text)]),
        (1, [(30, .name), (60, .text)]),
        (0, [(6, .text)]),
    ]
}
