import Foundation
import PilotCore

extension SettingsSchema {
    /// Tools › Captures (spec `capture.html`): Pilot's two folders (empty meaning the
    /// standard one, `~/Pictures/Pilot`, `~/Movies/Pilot`) and how a recording sounds, counts down and shows clicks.
    func registerCaptures(_ store: CaptureSettingsStore) {
        func folder(_ kind: CaptureKind) -> SettingKey {
            .text(kind == .capture ? "capture.folder" : "capture.recordingsFolder", kind == .capture ? "Captures folder" : "Recordings folder",
                  page: "captures", standard: CaptureSettings.default.folder(kind).path(percentEncoded: false),
                  read: { store.folder(kind).path(percentEncoded: false) }, write: { path throws(ControlError) in
                      let picked = path.isEmpty ? nil : try Self.folder(path)
                      if kind == .capture { store.settings.capturesFolder = picked } else { store.settings.recordingsFolder = picked }
                  })
        }
        register([
            folder(.capture),
            folder(.recording),
            .choice("capture.audio", "Recording sound", page: "captures", CaptureSettings.Audio.allCases, standard: CaptureSettings.default.audio,
                    read: { store.settings.audio }, write: { store.settings.audio = $0 }),
            .choice("capture.countdown", "Count down first, in seconds", page: "captures", ["0", "3"],
                    standard: String(CaptureSettings.default.countdown),
                    read: { String(store.settings.countdown) }, write: { store.settings.countdown = Int($0) ?? store.settings.countdown }),
            .choice("capture.recordQuality", "Recording quality", page: "captures", CaptureSettings.RecordQuality.allCases,
                    standard: CaptureSettings.default.recordQuality,
                    read: { store.settings.recordQuality }, write: { store.settings.recordQuality = $0 }),
            .choice("capture.recordResolution", "Recording resolution", page: "captures", CaptureSettings.RecordResolution.allCases,
                    standard: CaptureSettings.default.recordResolution,
                    read: { store.settings.recordResolution }, write: { store.settings.recordResolution = $0 }),
            .choice("capture.recordFPS", "Recording frames a second", page: "captures", ["30", "60"], standard: String(CaptureSettings.default.recordFPS),
                    read: { String(store.settings.recordFPS) }, write: { store.settings.recordFPS = Int($0) ?? store.settings.recordFPS }),
            .bool("capture.showClicks", "Show clicks in recordings", page: "captures", standard: CaptureSettings.default.showClicks,
                  read: { store.settings.showClicks }, write: { store.settings.showClicks = $0 }),
            .choice("capture.delay", "A delayed capture waits, in seconds", page: "captures", ["3", "5", "10"],
                    standard: String(CaptureSettings.default.delay),
                    read: { String(store.settings.delay) }, write: { store.settings.delay = Int($0) ?? store.settings.delay }),
            .bool("capture.autoScroll", "Scrolling captures: Pilot scrolls for you", page: "captures", standard: CaptureSettings.default.autoScroll,
                  read: { store.settings.autoScroll }, write: { store.settings.autoScroll = $0 }),
            .bool("capture.hideDesktopIcons", "Hide desktop icons in captures and recordings", page: "captures", standard: CaptureSettings.default.hideDesktopIcons,
                  read: { store.settings.hideDesktopIcons }, write: { store.settings.hideDesktopIcons = $0 }),
            .choice("capture.afterCapture", "After a capture", page: "captures", CaptureSettings.AfterCapture.allCases,
                    standard: CaptureSettings.default.afterCapture,
                    read: { store.settings.afterCapture }, write: { store.settings.afterCapture = $0 }),
            .choice("capture.thumbnailPlace", "Where the thumbnail shows", page: "captures", CaptureSettings.ThumbnailPlace.allCases,
                    standard: CaptureSettings.default.thumbnailPlace,
                    read: { store.settings.thumbnailPlace }, write: { store.settings.thumbnailPlace = $0 }),
            .choice("capture.historyCap", "History size cap, in GB (0 keeps everything)", page: "captures", CaptureHistory.caps.map(String.init),
                    standard: "0", read: { String(CaptureHistoryStore.shared.capGB) },
                    write: { CaptureHistoryStore.shared.capGB = Int($0) ?? CaptureHistoryStore.shared.capGB }),
        ])
    }
}
