import AppKit
import ImageIO
import PilotCore
import SwiftUI

/// One editor lifetime. Every replacement or edit invalidates pending panels and image reads.
@Observable @MainActor
final class ThemeDraftSession {
    var draft: ThemePackStore.Draft? { didSet { invalidate() } }
    private(set) var generation = UUID()
    private(set) var loading = false
    private(set) var error = ""
    init(draft: ThemePackStore.Draft? = nil) { self.draft = draft }
    func invalidate() { generation = UUID(); loading = false; error = "" }

    func attach(_ paths: [String], ifCurrent expected: UUID,
                read: @escaping @Sendable ([String], ThemePackStore.Draft) async throws -> ThemePackStore.Draft = { paths, original in
                    try await Task.detached { try ThemePackStore.attaching(paths, to: original) }.value
                }) async {
        guard generation == expected, let original = draft else { return }
        generation = UUID(); let requestGeneration = generation
        loading = true; error = ""
        defer { if generation == requestGeneration { loading = false } }
        do {
            let result = try await read(paths, original)
            guard generation == requestGeneration else { return }
            draft = result
        } catch {
            guard generation == requestGeneration else { return }
            self.error = String(describing: error)
        }
    }
}

/// Approved library inspector's draft. This view never applies a theme or writes app configuration.
struct ThemePackEditor: View {
    @Environment(\.ink) private var ink
    @Bindable var session: ThemeDraftSession
    private let initial: ThemePackStore.Draft
    private var draft: ThemePackStore.Draft {
        get { session.draft ?? initial }
        nonmutating set { session.draft = newValue }
    }
    private var editing: Binding<ThemePackStore.Draft> { Binding(get: { draft }, set: { draft = $0 }) }
    let save: () -> Void
    let review: () -> Void
    let cancel: () -> Void
    init(session: ThemeDraftSession, save: @escaping () -> Void, review: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.session = session; initial = session.draft!; self.save = save; self.review = review; self.cancel = cancel
    }
    /// Existing offscreen renders supply a fixed draft without constructing production state.
    init(draft: Binding<ThemePackStore.Draft>, save: @escaping () -> Void, review: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.init(session: ThemeDraftSession(draft: draft.wrappedValue), save: save, review: review, cancel: cancel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(draft.pack.title).font(ink.ui(18)); Spacer(); Text("Draft · not applied").foregroundStyle(ink.text2) }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 22) {
                    palette.frame(minWidth: 230, idealWidth: 300, maxWidth: .infinity)
                    assets.frame(minWidth: 230, idealWidth: 320, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 18) { palette; assets }
            }
            Divider()
            HStack {
                Text("Save keeps a pack. Apply is separate.").foregroundStyle(ink.text2)
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save draft", action: save)
                Button("Review changes", action: review)
            }
            if !session.error.isEmpty { Text(session.error).foregroundStyle(ink.text2).textSelection(.enabled) }
        }.disabled(session.loading)
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Palette").font(ink.ui(14))
            TextField("Name", text: editing.pack.title)
            TextField("Identity", text: editing.pack.id).help("A distinct lowercase identity; factory identities are reserved.")
            Toggle("Dark appearance", isOn: Binding(get: { draft.pack.dark }, set: { dark in
                if draft.pack.variants != nil {
                    draft.pack.variants?[draft.pack.dark ? "dark" : "light"] = draft.pack.palette
                    if let next = draft.pack.variants?[dark ? "dark" : "light"] { draft.pack.palette = next }
                }
                draft.pack.dark = dark
            }))
            roles(["accent", "background", "foreground", "selection"])
            KitFold(title: "Ink, borders, ANSI and syntax") {
                roles(draft.pack.palette.keys.sorted().filter { !["accent", "background", "foreground", "selection"].contains($0) })
            }
            HStack {
                Button("Add \(draft.pack.dark ? "light" : "dark") appearance") {
                    var variants = draft.pack.variants ?? [:]
                    variants[draft.pack.dark ? "light" : "dark"] = draft.pack.palette
                    draft.pack.variants = variants
                }
                if draft.pack.variants != nil { Button("Remove variants") { draft.pack.variants = nil } }
            }
            if let variants = draft.pack.variants {
                ForEach(variants.keys.sorted(), id: \.self) { mode in
                    KitFold(title: "\(mode.capitalized) appearance roles") {
                        ForEach((variants[mode] ?? [:]).keys.sorted(), id: \.self) { role in
                            TextField(role, text: Binding(get: { draft.pack.variants?[mode]?[role] ?? "" }, set: { draft.pack.variants?[mode]?[role] = $0; if mode == (draft.pack.dark ? "dark" : "light") { draft.pack.palette[role] = $0 } }))
                        }
                    }
                }
            }
            Text("Style compatibility").font(ink.ui(14))
            ForEach(PilotStyle.allCases, id: \.self) { style in
                Toggle(style.title, isOn: Binding(get: { draft.pack.styles.isEmpty || draft.pack.styles.contains(style.rawValue) }, set: { on in
                    var values = draft.pack.styles.isEmpty ? PilotStyle.allCases.map(\.rawValue) : draft.pack.styles
                    if on { if !values.contains(style.rawValue) { values.append(style.rawValue) } }
                    else { values.removeAll { $0 == style.rawValue } }
                    // No selection would mean unrestricted in schema 1; keep at least the remaining style.
                    if !values.isEmpty { draft.pack.styles = values }
                }))
            }
            Text("Style keeps shape, type and spacing.").foregroundStyle(ink.text2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func roles(_ roles: [String]) -> some View {
        ForEach(roles, id: \.self) { role in
            HStack {
                Text(role.replacingOccurrences(of: "_", with: " ")).foregroundStyle(ink.text2)
                Spacer()
                TextField("#RRGGBB", text: Binding(get: { draft.pack.palette[role] ?? "" }, set: { value in
                    draft.pack.palette[role] = value
                    if draft.pack.variants?[draft.pack.dark ? "dark" : "light"] != nil {
                        draft.pack.variants?[draft.pack.dark ? "dark" : "light"]?[role] = value
                    }
                })).frame(width: 92)
            }
        }
    }

    private var assets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wallpapers").font(ink.ui(14))
            HStack { Button("Add images…") { add(folder: false) }; Button("Add folder…") { add(folder: true) } }
            Text("Any image count. Natural filename order; personal pins and cycling preferences stay.").foregroundStyle(ink.text2)
            ScrollView(.horizontal) {
                LazyHStack {
                    ForEach(draft.files.keys.filter { $0 != "PROVENANCE.md" }.sorted(), id: \.self) { path in
                        VStack { ThemeDraftThumbnail(bytes: draft.files[path]!); Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1) }.frame(width: 88)
                    }
                }
            }.frame(height: 90)
            ForEach(draft.pack.wallpapers, id: \.self) { path in
                HStack {
                    Text(path).lineLimit(1); Spacer()
                    Button("Remove") {
                        draft.pack.wallpapers.removeAll { $0 == path }
                        draft.files = draft.files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
                    }
                }
            }
            if draft.pack.wallpapers.isEmpty { Text("No images · keep current wallpaper").foregroundStyle(ink.text2) }
            Text("Apps & vaults").font(ink.ui(14))
            ForEach(["ghostty", "zed", "obsidian"], id: \.self) { app in
                Toggle(app == "ghostty" ? "Ghostty" : app.capitalized, isOn: Binding(get: { draft.pack.adapters[app] != nil }, set: { on in
                    draft.pack.adapters[app] = on ? .object([:]) : nil
                }))
            }
            Text("Destinations and vault opt-outs stay personal. Choose them in the inspector before Review.").foregroundStyle(ink.text2)
            KitFold(title: "Advanced · compatible custom apps") {
                Text("Built-in apps need no template. Custom JSON/JSONC keys, named text blocks and generated theme files only; app coverage and refresh remain app-specific.").foregroundStyle(ink.text2)
                ForEach(Array((draft.pack.customMappings ?? []).indices), id: \.self) { index in
                    ThemeMappingFields(mapping: Binding(get: { draft.pack.customMappings![index] }, set: { draft.pack.customMappings?[index] = $0 }))
                    Button("Remove mapping") {
                        draft.pack.customMappings?.remove(at: index)
                        if draft.pack.customMappings?.isEmpty == true { draft.pack.customMappings = nil }
                    }
                }
                Button("Add mapping") {
                    if draft.pack.customMappings == nil { draft.pack.customMappings = [] }
                    draft.pack.customMappings?.append(.init(id: "custom-" + UUID().uuidString.lowercased(), ownership: .block(begin: "# BEGIN PILOT THEME", end: "# END PILOT THEME"), template: "accent = {{accent}}"))
                }
            }
            Text("Pack defaults").font(ink.ui(14))
            Toggle("Offer a material default", isOn: Binding(get: { draft.pack.material != nil }, set: { draft.pack.material = $0 ? .init(glass: true, transparency: 35, blur: "full") : nil }))
            if draft.pack.material != nil {
                Toggle("Glass", isOn: Binding(get: { draft.pack.material!.glass }, set: { draft.pack.material?.glass = $0 }))
                Stepper("Transparency \(draft.pack.material!.transparency)%", value: Binding(get: { draft.pack.material!.transparency }, set: { draft.pack.material?.transparency = $0 }), in: 0...100)
                Picker("Blur", selection: Binding(get: { draft.pack.material!.blur }, set: { draft.pack.material?.blur = $0 })) {
                    ForEach(GlassBlur.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented)
            }
            Picker("Bar preset suggestion", selection: Binding(get: { draft.pack.barPreset?.rawValue ?? "none" }, set: { draft.pack.barPreset = BarPreset(rawValue: $0) })) {
                Text("Keep personal layout").tag("none")
                ForEach(BarPreset.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            Text("Suggestions only. Material and bar geometry stay personal unless explicitly followed. Items, their order and fonts stay personal.").foregroundStyle(ink.text2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func add(folder: Bool) {
        let generation = session.generation
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder; panel.canChooseFiles = !folder; panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            let paths = panel.urls.map(\.path)
            Task { @MainActor in
                await session.attach(paths, ifCurrent: generation)
            }
        }
    }
}

/// Small advanced controls inside the approved inspector. Draft data and local authority stay separate.
private struct ThemeMappingFields: View {
    @Binding var mapping: ThemeMapping
    @State private var root = ""
    @State private var path = ""
    @State private var app = ""
    @State private var executable = ""
    @State private var arguments = "[]"
    @State private var outcome = ""
    @State private var running = false
    private var kind: String {
        switch mapping.ownership { case .generatedFile: "file"; case .block: "block"; case .json: "json" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Stable mapping identity", text: $mapping.id)
            Picker("Ownership", selection: Binding(get: { kind }, set: { kind in
                switch kind {
                case "json": mapping.ownership = .json(path: ["theme"]); mapping.template = "\"{{accent}}\""
                case "file": mapping.ownership = .generatedFile
                default: mapping.ownership = .block(begin: "# BEGIN PILOT THEME", end: "# END PILOT THEME")
                }
            })) {
                Text("JSON/JSONC key").tag("json"); Text("Named text block").tag("block"); Text("Generated whole file").tag("file")
            }
            if case .json(let keys) = mapping.ownership {
                ForEach(keys.indices, id: \.self) { index in
                    TextField("Key \(index + 1)", text: Binding(get: { keys[index] }, set: { value in
                        var path = keys; path[index] = value; mapping.ownership = .json(path: path)
                    }))
                }
                HStack {
                    Button("Add nested key") { mapping.ownership = .json(path: keys + [""]) }
                    Button("Remove last key") { mapping.ownership = .json(path: Array(keys.dropLast())) }.disabled(keys.isEmpty)
                }
            }
            if case .block(let begin, let end) = mapping.ownership {
                TextField("Begin marker", text: Binding(get: { begin }, set: { mapping.ownership = .block(begin: $0, end: end) }))
                TextField("End marker", text: Binding(get: { end }, set: { mapping.ownership = .block(begin: begin, end: $0) }))
            }
            Text("Template · {{accent}}, {{background}}, {{foreground}} and validated palette roles")
            TextEditor(text: $mapping.template).font(.system(.caption, design: .monospaced)).frame(height: 80)
            KitFold(title: "Local destination & optional reload") {
                Button("Show selected local destination") {
                    do {
                        guard let binding = try ThemeCoordinator.production().zedSelection.custom?.first(where: { $0.id == mapping.id }) else { outcome = "No local destination selected."; return }
                        root = binding.root; path = binding.path; app = binding.app; executable = binding.reload?.executable ?? ""
                        arguments = String(decoding: try ThemeDigest.encoded(binding.reload?.arguments ?? []), as: UTF8.self)
                    } catch { outcome = String(describing: error) }
                }
                TextField("Configuration root (absolute folder)", text: $root)
                TextField("File within root (relative path)", text: $path)
                TextField("Exact application (.app path)", text: $app)
                TextField("Optional native helper inside this app's Contents/MacOS", text: $executable)
                TextField("Fixed arguments (JSON string array)", text: $arguments)
                Text("Selecting saves local authority after Allow. Save, import and Review execute nothing. After Apply commits files, an optional helper asks a separate Allow; no implicit restart.")
                Button("Select local destination") {
                    running = true
                    Task { @MainActor in
                        defer { running = false }
                        do {
                            let argv = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
                            let binding = ThemeMappingBinding(id: mapping.id, root: root, path: path, app: app,
                                reload: executable.isEmpty ? nil : .init(executable: executable, arguments: argv))
                            let result = try await ThemeCoordinator.production().bindCustom(binding, peer: nil)
                            outcome = String(decoding: try ThemeDigest.encoded(result), as: UTF8.self)
                        } catch { outcome = String(describing: error) }
                    }
                }.disabled(running)
            }
            if !outcome.isEmpty { Text(outcome).textSelection(.enabled) }
        }
    }
}

private struct ThemeDraftThumbnail: View {
    let bytes: Data
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: "photo") }
        }.frame(width: 88, height: 60).task(id: ThemeDigest.of(bytes)) {
            image = await Task.detached {
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 176] as CFDictionary)
            }.value
        }
    }
}
