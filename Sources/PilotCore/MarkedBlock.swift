import Foundation

/// A block Pilot owns inside a file someone else owns, between a begin and an end marker line: Ghostty's
/// config (GhosttyConfigBlock). Markers count only as whole lines.
public struct MarkedBlock: Sendable {
    public enum Location: Equatable, Sendable {
        case absent
        /// Line indexes of the begin and end markers.
        case at(begin: Int, end: Int)
        /// A marker doubled, missing or out of order: a hand edit broke the block.
        case broken
    }

    public let begin: String, end: String

    public init(begin: String, end: String) { self.begin = begin; self.end = end }

    public func locate(_ lines: [String]) -> Location {
        let begins = lines.indices.filter { lines[$0] == begin }, ends = lines.indices.filter { lines[$0] == end }
        switch (begins.first, ends.first) {
        case (nil, nil): return .absent
        case (let b?, let e?) where begins.count == 1 && ends.count == 1 && b < e: return .at(begin: b, end: e)
        default: return .broken
        }
    }

    /// `file` with `block` appended after one blank line.
    public static func appending(_ block: String, to file: String) -> String {
        file + (file.isEmpty ? "" : file.hasSuffix("\n") ? "\n" : "\n\n") + block + "\n"
    }

    /// `file` without the block and the blank line `appending` put before it; nil when there is no block or it is broken.
    public func removing(from file: String) -> String? {
        var lines = file.components(separatedBy: "\n")
        guard case .at(let b, let e) = locate(lines) else { return nil }
        lines.removeSubrange(b...e)
        if b > 0, lines[b - 1].isEmpty, lines[b...].allSatisfy(\.isEmpty) { lines.remove(at: b - 1) }
        return lines.joined(separator: "\n")
    }
}

/// A file someone else owns, rewritten in place: truncated and written through any symlink, so the link (a dotfiles
/// one) and the inode stay. Never a renamed temp file.
public enum InPlaceFile {
    public static func overwrite(_ path: String, with text: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Reads the file, changes its text and writes it back in place when it differs, first copying the old text once
    /// to `backup` when one is named and none exists yet. Returns whether the file changed.
    @discardableResult
    public static func update(_ path: String, backup: String? = nil, _ change: (String) throws -> String) throws -> Bool {
        let previous = try String(contentsOfFile: path, encoding: .utf8)
        let next = try change(previous)
        guard next != previous else { return false }
        if let backup, !FileManager.default.fileExists(atPath: backup) {
            try FileManager.default.createDirectory(atPath: (backup as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try previous.write(toFile: backup, atomically: true, encoding: .utf8)
        }
        try overwrite(path, with: next)
        return true
    }
}
