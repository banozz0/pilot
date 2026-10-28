import AppKit
import PilotCore
import Testing
@testable import Pilot

/// Hyper+Ctrl+A, B and W open Pilot's Setup page at Sound, Bluetooth and Wi-Fi instead of System Settings (card
/// agent-bo-95422805, Sven's yes 2026-10-05). The actions keep their ids, so the binds and the Omarchy preset keep working.
@MainActor
@Suite("Setup keys")
struct SetupKeysTests {
    @Test("Each of the three actions opens the app window on Setup at its own section, under its new name")
    func actions() throws {
        testApp()
        var registry = ActionRegistry()
        SystemModule.register(into: &registry)
        // The real window controller, told the screen is locked, so each open only records the page and waits: no
        // window is made in the test.
        let c = AppWindowController.shared, locked = c.screenLocked
        c.screenLocked = { true }
        defer { c.screenLocked = locked; c.model.setupSection = nil }
        for (id, label, section) in [("system.soundSettings", "Sound in Pilot", SetupSection.sound),
                                     ("system.bluetoothSettings", "Bluetooth in Pilot", .bluetooth),
                                     ("system.wifiSettings", "Wi-Fi in Pilot", .wifi),
                                     ("system.displaySettings", "Displays in Pilot", .displays)] {
            let action = try #require(registry.actions[id])
            #expect(action.label == label)
            c.model.setupSection = nil
            action.run()
            #expect(c.model.setupSection == section, "\(id)")
            #expect(c.waitsForUnlock)
        }
    }

    @Test("Opening System at a section leaves the window's model on System and that section, even while the screen is locked")
    func controller() {
        testApp()
        let c = AppWindowController()
        c.autosaveName = nil
        c.applyDockIcon = { _ in }
        c.screenLocked = { true }   // the open waits for the unlock, so no window is made in the test
        c.open(.system, setup: .wifi)
        #expect(c.model.setupSection == .wifi)
        #expect(c.waitsForUnlock)
        // A section with another page is no section.
        c.model.setupSection = nil
        c.open(.home, setup: .wifi)
        #expect(c.model.setupSection == nil)
    }
}
