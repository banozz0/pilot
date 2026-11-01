import AppKit
import Observation
import PilotCore
import SwiftUI

/// The builder without AI (Q675, T24): pick a look, a data source and a colour, see it, and Save writes an ordinary
/// blocks widget folder, made here, editable by hand or by /widget. A reading needs no program: Pilot draws it in its
/// own look. A program or a web address gets `feed.js`, run by macOS's JavaScript for Automation (`osascript`): it starts
/// the program from its path and arguments with no shell, or fetches the address and takes one field of its JSON, and
/// prints the look's blocks. What Sven typed sits in feed.js as a JSON literal, never pasted into a script or a shell.
struct WidgetSpec: Equatable {
    enum Look: String, CaseIterable { case hero, stats, meter, list, strip }
    enum Source: String, CaseIterable { case reading, program, web }
    enum Colour: String, CaseIterable { case plain, green, amber, red }

    var title = "My widget"
    var look = Look.hero
    var source = Source.reading
    var readings: Set<Widget.Reading> = [.cpu]
    /// The program's full path, and its arguments one per line (each kept whole, spaces and all).
    var program = "/bin/date"
    var arguments = "+%H:%M"
    var url = "https://"
    /// A dotted path into the JSON answer, "current.temperature_2m"; empty for the whole answer.
    var field = ""
    var label = ""
    var colour = Colour.plain
    var every = 60

    static let everies = [10, 30, 60, 300, 900, 3600]

    var tone: String? { switch colour { case .plain: nil; case .green: "fine"; case .amber: "warn"; case .red: "alert" } }
    var height: Int { look == .list || look == .strip ? 200 : 140 }
    var picked: [Widget.Reading] { Widget.Reading.allCases.filter(readings.contains) }
    var shownLabel: String { label.isEmpty ? title : label }
    var argumentList: [String] { arguments.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }

    /// The widget.json and files Save writes, or why it cannot yet.
    func files(id: String) -> Result<[String: (text: String, executable: Bool)], Widget.Problems> {
        var manifest: [String: JSONValue] = ["id": .string(id), "title": .string(title), "icon": .string("🧩"), "version": .string("1.0"),
                                             "description": .string("Made with the widget builder."), "draw": .string("blocks"),
                                             "size": .object(["width": .number(240), "height": .number(Double(height))])]
        var files: [String: (text: String, executable: Bool)] = [:]
        switch source {
        case .reading:
            guard !picked.isEmpty else { return .failure(.init(reasons: ["pick a reading"])) }
            manifest["data"] = .object(["reading": picked.count == 1 ? .string(picked[0].rawValue) : .array(picked.map { .string($0.rawValue) })])
        case .program, .web:
            if source == .program, !program.hasPrefix("/") { return .failure(.init(reasons: ["the program is its full path, like /bin/date"])) }
            if source == .web, !(url.hasPrefix("https://") || url.hasPrefix("http://")) || URL(string: url)?.host() == nil {
                return .failure(.init(reasons: ["the address starts https:// and names a site"]))
            }
            manifest["data"] = .object(["command": .array(["/usr/bin/osascript", "-l", "JavaScript", "./feed.js"].map(JSONValue.string)),
                                        "every": .number(Double(max(every, Widget.fewestSeconds)))])
            if source == .web, let host = URL(string: url)?.host(), Widget.isHost(host) { manifest["hosts"] = .array([.string(host)]) }
            let config: JSONValue = .object(["look": .string(look.rawValue), "label": .string(shownLabel), "tone": .string(tone ?? ""),
                                             "program": .string(source == .program ? program : ""), "arguments": .array(argumentList.map(JSONValue.string)),
                                             "url": .string(source == .web ? url : ""), "field": .string(field)])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let literal = String(decoding: (try? encoder.encode(config)) ?? Data("{}".utf8), as: UTF8.self)
            files["feed.js"] = (Self.feed.replacingOccurrences(of: "__CONFIG__", with: literal), false)
        }
        files[Widget.manifestName] = (WidgetTemplates.manifest(manifest), false)
        return .success(files)
    }

    /// What the preview draws before a run: the look with a sample value, or the reading's own blocks.
    @MainActor func sample() -> [Extension.Block] {
        let label = shownLabel, tone = tone.flatMap(Extension.Tone.init(rawValue:))
        switch source {
        case .reading:
            let data: [String: JSONValue] = ["cpu": .object(["percent": .number(23)]), "memory": .object(["percent": .number(64)]),
                                             "disk": .object(["percent": .number(61), "available": .number(212_000_000_000)]),
                                             "battery": .object(["present": .bool(true), "percent": .number(82), "phrase": .string("82 %")]),
                                             "network": .object(["down": .number(120_000), "up": .number(8_000)]),
                                             "clock": .object(["time": .string("21:04"), "date": .string("Wednesday 7 October")]),
                                             "calendar": .object(["access": .bool(true), "events": .array([])])]
            return WidgetReadings.blocks(picked, picked.count == 1 ? data[picked[0].rawValue]! : .object(data))
        case .program, .web:
            switch look {
            case .hero: return [.hero(.init(value: "42", place: label, tone: tone))]
            case .stats: return [.stats([.init(label: label, value: "42", tone: tone)])]
            case .meter: return [.meter(.init(label: label, percent: 42, tone: tone))]
            case .list: return [.markdown("**\(label)**\n\nfirst line\n\nsecond line")]
            case .strip: return [.strip([.init(label: "Mon", high: "21"), .init(label: "Tue", high: "19"), .init(label: "Wed", high: "23")])]
            }
        }
    }

    /// feed.js: the source's value, as text, drawn in the look; any failure is its error message.
    static let feed = """
        ObjC.import('Foundation')
        // Written by Pilot's widget builder. Pilot writes one JSON line on stdin; this prints one JSON object on stdout.
        const config = __CONFIG__
        function text(data) { return data && !data.isNil() ? $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js : '' }
        // The program from its path with its arguments as they are: no shell reads them.
        function program() {
          const task = $.NSTask.alloc.init
          task.executableURL = $.NSURL.fileURLWithPath(config.program)
          task.arguments = config.arguments
          const out = $.NSPipe.pipe
          task.standardOutput = out
          task.standardInput = $.NSFileHandle.fileHandleWithNullDevice
          if (!task.launchAndReturnError(null)) throw new Error(config.program + ' did not start')
          const data = out.fileHandleForReading.readDataToEndOfFile
          task.waitUntilExit
          return text(data).trim()
        }
        // The address's JSON, then the dotted field in it.
        function web() {
          const data = $.NSData.dataWithContentsOfURL($.NSURL.URLWithString(config.url))
          let value = JSON.parse(text(data))
          for (const key of config.field.split('.').filter(k => k)) value = value == null ? null : value[key]
          return value == null ? '' : (typeof value === 'object' ? JSON.stringify(value) : String(value))
        }
        function blocks(value) {
          const lines = value.split('\\n').filter(l => l.trim())
          const tone = config.tone || undefined
          switch (config.look) {
            case 'hero': return [{type: 'hero', value: lines[0] || '–', place: config.label}]
            case 'stats': return [{type: 'stats', items: [{label: config.label, value: lines[0] || '–', tone}]}]
            case 'meter': return [{type: 'meter', label: config.label, percent: Math.max(0, Math.min(100, parseFloat(lines[0]) || 0)), tone}]
            case 'list': return [{type: 'list', title: config.label, items: lines.slice(0, 20).map((l, i) => ({id: String(i), title: l}))}]
            default: return [{type: 'strip', items: lines.slice(0, 7).map(l => { const [label, ...rest] = l.trim().split(/\\s+/); return {label, high: rest.join(' ')} })}]
          }
        }
        function run() {
          try {
            $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile
            return JSON.stringify({type: 'blocks', blocks: blocks(config.program ? program() : web())})
          } catch (e) { return JSON.stringify({type: 'error', text: String(e)}) }
        }

        """
}

/// The builder's sheet: the choices on the left, the tile as it will look on the right; Try it runs the feed once from a
/// copy (Sven's own click, as Save is), and Save writes the folder into Widgets, made here.
struct WidgetBuilderSheet: View {
    @Environment(\.ink) private var ink
    @State var spec = WidgetSpec()
    @State private var tried: [Extension.Block]?
    /// The preview's one tile, its blocks set as the spec or a try changes, never rebuilt by a render.
    @State private var tile = WidgetTileModel()
    @State private var trying = false
    @State private var problem: String?
    let store: WidgetStore
    let saved: (Widget) -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Form {
                TextField("Title", text: $spec.title)
                Picker("Data", selection: $spec.source) {
                    Text("A Pilot reading").tag(WidgetSpec.Source.reading)
                    Text("A program").tag(WidgetSpec.Source.program)
                    Text("A web address (JSON)").tag(WidgetSpec.Source.web)
                }
                switch spec.source {
                case .reading:
                    ForEach(Widget.Reading.allCases, id: \.self) { reading in
                        Toggle(reading.rawValue.capitalized, isOn: Binding(get: { spec.readings.contains(reading) },
                                                                           set: { if $0 { spec.readings.insert(reading) } else { spec.readings.remove(reading) } }))
                    }
                    Text("Pilot draws its readings in its own look.").font(.caption).foregroundStyle(ink.muted)
                case .program:
                    TextField("Program (full path)", text: $spec.program)
                    TextField("Arguments, one a line", text: $spec.arguments, axis: .vertical).lineLimit(2...4)
                case .web:
                    TextField("Address", text: $spec.url)
                    TextField("Field (dotted, like current.temperature)", text: $spec.field)
                }
                if spec.source != .reading {
                    Picker("Look", selection: $spec.look) { ForEach(WidgetSpec.Look.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    TextField("Label", text: $spec.label, prompt: Text(spec.title))
                    Picker("Colour", selection: $spec.colour) { ForEach(WidgetSpec.Colour.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    Picker("Every", selection: $spec.every) { ForEach(WidgetSpec.everies, id: \.self) { Text($0 < 60 ? "\($0) s" : "\($0 / 60) min").tag($0) } }
                }
                Text("Glass follows Look › Glass.").font(.caption).foregroundStyle(ink.muted)
            }
            .formStyle(.grouped).frame(width: 360)
            VStack(alignment: .leading, spacing: 10) {
                WidgetTile(model: tile).frame(width: 240, height: CGFloat(spec.height))
                if spec.source != .reading {
                    Button(trying ? "Trying…" : "Try it") { tryIt() }.buttonStyle(.pilot).disabled(trying)
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(ink.red).fixedSize(horizontal: false, vertical: true).frame(width: 240, alignment: .leading) }
                Spacer()
                HStack {
                    Button("Cancel", action: cancel).buttonStyle(.pilot).keyboardShortcut(.cancelAction)
                    Button("Save") { save() }.buttonStyle(.pilotPrimary)
                }
            }
        }
        .padding(18).pilotSheet()
        .onChange(of: spec, initial: true) { tried = nil; problem = nil; showPreview() }
    }

    private func showPreview() { tile.title = spec.title; tile.blocks = tried ?? spec.sample() }

    /// Runs the feed once from a temporary copy, as `pilot widget check` runs a folder after Allow: Sven pressed it.
    private func tryIt() {
        let files: [String: (text: String, executable: Bool)]
        switch spec.files(id: "preview") {
        case .success(let made): files = made
        case .failure(let problems): return problem = problems.description
        }
        trying = true
        Task {
            switch await Self.trial(files) {
            case .blocks(let blocks): tried = blocks; showPreview()
            case .data: problem = "It answered data, which only a page draws"
            case .error(let reason, let said): problem = [reason, said].compactMap { $0 }.joined(separator: ": ")
            }
            trying = false
        }
    }

    /// One run of the files from a temporary folder of their own, off the main thread, the folder removed after.
    @concurrent private static func trial(_ files: [String: (text: String, executable: Bool)]) async -> Widget.Answer {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "pilot-widget-builder-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let folder = scratch.appending(path: "preview", directoryHint: .isDirectory)
            try WidgetTemplates.write(files, to: folder)
            return await WidgetRunner.run(try Widget(folder: folder), store: WidgetStore(root: scratch, passwords: false), grant: .allowed).answer
        } catch { return .error((error as? Widget.Problems)?.description ?? error.localizedDescription) }
    }

    /// Saves under a free id from the title, made here (the builder is Sven making it): written to a scratch folder, read
    /// through the import's checks into Pilot's staging copy and moved into Widgets whole (WidgetStore.importStaged), so a
    /// folder that does not read never lands there; off the main thread.
    private func save() {
        guard Widget.isTitle(spec.title) else { return problem = "The title is plain text of 1 to 60 characters, without №" }
        let letters = String(spec.title.lowercased().map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? $0 : "-" })
        var slug = String(letters.split(separator: "-").map(String.init).joined(separator: "-").prefix(50))
        while slug.hasSuffix("-") { slug.removeLast() }   // a cut that lands on a hyphen
        let base = slug.isEmpty ? "widget" : ReadyWidgets.isReady(slug) ? "my-\(slug)" : slug
        let (spec, store) = (spec, store)
        Task {
            do { saved(try await Self.write(spec, base: base, into: store)) }
            catch { problem = (error as? Widget.Problems)?.description ?? error.localizedDescription }
        }
    }

    @concurrent private static func write(_ spec: WidgetSpec, base: String, into store: WidgetStore) async throws -> Widget {
        let id = try store.freeID(for: base)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "pilot-widget-builder-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try WidgetTemplates.write(try spec.files(id: id).get(), to: scratch.appending(path: id, directoryHint: .isDirectory))
        let staged = try await Widget.stage(scratch.appending(path: id, directoryHint: .isDirectory), into: scratch.appending(path: "staged"))
        let widget = try store.importStaged(staged, expecting: id, trash: { _ in throw CocoaError(.fileWriteFileExists) })
        try store.setTrust(.madeHere, for: widget)
        return widget
    }
}
