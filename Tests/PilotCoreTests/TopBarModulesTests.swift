import Foundation
import Testing
@testable import PilotCore

@Suite("Top bar modules")
struct TopBarModulesTests {
    @Test("Volume reads as its percentage in Pilot's style (50 %), Muted when muted, a dash with no volume to read")
    func volume() {
        #expect(TopBarText.volume(0.4, muted: false) == "40 %")
        #expect(TopBarText.volume(0.4, muted: true) == "Muted")
        // A screen that sets its own volume (HDMI) has none to read.
        #expect(TopBarText.volume(nil, muted: nil) == "–")
    }

    @Test("The input source reads as its name, or two letters in the code style")
    func inputSource() {
        #expect(TopBarText.inputSource("British – PC", style: .name) == "British – PC")
        #expect(TopBarText.inputSource("British – PC", style: .code) == "BR")
        #expect(TopBarText.inputSource("ABC", style: .code) == "AB")
        #expect(TopBarText.inputSource(nil, style: .code) == "–")
    }

    @Test("The next layout is the one after the current, wrapping; one layout has no next")
    func nextLayout() {
        let a = InputSource(id: "a", name: "ABC", isKeyboard: true, isEnabled: true, isSelectable: true, isCurrent: false)
        let b = InputSource(id: "b", name: "British", isKeyboard: true, isEnabled: true, isSelectable: true, isCurrent: true)
        let c = InputSource(id: "c", name: "Spanish", isKeyboard: true, isEnabled: true, isSelectable: true, isCurrent: false)
        #expect(KeyboardLayouts.next(in: [a, b, c])?.id == "c")
        #expect(KeyboardLayouts.next(in: [a, c, b])?.id == "a")
        #expect(KeyboardLayouts.next(in: [b]) == nil)
    }

    @Test("The focused app reads as its name; with no app focused, or one with no name, the module hides")
    func focusedApp() {
        #expect(TopBarText.focusedApp("Ghostty") == "Ghostty")
        #expect(TopBarText.focusedApp(nil) == nil)
        #expect(TopBarText.focusedApp("") == nil)
    }

    @Test("The battery's symbol follows its level in quarters")
    func batterySymbol() {
        #expect(TopBarText.batterySymbol(SystemStats.Battery(percent: 82, charging: false, minutesLeft: nil)) == "battery.75")
        #expect(TopBarText.batterySymbol(SystemStats.Battery(percent: 96, charging: false, minutesLeft: nil)) == "battery.100")
        #expect(TopBarText.batterySymbol(SystemStats.Battery(percent: 9, charging: false, minutesLeft: nil)) == "battery.0")
        #expect(TopBarText.batterySymbol(SystemStats.Battery(percent: 40, charging: false, minutesLeft: nil)) == "battery.50")
    }
}
