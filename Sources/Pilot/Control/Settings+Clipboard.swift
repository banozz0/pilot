import Clipboard
import Foundation
import PilotCore

extension SettingsSchema {
    /// Settings › Clipboard's scalars, applied through the history as the page applies them, so a lowered limit prunes at
    /// once; and the dropdown's recording switch, which holds for this session only. The never-record apps are a list,
    /// not a key.
    func registerClipboard(_ history: ClipboardHistory, recording: SessionSwitch) {
        func change(_ edit: @escaping (inout ClipboardSettings) -> Void) {
            var settings = history.settings
            edit(&settings)
            history.apply(settings)
        }
        let standard = ClipboardSettings.default
        register([
            .int("clipboard.keepCount", "Keep the last, in items", page: "clipboard", range: 1...1_000_000, standard: standard.keepCount,
                 read: { history.settings.keepCount }, write: { n in change { $0.keepCount = n } }),
            // The page's picker: a day count it does not list would show as no pick.
            .choice("clipboard.keepDays", "Keep for, in days", page: "clipboard", ["1", "7", "30", "90", "365", "forever"],
                    standard: standard.keepDays.map(String.init) ?? "forever",
                    read: { history.settings.keepDays.map(String.init) ?? "forever" }, write: { days in change { $0.keepDays = Int(days) } }),
            .bool("clipboard.saveImages", "Save images", page: "clipboard", standard: standard.saveImages,
                  read: { history.settings.saveImages }, write: { on in change { $0.saveImages = on } }),
            .choice("clipboard.returnAction", "Return in the panel", page: "clipboard", ClipboardSettings.ReturnAction.allCases,
                    standard: standard.returnAction,
                    read: { history.settings.returnAction }, write: { action in change { $0.returnAction = action } }),
            .choice("clipboard.sort", "Sort by", page: "clipboard", ClipSort.allCases, standard: standard.order.sort,
                    read: { history.settings.order.sort }, write: { sort in change { $0.order.sort = sort } }),
            .bool("clipboard.sortReversed", "Sort reversed", page: "clipboard", standard: standard.order.reversed,
                  read: { history.settings.order.reversed }, write: { on in change { $0.order.reversed = on } }),
            .bool("clipboard.expireSecrets", "Expire card numbers and keys", page: "clipboard", standard: standard.expireSecrets,
                  read: { history.settings.expireSecrets }, write: { on in change { $0.expireSecrets = on } }),
            .int("clipboard.secretMinutes", "Expire them after (minutes)", page: "clipboard", range: ClipboardSettings.secretMinuteRange,
                 standard: standard.secretMinutes, read: { history.settings.secretMinutes }, write: { n in change { $0.secretMinutes = n } }),
            .bool("clipboard.recording", "Clipboard keeps what is copied (on again at every launch)", page: "clipboard", standard: true,
                  read: { recording.isOn }, write: { recording.set($0) }),
        ])
    }
}
