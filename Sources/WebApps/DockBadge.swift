import Foundation

/// The web app's Dock badge from the page title (story 187): sites put their unread count in the title, as WhatsApp's
/// "(3) WhatsApp" or Gmail's "Inbox (3) - … - Gmail". Only a count at the start, or Gmail's Inbox count, is read, so a
/// title like "Song (2024) - YouTube" never badges.
public enum DockBadge {
    /// The badge's text, or nil for none (nil clears it; an empty label would still draw).
    public static func label(fromTitle title: String?) -> String? {
        guard let title, let match = title.firstMatch(of: /^(?:Inbox )?\((\d+)(\+?)\)/) else { return nil }
        guard let count = Int(match.1), count > 0 else { return nil }
        return "\(count)\(match.2)"
    }
}
