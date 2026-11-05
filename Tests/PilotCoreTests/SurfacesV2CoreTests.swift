import Foundation
import Testing
@testable import PilotCore

/// Surfaces v2 (design https://claude.ai/artifact/Cd9woPtPXQ4HJWKUYXRSYh, SPEC story 165, ADR 0010 amended): every new
/// field decodes leniently, a v1 answer reads exactly as before, and each extension's bar item is placed on its own.
@Suite("Surfaces v2 core")
struct SurfacesV2CoreTests {
    // MARK: P1, gauges and placement

    @Test("A row's picture (Now playing's artwork): base64 decoded, kept up to 64 KB, a broken or oversize one dropped, the row kept")
    func rowImage() throws {
        let dot = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        let big = Data(count: Extension.Item.largestImage + 1).base64EncodedString()
        let line = #"{"type":"blocks","blocks":[{"type":"list","items":[{"title":"Song","subtitle":"Artist","icon":"🎵","image":"\#(dot)"},{"title":"Big","image":"\#(big)"},{"title":"Junk","image":"not base64!"},{"title":"None","image":7}]}]}"#
        guard case .blocks(let blocks) = ExtensionRun.surfaceAnswer(line, kind: .popover), case .list(_, let items, _) = blocks.0.first else {
            Issue.record("no list"); return
        }
        #expect(items.map(\.title) == ["Song", "Big", "Junk", "None"])
        #expect(items[0].image == Data(base64Encoded: dot) && items[0].icon == "🎵")
        #expect(items.dropFirst().allSatisfy { $0.image == nil })
    }

    @Test("A bar line's gauges: three at most, labels cut to five characters, two meters each held to 0-100, the broken skipped")
    func gauges() throws {
        let line = #"{"type":"bar","text":"","tone":"warn","gauges":[{"label":"Claude","meters":[34,25,99]},{"label":"X","meters":[-5,167],"tone":"alert"},{"label":"no meters","meters":[]},{"meters":"nope"},{"label":"G","meters":[1]},{"label":"H","meters":[2]}]}"#
        guard case .bar(let answer) = ExtensionRun.surfaceAnswer(line, kind: .bar) else { Issue.record("no bar"); return }
        #expect(answer.gauges == [Extension.Gauge(label: "Claud", meters: [34, 25]), Extension.Gauge(label: "X", meters: [0, 100], tone: .alert),
                                  Extension.Gauge(label: "G", meters: [1])])
        #expect(answer.text.isEmpty && answer.shows, "gauges alone show the item")
        #expect(answer.loudest == .alert && Extension.BarAnswer(text: "x", tone: .fine).loudest == .fine && Extension.BarAnswer(text: "x").loudest == nil)
        #expect(ExtensionRun.surfaceAnswer(#"{"type":"bar","text":"ok","gauges":"wrong"}"#, kind: .bar) == .bar(Extension.BarAnswer(text: "ok")))
    }

    @Test("A v1 bar line and page answer read exactly as before")
    func v1Unchanged() {
        #expect(ExtensionRun.surfaceAnswer(#"{"type":"bar","text":"AI 52%","tone":"warn","blocks":[{"type":"markdown","text":"hi"}]}"#, kind: .bar)
                == .bar(Extension.BarAnswer(text: "AI 52%", tone: .warn, blocks: [.markdown("hi")])))
        #expect(ExtensionRun.surfaceAnswer(#"{"type":"blocks","blocks":[{"type":"meter","label":"Week","percent":25,"note":"Thu"}]}"#, kind: .page)
                == .blocks([.meter(.init(label: "Week", percent: 25, note: "Thu"))]))
    }

    @Test("An extension's item is on in the macOS menu bar until placed; in the top bar it is its own slot, put last on the right when it first joins")
    func placement() throws {
        var s = BarSettings.defaults
        #expect(s.extensionEntry("ai") == ExtensionBarEntry(id: "ai", on: true, placement: .menuBar))
        #expect(s.shows(extension: "ai", in: .menuBar, topBarOn: true) && !s.shows(extension: "ai", in: .topBar, topBarOn: true))
        s.toggle(extension: "ai", in: .topBar)
        #expect(s.extensionEntry("ai").placement == .both && s.isOn(extension: "ai", in: .both))
        #expect(!s.shows(extension: "ai", in: .menuBar, topBarOn: true) && s.shows(extension: "ai", in: .menuBar, topBarOn: false),
                "both leaves the macOS menu bar while the top bar is on, as a built-in item does")
        s.toggle(extension: "ai", in: .menuBar)
        #expect(s.extensionEntry("ai").placement == .topBar && s.shows(extension: "ai", in: .topBar, topBarOn: true))
        #expect(s.slots(in: .topBar, topBarOn: true, side: .right).last?.item == .extension("ai"), "a new one lands last (spec pilot-1.1 T50)")
        s.set(.extensions, on: false)
        #expect(s.shows(extension: "ai", in: .topBar, topBarOn: true), "the old Extensions item no longer gates them")
        s.toggle(extension: "ai", in: .topBar)
        #expect(!s.extensionEntry("ai").on && !s.shows(extension: "ai", in: .menuBar, topBarOn: false))
        #expect(!s.slots(in: .topBar, topBarOn: true).contains { $0.item == .extension("ai") })
        s.place(.kind(.timer), on: .left, at: 1)
        s.toggle(extension: "ai", in: .topBar)
        s.toggle(extension: "bi", in: .topBar)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .right).suffix(2).map(\.item) == [.extension("ai"), .extension("bi")],
                "one back keeps its place; the next new one lands after it")
        let read = try JSONDecoder().decode(BarSettings.self, from: JSONEncoder().encode(s))
        #expect(read == s && read.extensionItems.map(\.id) == ["ai", "bi"] && read.extensionEntry("ai").placement == .topBar)
        // A Pilot from before T50 skips the extensions' own entries, never drawing its Extensions slot twice.
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        let kinds = (saved["entries"] as! [[String: Any]]).compactMap { $0["kind"] as? String }
        #expect(kinds.filter { $0 == "extensions" }.count == 1 && kinds.filter { $0 == "extension" }.count == 2)
    }

    @Test("A layout saved before Surfaces v2 reads with no extension placed; a broken entry is skipped")
    func savedBefore() throws {
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BarSettings.defaults)) as! [String: Any]
        old["extensionItems"] = nil
        #expect(try JSONDecoder().decode(BarSettings.self, from: JSONSerialization.data(withJSONObject: old)) == .defaults)
        old["extensionItems"] = [["id": "ok", "on": false, "placement": "both"], ["id": "bad", "placement": "moon"]]
        let read = try JSONDecoder().decode(BarSettings.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(read.extensionItems == [ExtensionBarEntry(id: "ok", on: false, placement: .both)])

        // Saved before T50: the top bar drew every extension's item in one Extensions slot, by title. Each gets its own
        // slot where that slot was, in that order, not the order they were placed in; one in the menu bar alone gets none.
        var grouped = BarSettings.defaults
        grouped.move(.extensions, to: grouped.entries.firstIndex { $0.kind == .timer }!)
        var before = try JSONSerialization.jsonObject(with: JSONEncoder().encode(grouped)) as! [String: Any]
        before["extensionItems"] = [["id": "zed", "on": true, "placement": "topBar"], ["id": "menu", "on": true, "placement": "menuBar"],
                                    ["id": "apple", "on": true, "placement": "both"]]
        let data = try JSONSerialization.data(withJSONObject: before)
        let decoder = JSONDecoder()
        decoder.userInfo[BarSettings.extensionOrder] = { @Sendable in ["apple", "menu", "zed"] }
        let split = try decoder.decode(BarSettings.self, from: data)
        #expect(split.slots(in: .topBar, topBarOn: true, side: .right).map(\.item)
                == [.kind(.otherApps), .kind(.group), .extension("apple"), .extension("zed"), .kind(.timer)])
        #expect(try JSONDecoder().decode(BarSettings.self, from: JSONEncoder().encode(split)) == split, "read again, nothing moves")
        #expect(try JSONDecoder().decode(BarSettings.self, from: data).slots(in: .topBar, topBarOn: true, side: .right).map(\.item)
                .filter { $0.kind == nil } == [.extension("zed"), .extension("apple")], "with no titles, the order they were placed in")
        // Its Extensions slot off, they drew nowhere: they leave the top bar, the menu bar keeps the one there too.
        var entries = before["entries"] as! [[String: Any]]
        entries[entries.firstIndex { $0["kind"] as? String == "extensions" }!]["on"] = false
        before["entries"] = entries
        let hidden = try decoder.decode(BarSettings.self, from: JSONSerialization.data(withJSONObject: before))
        #expect(!hidden.slots(in: .topBar, topBarOn: true).contains { $0.item.kind == nil })
        #expect(hidden.extensionEntry("apple") == ExtensionBarEntry(id: "apple", on: true, placement: .menuBar) && !hidden.extensionEntry("zed").on)
    }

    @Test("Each extension in the top bar is its own target with its own click, and says its gauges in the tooltip")
    func faces() {
        let face = ExtensionBarFace(id: "ai", title: "AI usage", answer: Extension.BarAnswer(text: "", gauges: [.init(label: "C", meters: [34, 25])]))
        #expect(BarPart.extensionItem(face).click == .extension("ai") && face.tooltip == "AI usage · C 34% 25%")
    }

    // MARK: P2, popover, section, countdown

    @Test("A section holds its blocks one level deep: a section in it is skipped, an empty untitled one dropped; a meter keeps its reset time")
    func sections() {
        let line = #"{"type":"blocks","blocks":[{"type":"section","title":"Claude","subtitle":"Max","blocks":[{"type":"meter","label":"Session","percent":34,"resetsAt":1791628800},{"type":"section","title":"deep","blocks":[{"type":"markdown","text":"x"}]},{"type":"chart"}]},{"type":"section","blocks":[]},{"type":"section","title":"Codex"}]}"#
        let answer = ExtensionRun.surfaceAnswer(line, kind: .popover)
        #expect(answer == .blocks([
            .section(title: "Claude", subtitle: "Max", blocks: [.meter(.init(label: "Session", percent: 34, resetsAt: Date(timeIntervalSince1970: 1_791_628_800)))]),
            .section(title: "Codex", subtitle: nil, blocks: []),
        ]))
        #expect(ExtensionRun.surfaceAnswer(line, kind: .bar) == .error("sent no bar line"), "a popover answers blocks, a bar a bar line")
    }

    @Test("A meter's mark is held to 0-100 and its value replaces the percent; a wrong type of either is ignored")
    func meterMark() {
        let line = #"{"type":"blocks","blocks":[{"type":"meter","label":"Session","percent":94,"mark":54,"value":"94% left"},{"type":"meter","label":"Week","percent":71,"mark":140},{"type":"meter","label":"x","percent":1,"mark":"half","value":3}]}"#
        #expect(ExtensionRun.surfaceAnswer(line, kind: .popover) == .blocks([
            .meter(.init(label: "Session", percent: 94, mark: 54, value: "94% left")), .meter(.init(label: "Week", percent: 71, mark: 100)),
            .meter(.init(label: "x", percent: 1)),
        ]))
    }

    @Test("A meter's countdown: today's time and what is left, tomorrow's, a weekday's past a day, and the time it reset once past")
    func countdown() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB"), now = Date(timeIntervalSince1970: 1_791_631_080)   // Sat 10 Oct 2026 11:18 UTC
        func says(_ minutes: Double) -> String {
            Extension.Block.Meter.countdown(to: now.addingTimeInterval(minutes * 60), now: now, calendar: calendar, locale: locale)
        }
        #expect(says(82) == "resets 12:40 · in 1 h 22 min")
        #expect(says(0.5) == "resets 11:18 · in under a minute" && says(5) == "resets 11:23 · in 5 min")
        #expect(says(13 * 60 + 5) == "resets tomorrow 0:23 · in 13 h 5 min")
        #expect(says(5 * 1440 + 8 * 60 + 42) == "resets Thu 20:00 · in 5 d 8 h")
        #expect(says(-3) == "reset at 11:15")
    }

    // MARK: CodexBar's look: mark tone, asides, provider gauges, reset label

    @Test("A meter's mark tone and a section's asides read; a wrong type or an unknown tone is none")
    func markToneAndAsides() {
        let line = #"{"type":"blocks","blocks":[{"type":"section","title":"Claude","subtitle":"Updated 08:47","aside":"sven@example.com","asideNote":"Max 20x","blocks":[{"type":"meter","label":"Session","percent":66,"mark":71,"markTone":"fine","value":"66% left"},{"type":"meter","label":"Weekly","percent":50,"mark":64,"markTone":"pink"}]},{"type":"section","title":"Codex","aside":3,"blocks":[{"type":"meter","label":"x","percent":1,"markTone":2}]}]}"#
        #expect(ExtensionRun.surfaceAnswer(line, kind: .popover) == .blocks([
            .section(title: "Claude", subtitle: "Updated 08:47", aside: "sven@example.com", asideNote: "Max 20x", blocks: [
                .meter(.init(label: "Session", percent: 66, mark: 71, value: "66% left", markTone: .fine)), .meter(.init(label: "Weekly", percent: 50, mark: 64)),
            ]),
            .section(title: "Codex", subtitle: nil, blocks: [.meter(.init(label: "x", percent: 1))]),
        ]))
    }

    @Test("Q138: a meter's and a section's help, a section's provider icon, a note, and a links row read; an unknown icon or an empty link is dropped")
    func calmBlocks() {
        let line = #"{"type":"blocks","blocks":[{"type":"section","title":"Claude","icon":"claude","help":"sven@example.com","aside":"sven","asideNote":"Max 20x","blocks":[{"type":"meter","label":"Weekly","percent":85,"mark":92,"markTone":"alert","help":"7% in deficit"},{"type":"note","icon":"reset","text":"2 reset credits","aside":"next expires 29 Oct","help":"Expire 29 Oct 19:35"},{"type":"note","icon":"rocket","text":"plain"},{"type":"note","text":""}]},{"type":"section","title":"Codex","icon":"mistral","subtitle":"not asked","blocks":[]},{"type":"links","items":[{"title":"Codex","tone":"warn","word":"minor","help":"Partial","actions":[{"type":"open","url":"https://status.openai.com/"}]},{"icon":"chart","actions":[{"type":"open","url":"a"},{"type":"open","url":"b"}]},{"icon":"rocket","actions":[{"type":"open","url":"c"}]},{"title":"none","actions":[]}]},{"type":"links","items":[]}]}"#
        #expect(ExtensionRun.surfaceAnswer(line, kind: .popover) == .blocks([
            .section(title: "Claude", subtitle: nil, aside: "sven", asideNote: "Max 20x", blocks: [
                .meter(.init(label: "Weekly", percent: 85, mark: 92, markTone: .alert, help: "7% in deficit")),
                .note(.init(text: "2 reset credits", aside: "next expires 29 Oct", help: "Expire 29 Oct 19:35", icon: "reset")),
                .note(.init(text: "plain")),
            ], icon: .claude, help: "sven@example.com"),
            .section(title: "Codex", subtitle: "not asked", blocks: []),
            .links([
                Extension.Block.Link(title: "Codex", tone: .warn, word: "minor", help: "Partial", actions: [.open("https://status.openai.com/")])!,
                Extension.Block.Link(icon: "chart", actions: [.open("a"), .open("b")])!,
            ]),
        ]))
        #expect(Extension.Block.Link(icon: "chart", actions: [.open("a")])?.label == "Open", "no help or title: its first action's label")
    }

    @Test("A gauge may be a provider glyph and a text of at most six characters, no meters; an unknown glyph alone is dropped")
    func providerGauges() throws {
        let line = #"{"type":"bar","text":"","gauges":[{"icon":"claude","text":"66%"},{"icon":"openai","text":" 15% left ","tone":"warn","meters":[15]},{"icon":"mistral"},{"text":""}]}"#
        guard case .bar(let answer) = ExtensionRun.surfaceAnswer(line, kind: .bar) else { Issue.record("no bar"); return }
        #expect(answer.gauges == [Extension.Gauge(icon: .claude, text: "66%"), Extension.Gauge(meters: [15], tone: .warn, icon: .openai, text: "15% le")])
        #expect(answer.shows && ExtensionBarFace(id: "ai", title: "AI usage", answer: answer).tooltip == "AI usage · Claude 66% · OpenAI 15% 15% le")
        #expect(ExtensionRun.surfaceAnswer(#"{"type":"bar","text":"","gauges":[{"label":"C","text":"9%"}]}"#, kind: .bar)
                == .bar(Extension.BarAnswer(text: "", gauges: [.init(label: "C", text: "9%")])), "a label and a text are enough")
    }

    @Test("A popover meter's reset label: today's time, tomorrow's, a weekday's up to six days on, then the date; always 24-hour")
    func resetLabel() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_631_080)   // Sat 10 Oct 2026 11:18 UTC
        func says(_ minutes: Double, _ locale: String = "en_GB") -> String {
            Extension.Block.Meter.resets(at: now.addingTimeInterval(minutes * 60), now: now, calendar: calendar, locale: Locale(identifier: locale))
        }
        #expect(says(31) == "Resets 11:49" && says(12 * 60 + 41) == "Resets 23:59")
        #expect(says(21 * 60 + 42) == "Resets tomorrow 09:00")
        #expect(says(5 * 1440 + 8 * 60 + 41) == "Resets Thu 19:59" && says(5 * 1440 + 8 * 60 + 41, "en_US") == "Resets Thu 19:59")
        #expect(says(6 * 1440) == "Resets Fri 11:18" && says(7 * 1440) == "Resets 17 Oct 11:18")
        #expect(says(10 * 1440 + 8 * 60 + 42) == "Resets 20 Oct 20:00")
    }

    @Test("A popover's run message names the popover and hands on the push's context; a menu run still names no surface")
    func popoverMessage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"id":"demo","title":"Demo","icon":"🧪","commands":[{"name":"chat","title":"Chat","mode":"no-view","run":"go"}]}"#.utf8)
            .write(to: dir.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "go").path)
        let command = try Extension(folder: dir).commands[0]
        let sent = try JSONDecoder().decode(JSONValue.self, from: ExtensionRun.message(command, context: .object(["ref": .string("s1")]), surface: .popover, inputs: .sample))
        guard case .object(let fields) = sent else { Issue.record("not an object"); return }
        #expect(fields["surface"] == .string("popover") && fields["context"] == .object(["ref": .string("s1")]) && fields["command"] == .string("chat"))
    }
}

