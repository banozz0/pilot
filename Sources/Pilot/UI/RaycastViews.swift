import AppKit
import PilotCore
import SwiftUI

// Raycast's views as Raycast lays them out (raycast-extensions T31), in Pilot's theme colours and fonts: a row's
// accessories, a section's heading, a Detail's metadata column, a List.Item.Detail's metadata rows, the list and its
// detail side by side, a markdown image, and the foot's place. Ideas from Raycast's store screenshots and API docs,
// never its code (ADR 0010 stands: the extension speaks, Pilot draws). Hyper+Space (MenuBody, LineFoot) and an
// extension's live page (ExtensionLivePage) draw them alike.

/// A Raycast colour in the theme (Extension.tint): the accent, the theme's green, amber or red, or the text's own.
@MainActor func raycastInk(_ colour: String?, _ style: StyleTokens, else plain: KeyPath<StyleColors, Paint> = \.text) -> Color {
    raycastInk(Extension.tint(colour), style, else: plain)
}

/// A theme role as a Raycast colour draws in it; `plain` when there is none.
@MainActor func raycastInk(_ tint: MenuIcon.Tint?, _ style: StyleTokens, else plain: KeyPath<StyleColors, Paint> = \.text) -> Color {
    switch tint {
    case .accent?: style.color(\.accentText)
    // The theme's own green, amber and red: Instrument folds them into the accent, but a Raycast colour says something
    // (Todo List's priorities), so it keeps its hue in the theme's palette.
    case .good?: Theme.green
    case .amber?: Theme.yellow
    case .problem?: Theme.red
    case .second?, .third?: style.color(\.text2)
    case .neutral?: style.color(\.text)
    case nil: style.color(plain)
    }
}

/// The share of the width Raycast gives a list beside its detail (speedtest-2, -3: about 37%), and a Detail's metadata
/// column (speedtest-1: about 35%).
enum RaycastLayout {
    static let listShare: CGFloat = 0.37, metadataShare: CGFloat = 0.35
}

/// A Raycast icon (an accessory's, a label's, a tag's): its SF Symbol in its tint, its picture, its emoji or a file's
/// own icon, `side` points square.
struct RaycastPicture: View {
    @Environment(\.style) private var style
    let picture: Extension.Picture
    var side: CGFloat = 14
    /// The ink a symbol with no tint of its own takes.
    var plain: KeyPath<StyleColors, Paint> = \.text2

    var body: some View {
        if let symbol = picture.symbol, picture.image == nil {
            Image(systemName: symbol).resizable().scaledToFit().frame(width: side, height: side)
                .foregroundStyle(raycastInk(picture.tint, style, else: plain))
        } else if let image = icon.appImage() {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: side, height: side)
        }
    }

    private var icon: MenuIcon {
        var icon = MenuIcon(appPath: picture.file, symbol: "", tint: .neutral, emoji: picture.emoji)
        icon.image = picture.image
        return icon
    }
}

/// A row's accessories at its right, in Raycast's order: each its icon then its text in the secondary colour (a colour
/// of its own when it has one), a tag as a pill tinted with its colour, its tooltip on hover.
struct RaycastAccessories: View {
    @Environment(\.style) private var style
    let accessories: [Extension.Item.Accessory]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(accessories.enumerated()), id: \.offset) { _, one in
                Group {
                    if one.tag {
                        RaycastTag(text: one.text, colour: one.color, picture: one.picture)
                    } else {
                        HStack(spacing: 5) {
                            if !one.picture.isEmpty { RaycastPicture(picture: one.picture) }
                            if let text = one.text {
                                Text(text).styleText(\.caption).foregroundStyle(raycastInk(one.color, style, else: \.text2)).truncationMode(.middle)
                            }
                        }
                    }
                }
                .tooltip(one.tooltip)
            }
        }
        // They give way to the row's title (its layout priority), each text cut in its middle.
        .lineLimit(1)
    }
}

private extension View {
    /// Its tooltip, when it has one: no tooltip modifier on an accessory that has none.
    @ViewBuilder func tooltip(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

/// A Raycast tag: its icon and text in its colour on a soft fill of that colour (a TagList's tag, a tag accessory).
struct RaycastTag: View {
    @Environment(\.style) private var style
    let text: String?
    let colour: String?
    var picture = Extension.Picture()

    var body: some View {
        let ink = raycastInk(colour, style, else: \.text2)
        HStack(spacing: 4) {
            if !picture.isEmpty { RaycastPicture(picture: picture, side: 12, plain: \.text2).foregroundStyle(ink) }
            if let text { Text(text).styleText(\.caption).foregroundStyle(ink) }
        }
        .lineLimit(1)
        .padding(.horizontal, 7).frame(height: 22)
        .background(ink.opacity(0.14), in: .rect(cornerRadius: 6, style: .continuous))
    }
}

/// A Raycast section's heading: its title in the secondary colour, its subtitle quieter beside it ("Processes  9 running").
struct RaycastSectionHeader: View {
    @Environment(\.style) private var style
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).styleText(\.caption).fontWeight(.medium).foregroundStyle(style.color(\.text2))
            if let subtitle { Text(subtitle).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
        }
        .lineLimit(1).truncationMode(.tail)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

/// A Detail's metadata column as Raycast draws it at the detail's right (speedtest-1): each title in the secondary
/// colour, as written, over its value; a tag list's tags as pills in a row that wraps; a link in the accent; a
/// separator a hairline.
struct RaycastMetadataColumn: View {
    @Environment(\.style) private var style
    let parts: [Extension.Detail.Part]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if part.kind == .separator {
                        InstrumentRule()
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            if !part.title.isEmpty { Text(part.title).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
                            RaycastPartValue(part: part, wraps: true)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(EdgeInsets(top: 18, leading: 18, bottom: 16, trailing: 18))
        }
    }
}

/// A List.Item.Detail's metadata as Raycast draws it under the detail's markdown (speedtest-2, -3): a row per part, its
/// title left in the secondary colour and its value right, a separator a hairline.
struct RaycastMetadataRows: View {
    @Environment(\.style) private var style
    let parts: [Extension.Detail.Part]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if part.kind == .separator {
                    InstrumentRule().padding(.vertical, 4)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(part.title).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1)
                        Spacer(minLength: 8)
                        RaycastPartValue(part: part, wraps: false)
                    }
                    .frame(minHeight: 28)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// A metadata part's value: a label's icon and text, a link's text in the accent (opened by a click), a tag list's tags.
private struct RaycastPartValue: View {
    @Environment(\.style) private var style
    let part: Extension.Detail.Part
    /// Tags wrap onto more rows (the column) or stay on one (a row, right-aligned).
    let wraps: Bool

    var body: some View {
        switch part.kind {
        case .tags:
            if wraps {
                RaycastWrap(spacing: 6) { tags }
            } else {
                HStack(spacing: 6) { tags }.lineLimit(1)
            }
        case .link:
            Button {
                if let target = part.target, let url = ExtensionList.url(target) { NSWorkspace.shared.open(url) }
            } label: {
                Text(part.text ?? "").styleText(\.body).foregroundStyle(style.color(\.accentText)).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain).focusable(false)
        default:
            HStack(spacing: 6) {
                if !part.picture.isEmpty { RaycastPicture(picture: part.picture, side: 15) }
                if let text = part.text { Text(text).styleText(\.body).foregroundStyle(raycastInk(part.color, style)) }
            }
        }
    }

    private var tags: some View {
        ForEach(Array(part.tags.enumerated()), id: \.offset) { _, tag in RaycastTag(text: tag.text, colour: tag.color, picture: tag.picture) }
    }
}

/// Views in rows that wrap at the width given: a tag list's tags.
private struct RaycastWrap: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, frame) in arrange(bounds.width, subviews).enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            line = max(line, size.height)
        }
        return frames
    }
}

/// A Raycast List that shows details (isShowingDetail): the list at Raycast's share of the width, a hairline, the
/// selected row's detail beside it; Hyper+Space and the live page alike.
struct RaycastListWithDetail<Rows: View>: View {
    let detail: Extension.Detail?
    @ViewBuilder let rows: Rows

    var body: some View {
        GeometryReader { size in
            HStack(spacing: 0) {
                rows.frame(width: (size.size.width * RaycastLayout.listShare).rounded())
                InstrumentRule(vertical: true)
                RaycastSideDetail(detail: detail).equatable()
            }
        }
    }
}

/// The selected row's detail beside a Raycast list that shows details (List isShowingDetail, speedtest-2 and -3): its
/// markdown on top, its metadata as rows at the foot; nothing when the row has none.
struct RaycastSideDetail: View, Equatable {
    let detail: Extension.Detail?

    /// The same detail draws the same, so a menu redraw (an arrow key, a pointer move) never splits its markdown again.
    nonisolated static func == (a: Self, b: Self) -> Bool { a.detail == b.detail }

    var body: some View {
        if let detail {
            let blocks = DetailBlock.split(detail.markdown)
            let parts = detail.laidOut
            VStack(spacing: 0) {
                if !blocks.isEmpty {
                    ExtensionDetailWords(blocks: blocks)
                } else {
                    Spacer(minLength: 0)
                }
                if !parts.isEmpty {
                    if !blocks.isEmpty { InstrumentRule() }
                    ScrollView { RaycastMetadataRows(parts: parts).padding(.horizontal, 18).padding(.vertical, 10) }
                        .frame(maxHeight: blocks.isEmpty ? .infinity : 220)
                        .fixedSize(horizontal: false, vertical: !blocks.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            Color.clear
        }
    }
}

/// A markdown image (`![alt](source)`, DetailBlock.image) as Raycast draws it: a `data:` picture (PNG, JPEG or SVG,
/// base64 or percent-encoded) or a file at an absolute path, at its `raycast-width` and no wider than the words. Its
/// first frame is read where it shows (0.4 ms for Speedtest's dashboard); every later one is read and drawn into a bitmap
/// off the main thread, the one before kept on screen until it is ready (Speedtest sends a new dashboard many times a
/// second, and an SVG drawn as it is costs 3.7 ms a frame). A picture on the network is not fetched: its alt text shows,
/// quiet.
struct MarkdownImage: View {
    @Environment(\.style) private var style
    let alt: String
    let source: String

    @State private var image: NSImage?

    var body: some View {
        let (_, width, height) = MarkdownImage.parse(source)
        let shown = image ?? Self.first(source)
        Group {
            if let shown {
                Image(nsImage: shown).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(maxWidth: width ?? shown.size.width, maxHeight: height)
                    .accessibilityLabel(alt)
            } else {
                Text(alt).styleText(\.caption).foregroundStyle(style.color(\.text3))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .task(id: source) {
            let source = source
            if let made = await Task.detached(priority: .userInitiated, operation: { MarkdownImage.load(source, raster: true) }).value { image = made }
        }
    }

    /// The first frame, read here once per source (the last few kept), so the view never opens blank.
    @MainActor private static func first(_ source: String) -> NSImage? {
        if let kept = firsts[source] { return kept }
        guard let made = load(source, raster: false) else { return nil }
        if firsts.count >= 4 { firsts.removeAll() }
        firsts[source] = made
        return made
    }

    @MainActor private static var firsts: [String: NSImage] = [:]

    /// The picture's bytes source with Raycast's sizing query taken off, and its `raycast-width` and `raycast-height`.
    nonisolated static func parse(_ source: String) -> (source: String, width: CGFloat?, height: CGFloat?) {
        guard let mark = source.range(of: "?raycast-", options: .backwards) else { return (source, nil, nil) }
        var width: CGFloat?, height: CGFloat?
        for pair in source[source.index(after: mark.lowerBound)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, let value = Double(kv[1]) else { continue }
            if kv[0] == "raycast-width" { width = value } else if kv[0] == "raycast-height" { height = value }
        }
        return (String(source[..<mark.lowerBound]), width, height)
    }

    /// The picture `source` names; nil for one on the network or one that does not read. `raster`: drawn into a bitmap at
    /// twice its size, so the main thread only shows pixels.
    nonisolated static func load(_ source: String, raster: Bool) -> NSImage? {
        let bare = parse(source).source
        let data: Data?
        if bare.hasPrefix("data:"), let comma = bare.firstIndex(of: ",") {
            let head = bare[..<comma], body = String(bare[bare.index(after: comma)...])
            data = head.hasSuffix(";base64") ? Data(base64Encoded: body) : body.removingPercentEncoding.map { Data($0.utf8) }
        } else if bare.hasPrefix("file://"), let url = URL(string: bare) {
            data = try? Data(contentsOf: url)
        } else if bare.hasPrefix("/") {
            data = try? Data(contentsOf: URL(filePath: bare))
        } else {
            data = nil
        }
        guard let data, data.count <= 8 * 1024 * 1024, let image = NSImage(data: data), image.size.width > 0 else { return nil }
        guard raster else { return image }
        let size = image.size
        guard size.width * size.height <= 4_000_000,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = size
        let drawn = NSImage(size: size)
        drawn.addRepresentation(bitmap)
        return drawn
    }
}

/// The foot's left in a Raycast view, as Raycast's: the command's icon and the view's navigation title, else the
/// command's title.
struct RaycastFootPlace: View {
    @Environment(\.style) private var style
    let chrome: Extension.Chrome?
    let title: String?

    var body: some View {
        HStack(spacing: 8) {
            if let icon = chrome?.icon {
                InstrumentRowIcon(row: MenuEntry(title: "", target: .action(""), icon: icon), on: false, tile: nil, side: 16)
            }
            if let title = chrome?.title ?? title { Text(title).foregroundStyle(style.color(\.text2)) }
        }
    }
}

/// A Raycast List.EmptyView as Raycast draws it (speedtest-4): its icon large in the middle, its title under it, its
/// description quieter; Return and Cmd+K still press its actions (the row kept behind it, T28).
struct RaycastEmptyView: View {
    @Environment(\.style) private var style
    let view: Extension.Empty

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let icon = view.icon {
                    Text(icon).font(.system(size: 40))
                } else {
                    Image(systemName: view.symbol ?? "list.bullet").font(.system(size: 40, weight: .light)).foregroundStyle(style.color(\.text3))
                }
            }
            .padding(.bottom, 10).accessibilityHidden(true)
            if !view.title.isEmpty { Text(view.title).styleText(\.body).foregroundStyle(style.color(\.text2)) }
            if let line = view.description { Text(line).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
        }
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
