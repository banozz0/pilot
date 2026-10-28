import PilotCore
import SwiftUI

/// Editor A's kind forms (spec bind-editor T5, mockups a4 and a10): the kinds the one search leaves to fields. Shell: a
/// multi-line mono command and Run once. Menu item: the picked app's menu items, read off the main thread while it runs,
/// filtered as you type, or a typed path `File > New Window`. Send keys: Record catches a plain combo, a text field the
/// fallback. Pick from a list: its three fields. App URL: one field. Shortcut is a search over `shortcuts list`'s names,
/// read once in a child. Each kind's token in the field-shaped box above drops it, back to the kinds.
extension BindEditor {
    /// A form's text fields: while one has focus, Cmd+Delete deletes text and never removes the key.
    enum FormField: Hashable { case command, keys, url, pickerTitle, pickerList, pickerRun }

    /// Run once while it runs, or why it failed; nothing shows once it ran.
    enum RunOnce: Equatable { case running, failed(String) }

    /// One row of the Menu item form: a menu item's path and its shortcut, or the path typed.
    struct MenuRow: Identifiable, Equatable {
        var id: String
        var path: String
        var key: String?
    }

    /// The app's menu items the query matches, best first; a path typed with ">" is a row of its own first, so an app not
    /// running still binds. The AI's `guess` (a menu route in this app) leads while nothing is typed: the app's own item
    /// with its key when it has one, else the path as guessed (Q128).
    static func menuRows(_ items: [MenuEntry], query: String, bundle: String, guess: String? = nil) -> [MenuRow] {
        if let guess, query.isEmpty, case .menu(bundle, let path)? = DriveRoute(id: guess) {
            let rows = menuRows(items, query: query, bundle: bundle)
            let lead = rows.first { $0.id == guess } ?? MenuRow(id: guess, path: "Press \(DriveRoute.title(path))", key: nil)
            return [lead] + rows.filter { $0.id != guess }
        }
        let typed = query.contains(">") ? query.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) } : []
        let path = typed.isEmpty ? nil : DriveRoute.menu(bundle: bundle, path: typed).checked.map { route in
            MenuRow(id: route.id, path: "Press \(DriveRoute.title(typed))", key: nil)
        }
        let rows = FuzzyRanker.rank(items, query: query) { "\($0.subtitle ?? "") \($0.title)" }.compactMap { entry -> MenuRow? in
            guard case .action(let id) = entry.target else { return nil }
            return MenuRow(id: id, path: [entry.subtitle, entry.title].compactMap(\.self).joined(separator: " › "), key: entry.detail)
        }
        return (path.map { [$0] } ?? []) + rows.filter { $0.id != path?.id }
    }

    /// The form a kind with fields draws in place of the list.
    func kindForm(_ kind: BindSearch.Kind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch kind {
            case .menu: menuForm
            case .shell: shellForm
            case .keys: keysForm
            case .appURL:
                kindBox(kind)
                formField("App URL", text: $field, prompt: "obsidian://new", focus: .url)
                caption(field.contains("://") || field.isEmpty ? "Opens without bringing the app forward, where its scheme allows."
                        : "An app's link starts with its scheme: name://…")
            default:
                kindBox(kind)
                formField("Title", text: $pickerTitle, prompt: "Audio output", focus: .pickerTitle)
                formField("List command", text: $pickerList, prompt: "ls ~/code", focus: .pickerList, mono: true)
                formField("Then run", text: $pickerRun, prompt: #"open "$HOME/code/$1""#, focus: .pickerRun, mono: true)
                caption("Each line the list prints is a row; the pick reaches the second command as $1.")
            }
            if finder.suggested { suggestedCaption }
        }
        // The kind's first field takes the keys as its form opens; a menu's search has them already.
        .onAppear { formField = Self.firstField[kind] }
    }

    private static let firstField: [BindSearch.Kind: FormField] = [.shell: .command, .appURL: .url, .keys: .keys, .picker: .pickerTitle]

    // MARK: Shell (a4)

    /// The command box: 76 pt, or all of a command the AI wrote.
    private var shellBox: CGFloat { finder.suggested ? max(76, Self.shellHeight(field)) : 76 }

    private var shellForm: some View {
        Group {
            kindBox(.shell)
            HStack {
                Text("Command").foregroundStyle(style.color(\.text2))
                Spacer()
                Text("\(URL(filePath: DriveModule.loginShell).lastPathComponent) -l")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(style.color(\.text3))
            }
            TextEditor(text: $field)
                .font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden)
                .focused($formField, equals: .command)
                .padding(.horizontal, 8).padding(.vertical, 8)
                // A command the AI wrote shows whole (at most BindFinder.shellLimit, one line, wrapped), never scrolled.
                .frame(minHeight: 40, idealHeight: shellBox, maxHeight: shellBox)
                .fieldBox(style, focused: formField == .command)
                .accessibilityLabel("Command")
            HStack(alignment: .center, spacing: 10) {
                if case .failed(let why)? = ranOnce {
                    InstrumentAttention(text: "It failed: \(why)").lineLimit(2)
                } else {
                    caption("Runs in your login shell, in the background. Nothing shows unless it fails.")
                }
                Spacer(minLength: 8)
                Button { runOnce() } label: { Label(ranOnce == .running ? "Running…" : "Run once", systemImage: "play") }
                    .buttonStyle(InstrumentButtonStyle(kind: .raised))
                    .disabled(ranOnce == .running || field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// The command box's height for all of `command`, wrapped at the sheet's width in the box's mono face.
    static func shellHeight(_ command: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        // The sheet's 560 less its 22 pt sides, the box's 8 pt insets and the text view's own 5 pt line padding.
        let width: CGFloat = 560 - 44 - 16 - 10
        let text = (command as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return ceil(text.height) + 16 + font.boundingRectForFont.height
    }

    /// The command now, as its bind runs it: a child login shell, never on the main thread.
    func runOnce() {
        let command = field
        ranOnce = .running
        Task {
            let failure = await DriveModule.runOnce(command)
            ranOnce = failure.map(RunOnce.failed)
        }
    }

    // MARK: Menu item (a10)

    private var menuForm: some View {
        let name = apps.first { $0.bundle == bundle }?.name ?? AppsModule.appName(bundle) ?? bundle
        let read = menuItems?.bundle == bundle ? menuItems : nil
        let rows = Self.menuRows(read?.items ?? [], query: finder.query, bundle: bundle, guess: finder.guess)
        return Group {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
                token(BindSearch.Kind.menu.title, symbol: Self.symbol(.menu)) { change() }
                token(name, bundle: bundle) { bundle = ""; finder.query = "" }
                TextField("Menu item", text: $finder.query, prompt: Text("Search \(name)'s menus, or type File > New Window")
                    .foregroundStyle(style.color(\.text3)))
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { if rows.indices.contains(finder.highlighted) { pickMenu(rows[finder.highlighted]) } }
                    .onKeyPress(.downArrow) { finder.highlighted = min(finder.highlighted + 1, max(rows.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { finder.highlighted = max(finder.highlighted - 1, 0); return .handled }
            }
            .padding(.horizontal, 12).frame(height: 38)
            .fieldBox(style, focused: searchFocused)
            HStack {
                InstrumentEyebrow(text: "\(name)'s menus")
                Spacer()
                InstrumentEyebrow(text: read == nil ? "Reading…" : read?.items == nil ? "\(name) is not running" : "\(name) is running")
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in menuRow(row, lit: i == finder.highlighted) }
                }
            }
            .frame(minHeight: Self.rowHeight * 2, maxHeight: CGFloat(Self.listRows(windowHeight: windowHeight) - 1) * Self.rowHeight)
            caption("\(name) not running? Type the path: File > New Window.")
        }
        .task(id: bundle) {
            guard !bundle.isEmpty, menuItems?.bundle != bundle else { return }
            let app = bundle
            let items = await DriveModule.menuItems(of: app)
            if bundle == app { menuItems = (app, items) }
        }
    }

    private func menuRow(_ row: MenuRow, lit: Bool) -> some View {
        HStack(spacing: 10) {
            glyph(Self.symbol(.menu))
            Text(row.path).lineLimit(1)
            Spacer(minLength: 8)
            if let key = row.key { InstrumentKey(text: key) }
            if lit { Image(systemName: "return").font(.system(size: 11)).foregroundStyle(style.color(\.accent)).accessibilityHidden(true) }
        }
        .padding(.horizontal, 10).frame(height: Self.rowHeight)
        .background { if lit { RoundedRectangle(cornerRadius: style.radii.control).fill(style.color(\.accentSoft)) } }
        .overlay(alignment: .leading) { if lit { Capsule().fill(style.color(\.accent)).frame(width: 2, height: 20) } }
        .contentShape(.rect)
        .onTapGesture { pickMenu(row) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// A menu item picked: the bind's action, its card shown.
    func pickMenu(_ row: MenuRow) {
        finder.picked = row.id
        finder.scope = nil
        finder.query = ""
        finder.highlighted = 0
    }

    // MARK: Send keys

    private var keysForm: some View {
        let key = Key(spelling: keystroke)
        return Group {
            kindBox(.keys)
            HStack(spacing: 10) {
                if let key {
                    InstrumentKeys(caps: key.label.components(separatedBy: "+"), hyper: false)
                } else {
                    caption(recordingKeys ? "Press the keys, such as ⌘⇧T. esc stops." : "No keys yet.")
                }
                Spacer(minLength: 8)
                Button { recordingKeys ? stopKeystroke() : recordKeystroke() } label: {
                    if recordingKeys { Text("Stop") } else { Label("Record", systemImage: "circle.fill") }
                }
                .buttonStyle(InstrumentButtonStyle(kind: recordingKeys ? .raised : .ghost))
            }
            formField("Keys", text: $keystroke, prompt: "cmd+shift+t", focus: .keys, mono: true)
            caption(!keystroke.isEmpty && key == nil ? "Not keys Pilot knows: modifiers, then the key, as cmd+shift+t."
                    : "Sent to the app in front when the bind runs. Or type them: cmd+shift+t.")
        }
    }

    /// Record for Send keys: the next plain combo is the keystroke (the tap catches it, ADR 0001); a Hyper key is not one,
    /// so it listens on.
    func recordKeystroke() {
        if recording { recording = false }
        recordingKeys = true
        engine.recordKey { key in
            guard !key.hyper else { return recordKeystroke() }
            keystroke = key.spelling
            recordingKeys = false
        }
    }

    func stopKeystroke() {
        engine.recordKey(nil)
        recordingKeys = false
    }

    // MARK: parts

    /// The kind's token in a box shaped as the search: its × drops the kind, back to the kinds.
    private func kindBox(_ kind: BindSearch.Kind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
            token(kind.title, symbol: Self.symbol(kind)) { change() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(height: 38)
        .fieldBox(style, focused: false)
    }

    private func token(_ title: String, symbol: String? = nil, bundle: String? = nil, drop: @escaping () -> Void) -> some View {
        Button(action: drop) {
            HStack(spacing: 5) {
                if let bundle { AppIcon(name: title, bundle: bundle, size: 16) } else if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
                Text(title).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
        }
        .buttonStyle(InstrumentButtonStyle(kind: .raised)).help("Drop \(title)")
    }

    private func formField(_ label: String, text: Binding<String>, prompt: String, focus: FormField, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).styleText(\.caption).foregroundStyle(style.color(\.text2))
            TextField(label, text: text, prompt: Text(prompt).foregroundStyle(style.color(\.text3)))
                .font(mono ? .system(size: 13, design: .monospaced) : nil)
                .textFieldStyle(.roundedBorder).focused($formField, equals: focus)
        }
    }

    /// Under a card or a form the AI filled: nothing is saved until Save.
    var suggestedCaption: some View {
        Label("Suggested by AI · check it, then Save", systemImage: "sparkles").styleText(\.caption).foregroundStyle(style.color(\.text3))
    }

    private func caption(_ text: String) -> some View {
        Text(text).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    /// The search's box: sunken, its outline the accent while it has the keys.
    func fieldBox(_ style: StyleTokens, focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        return background(style.color(\.sunken), in: shape)
            .overlay { shape.strokeBorder(style.color(focused ? \.accent : \.line2), lineWidth: focused ? 1.5 : 1) }
    }
}

extension BindEditor {
    /// Whether Return saves: not while a list picks its row (a menu's items too), nor in the shell's command, where it
    /// starts a new line. Cmd+Return saves from anywhere.
    func returnSaves(_ stage: Stage) -> Bool { stage != .list && stage != .form(.menu) && formField != .command }
}
