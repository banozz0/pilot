import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// The AI chat follows Look's Glass as the window and the other panels do (Sven on build 23: it stayed solid): glass
/// behind its notch in Instrument, none while Glass is off, under Reduce transparency or in Toybox, whose
/// window stays solid too; over the glass the notch draws no ground of its own.
@MainActor
@Suite("AI chat glass")
struct AIChatGlassTests {
    static func backdrop(_ look: Look) -> MaterialBackdrop {
        AIChatPanel.backdrop(NSView(frame: CGRect(origin: .zero, size: AIChatPanel.size)), look: look)
    }

    @Test("Glass behind the chat while Glass is on, in Instrument, clipped square at the top and round at the bottom")
    func backdrop() throws {
        testApp()
        let look = PanelLookTests.look()
        #expect(Self.backdrop(look).effect == nil, "Glass off: solid")
        look.glass = true
        look.style = .instrument
        let effect = try #require(Self.backdrop(look).effect as? NSGlassEffectView)
        #expect(effect.cornerRadius == AIChatPanel.radius(look))
        #expect(effect.frame == CGRect(x: 0, y: 0, width: AIChatPanel.size.width, height: AIChatPanel.size.height + effect.cornerRadius),
                "its top corners above the window: square at the top, round at the bottom")
        #expect(AIChatPanel.radius(look) == CGFloat(look.chromeTokens(.quickAI).radii.pop), "Instrument's pop corner")
        look.style = .toybox
        #expect(Self.backdrop(look).effect == nil, "Toybox stays solid")
        look.style = .instrument
        look.setAccessibility(reduceTransparency: true, increaseContrast: false)
        #expect(Self.backdrop(look).effect == nil, "Reduce transparency: solid")
    }

    @Test("Over the glass the notch's ground is clear, so the desktop shows; solid it draws its own")
    func ground() throws {
        testApp()
        let look = PanelLookTests.look()
        look.style = .instrument
        func sample() throws -> NSColor {
            let view = AIChatPanel.content(AIChatModel(), look: look).background(Color(red: 1, green: 0, blue: 1))
            let shot = try #require(snapshot(drawing: view, scale: 1))
            // An empty stretch of the conversation, under the hint and above the input.
            return try #require(shot.colorAt(x: shot.pixelsWide / 2, y: shot.pixelsHigh * 3 / 5))
        }
        let magenta = { (c: NSColor) in c.redComponent > 0.9 && c.greenComponent < 0.1 && c.blueComponent > 0.9 }
        #expect(!magenta(try sample()), "solid: its own ground")
        look.glass = true
        #expect(magenta(try sample()), "glass: what is behind shows through")
    }
}
}
