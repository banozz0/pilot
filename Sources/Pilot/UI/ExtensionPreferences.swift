import AppKit
import PilotCore
import SwiftUI

/// An extension's settings (Q637, pilot-1-1 T7 and T8): one form, drawn in the Extensions list's detail and as the first
/// panel of its page. A field per preference, saved as it changes through ExtensionsSettings; in `columns` 2 the rows
/// split into two columns side by side, the first half on the left.
struct ExtensionSettingsForm: View {
    let row: ExtensionsPage.Row
    let settings: ExtensionsSettings
    var columns = 1

    var body: some View {
        let fields = row.fields
        if columns > 1, fields.count > 1 {
            let half = (fields.count + 1) / 2
            HStack(alignment: .top, spacing: 28) {
                column(Array(fields[..<half]))
                column(Array(fields[half...]))
            }
        } else {
            column(fields)
        }
    }

    private func column(_ fields: [ExtensionsPage.Field]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(fields.enumerated()), id: \.element.id) { i, field in
                PreferenceRow(row: row, field: field, settings: settings, first: i == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A preference: its title (Needed while a required one has no value) with the manifest's description as its ⓘ (none
/// when the manifest gives none; page map ⓘ sweep, Sven 2026-10-17) on the left, its field on the right; a save that
/// failed says why under it.
private struct PreferenceRow: View {
    @Environment(\.ink) private var ink
    let row: ExtensionsPage.Row
    let field: ExtensionsPage.Field
    let settings: ExtensionsSettings
    let first: Bool

    private var preference: Extension.Preference { field.preference }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if preference.kind == .checkbox {
                BlockRow(first: first) {
                    Toggle(isOn: Binding(get: { field.value == .bool(true) }, set: { settings.set(.bool($0), for: field, of: row) })) { words }
                        .toggleStyle(.pilotSwitchRow)
                }
            } else {
                BlockRow(first: first) {
                    words
                    Spacer(minLength: 12)
                    control.frame(width: PreferenceRow.fieldWidth)
                }
            }
            if let failure = settings.failure(of: field, in: row) {
                FinePrint(text: failure, color: ink.red).padding(.bottom, 8)
            }
        }
    }

    /// Every field's width, so a row's fields line up down the form, narrow enough for the list's detail and a page's
    /// two columns.
    static let fieldWidth: CGFloat = 170

    private var words: some View {
        HStack(spacing: 7) {
            Text(preference.title).foregroundStyle(ink.text)
            if let detail, !detail.isEmpty { InfoMark(text: detail) }
            if field.isMissing { Chip(text: "Needed", color: ink.yellow, tag: true) }
        }
        .padding(.vertical, 7)
    }

    /// The manifest's description; a password adds where it is kept.
    private var detail: String? {
        guard preference.kind == .password else { return preference.description }
        return [preference.description, "Kept in your Keychain."].compactMap { $0 }.joined(separator: " ")
    }

    @ViewBuilder private var control: some View {
        switch preference.kind {
        case .text: TextPreference(row: row, field: field, settings: settings, secure: false)
        case .password: TextPreference(row: row, field: field, settings: settings, secure: true)
        case .dropdown(let options): DropdownPreference(row: row, field: field, settings: settings, options: options)
        case .app, .file, .folder: PathPreference(row: row, field: field, settings: settings)
        case .checkbox: EmptyView()
        }
    }
}

/// A text or password preference as the kit's field. Text is saved as it is typed, an empty one going back to its
/// default; a password only on Return or on leaving the field, so the Keychain is not written per keystroke. Leaving the
/// field shows the value a run gets.
private struct TextPreference: View {
    @Environment(\.ink) private var ink
    let row: ExtensionsPage.Row
    let field: ExtensionsPage.Field
    let settings: ExtensionsSettings
    let secure: Bool
    @State private var draft: String
    @FocusState private var typing: Bool

    init(row: ExtensionsPage.Row, field: ExtensionsPage.Field, settings: ExtensionsSettings, secure: Bool) {
        self.row = row; self.field = field; self.settings = settings; self.secure = secure
        _draft = State(initialValue: Self.text(field.value))
    }

    static func text(_ value: JSONValue?) -> String { if case .string(let s)? = value { s } else { "" } }

    var body: some View {
        let prompt = Text(field.preference.default.map(Self.text).flatMap { $0.isEmpty ? nil : "Default: \($0)" } ?? (secure ? "Not set" : "Type it"))
            .foregroundStyle(ink.muted)
        Group {
            if secure { SecureField("", text: $draft, prompt: prompt) } else { TextField("", text: $draft, prompt: prompt) }
        }
        .frame(minHeight: 24)
        .pilotField()
        .overlay { if field.isMissing { RoundedRectangle(cornerRadius: 6).strokeBorder(ink.yellow) } }
        .focused($typing)
        .onSubmit { if secure { save() } }
        .onChange(of: draft) { if !secure, draft != Self.text(field.value) { save() } }
        .onChange(of: typing) {
            guard !typing else { return }
            if secure, draft != Self.text(field.value) { save() }
            draft = Self.text(field.value)
        }
        .onChange(of: field.value) { if !typing { draft = Self.text(field.value) } }
        // A password typed but never submitted is still saved when the page goes away mid-edit.
        .onDisappear { if secure, draft != Self.text(field.value) { save() } }
        .accessibilityLabel(field.preference.title)
    }

    private func save() { settings.set(draft.isEmpty ? nil : .string(draft), for: field, of: row) }
}

/// A dropdown preference as a field naming the option picked, its options in a menu with the picked one ticked.
private struct DropdownPreference: View {
    let row: ExtensionsPage.Row
    let field: ExtensionsPage.Field
    let settings: ExtensionsSettings
    let options: [Extension.Preference.Option]

    var body: some View {
        DropdownField(label: field.preference.title, options: options.map { ($0.value, $0.title) }, picked: TextPreference.text(field.value),
                      missing: field.isMissing) { settings.set(.string($0), for: field, of: row) }
    }
}

/// A pick as the kit's field: the picked option's title with the up-down chevron, the options in a menu with the picked
/// one ticked; "Pick one" while none is (an extension's dropdown, a workspace's Monitor).
struct DropdownField<Value: Hashable>: View {
    @Environment(\.ink) private var ink
    let label: String
    let options: [(value: Value, title: String)]
    let picked: Value
    var missing = false
    let pick: (Value) -> Void

    var body: some View {
        let title = options.first { $0.value == picked }?.title
        Menu {
            Picker(label, selection: Binding(get: { picked }, set: pick)) {
                ForEach(options.indices, id: \.self) { Text(options[$0].title).tag(options[$0].value) }
            }
            .pickerStyle(.inline).labelsHidden().menuRows()
        } label: {
            HStack(spacing: 6) {
                Text(title ?? "Pick one").foregroundStyle(title == nil ? ink.muted : ink.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(ink.ui(10, .semibold)).foregroundStyle(ink.muted)
            }
            .font(ink.ui(12.5))
            .fieldFace(missing: missing)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel(label).accessibilityValue(title ?? "none")
    }
}

/// An app, file or folder preference as a field showing what is picked with its icon; a click opens the Mac's picker
/// (an app starting in /Applications, any app allowed), the × inside it puts the default back.
private struct PathPreference: View {
    @Environment(\.ink) private var ink
    let row: ExtensionsPage.Row
    let field: ExtensionsPage.Field
    let settings: ExtensionsSettings

    var body: some View {
        let path = TextPreference.text(field.value)
        let saved = field.value != nil && field.value != field.preference.default
        Button(action: choose) {
            HStack(spacing: 7) {
                if path.isEmpty {
                    Image(systemName: placeholder.symbol).font(ink.ui(12)).foregroundStyle(ink.muted).frame(width: 16)
                    Text(placeholder.text).foregroundStyle(ink.muted).lineLimit(1)
                } else {
                    Image(nsImage: AppsModule.icon(file: path)).resizable().interpolation(.high).frame(width: 16, height: 16)
                    Text(name(path)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .font(ink.ui(12.5))
            // Room for the × over the field's end.
            .padding(.trailing, saved ? 18 : 0)
            .fieldFace(missing: field.isMissing)
        }
        .buttonStyle(.kitPress)
        .help(path.isEmpty ? placeholder.text : path)
        .accessibilityLabel(field.preference.title).accessibilityValue(path.isEmpty ? "none" : name(path))
        .overlay(alignment: .trailing) {
            if saved {
                IconButton(symbol: "xmark", label: "Clear \(field.preference.title)", size: 20, glyph: 9) { settings.set(nil, for: field, of: row) }
                    .padding(.trailing, 4)
            }
        }
    }

    /// What an empty field says, and its symbol.
    private var placeholder: (text: String, symbol: String) {
        switch field.preference.kind {
        case .app: ("Choose an app…", "app.dashed")
        case .folder: ("Choose a folder…", "folder")
        default: ("Choose a file…", "doc")
        }
    }

    /// An app by its name, a file or folder by its path from home.
    private func name(_ path: String) -> String {
        field.preference.kind == .app ? AppsModule.appName(at: URL(fileURLWithPath: path)) : (path as NSString).abbreviatingWithTildeInPath
    }

    private func choose() {
        let panel = NSOpenPanel()
        let kind = field.preference.kind
        let current = TextPreference.text(field.value)
        switch kind {
        case .app:
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.prompt = "Use app"
        case .folder:
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Use folder"
        default:
            panel.prompt = "Use file"
        }
        if kind != .app, !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent() }
        panel.message = field.preference.title
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        settings.set(.string(picked.path), for: field, of: row)
    }
}

private extension View {
    /// A control drawn as the kit's field (pilotField's fill, edge and corner) at the field's height, 32; edged while a
    /// required preference has no value.
    func fieldFace(missing: Bool) -> some View { modifier(FieldFace(missing: missing)) }
}

private struct FieldFace: ViewModifier {
    @Environment(\.ink) private var ink
    let missing: Bool

    func body(content: Content) -> some View {
        let sized = content.padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
        if ink.style.kind == .toybox {
            // Toybox's typed field: a white well in the ink outline, a needed one on the sun's soft fill.
            sized.toyWell(missing ? \.accentSoft : \.panel, radius: 10).contentShape(.rect)
        } else {
            // pilotField's Instrument well, so every field in a list matches; a needed one edged in the signal (attention).
            sized.instrumentWell()
                .overlay { if missing { RoundedRectangle(cornerRadius: ink.style.radii.control, style: .continuous).strokeBorder(ink.accent) } }
                .contentShape(.rect)
        }
    }
}
