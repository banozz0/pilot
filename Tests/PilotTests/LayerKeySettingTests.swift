import Foundation
import Observation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Card agent-bo-95422775: a layer-key change reaches the running Pilot at once. On 865b4e7 the setting was a computed
/// property Observation did not track, so the pages' onChange never ran and the key changed only at the next launch.
@MainActor
@Suite("Layer key setting")
struct LayerKeySettingTests {
    func settings() throws -> (PilotSettings, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let item = LoginItem(service: .init(status: { .enabled }, register: {}, unregister: {}))
        return (PilotSettings(defaults: defaults, loginItem: item), defaults)
    }

    @Test("A layer-key change notifies what observes the setting")
    func observed() throws {
        let (settings, _) = try settings()
        nonisolated(unsafe) var fired = false
        withObservationTracking { _ = settings.layerKeys } onChange: { fired = true }
        settings.setLayerKeys([.rightCommand], from: .settings)
        #expect(fired)
    }

    @Test("One change persists and reaches the engine's apply hook once; the same keys again, or none, do nothing")
    func applies() throws {
        let (settings, defaults) = try settings()
        var applied = 0
        settings.onLayerKeyChange = { applied += 1 }
        #expect(settings.layerKeys == [.capsLock])
        settings.setLayerKeys([.rightCommand, .capsLock], from: .settings)
        settings.setLayerKeys([.capsLock, .rightCommand], from: .settings)
        settings.setLayerKeys([], from: .settings)
        #expect(applied == 1)
        #expect(defaults.stringArray(forKey: "layerKeys") == ["capsLock", "rightCommand"] && settings.layerKeys == [.capsLock, .rightCommand])
        #expect(PilotSettings(defaults: defaults, loginItem: LoginItem(service: .init(status: { .enabled }, register: {}, unregister: {})))
                .layerKeys == [.capsLock, .rightCommand], "read back at the next launch")
        settings.setLayerKeys([.capsLock], from: .onboarding)
        #expect(applied == 2)
    }

    @Test("The one key an older Pilot saved loads as a list of one; nothing or only unknown words load as Caps Lock")
    func migrates() throws {
        func loaded(_ fill: (UserDefaults) -> Void) throws -> [LayerKey] {
            let (_, defaults) = try settings()
            fill(defaults)
            return PilotSettings(defaults: defaults, loginItem: LoginItem(service: .init(status: { .enabled }, register: {}, unregister: {})))
                .layerKeys
        }
        #expect(try loaded { $0.set("rightCommand", forKey: "layerKey") } == [.rightCommand])
        #expect(try loaded { $0.set("rightOption", forKey: "layerKey"); $0.set(["capsLock", "rightCommand"], forKey: "layerKeys") }
                == [.capsLock, .rightCommand], "the list wins over the old key")
        #expect(try loaded { _ in } == [.capsLock])
        #expect(try loaded { $0.set("fn", forKey: "layerKey") } == [.capsLock])
        #expect(try loaded { $0.set([String](), forKey: "layerKeys") } == [.capsLock])
    }

    @Test("A tick that turns Caps Lock off waits for the confirm; adding a key, or any other change, applies at once")
    func picks() throws {
        let (settings, _) = try settings()
        nonisolated(unsafe) var asking: LayerKeyChange?
        let binding = Binding(get: { asking }, set: { asking = $0 })
        LayerKeyConfirm.ticked(.rightCommand, settings, from: .settings, asking: binding).wrappedValue = true
        #expect(asking == nil && settings.layerKeys == [.capsLock, .rightCommand])
        LayerKeyConfirm.ticked(.capsLock, settings, from: .settings, asking: binding).wrappedValue = false
        #expect(asking?.keys == [.rightCommand] && settings.layerKeys == [.capsLock, .rightCommand])
        asking = nil
        LayerKeyConfirm.ticked(.rightCommand, settings, from: .settings, asking: binding).wrappedValue = false
        #expect(asking == nil && settings.layerKeys == [.capsLock])
        LayerKeyConfirm.pick([.rightCommand], settings, from: .onboarding, asking: binding)
        #expect(asking?.keys == [.rightCommand] && settings.layerKeys == [.capsLock])
    }

    /// Card agent-bo-95422776: the quick-tap switch and the overlay mode had the same untracked, computed shape.
    @Test("A quick-tap or overlay-mode change notifies what observes the setting")
    func otherSettingsObserved() throws {
        let (settings, _) = try settings()
        nonisolated(unsafe) var fired = 0
        withObservationTracking { _ = settings.quickTapEscape } onChange: { fired += 1 }
        settings.quickTapEscape = false
        withObservationTracking { _ = settings.overlayMode } onChange: { fired += 1 }
        settings.overlayMode = .mostUsed
        #expect(fired == 2)
    }

    /// Card agent-bo-95422831: This Mac's public IP calls the internet, so it is off until switched on.
    @Test("The public IP switch starts off, notifies what observes it, and persists to the next launch")
    func publicIPSetting() throws {
        let (settings, defaults) = try settings()
        #expect(!settings.showPublicIP)
        nonisolated(unsafe) var fired = 0
        withObservationTracking { _ = settings.showPublicIP } onChange: { fired += 1 }
        settings.showPublicIP = true
        #expect(fired == 1 && defaults.object(forKey: "system.publicIP") as? Bool == true)
        #expect(PilotSettings(defaults: defaults, loginItem: LoginItem(service: .init(status: { .enabled }, register: {}, unregister: {})))
                .showPublicIP)
    }

    @Test("A quick-tap change persists, reads back at the next launch and reaches the engine's tap hook once")
    func quickTapApplies() throws {
        let (settings, defaults) = try settings()
        var applied = 0
        settings.onQuickTapChange = { applied += 1 }
        settings.onLayerKeyChange = { Issue.record("a quick-tap change does not re-apply the layer key") }
        #expect(settings.quickTapEscape)
        settings.quickTapEscape = false
        #expect(applied == 1 && defaults.object(forKey: "quickTapEscape") as? Bool == false)
        #expect(!PilotSettings(defaults: defaults, loginItem: LoginItem(service: .init(status: { .enabled }, register: {}, unregister: {})))
                .quickTapEscape)
    }
}
