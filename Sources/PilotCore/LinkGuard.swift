import Foundation

/// The per-install secret a pilot:// link must carry to run or bind an action that runs a command or opens a non-web
/// URL, the ones an import switches off (BindStore.arrivesOff; card agent-bo-95422763, Sven's option B): a web page,
/// mail or chat app cannot read the file, a local script can (`&token=$(cat ~/Library/Application\ Support/Pilot/link-token)`).
public struct LinkToken {
    public let url: URL

    /// ~/Library/Application Support/Pilot/link-token
    public static var standard: LinkToken { LinkToken(url: PilotFolder.support.appending(path: "link-token")) }

    /// The token, made on first use: 32 random bytes as hex, in a file only its owner can read. An empty file gets a new one.
    public func value() throws -> String {
        if let stored = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return token
    }

    /// Whether a link carrying `token` may run or bind `action`: always for Pilot's own actions, apps, web pages and
    /// menu items; for the rest only with the token. A keystroke goes into whichever app the link brings to the front,
    /// so links could type a command into a terminal key by key.
    public func allows(_ action: String, token: String?) -> Bool {
        if BindStore.arrivesOff(action) { return matches(token) }
        if case .keystroke? = DriveRoute(id: action) { return matches(token) }
        return true
    }

    /// `text` with every token value in it, plain or percent-encoded (once or more) inside another link, shown as <redacted>: a log
    /// line prints a link only through this, so `log stream` never carries the token.
    public static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(token(?:=|%(?:25)*3D)["'\s]*)(?:(?!&|%(?:25)*26)[^\s"'])+"#, with: "$1<redacted>", options: .regularExpression)
    }

    /// Whether `token` is this install's token, as pilot://press needs always: a press can fire a bind that runs a command.
    public func matches(_ token: String?) -> Bool {
        guard let token, let stored = try? value() else { return false }
        // Every byte compared, so how long a wrong token takes says nothing about how much of it was right.
        let a = Array(token.utf8), b = Array(stored.utf8)
        return a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
