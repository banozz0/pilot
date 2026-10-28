import Testing
@testable import WebApps

/// The Dock badge from the page title (story 187).
@Suite("Web app Dock badge")
struct DockBadgeTests {
    @Test("A leading count, or Gmail's Inbox count, is the badge")
    func counts() {
        #expect(DockBadge.label(fromTitle: "(3) WhatsApp") == "3")
        #expect(DockBadge.label(fromTitle: "(12) Home / X") == "12")
        #expect(DockBadge.label(fromTitle: "Inbox (5) - me@example.com - Gmail") == "5")
        #expect(DockBadge.label(fromTitle: "(99+) Discord") == "99+")
    }

    @Test("No count, a zero, or a number elsewhere in the title clears the badge")
    func none() {
        #expect(DockBadge.label(fromTitle: nil) == nil)
        #expect(DockBadge.label(fromTitle: "WhatsApp") == nil)
        #expect(DockBadge.label(fromTitle: "Inbox - me@example.com - Gmail") == nil)
        #expect(DockBadge.label(fromTitle: "(0) Inbox") == nil)
        #expect(DockBadge.label(fromTitle: "* Slack | general | Team") == nil)
        #expect(DockBadge.label(fromTitle: "Song (2024) - YouTube") == nil)
    }
}
