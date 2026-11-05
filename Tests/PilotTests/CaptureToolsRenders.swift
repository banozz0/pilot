#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The capture editor's new tools (T26; Sven Q805): C3 snap edges, C4 bend any arrow, C5 magnifier, C6 smooth pen,
/// C7 guides, C10 secure pixelate, each drawn in the real CaptureEditorView over the billing page, in Instrument and
/// Toybox, dark and light. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter CaptureToolsRenders`
extension SharedLook {
@MainActor
@Suite("Capture tools renders")
struct CaptureToolsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Each new capture tool renders in Instrument and Toybox, dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        try CaptureEditorRenders.rendering { look, out in try Self.renderTools(look: look, out: out) }
    }

    /// The tools as Sven would leave them, a drag still under way where the tool shows only while dragging.
    static func states(_ capture: CGImage, screen: CGImage, taken: CGRect, tokens: StyleTokens) -> [(String, EditorModel)] {
        func model(screen kept: Bool = false) -> EditorModel {
            // The notes window and the terminal on the desktop (CaptureEditorRenders.desktop), kept with the grab.
            let windows = [CGRect(x: 30, y: 190, width: 240, height: 330), CGRect(x: 1060, y: 250, width: 200, height: 360)]
            let m = EditorModel(image: capture, scale: 2, accent: tokens.colors.accent.rgb, dark: tokens.dark,
                                screen: kept ? CaptureGrab(image: screen, taken: taken, scale: 2, windows: windows) : nil)
            m.snaps = true
            return m
        }
        let update = CaptureFixture.updateButton, card = CaptureFixture.contactCard

        // C3: Crop's right edge pulled in to 4 points short of the terminal window's side (the contact card's too); it
        // sits on the side, its guide showing.
        let snap = model(screen: true)
        snap.loadEdgesNow()
        let t = snap.taken
        snap.pick(.crop)
        snap.begin(CGPoint(x: t.maxX, y: t.midY)); snap.drag(CGPoint(x: 1064, y: t.midY))

        // C4: an arrow bent by its middle, picked, so its three handles show.
        let bend = model()
        bend.pick(.arrow); bend.setSize(5)
        bend.begin(CGPoint(x: 560, y: 60)); bend.end(CGPoint(x: update.minX - 4, y: update.minY + 6))
        bend.pick(.select)
        if let arrow = bend.document.marks.first {
            bend.begin(arrow.arrowMiddle); bend.drag(CGPoint(x: arrow.arrowMiddle.x + 30, y: arrow.arrowMiddle.y - 50))
            bend.end(CGPoint(x: arrow.arrowMiddle.x + 40, y: arrow.arrowMiddle.y - 60))
        }

        // C5: the magnifier dragged over the email, then its lens moved off into a callout pointing back.
        let lens = model()
        lens.pick(.spotlight); lens.setStyle(1); lens.setSize(5)
        let email = CaptureFixture.email
        lens.begin(CGPoint(x: email.minX + 10, y: email.midY - 30)); lens.end(CGPoint(x: email.minX + 70, y: email.midY + 30))
        lens.pick(.select)
        lens.begin(CGPoint(x: email.minX + 40, y: email.midY)); lens.end(CGPoint(x: email.minX + 40, y: email.midY + 150))
        lens.deselect()

        // C6: the same shaky line drawn Smooth (top) and Freehand (below).
        let pen = model()
        pen.pick(.pen); pen.setSize(4); pen.setColour(4)
        func shaky(_ y: CGFloat) -> [CGPoint] {
            (0...90).map { i in
                let x = 260 + CGFloat(i) * 5, jitter = CGFloat((i * 7919) % 13) / 13 * 5 - 2.5
                return CGPoint(x: x, y: y + sin(CGFloat(i) / 9) * 26 + jitter)
            }
        }
        for (style, y) in [(0, 400.0), (1, 480.0)] {
            pen.setStyle(style)
            let line = shaky(y)
            pen.begin(line[0])
            for p in line.dropFirst() { pen.drag(p) }
            pen.end(line[line.count - 1])
        }
        pen.deselect()

        // C7: a third box moved under the first two, mid-drag, its middle on the capture's middle and its top on the
        // card's bottom: two guides.
        let guides = model()
        guides.pick(.rect); guides.setColour(2)
        guides.begin(CGPoint(x: card.minX, y: card.minY)); guides.end(CGPoint(x: card.maxX, y: card.maxY))
        guides.begin(CGPoint(x: 380, y: 420)); guides.end(CGPoint(x: 520, y: 480))
        guides.pick(.select)
        guides.begin(CGPoint(x: 450, y: 420))
        guides.drag(CGPoint(x: 452 + (CaptureFixture.size.width / 2 - 450), y: 420 - (420 - card.maxY) + 3))

        // C10: Pixelate over the live key and the email: noise that reads nothing of what is under it.
        let secure = model()
        secure.pick(.blur); secure.setStyle(1); secure.setSize(4)
        for r in [CaptureFixture.keyValue, email] { secure.begin(CGPoint(x: r.minX, y: r.minY)); secure.end(CGPoint(x: r.maxX, y: r.maxY)) }
        secure.deselect()

        return [("C3-snap", snap), ("C4-bend", bend), ("C5-magnifier", lens), ("C6-smooth-pen", pen), ("C7-guides", guides), ("C10-secure-pixelate", secure)]
    }

    static func renderTools(look: Look, out: URL) throws {
        let capture = try #require(CaptureFixture.image())
        let (screen, taken) = try #require(CaptureEditorRenders.desktop(around: capture))
        for pass in CaptureEditorRenders.passes {
            look.style = pass.style
            look.themeID = pass.theme
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            for (name, model) in Self.states(capture, screen: screen, taken: taken, tokens: tokens) {
                let size = EditorLayout.window(CaptureFixture.size, fit: 1, tokens: tokens, panel: model.panelOpen)
                let rep = try CaptureEditorRenders.draw(CaptureEditorView(model: model, drag: { NSItemProvider() }), tokens: tokens, size: size, scale: 2)
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("T26-\(name)-\(pass.tag).png"))
            }
        }
    }
}
}
#endif
