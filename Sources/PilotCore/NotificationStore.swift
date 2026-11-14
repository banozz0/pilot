import Foundation

/// The drawer across a relaunch: ~/Library/Application Support/Pilot/notifications.json, readable by Sven's account only.
/// Holds what a drawer row shows (app, title, subtitle, body, time) and the unread count, at most
/// `NotificationFeed.drawerLimit` rows; deleted when the setting goes off.
public struct NotificationStore: Sendable {
    public static let standard = NotificationStore(url: PilotFolder.support.appending(path: "notifications.json"))
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Nil when nothing is saved or the file doesn't read; a bad file is dropped rather than shown.
    public func load() -> NotificationFeed.Saved? {
        guard let saved = try? JSONFile<NotificationFeed.Saved>(url: url).load(or: .init()) else { delete(); return nil }
        return saved.entries.isEmpty && saved.unread == 0 ? nil : saved
    }

    public func save(_ saved: NotificationFeed.Saved) throws {
        guard !saved.entries.isEmpty || saved.unread > 0 else { return delete() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(encoder.encode(saved), to: url, mode: 0o600)
    }

    public func delete() { try? FileManager.default.removeItem(at: url) }
}
