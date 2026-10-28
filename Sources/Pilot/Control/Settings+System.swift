import Foundation
import PilotCore

/// Pilot's on/off switch as the settings reach it; PilotSwitch is the app's, a test passes a fake, since the real one
/// arms and disarms the binds.
@MainActor
protocol PilotSwitching: AnyObject {
    var isOn: Bool { get }
    func set(_ on: Bool)
}

extension PilotSwitch: PilotSwitching {}

extension SettingsSchema {
    /// The rest of Pilot's own settings: Look's wallpaper cycle, the overlay's mode, the notes folder, recommendations,
    /// This Mac's public IP, Update's self-updating casks and Pilot's switch. The switch's keys wait on the Allow gate, as
    /// the switch is Sven's alone; the live system values (brightness, volume, dark mode …) are actions, not settings.
    func registerSystem(settings: PilotSettings, wallpaper: WallpaperSettings, recommendations: Recommendations, pilotSwitch: any PilotSwitching,
                        dictation: PilotDictation, notesIn: @escaping @MainActor (URL) -> Int, changeNotes: @escaping @MainActor (URL) throws -> Void) {
        register([
            .choice("wallpaper.order", "Wallpapers go", page: "look", WallpaperCycle.Order.allCases, standard: .name,
                    read: { wallpaper.order }, write: { wallpaper.order = $0 }),
            .choice("wallpaper.scope", "Next wallpaper changes", page: "look", WallpaperCycle.Scope.allCases, standard: .focusedScreen,
                    read: { wallpaper.scope }, write: { wallpaper.scope = $0 }),
            // A screen's own folders are `pilot add wallpaper-sources --screen`.
            .choice("wallpaper.folders", "Wallpaper folders: the same on every screen, or each screen its own", page: "look",
                    WallpaperCycle.Folders.allCases, standard: .shared, read: { wallpaper.folders }, write: { wallpaper.folders = $0 }),
            // A workspace's own folders are `pilot add wallpaper-sources --workspace`.
            .choice("wallpaper.workspaces", "Wallpaper per workspace: every workspace its screen's, or each workspace its own", page: "look",
                    WallpaperCycle.Workspaces.allCases, standard: .shared, read: { wallpaper.workspaces }, write: { wallpaper.workspaces = $0 }),
            .bool("wallpaper.fitShape", "Only images that fit the screen: off, every screen steps through every image", page: "look",
                  standard: true, read: { wallpaper.fitShape }, write: { wallpaper.fitShape = $0 }),
            // The page's picker: a minute count it does not list would show as no pick.
            .choice("wallpaper.interval", "Change on their own, every minutes (0 never)", page: "look",
                    WallpaperCycle.intervals.map(String.init), standard: "0",
                    read: { String(wallpaper.interval) }, write: { wallpaper.interval = Int($0) ?? wallpaper.interval }),
            .choice("overlayMode", "The overlay shows", page: "binds", OverlayPage.Mode.allCases, standard: .every,
                    read: { settings.overlayMode }, write: { settings.overlayMode = $0 }),
            .text("notes.folder", "Notes folder", page: "notes", standard: NotesFolder.pilotDefault.path,
                  read: { NotesFolder.folder(settings.notesFolder).path }, write: { path throws(ControlError) in
                      let new = URL(filePath: try Self.folder(path), directoryHint: .isDirectory)
                      let old = NotesFolder.folder(settings.notesFolder)
                      guard !NotesFolder.same(new, old) else { return }
                      // Moving Sven's notes is the page's question, never the command's.
                      let count = notesIn(old)
                      guard count == 0 else {
                          throw ControlError(.badValue, "\(count) notes are in \(old.path): pick the new folder on the Notes page, which moves them")
                      }
                      do { try changeNotes(new) } catch { throw ControlError(.badValue, "notes folder not changed: \(error.localizedDescription)") }
                  }),
            // Voice › Dictation's speech model; automatic is the first one on disk. One not on disk waits for its
            // download on the page.
            .choice(SpeechModels.key, "Speech model", page: "voice", ["automatic"] + SpeechChoice.allCases.map(\.rawValue), standard: "automatic",
                    read: { dictation.models.pick?.rawValue ?? "automatic" },
                    write: { dictation.models.pick = SpeechChoice(rawValue: $0) }),
            // Pilot's own dictation: what the pill shows while Sven speaks, and whether a typed take stays on the clipboard.
            .choice(PilotDictation.whileSpeakingKey, "While you speak, the pill shows", page: "voice", PilotDictation.WhileSpeaking.allCases,
                    standard: .waveform, read: { dictation.whileSpeaking }, write: { dictation.whileSpeaking = $0 }),
            .bool(PilotDictation.copyKey, "Dictation also leaves its words on the clipboard", page: "voice", standard: false,
                  read: { dictation.copiesText }, write: { dictation.copiesText = $0 }),
            .bool(PilotDictation.pauseMediaKey, "Dictation pauses what is playing and plays it again after", page: "voice", standard: false,
                  read: { dictation.pausesMedia }, write: { dictation.pausesMedia = $0 }),
            // The one key that alone starts and stops dictation (Q224); a layer key is Hyper, never this too.
            .choice(PilotSettings.dictationKeyKey, "Dictation key (a tap alone, or held)", page: "voice", DictationKey.allCases,
                    standard: .off, read: { settings.dictationKey }, write: { key throws(ControlError) in
                        guard key.isFree(layerKeys: settings.layerKeys) else {
                            throw ControlError(.badValue, "\(key.rawValue) is a Hyper key: turn it off as one in General first")
                        }
                        settings.dictationKey = key
                    }),
            .choice(PilotSettings.dictationKeyModeKey, "Dictation key mode", page: "voice", DictationKeyMode.allCases, standard: .toggle,
                    read: { settings.dictationKeyMode }, write: { settings.dictationKeyMode = $0 }),
            .bool("recommendations.show", "Recommend apps", page: "install", standard: true,
                  read: { recommendations.show }, write: { recommendations.show = $0 }),
            .bool("system.publicIP", "Show This Mac's public IP", page: "stats", standard: false,
                  read: { settings.showPublicIP }, write: { settings.showPublicIP = $0 }),
            .bool("update.selfUpdatingCasks", "Update lists casks that update themselves", page: "install", standard: false,
                  read: { settings.updateSelfUpdatingCasks }, write: { settings.updateSelfUpdatingCasks = $0 }),
            .bool("switch.on", "Pilot on (its binds armed)", page: "home", standard: true, confirms: true,
                  read: { pilotSwitch.isOn }, write: { pilotSwitch.set($0) }),
        ])
    }
}
