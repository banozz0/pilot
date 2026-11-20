import CoreServices
import Foundation
import JavaScriptCore

// AppleScript consent (ADR 0017, T9): an app a script names, by its name, its bundle id or its path, resolved to one
// bundle id and the name it shows, so `application "Calendar"` and `application id "com.apple.iCal"` are one app asked
// once and the question names it as people know it. Read from the app's own Info.plist; nothing is opened or sent.

extension Host {
    func installApps(into native: JSValue) {
        let identify: @convention(block) (String, Bool) -> Any = { text, byID in Host.appIdentity(text, byID: byID) ?? NSNull() }
        native.setObject(identify, forKeyedSubscript: "appIdentity" as NSString)
    }

    /// Where an app named by name alone is looked for, as AppleScript finds the usual ones.
    static let appFolders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                             "/System/Library/CoreServices", NSHomeDirectory() + "/Applications"]

    /// `{ id, name }` for the app `text` names (a bundle id when `byID`, else a name or a path), or nil when none is found.
    static func appIdentity(_ text: String, byID: Bool) -> [String: String]? {
        let url: URL?
        if byID {
            url = (LSCopyApplicationURLsForBundleIdentifier(text as CFString, nil)?.takeRetainedValue() as? [URL])?.first
        } else if text.hasPrefix("/") {
            url = URL(filePath: text)
        } else {
            let file = text.lowercased().hasSuffix(".app") ? text : text + ".app"
            url = appFolders.lazy.map { URL(filePath: $0).appending(path: file) }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let shown = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        return ["id": id, "name": shown]
    }
}
