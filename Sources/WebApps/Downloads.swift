import CoreServices
import Foundation

/// Downloads in a web app (card agent-bo-95422810): the file lands in ~/Downloads under a free name, marked as a web
/// download the way Safari marks it, and the window's bar says how it goes.
public enum Downloads {
    public static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads") }

    /// Extensions kept whole when a number goes in: archive (1).tar.gz, not archive.tar (1).gz.
    static let doubleExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]

    /// A name no file in `folder` has: the site's name made safe (no slash or colon, no leading dot, "download" when
    /// empty), then name (1), name (2)… before the extension.
    public static func destination(for suggested: String, in folder: URL) -> URL {
        var name = WebAppSpec.safeFileName(suggested).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "download" }
        let lower = name.lowercased()
        let ext = doubleExtensions.first { lower.hasSuffix("." + $0) }.map { "." + String(name.suffix($0.count)) }
            ?? ((name as NSString).pathExtension.isEmpty ? "" : "." + (name as NSString).pathExtension)
        let base = String(name.dropLast(ext.count))
        var candidate = name, number = 0
        while FileManager.default.fileExists(atPath: folder.appending(path: candidate).path) {
            number += 1
            candidate = "\(base) (\(number))\(ext)"
        }
        return folder.appending(path: candidate)
    }

    /// What macOS keeps on a file from the web: Gatekeeper asks before opening it, and Finder's Get Info says where it
    /// came from.
    public static func quarantine(agent: String, source: URL?, page: URL?) -> [String: Any] {
        var properties: [String: Any] = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
                                         kLSQuarantineAgentNameKey as String: agent]
        if let source { properties[kLSQuarantineDataURLKey as String] = source }
        if let page { properties[kLSQuarantineOriginURLKey as String] = page }
        return properties
    }

    public static func mark(_ file: URL, with properties: [String: Any]) throws {
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var file = file
        try file.setResourceValues(values)
    }

    /// The row's name for a download that failed before the site answered (offline, refused), so no destination was
    /// ever picked: the link's file name, or "download".
    public static func unansweredName(_ source: URL?) -> String {
        let name = source?.lastPathComponent ?? ""
        return name.isEmpty || name == "/" ? "download" : name
    }

    /// Whether the site sends the response as a file to save (Content-Disposition: attachment).
    public static func isAttachment(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") == true
    }

    public enum State: Equatable, Sendable {
        case progress(received: Int64, total: Int64), done, failed(String)
        /// Saved, but macOS's web-download mark could not be set, so Gatekeeper will not ask before it opens.
        case unmarked(String)
    }

    /// A finished row's buttons, in the row's order.
    public enum Action: String, CaseIterable, Sendable { case open = "Open", showInFinder = "Show in Finder" }

    /// What a row offers: nothing until the file is there, then Open and Show in Finder. A file without its web mark
    /// is only shown, since Gatekeeper would not ask before Open ran it.
    public static func actions(_ state: State) -> [Action] {
        switch state {
        case .done: [.open, .showInFinder]
        case .unmarked: [.showInFinder]
        case .progress, .failed: []
        }
    }

    /// The bar's line: the percent, the size so far when the site gave no total, downloaded, downloaded without its
    /// mark, or why it failed.
    public static func status(name: String, _ state: State) -> String {
        let said = switch state {
        case .failed(let reason): "failed: \(reason)"
        case .done: "downloaded"
        case .unmarked(let reason): "downloaded, not marked as from the web: \(reason)"
        case .progress(let received, let total) where total > 0: "\(min(100, received * 100 / total)) %"
        case .progress(let received, _): ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        }
        return "\(name) — \(said)"
    }
}
