import Foundation
import Testing
@testable import PilotCore

/// The per-install token a pilot:// link carries to run or bind a command (card agent-bo-95422763, Sven's option B).
@Suite("Link token")
struct LinkTokenTests {
    static func token() -> LinkToken {
        LinkToken(url: FileManager.default.temporaryDirectory.appending(path: "pilot-link-\(UUID().uuidString)/Pilot/link-token"))
    }

    @Test("The token is made once: 64 hex characters in a file only its owner can read, the same on every read")
    func made() throws {
        let t = Self.token()
        let value = try t.value()
        #expect(value.count == 64 && value.allSatisfy(\.isHexDigit))
        #expect(try t.value() == value && LinkToken(url: t.url).value() == value)
        let mode = try FileManager.default.attributesOfItem(atPath: t.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try Self.token().value() != value)
    }

    @Test("An emptied file gets a new token rather than letting an empty one through")
    func emptied() throws {
        let t = Self.token()
        _ = try t.value()
        try Data().write(to: t.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: t.url.path)
        #expect(try t.value().count == 64)
        #expect(try FileManager.default.attributesOfItem(atPath: t.url.path)[.posixPermissions] as? Int == 0o600)
        #expect(!t.allows("drive.shell:true", token: ""))
    }

    @Test("A link runs or binds a shell, picker, Shortcuts, drive URL, keystroke, non-web app link, radio, power or session action only with the token")
    func risky() throws {
        let t = Self.token()
        let pick = DriveRoute.picker(title: nil, list: "ls", run: "open $1").id
        let token = try t.value()
        for id in ["drive.shell:touch /tmp/pilot-link-probe", "drive.url:shottr://grab/area", "drive.shortcut:Morning", pick,
                   "apps.web:pilot://run?action=drive.shell%3Atouch%20/tmp/x", "apps.url:app.zen-browser.zen:shortcuts://x",
                   // A keystroke goes into whichever app the link names (&app=Terminal), so links could type a command key by key.
                   "drive.key:cmd+T", "drive.key:return",
                   // Any web page could cut the network, a radio, the power or the session (T52).
                   "system.wifi", "system.bluetooth", "system.shutDown", "system.restart", "system.sleep", "system.logOut",
                   "system.lock", "system.lockKeyboard"] {
            #expect(!t.allows(id, token: nil), "\(id)")
            #expect(!t.allows(id, token: "wrong"), "\(id)")
            #expect(!t.allows(id, token: String(token.dropLast())), "\(id)")
            #expect(t.allows(id, token: token), "\(id)")
        }
    }

    @Test("Pilot's own actions, apps, web pages and menu items need no token")
    func safe() {
        let t = Self.token()
        for id in ["windows.close", "apps.open:com.apple.Notes", "apps.web:https://chatgpt.com",
                   "apps.url:app.zen-browser.zen:https://claude.ai", "drive.menu:com.apple.finder:File > New Finder Window"] {
            #expect(t.allows(id, token: nil), "\(id)")
        }
        #expect(!FileManager.default.fileExists(atPath: t.url.path), "a safe link does not need the file")
    }

    @Test("A press link, which can fire any bind, needs the token whatever it presses")
    func press() throws {
        let t = Self.token()
        #expect(!t.matches(nil) && !t.matches("") && !t.matches("wrong"))
        #expect(t.matches(try t.value()))
    }

    @Test("A logged link shows token=<redacted>, never the token, also inside a link carried in another link")
    func redacted() {
        let token = String(repeating: "ab", count: 32)
        #expect(LinkToken.redact("pilot://bar?move=cpu&token=\(token)&side=left") == "pilot://bar?move=cpu&token=<redacted>&side=left")
        #expect(LinkToken.redact("move=cpu&token=\(token)") == "move=cpu&token=<redacted>")
        #expect(!LinkToken.redact("pilot://run?action=apps.web%3Apilot%3A%2F%2Fpress%3Fkey%3Dk%26token%3D\(token)").contains(token))
        #expect(!LinkToken.redact("apps.web:pilot://press?key=k&TOKEN=\(token)").contains(token))
        #expect(!LinkToken.redact("drive.url:pilot%3A%2F%2Fpress%253Fkey%253Dk%2526token%253D\(token)").contains(token))
        #expect(!LinkToken.redact("token=\" \(token)\"").contains(token))
        #expect(LinkToken.redact("pilot://observers") == "pilot://observers")
    }

    /// Lane 1 found the full token in the bar link log line on 2026-10-08: a log line that prints a link or its
    /// query goes through LinkToken.redact, so `log stream` and sysdiagnose never carry it. Each interpolation is checked
    /// on its own: one redacted value on a line once let a raw action id beside it pass (Binds' refused-bind line, P5).
    @Test("Every log line that prints a link, its query or an action id from a bind or link redacts the token")
    func logsRedact() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources").standardized
        let logCall = #"\b\w*[lL]og\.(notice|error|info|debug|warning|fault|log)\("#
        var leaks: [String] = []
        for case let file as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
            for (n, line) in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.range(of: logCall, options: .regularExpression) != nil
                && Self.interpolations(line).contains(where: { Self.leaks($0, namesActions: Self.namesActions.contains(file.lastPathComponent)) }) {
                leaks.append("\(file.lastPathComponent):\(n + 1)")
            }
        }
        #expect(leaks == [], "these log a link or action id without LinkToken.redact: \(leaks)")
    }

    @Test("The log guard flags each raw interpolation, even beside a redacted one, and passes redacted and private ones")
    func logGuard() {
        func flagged(_ line: Substring) -> Bool { Self.interpolations(line).contains { Self.leaks($0, namesActions: true) } }
        #expect(flagged(#"log.error("binds: \(r.action, privacy: .public) refused, \(LinkToken.redact(r.takenBy), privacy: .public) holds it")"#))
        #expect(flagged(#"log.notice("binds: \(old, privacy: .public) renamed \(LinkToken.redact(new), privacy: .public)")"#))
        #expect(flagged(#"log.notice("switched off: \(plan.switchedOff.joined(separator: ", "), privacy: .public)")"#))
        #expect(flagged(#"log.notice("link \(url.absoluteString, privacy: .public)")"#))
        #expect(!flagged(#"log.error("binds: \(LinkToken.redact(r.action), privacy: .public) on \(r.trigger.label, privacy: .public)")"#))
        #expect(!flagged(#"log.notice("binds: \(self.store.binds.count) loaded, preset \(new.id, privacy: .public)")"#))
        #expect(!flagged(#"log.notice("run \(action, privacy: .private)")"#))
    }

    /// The files where binds and links name actions: there the action id itself is checked, as it can carry a link of
    /// its own (drive.url:pilot://…).
    static let namesActions: Set = ["Engine.swift", "Binds.swift", "MenuPanel.swift"]

    /// Each `\(…)` in `line`, as written inside the parentheses.
    static func interpolations(_ line: Substring) -> [String] {
        var found: [String] = [], rest = line[...]
        while let open = rest.range(of: "\\(") {
            var depth = 1, end = open.upperBound
            while end < rest.endIndex, depth > 0 {
                if rest[end] == "(" { depth += 1 } else if rest[end] == ")" { depth -= 1 }
                if depth > 0 { end = rest.index(after: end) }
            }
            found.append(String(rest[open.upperBound..<end]))
            rest = end < rest.endIndex ? rest[rest.index(after: end)...] : ""
        }
        return found
    }

    /// Whether one interpolation can print the token: a URL or its query, a drive URL (raw), or, where actions are
    /// named, an action id or a list of them, unless it goes through LinkToken.redact or is logged private.
    static func leaks(_ interpolation: String, namesActions: Bool) -> Bool {
        let value = interpolation.replacingOccurrences(of: #",\s*privacy:\s*\.(\w+)$"#, with: "", options: .regularExpression)
        if interpolation.range(of: #"privacy:\s*\.(private|sensitive)"#, options: .regularExpression) != nil || value.hasPrefix("LinkToken.redact(") { return false }
        if value.range(of: #"\.absoluteString\b|\burl\.query\b|^raw$"#, options: .regularExpression) != nil { return true }
        let actionID = #"^(self\.)?(r\.)?(id|action|other|old|new|left|moved|takenBy|key|press\.line)$|^entry\.frecencyKey|switchedOff"#
        return namesActions && value.range(of: actionID, options: .regularExpression) != nil
    }
}
