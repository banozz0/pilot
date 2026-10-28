import AppKit
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95423032: the drop zone on a fake surface, and the panel it draws in, never ordered front.
@MainActor
@Suite("Drop zone")
struct DropZoneTests {
    final class FakeSurface: DropZoneSurface {
        var shown: (frame: CGRect, below: UInt32?, theme: PilotTheme, edge: Int)?
        func show(frame: CGRect, below: UInt32?, theme: PilotTheme, edge: Int) { shown = (frame, below, theme, edge) }
        func hide() { shown = nil }
    }

    @Test("Shows the landing frame below the dragged window in the theme's colours, edged like the focus border, and goes at the release")
    func follows() {
        let look = WindowBorderControllerTests.look()
        let surface = FakeSurface()
        let zone = DropZone(surface: surface, look: look)
        zone.update(CGRect(x: 960, y: 0, width: 960, height: 1080), below: 7)
        #expect(surface.shown?.frame == CGRect(x: 960, y: 0, width: 960, height: 1080))
        #expect(surface.shown?.below == 7 && surface.shown?.theme == look.theme)
        #expect(surface.shown?.edge == look.windowBorderWidth)
        zone.update(nil, below: nil)
        #expect(surface.shown == nil)
    }

    @Test("The panel takes no clicks, stays when Pilot is not active, and is a panel the tiler never lays out")
    func panel() {
        let panel = DropZonePanel()
        #expect(panel.window.ignoresMouseEvents && !panel.window.hidesOnDeactivate && !panel.window.isOpaque)
        #expect(panel.window.styleMask.contains(.nonactivatingPanel) && !panel.window.isVisible)
    }

    @Test("The zone's edge sits just outside the landing frame, where the focus border is drawn once the window lands")
    func edge() {
        let landing = CGRect(x: 960, y: 0, width: 960, height: 1080)
        #expect(DropZonePanel.frame(around: landing, edge: 2) == CGRect(x: 958, y: -2, width: 964, height: 1084))
        let layer = CALayer()
        DropZonePanel.paint(layer, PilotTheme.designed[0], edge: 2)
        #expect(layer.borderWidth == 2 && layer.cornerRadius == WindowBorderPanel.windowRadius + 2)
    }

    @Test("Esc reaches the tiler's drag on the key tap and still goes on to the app (card agent-bo-95423034)")
    func escapeCancelsADrag() {
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        var escapes = 0
        tap.onEscape = { escapes += 1 }
        #expect(!tap.route(KeyEvent(kind: .keyDown, keyCode: KeyCode.escape)))
        #expect(!tap.route(KeyEvent(kind: .keyUp, keyCode: KeyCode.escape)))
        #expect(!tap.route(KeyEvent(kind: .keyDown, keyCode: 0)))
        #expect(escapes == 1)
    }
}
