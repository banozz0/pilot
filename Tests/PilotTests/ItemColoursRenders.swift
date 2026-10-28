#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Item colours (Sven, Q251): CPU at 100 % red, memory at 75 % amber, the disk calm, the battery at 8 % red, Pilot's
/// clock in the theme's colour, Claude's glyph orange and a coloured app's item in its own colour beside a grey one; each
/// row switch on, then off, on Solid, Glass (a stand-in wallpaper under the glass's tint; Liquid Glass draws nothing
/// offscreen) and Clear, in Instrument and Toybox. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-colours PILOT_RENDER_DIR=/tmp/pilot-renders-colours swift test --filter ItemColoursRenders`
@MainActor
@Suite("Item colours renders")
struct ItemColoursRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let parts: [[BarPart]] = [
        [.reading(.cpu), .value("100%", widest: "100%"), .warn, .level(.critical)],
        [.reading(.ram), .value("75%", widest: "100%"), .level(.high)],
        [.reading(.disk), .value("40%", widest: "100%")],
        [.symbol("battery.25"), .value("8%", widest: "100%"), .warn, .level(.critical)],
        [.extensionItem(ExtensionBarFace(id: "ai-usage", title: "AI usage", answer: Extension.BarAnswer(
            text: "", gauges: [Extension.Gauge(meters: [66, 30], icon: .claude, text: "66%")])))],
        [.time("13:11")],
    ]

    /// A coloured app's item (an orange tile) and a grey one, as MenuItemPictures keeps them.
    static func pictures() -> [MenuItemPictures.Picture] {
        let size = NSSize(width: 16, height: 16)
        let coloured = NSImage(size: size, flipped: false) { rect in
            NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
            return true
        }
        let grey = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        grey.isTemplate = true
        return [.init(image: coloured), .init(image: grey)]
    }

    @Test("Readings by level, Claude orange and a coloured app's item kept, switch on and off, on Solid, Glass and Clear, in each style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try ClockRenders.dir("item-colours")
        testApp()
        let theme = try #require(PilotTheme.named("void"))
        let pictures = Self.pictures()
        for kind in [PilotStyle.instrument, .toybox] {
            let style = StyleTokens.of(kind, theme: theme)
            let rows = VStack(alignment: .leading, spacing: 10) {
                ForEach(TopBarBackground.allCases, id: \.self) { background in
                    ForEach([true, false], id: \.self) { on in
                        HStack(spacing: 16) {
                            BarPartsView(items: Self.parts)
                            ForEach(pictures.indices, id: \.self) { MenuItemPictureView(picture: pictures[$0]) }
                            Spacer(minLength: 0)
                            Text("\(background.title) · \(on ? "on" : "off")").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.horizontal, 12).frame(height: 30)
                        .environment(\.inTopBar, true).environment(\.barItemColours, on)
                        .background { Self.ground(background, style: style) }
                    }
                }
            }
            .padding(12).frame(width: 760, alignment: .leading)
            .background(LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.2), Color(red: 0.3, green: 0.2, blue: 0.3)],
                                       startPoint: .leading, endPoint: .trailing))
            .style(style)
            _ = try ClockRenders.write(rows, size: NSSize(width: 760, height: 260), settle: 0.6, to: dir.appendingPathComponent("item-colours-\(kind.rawValue).png"))
        }
    }

    /// What each background puts under the items here: the theme's bar colour, the glass's tint over the wallpaper, or
    /// Clear's all but nothing.
    @ViewBuilder static func ground(_ background: TopBarBackground, style: StyleTokens) -> some View {
        switch background {
        case .solid: TopBarColour.themeGround(style)
        case .glass: Color(nsColor: TopBarColour.tint(.theme, style: style, look: .shared))
        case .clear: TopBarColour.clearGround
        }
    }
}
}
#endif
