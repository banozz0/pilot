import Foundation
import PilotCore

extension SettingsSchema {
    /// Settings › General's keys, Launcher's translate pair (System's until the page map, Sven 2026-10-17) and System's
    /// brightness keys, all on the engine's PilotSettings; and Home's Hyper switch, which holds for this session only, as
    /// the page's does.
    func registerGeneral(_ settings: PilotSettings, hyper: SessionSwitch) {
        register([
            .bool("hyper.on", "Hyper key on (on again at every launch)", page: "home", standard: true,
                  read: { hyper.isOn }, write: { hyper.set($0) }),
            // Each key listed is Hyper alone. The page confirms turning Caps Lock off; the command waits on the Allow gate
            // for any change. "layerKey" still, so `pilot set layerKey rightCommand` works as before.
            .choices("layerKey", "Hyper keys", page: "general", LayerKey.allCases, standard: [.capsLock], confirms: true,
                     read: { settings.layerKeys }, write: { settings.setLayerKeys($0, from: .settings) },
                     check: { keys throws(ControlError) in
                         guard !LayerKey.hasTwins(keys) else {
                             throw ControlError(.badValue, "one side of Control, Option or Command at most, so the other stays itself")
                         }
                     }),
            // Binds › More › Swap keys (Q406): "capsLock:leftControl,escape:tab" sets every pair at once, "" none; pilot add|remove
            // key-swaps changes one. It changes typing, so it waits on Allow.
            .text("keySwaps", "Swapped keys, first:second each", page: "binds", standard: "", confirms: true,
                  read: { settings.keySwaps.map(\.word).joined(separator: ",") },
                  // Another tool's mapping is the engine's to see: a swap it catches waits, as on the page.
                  write: { words throws(ControlError) in
                      var swaps: [KeySwap] = []
                      for word in words.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !word.isEmpty {
                          swaps = try KeySwap.adding(KeySwap.parsed(word), to: swaps, layerKeys: settings.layerKeys, foreign: [])
                      }
                      settings.keySwaps = swaps
                  }),
            .bool("quickTapEscape", "A tap of the Hyper key is Escape", page: "general", standard: true,
                  read: { settings.quickTapEscape }, write: { settings.quickTapEscape = $0 }),
            .number("overlay.delay", "Seconds Hyper is held before the overlay shows", page: "general", range: HoldOverlay.delayRange,
                    standard: HoldOverlay.delay, read: { settings.overlayDelay }, write: { settings.overlayDelay = $0 }),
            .bool("overlay.enabled", "Holding Hyper shows your binds", page: "general", standard: true,
                  read: { settings.overlayEnabled }, write: { settings.overlayEnabled = $0 }),
            .bool("general.bindNudges", "Show an app's bind after you open it", page: "general", standard: true,
                  read: { settings.bindNudges }, write: { settings.bindNudges = $0 }),
            .bool("launchAtLogin", "Launch at login", page: "general", standard: PilotSettings.launchAtLoginDefault,
                  read: { settings.launchAtLogin }, write: { settings.launchAtLogin = $0 }),
            // Q715: Configs, its Agents tab and Repos. Off for a new install; an existing one started on once (PilotSettings).
            .bool("general.developer", "Developer pages: Configs, Agents and Repos", page: "general", standard: false,
                  read: { settings.developer }, write: { settings.developer = $0 }),
            .choice("translate.home", "Translate into", page: "menu", TranslatePair.languages, standard: TranslatePair.standard.home,
                    read: { settings.translatePair.home }, write: { settings.translatePair = settings.translatePair.with(home: $0) }),
            .choice("translate.other", "Your language goes into", page: "menu", TranslatePair.languages,
                    standard: TranslatePair.standard.other,
                    read: { settings.translatePair.other }, write: { settings.translatePair = settings.translatePair.with(other: $0) }),
            .bool("displays.brightnessKeys", "Brightness keys follow the focused window", page: "system", standard: true,
                  read: { settings.brightnessKeys }, write: { settings.brightnessKeys = $0 }),
        ])
    }
}
