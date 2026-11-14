#if DEBUG
import AppKit
import CoreImage
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Pilot's dock in the rice look (Sven 2026-11-13, Q220 A, Q221, Q222): attached to the screen's foot, the icons in the
/// theme's colours, accent dots, and the visualizer's bars from the window's own path (DockBarsPath) over each theme's
/// wallpaper, playing (DockSyntheticMusic through DockSpectrum, 30 ms after a kick) and silent (the flat line). Tokyo
/// Night (dark) on a laptop and on the ultrawide with the default widgets, Folio (light) on a laptop; and floating for
/// the placement's other choice. No tap is made: the spectrum is synthetic. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/h PILOT_RENDER_DIR=/tmp/r PILOT_DOCK_WALL=<dark png> PILOT_DOCK_WALL_LIGHT=<light png> swift test --filter DockRiceRenders`
@MainActor
@Suite("Dock rice renders")
struct DockRiceRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let names = ["Finder", "Safari", "Music", "Messages", "Mail", "Calendar", "Notes", "Terminal", "Photos", "System Settings"]

    static func apps() -> [DockApp] {
        names.enumerated().map { i, name in DockRenders.app(name, windows: [0, 1, 2, 3, 7].contains(i) ? 1 : 0, front: name == "Music") }
    }

    @Test("Attached, theme-coloured, with the visualizer playing and silent, light and dark", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try ClockRenders.dir("dock-rice")
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let was = (look.style, look.themeID, look.glass, look.transparency)
        defer { (look.style, look.themeID, look.glass, look.transparency) = was }
        (look.style, look.transparency) = (.instrument, 33)
        let frame = DockSyntheticMusic.frame(at: 3.90)
        let cases: [(String, String, String?, CGSize, Bool, DockPlacement)] = [
            ("tokyo-night", "laptop", Self.env["PILOT_DOCK_WALL"], DockRenders.laptop, false, .attached),
            ("tokyo-night", "ultrawide", Self.env["PILOT_DOCK_WALL"], DockRenders.ultrawide, true, .attached),
            ("folio", "laptop", Self.env["PILOT_DOCK_WALL_LIGHT"], DockRenders.laptop, false, .attached),
            ("tokyo-night", "laptop-floating", Self.env["PILOT_DOCK_WALL"], DockRenders.laptop, false, .floating),
        ]
        for (theme, name, wall, screen, widgets, placement) in cases {
            look.themeID = theme
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            let glassTint = Color(nsColor: TopBarColour.tint(.theme, style: tokens, look: look))
            for playing in [true, false] where playing || placement == .attached {
                let scene = Scene(wall: wall.flatMap(NSImage.init(contentsOfFile:)), screen: screen, size: CGSize(width: screen.width, height: 330),
                                  glassTint: glassTint, accent: Color(nsColor: Self.colour(look.theme.accent)), apps: Self.apps(), widgets: widgets,
                                  placement: placement, left: playing ? frame.left.heights : nil, right: playing ? frame.right.heights : nil)
                try writeRender(scene.body.styled(.topBar, look: look).pilotTheme(look: look),
                                to: dir.appendingPathComponent("rice-\(theme)-\(name)-\(playing ? "playing" : "silent").png"), wait: 1.5)
            }
        }

        // Attached round 2 (Sven on build 2479, 2026-11-14): the flared edge in each style, and the widgets at each size
        // in one ratio to the icons, on his ultrawide with the default widgets and sixteen apps.
        look.themeID = "tokyo-night"
        let tokens = StyleTokens.of(look.style, theme: look.theme)
        let glassTint = Color(nsColor: TopBarColour.tint(.theme, style: tokens, look: look))
        let crowd = DockRenders.apps(16)
        for (name, style, dockSize) in [("glass-medium", TopBarBackground.glass, DockSize.medium), ("solid-medium", .solid, .medium), ("clear-medium", .clear, .medium),
                                        ("glass-small", .glass, .small), ("glass-large", .glass, .large)] {
            let scene = Scene(wall: Self.env["PILOT_DOCK_WALL"].flatMap(NSImage.init(contentsOfFile:)), screen: DockRenders.ultrawide,
                              size: CGSize(width: DockRenders.ultrawide.width, height: 260), glassTint: glassTint,
                              accent: Color(nsColor: Self.colour(look.theme.accent)), apps: crowd, widgets: true, placement: .attached,
                              left: frame.left.heights, right: frame.right.heights, style: style, dockSize: dockSize)
            try writeRender(scene.body.styled(.topBar, look: look).pilotTheme(look: look), to: dir.appendingPathComponent("edge-\(name).png"), wait: 1.5)
        }
    }

    static func colour(_ hex: UInt32) -> NSColor {
        let c = DockTinter.rgb(hex)
        return NSColor(srgbRed: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: 1)
    }

    /// The foot of a screen: the wallpaper, the bars, and the pill over them on a glass stand-in that blurs both, as
    /// Liquid Glass would.
    struct Scene {
        let wall: NSImage?
        let screen: CGSize
        let size: CGSize
        let glassTint: Color
        let accent: Color
        let apps: [DockApp]
        let widgets: Bool
        let placement: DockPlacement
        let left: [Float]?, right: [Float]?
        var style: TopBarBackground = .glass
        var dockSize: DockSize = .medium

        var tallest: CGFloat { CGFloat(dockSize.tallestBar) }

        /// The rest pill's width, measured from a strip drawn alone.
        @MainActor var pillWidth: CGFloat {
            (try? rendered(strip, wait: 0.6)).map { CGFloat($0.pixelsWide) / 2 } ?? 600
        }

        @MainActor var strip: some View {
            DockStrip(size: dockSize, apps: apps, hasWidgets: widgets, maxWidth: size.width - 2 * DockPill.sideMargin, style: style,
                      backing: { AnyView($0) }, placement: placement, tint: .theme) {
                if widgets {
                    ForEach(Array(DockRenders.widgets.enumerated()), id: \.offset) { _, pair in DockWidgetBodyView(widget: pair.0, shown: pair.1) }
                }
            }
            .environment(\.inTopBar, true).environment(\.barItemColours, true)
        }

        @MainActor func backdrop(bars pill: CGFloat) -> some View {
            let path = DockBarsPath.path(width: size.width, pill: pill, tallest: tallest, left: left, right: right)
            return ZStack(alignment: .bottom) {
                Group {
                    if let wall {
                        Image(nsImage: wall).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        Color(red: 0.1, green: 0.1, blue: 0.16)
                    }
                }
                .frame(width: screen.width, height: screen.height)
                .frame(width: size.width, height: size.height, alignment: .bottom).clipped()
                // The window's own path, y 0 at the foot, flipped into SwiftUI's space.
                Path(path).applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: tallest)).fill(accent)
                    .frame(width: size.width, height: tallest)
            }
            .frame(width: size.width, height: size.height)
        }

        /// Core Image's blur on a drawn copy: a SwiftUI blur is a layer filter the offscreen capture leaves out.
        @MainActor func blurred(_ view: some View) -> NSImage {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let cg = renderer.cgImage else { return NSImage() }
            let source = CIImage(cgImage: cg)
            let blur = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 44]).cropped(to: source.extent)
            guard let out = CIContext().createCGImage(blur, from: source.extent) else { return NSImage() }
            return NSImage(cgImage: out, size: size)
        }

        @MainActor var body: some View {
            let pill = pillWidth
            let ground = backdrop(bars: pill)
            let margin = CGFloat(DockSize.margin(placement))
            let shape = DockPill.shape(placement)
            return ZStack(alignment: .bottom) {
                ground
                // Glass's stand-in only on Glass: Solid and Clear draw their own ground (DockBacking).
                if style == .glass {
                    Image(nsImage: blurred(ground)).resizable().frame(width: size.width, height: size.height).overlay(glassTint)
                        .mask(shape.frame(width: pill, height: CGFloat(dockSize.pill)).padding(.bottom, margin)
                            .frame(width: size.width, height: size.height, alignment: .bottom))
                }
                strip.padding(.bottom, margin)
            }
            .frame(width: size.width, height: size.height)
        }
    }
}
}
#endif
