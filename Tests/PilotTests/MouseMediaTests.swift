import Foundation
import IOKit.hid
import PilotCore
import Testing
@testable import Pilot

/// The mouse's HID watch (MouseMedia) turned on and off as Learn and a save do. IOKit runs the manager's cancel handler
/// on the HID queue: a handler that inherited the main actor trapped there (Build 55, both crashes on ending Learn).
@MainActor
@Suite("Mouse HID watch")
struct MouseMediaTests {
    @Test("Turning the HID watch off runs its cancel handler on the HID queue without trapping, and lets the manager go")
    func cancelOffMain() async throws {
        let media = MouseMedia()
        for _ in 0..<3 {
            media.run(true, verbose: true)
            #expect(media.isRunning)
            media.run(false, verbose: false)
            #expect(!media.isRunning)
        }
        for _ in 0..<200 where media.retiringCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(media.retiringCount == 0, "every cancelled manager is let go once its handler ran")
    }

    @Test("The connected mice are listed with their buttons from 3 up, without Input Monitoring",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] != nil))
    func findsMice() {
        let mouse = MouseButtons(tap: HyperTap(layer: HyperLayer(layerKey: .capsLock)))
        mouse.findMice()
        #expect(!mouse.found.names.isEmpty && mouse.found.buttons.first == MouseKeys.button(2), "\(mouse.found)")
        print("found \(mouse.found.names) \(mouse.found.buttons.map(\.label)), Input Monitoring \(MouseButtons.describe(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)))")
    }

    @Test("Only mice that have sent an event are named: a keyboard receiver's pointer that never moved is not; a trackpad never")
    func usedMiceOnly() {
        let hyperX = MouseKeys.Device(vendor: 1008, product: 3471, name: "HyperX Pulsefire Core")
        let link = MouseKeys.Device(vendor: 13364, product: 53297, name: "Keychron Link")
        let pad = MouseKeys.Device(vendor: 1452, product: 613, name: "Trackpad")
        typealias C = MouseButtons.Candidate
        let sven = MouseButtons.found([C(device: link, buttons: 5, sentEvents: false), C(device: hyperX, buttons: 5, sentEvents: true),
                                       C(device: pad, buttons: 1, sentEvents: true)])
        #expect(sven.names == ["HyperX Pulsefire Core"] && sven.buttons.map(\.label) == ["Mouse 3", "Mouse 4", "Mouse 5"])
        #expect(MouseButtons.found([C(device: link, buttons: 5, sentEvents: nil), C(device: hyperX, buttons: 5, sentEvents: true)]).names.count == 2,
                "unknown use keeps a mouse")
        #expect(MouseButtons.found([C(device: link, buttons: 5, sentEvents: false)]).names == ["Keychron Link"],
                "when no mouse has been used, every one is shown rather than none")
        #expect(MouseButtons.found([C(device: pad, buttons: 1, sentEvents: true)]) == MouseButtons.Found())
    }
}
