import Foundation
import PilotCore

/// The folders `pilot widget new` and the builder write (T23, T24): a blocks widget fed by a small shell program, or an
/// HTML page fed by a reading. Each is an ordinary widget folder that passes `pilot widget check`; nothing here writes
/// trust: a folder becomes made here only through `pilot widget install`'s Allow or the builder's own Save.
enum WidgetTemplates {
    enum Kind: String, CaseIterable { case blocks, html }

    /// Pilot's widget look kit, the designer's Packaging/widgets/kit (Q694), in the app's Resources as widgets/kit: these
    /// files, whose pilot-kit.css says how to use them; nil while the app ships none. A page is served from its own folder
    /// alone, so `pilot widget new --html` copies them beside index.html, as every desk widget carries them.
    static let kitFiles = ["pilot-kit.css", "pilot-kit.js"]
    static var kit: URL? { BundledJSON.url("pilot-kit", "css", in: "widgets/kit")?.deletingLastPathComponent() }

    /// `pilot widget new`'s folder, which must not exist yet: the template's files and, for a page, the kit beside them
    /// when the app has one; nothing is left behind when any of it fails. True when the kit went in.
    static func make(id: String, title: String, kind: Kind, in folder: URL) throws -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: folder.path]) }
        let kit = kind == .html ? Self.kit : nil
        do {
            try write(files(id: id, title: title, kind: kind, kit: kit != nil), to: folder)
            if let kit { for name in kitFiles { try fm.copyItem(at: kit.appending(path: name), to: folder.appending(path: name)) } }
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return kit != nil
    }

    /// The files of a new widget: widget.json and what it runs or draws, by path; an HTML page is built on the kit when
    /// `kit` (copied beside it by `make`).
    static func files(id: String, title: String, kind: Kind, kit: Bool = false) -> [String: (text: String, executable: Bool)] {
        switch kind {
        case .blocks:
            return [Widget.manifestName: (manifest(["id": .string(id), "title": .string(title), "icon": .string("🧩"), "version": .string("1.0"),
                                                    "description": .string("Made with pilot widget new: edit feed.sh."), "draw": .string("blocks"),
                                                    "data": .object(["command": .array([.string("./feed.sh")]), "every": .number(60)]),
                                                    "size": .object(["width": .number(240), "height": .number(160)])]), false),
                    "feed.sh": (feed, true)]
        case .html:
            return [Widget.manifestName: (manifest(["id": .string(id), "title": .string(title), "icon": .string("🧩"), "version": .string("1.0"),
                                                    "description": .string("Made with pilot widget new: edit index.html."), "draw": .string("html"),
                                                    "data": .object(["reading": .string("clock")]),
                                                    "size": .object(["width": .number(260), "height": .number(160)])]), false),
                    Widget.entryName: (page(title: title, kit: kit), false)]
        }
    }

    /// widget.json as people write it: sorted keys, indented.
    static func manifest(_ fields: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(JSONValue.object(fields))) ?? Data(), as: UTF8.self) + "\n"
    }

    /// Writes `files` into `folder`, which must not exist yet.
    static func write(_ files: [String: (text: String, executable: Bool)], to folder: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: folder.path]) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, file) in files {
            let url = folder.appending(path: path)
            try Data(file.text.utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: file.executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
    }

    /// The blocks template's program: reads Pilot's message from stdin, prints one blocks answer.
    static let feed = """
        #!/bin/sh
        # Pilot writes one JSON line on stdin, {"type":"widget","settings":{…},"size":{…}}, and closes it.
        # Print one JSON object: {"type":"blocks","blocks":[…]} (stats, meter, hero, list, markdown, strip, note)
        # or {"type":"data","data":{…}} for a page. It runs every `every` seconds while the widget shows, stopped after 5 s.
        cat > /dev/null
        now=$(/bin/date +%H:%M)
        printf '{"type":"blocks","blocks":[{"type":"hero","value":"%s","place":"Edit feed.sh"}]}\\n' "$now"

        """

    /// The HTML template's page, which shows the clock reading it is fed: on the kit (its panel, header and hero, its
    /// theme from Pilot) when `kit`, else a dark panel of its own. `title` is plain (Widget.isTitle), but escaped for HTML.
    static func page(title: String, kit: Bool) -> String {
        let heading = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        guard !kit else {
            return """
                <!doctype html>
                <meta charset="utf-8">
                <link rel="stylesheet" href="pilot-kit.css">
                <script src="pilot-kit.js"></script>
                <body class="pk">
                  <div class="pk-head"><span class="pk-title">\(heading)</span><span class="pk-meta" id="day"></span></div>
                  <div class="pk-hero pk-num" id="time">–</div>
                  <div class="pk-sub" id="date"></div>
                </body>
                <script>
                  // PilotKit.on hands over each pilotdata event and the last data on load, and applies Pilot's theme.
                  PilotKit.on(d => {
                    if (!d.time) return
                    PilotKit.$('time').textContent = d.time
                    PilotKit.$('date').textContent = d.date
                  })
                </script>

                """
        }
        return """
            <!doctype html>
            <meta charset="utf-8">
            <style>
              :root { --panel: rgba(16, 16, 20, 0.86); --line: rgba(255, 255, 255, 0.09); --text: #ececf1; --muted: #8b8b98;
                      --mono: ui-monospace, "SF Mono", Menlo, monospace; --radius: 14px; }
              html, body { margin: 0; height: 100%; background: transparent; }
              body { box-sizing: border-box; padding: 6px; font: 13px -apple-system, system-ui, sans-serif; color: var(--text); }
              .panel { box-sizing: border-box; height: 100%; padding: 12px 14px; background: var(--panel); border: 1px solid var(--line);
                       border-radius: var(--radius); display: flex; flex-direction: column; gap: 6px; overflow: hidden; }
              .head { font: 600 10px var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }
              .value { font: 600 34px var(--mono); letter-spacing: -.01em; }
              .note { color: var(--muted); font-size: 12px; }
            </style>
            <div class="panel">
              <div class="head">\(heading)</div>
              <div class="value" id="time">–</div>
              <div class="note" id="date"></div>
            </div>
            <script>
              // Pilot sends the data as a pilotdata event while the widget shows (a reading every 10 s, a program's
              // {"type":"data"} answer each run); /__pilot/data holds the last. Keep nothing in localStorage: the page's
              // storage goes when it ends.
              function show(data) {
                if (!data.time) return
                document.getElementById('time').textContent = data.time
                document.getElementById('date').textContent = data.date
              }
              addEventListener('pilotdata', e => show(e.detail))
              fetch('/__pilot/data').then(r => r.json()).then(show)
            </script>

            """
    }
}
