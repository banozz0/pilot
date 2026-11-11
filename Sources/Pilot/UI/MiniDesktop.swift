import PilotCore
import SwiftUI

/// A screen in small, for the previews that follow a page's controls (simplify-pages T25; the prototype's mini desktop):
/// the style's desk, then the windows tiled as the tiler would (main + stack unless `layout` says otherwise), the gaps
/// at their share of a 1440 pt screen, the focused window's border, and the other windows blurred and dimmed as Defocus
/// does them, over the style's desk or a wallpaper. A page draws its own part over it with `.overlay`.
struct MiniDesktop: View {
    @Environment(\.ink) private var ink

    /// The windows' titles, the first the main one.
    var windows: [String] = ["", "", ""]
    var layout: LayoutPreset = .mainStack
    /// The gaps in points on the real screen: between windows, and at the screen's edges.
    var inner: Double = 0
    var outer: Double = 0
    /// The window in front, which takes the border and is never dimmed.
    var focused: Int? = 0
    /// The focused window's border width in points on the real screen (`look.windowBorderWidth`), in `borderColour`;
    /// nil for none.
    var border: Int? = nil
    /// The border's colour (`look.windowBorderColour`); nil is the theme's accent.
    var borderColour: Color? = nil
    /// Defocus on the other windows as Pilot draws it (`Defocus.look`), its blur at the screen's scale; nil for off.
    var defocus: Defocus.Look? = nil
    /// The desk's picture, filling it (Look's preview, simplify-pages T28); nil is the style's desk.
    var wallpaper: Image? = nil

    /// The width a 1440 pt screen's gaps are drawn against: twice their share, so 10 pt still reads at 220 pt wide.
    private static let screen: CGFloat = 720

    private struct Shown: Equatable { let inner, outer: Double, border: Int?, borderColour: Color?, defocus: Defocus.Look?, focused: Int? }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(8), style: .continuous)
        let window = RoundedRectangle(cornerRadius: ink.radius(5), style: .continuous)
        GeometryReader { g in
            let scale = g.size.width / Self.screen
            ZStack(alignment: .topLeading) {
                let frames = Self.frames(windows.count, layout: layout, in: g.size, inner: inner * scale, outer: outer * scale)
                ForEach(frames.indices, id: \.self) { i in
                    let front = i == focused
                    MiniWindow(title: windows[i], size: frames[i].size)
                        .overlay { if front, let border { window.strokeBorder(borderColour ?? ink.accent, lineWidth: max(1, CGFloat(border) * scale)) } }
                        .overlay { if !front, let defocus, defocus.dim > 0 { Color.black.opacity(defocus.dim) } }
                        .clipShape(window)
                        .blur(radius: front ? 0 : CGFloat(defocus?.blurRadius ?? 0) * scale)
                        .offset(x: frames[i].minX, y: frames[i].minY)
                }
            }
        }
        .background { if let wallpaper { wallpaper.resizable().aspectRatio(contentMode: .fill) } else { ink.well } }
        .clipShape(shape)
        .overlay { shape.strokeBorder(ink.line2, lineWidth: 1) }
        .animation(Kit.press, value: Shown(inner: inner, outer: outer, border: border, borderColour: borderColour, defocus: defocus, focused: focused))
        .accessibilityHidden(true)
    }

    /// The tiler's tiles for `count` windows (WorkspacePreview's half-gap trick): laid out half a gap past the outer
    /// inset, then each tile inset by half a gap, so they stand `inner` apart and `outer` in from the edges.
    private static func frames(_ count: Int, layout: LayoutPreset, in size: CGSize, inner: Double, outer: Double) -> [CGRect] {
        let half = inner / 2
        let area = CGRect(origin: .zero, size: size).insetBy(dx: outer - half, dy: outer - half)
        return layout.tiles(count, in: area).map { $0.insetBy(dx: half, dy: half) }
    }
}

/// One window in small: a title bar with its three lights and title, then three lines standing for its text; a window
/// too short for them is its surface alone.
private struct MiniWindow: View {
    @Environment(\.ink) private var ink
    let title: String
    let size: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if size.height >= 40 {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(ink.line3).frame(width: 4, height: 4) }
                    if !title.isEmpty { Text(title).font(ink.ui(8.5, .medium)).foregroundStyle(ink.text2).lineLimit(1).padding(.leading, 3) }
                }
                .padding(.horizontal, 6).frame(height: 14).frame(maxWidth: .infinity, alignment: .leading)
                .background(ink.surface)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach([0.62, 0.84, 0.46], id: \.self) { share in
                        Capsule().fill(ink.line2).frame(width: (size.width - 16) * share, height: 3)
                    }
                }
                .padding(.horizontal, 8).padding(.top, 7)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(ink.selected)
    }
}
