import Testing
import CoreGraphics
@testable import PilotCore

@Suite("Floating windows")
struct FloatingTests {
    static func window(_ id: Int, _ layout: String) -> AeroWindow {
        AeroWindow(id: id, appName: "Finder", bundleId: "com.apple.finder", pid: 1, workspace: "3", monitorId: 1,
                   layout: layout, title: "w\(id)")
    }

    @Test("Floating or tiling one window is the tiler's layout command aimed at it")
    func setFloating() {
        #expect(AeroCommand.setFloating(id: 7, true).arguments == ["layout", "--window-id", "7", "floating"])
        #expect(AeroCommand.setFloating(id: 7, false).arguments == ["layout", "--window-id", "7", "tiling"])
    }

    @Test("Float or tile the workspace: while any window tiles, the tiled ones float; once none does, all tile")
    func toggleWorkspace() {
        let mixed = [Self.window(1, "h_tiles"), Self.window(2, "floating"), Self.window(3, "h_scrolling")]
        #expect(Floating.toggleWorkspace(mixed).commands == [.setFloating(id: 1, true), .setFloating(id: 3, true)])
        let floating = [Self.window(1, "floating"), Self.window(2, "floating")]
        #expect(Floating.toggleWorkspace(floating).commands == [.setFloating(id: 1, false), .setFloating(id: 2, false)])
        #expect(Floating.toggleWorkspace([]).commands.isEmpty)
    }

    @Test("Floated windows cascade from the centre: the middle one centred, each next one a step down and right")
    func cascade() {
        let visible = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        let centre = Placement.centre.frame(in: visible)
        #expect(Floating.cascade(1, in: visible) == [centre])
        let three = Floating.cascade(3, in: visible, step: 30)
        #expect(three == [centre.offsetBy(dx: -30, dy: -30), centre, centre.offsetBy(dx: 30, dy: 30)])
        #expect(Floating.cascade(0, in: visible).isEmpty)
    }
}
