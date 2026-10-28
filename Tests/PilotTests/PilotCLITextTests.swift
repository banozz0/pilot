import Foundation
@testable import PilotCLI
import Testing

/// The pilot command's text printer (TextAnswer.swift) on answers shaped like Pilot's own, and the text-or-JSON switch.
@Suite("pilot command text")
struct PilotCLITextTests {
    static func json(_ text: String) -> Any { try! JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) }

    static let status = """
    {"line": "Hyper is on (Caps Lock) · workspace 2 · AeroSpace",
     "hyper": {"on": true, "layerKeys": ["capsLock", "rightCommand"], "layerKeyLabel": "Caps Lock or right Command"},
     "switch": {"on": true},
     "permissions": {"accessibility": true, "fullDiskAccess": false, "screenRecording": null},
     "engine": {"keyEngine": true, "secureInput": false, "lastError": null,
                "tiler": {"name": "Pilot", "running": true, "tiling": true}},
     "problems": [{"kind": "fullDiskAccess", "title": "Full Disk Access is off", "detail": "File search can't see Mail", "fix": "pilot open permissions"}],
     "today": {"total": 312, "top": [{"action": "apps.ghostty", "count": 41}, {"action": "tiler.focusLeft", "count": 30}],
               "byHour": [0,0,0,0,0,0,0,3,12,40,41,30,22,18,25,33,28,20,15,10,8,4,2,1]},
     "loginItem": {"wanted": true, "status": "enabled", "problem": null},
     "commandLink": {"state": "linked", "link": "/Users/ada/.local/bin/pilot", "onPath": true, "problem": null},
     "update": {"commit": "8bf69587", "source": "/Users/ada/code/pilot", "canCheck": true, "label": "Up to date", "state": "current"},
     "workspaces": {"focused": "2", "occupied": [{"name": "1", "apps": ["Zen"]}, {"name": "2", "apps": ["Ghostty", "Xcode"]}]}}
    """

    static let clip = """
    {"kept": 812, "reading": 0, "rows": [
      {"id": 9001, "kind": "text", "copied": "2026-10-12T09:14:02Z", "firstCopied": "2026-10-12T09:14:02Z", "copies": 1, "size": 48, "pinned": false, "tags": [], "app": "com.mitchellh.ghostty"},
      {"id": 8990, "kind": "image", "copied": "2026-10-12T08:50:11Z", "firstCopied": "2026-10-11T17:02:40Z", "copies": 3, "size": 220114, "pinned": true, "tags": ["work", "pilot"], "app": "com.apple.Safari", "readingText": true}]}
    """

    static let system = """
    {"sound": {"output": {"devices": [{"id": 91, "name": "MacBook Pro Speakers", "inUse": true}, {"id": 104, "name": "AirPods Pro", "inUse": false}],
                          "inUse": "MacBook Pro Speakers", "volume": 45, "volumeSettable": true, "muted": false},
               "input": {"devices": [{"id": 88, "name": "MacBook Pro Microphone", "inUse": true}], "inUse": "MacBook Pro Microphone", "volume": 70, "volumeSettable": true}},
     "displays": {"screens": [{"id": 1, "name": "Built-in Retina Display", "main": true, "rotation": 0,
                               "frame": {"x": 0, "y": 0, "width": 1512, "height": 982}, "mode": "1512 × 982",
                               "sizes": ["1147 × 745", "1312 × 852", "1512 × 982", "1728 × 1117"], "rates": [60, 120]}]},
     "awake": {"on": false, "state": "off", "for": ""},
     "layouts": [{"id": "com.apple.keylayout.US", "name": "U.S.", "inUse": true}, {"id": "com.apple.keylayout.ABC", "name": "ABC", "inUse": false}],
     "dark": true}
    """

    @Test("A top-level line prints first; scalars align; null and empty are skipped; objects nest")
    func statusReads() {
        let text = readable(Self.json(Self.status))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "Hyper is on (Caps Lock) · workspace 2 · AeroSpace")
        #expect(lines.contains("login item"))
        #expect(lines.contains("  wanted  yes"))
        #expect(lines.contains("  accessibility     yes") && lines.contains("  full disk access  no"))
        #expect(!text.contains("screen recording") && !text.contains("problem ") && !text.contains("last error"))
        #expect(lines.contains("  tiler") && lines.contains("    name     Pilot"))
        #expect(text.contains("by hour  24 values, total 312, max 41"))
        #expect(lines.contains("    apps.ghostty     count 41"))
        #expect(lines.contains("    1  apps Zen") && lines.contains("    2  apps Ghostty, Xcode"))
        #expect(!text.contains("{") && !text.contains("\""))
    }

    @Test("Rows: the id first, trues as their word, falses and empties dropped")
    func clipReads() {
        let text = readable(Self.json(Self.clip))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.prefix(2) == ["kept     812", "reading  0"])
        #expect(lines.contains("  9001  app com.mitchellh.ghostty, copied 2026-10-12T09:14:02Z, copies 1, first copied 2026-10-12T09:14:02Z, kind text, size 48"))
        #expect(lines.contains { $0.hasPrefix("  8990  ") && $0.contains("pinned, reading text, size 220114, tags work, pilot") })
    }

    @Test("Sections nest; a row's object reads inline and its list of objects as a count")
    func systemReads() {
        let text = readable(Self.json(Self.system))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "dark  yes")
        #expect(lines.contains("    in use           MacBook Pro Speakers") && lines.contains("    volume settable  yes"))
        #expect(lines.contains("      91   in use, name MacBook Pro Speakers"))
        #expect(lines.contains { $0.contains("frame (height 982, width 1512, x 0, y 0)") && $0.contains("rates 60, 120") })
        #expect(lines.contains("  com.apple.keylayout.US   in use, name U.S."))
        #expect(lines.contains("  state  off") && !text.contains("for "))
    }

    @Test("A long list is cut with how many more; a top-level list of words prints one a line")
    func longLists() {
        let rows = (1...30).map { ["id": "note-\($0)", "title": "Note \($0)"] }
        let lines = readable(rows).split(separator: "\n").map(String.init)
        #expect(lines.count == 26 && lines.last == "… 5 more (--json for all)")
        #expect(readable(["a", "b"]) == "a\nb")
        #expect(readable(["tags": (1...10).map(String.init)]) == "tags  1, 2, 3, 4, 5, 6, 7, 8, … 2 more")
        #expect(readable(["value": "dark", "key": "look.theme"]) == "key    look.theme\nvalue  dark")
    }

    @Test("Text only at a terminal with no --json, before or after the verb")
    func textOrJSON() {
        #expect(printsText(terminal: true, words: ["status"]))
        #expect(!printsText(terminal: false, words: ["status"]))
        #expect(!printsText(terminal: true, words: ["actions", "--json"]))
        #expect(printsText(terminal: true, words: ["note", "write", "scratch", "--", "--json"]))
        #expect(TextAnswer.words("loginItem") == "login item" && TextAnswer.words("macOS") == "macOS" && TextAnswer.words("cpuPercent") == "cpu percent")
    }
}
