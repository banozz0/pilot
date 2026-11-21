import Foundation

/// The video calls an event can link to, in its URL, location or notes (spec launcher-best T5, Join the next meeting).
/// Its name and `find(in:)` mirror branch smart-nudges' finder, so the two become one when that branch lands.
public enum MeetingLink {
    /// Each call service's hosts, a subdomain counted (`us02web.zoom.us`), and its name.
    static let services: [(hosts: [String], name: String)] = [
        (["zoom.us", "zoom.com"], "Zoom"), (["meet.google.com"], "Meet"), (["teams.microsoft.com", "teams.live.com"], "Teams"),
        (["webex.com"], "Webex"), (["facetime.apple.com"], "FaceTime"), (["whereby.com"], "Whereby"), (["meet.jit.si"], "Jitsi"),
        (["chime.aws"], "Chime"), (["gotomeeting.com", "meet.goto.com"], "GoTo"),
    ]
    static let hosts = services.flatMap(\.hosts)

    /// The first video-call link in `texts`; nil when none links to one.
    public static func find(in texts: [String?]) -> URL? {
        for text in texts.compactMap(\.self) {
            for match in text.matches(of: /https?:\/\/[^\s<>"')\]]+/) {
                guard let url = URL(string: String(match.output)), service(of: url) != nil else { continue }
                return url
            }
        }
        return nil
    }

    /// The service a call link goes to, "Zoom"; nil for any other link.
    public static func service(of url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        return services.first { $0.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }?.name
    }

    /// How long before its start a call is offered: from then to its end.
    public static let lead: TimeInterval = 10 * 60

    /// The call to join at `now`: a timed event with a call link, from `lead` before its start to its end, the soonest
    /// starting (a call just begun over one still running).
    public static func joinable(_ events: [ClockEvent], at now: Date) -> ClockEvent? {
        events.filter { !$0.allDay && $0.call != nil && $0.start.addingTimeInterval(-lead) <= now && now < $0.end }
            .max { $0.start < $1.start }
    }

    /// The menu's Join row for `event`: "Join Design sync", "Zoom · in 4 min"; Return opens the link as a web link does
    /// (a web app, else the browser, which hands a Zoom or Teams link to its app). Never a pick: it leads the root only
    /// while the call is near.
    public static func row(_ event: ClockEvent, at now: Date) -> MenuEntry? {
        guard let call = event.call else { return nil }
        let title = event.title.trimmingCharacters(in: .whitespaces)
        var row = MenuEntry(title: title.isEmpty ? "Join the call" : "Join \(title)", target: .action(AppLink.web(url: call.absoluteString).id),
                            detail: [service(of: call), when(event.start, at: now)].compactMap(\.self).joined(separator: " · "),
                            keywords: "join meeting call", icon: .glyph("video.fill", .accent))
        row.leadsRoot = true
        return row
    }

    /// "in 4 min", "now", "started 6 min ago".
    static func when(_ start: Date, at now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds >= 60 { return "in \(Int((seconds / 60).rounded(.up))) min" }
        if seconds > -60 { return "now" }
        return "started \(Int((-seconds / 60).rounded(.down))) min ago"
    }
}
