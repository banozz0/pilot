import AppKit
import PilotCore
import Testing
@testable import Pilot

/// The tap takes the keyboard's brightness keys and nothing else of the system-defined events (card agent-bo-95423314):
/// what onBrightness answers decides, and every other one passes untouched. Events are made, never posted.
@MainActor
@Suite("Brightness tap")
struct BrightnessTapTests {
    /// A system-defined event as the keyboard sends it: subtype 8, the key type and state packed in data1.
    func systemDefined(subtype: Int16 = 8, key: Int, down: Bool = true) throws -> CGEvent {
        let data1 = key << 16 | (down ? 0x0A : 0x0B) << 8
        let ns = try #require(NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil, subtype: subtype, data1: data1, data2: -1))
        return try #require(ns.cgEvent)
    }

    let type = CGEventType(rawValue: BrightnessKeys.eventType)!

    @Test("Brightness up and down reach onBrightness: taken when it says so, passed when it does not")
    func brightness() throws {
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        var seen: [BrightnessKeys.Press] = []
        var answer = true
        tap.onBrightness = { seen.append($0); return answer }
        #expect(tap.handle(type: type, event: try systemDefined(key: 2)) == nil)
        #expect(tap.handle(type: type, event: try systemDefined(key: 3, down: false)) == nil)
        answer = false
        #expect(tap.handle(type: type, event: try systemDefined(key: 2)) != nil)
        #expect(seen == [.init(up: true, isDown: true, isRepeat: false), .init(up: false, isDown: false, isRepeat: false),
                         .init(up: true, isDown: true, isRepeat: false)])
    }

    @Test("Volume, play and mouse-button system events pass untouched and never reach onBrightness")
    func othersPass() throws {
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        var asked = 0
        tap.onBrightness = { _ in asked += 1; return true }
        for event in [try systemDefined(key: 0), try systemDefined(key: 16), try systemDefined(subtype: 7, key: 2)] {
            #expect(tap.handle(type: type, event: event) != nil)
        }
        let f2 = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 120, keyDown: true))
        #expect(tap.handle(type: .keyDown, event: f2) != nil)
        #expect(asked == 0)
    }
}

/// Setup › Displays' switch for the brightness keys: on at first, saved as it changes (card agent-bo-95423314).
@MainActor
@Suite("Brightness keys setting")
struct BrightnessKeysSettingTests {
    @Test("On by default; switched off it stays off at the next launch")
    func stored() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let item = LoginItem(service: .init(status: { .enabled }, register: {}, unregister: {}))
        let settings = PilotSettings(defaults: defaults, loginItem: item)
        #expect(settings.brightnessKeys)
        settings.brightnessKeys = false
        #expect(!PilotSettings(defaults: defaults, loginItem: item).brightnessKeys)
    }
}
