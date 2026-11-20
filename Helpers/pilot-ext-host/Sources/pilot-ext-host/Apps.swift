import CoreServices
import Foundation
import JavaScriptCore

// AppleScript consent (ADR 0017, T9): an app a script names, by its name, its bundle id or its path, resolved to one
// bundle id and the name it shows, so `application "Calendar"` and `application id "com.apple.iCal"` are one app asked
// once and the question names it as people know it. Read from the app's own Info.plist; nothing is opened or sent.
// And which program a child really is: its file resolved as posix_spawnp will (the host's own PATH for a bare name, the
// child's cwd for a relative one) to its real path, so only a call that really is /usr/bin/osascript is read for apps.

extension Host {
    func installApps(into native: JSValue) {
        let identify: @convention(block) (String, Bool) -> Any = { text, byID in Host.appIdentity(text, byID: byID) ?? NSNull() }
        native.setObject(identify, forKeyedSubscript: "appIdentity" as NSString)
        let real: @convention(block) (String, String) -> Any = { file, cwd in Host.realExecutable(file, cwd: cwd) ?? NSNull() }
        native.setObject(real, forKeyedSubscript: "realExecutable" as NSString)
        let trusted: @convention(block) () -> [String] = { Host.trustedOsascripts }
        native.setObject(trusted, forKeyedSubscript: "trustedOsascripts" as NSString)
    }

    /// The real path of the program `file` starts, found as posix_spawnp finds it; nil when there is none.
    static func realExecutable(_ file: String, cwd: String) -> String? {
        let fm = FileManager.default
        let candidates: [String]
        if file.contains("/") {
            candidates = [file.hasPrefix("/") ? file : URL(filePath: cwd.isEmpty ? fm.currentDirectoryPath : cwd).appending(path: file).path]
        } else {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            candidates = path.split(separator: ":").map { URL(filePath: String($0)).appending(path: file).path }
        }
        guard let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }
        return URL(filePath: found).resolvingSymlinksInPath().path
    }

    /// The programs a call must really be to have its apps read: /usr/bin/osascript, and, only for a host that runs outside
    /// an app (the sandbox's), the real paths listed in `pilot-ext-trusted-osascript` beside it, so its proof can use a
    /// stand-in. Pilot's own bundled host never reads that file.
    static let trustedOsascripts: [String] = {
        var list = ["/usr/bin/osascript"]
        guard let me = Bundle.main.executableURL?.resolvingSymlinksInPath(), !me.path.contains(".app/Contents/") else { return list }
        let file = me.deletingLastPathComponent().appending(path: "pilot-ext-trusted-osascript")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            list += text.split(whereSeparator: \.isNewline).map { URL(filePath: String($0)).resolvingSymlinksInPath().path }.filter { $0.hasPrefix("/") }
        }
        return list
    }()

    /// Where an app named by name alone is looked for when LaunchServices does not know it.
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
            // LaunchServices first, as AppleScript itself finds an app by name; then the usual folders.
            let bare = text.lowercased().hasSuffix(".app") ? String(text.dropLast(4)) : text
            var found: Unmanaged<CFURL>?
            let file = bare + ".app"
            url = LSFindApplicationForInfo(kLSUnknownCreator, nil, file as CFString, nil, &found) == noErr ? found?.takeRetainedValue() as URL?
                : appFolders.lazy.map { URL(filePath: $0).appending(path: file) }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let shown = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        return ["id": id, "name": shown]
    }
}
