import AppKit
import PilotCore
import SwiftUI

/// A Raycast Form (ADR 0017, T10) in a key panel of its own, opened by ExtensionListSession when a view answers a form
/// (the coordinator's option B, 2026-11-20): Hyper+Space gives way as the panel takes the keyboard, and the panel then
/// owns the view's host, ending it as it closes. Each field is Pilot's own control, as an extension's settings draw
/// them (ExtensionPreferences.swift): a row with the title on the left and the field on the right, an error in red
/// under it. An edit goes to the host at once (ExtensionSession.edit), the field showing it until the host agrees, so
/// typing never waits on an answer. Command+Return presses the form's SubmitForm, Escape closes the panel; once a submit
/// moves the view on, a detail it pushed draws in the panel.
@MainActor
final class ExtensionFormPanel {
    /// The one form open; a second form closes it.
    private static var shown: ExtensionFormPanel?

    private let panel: KeyPanel
    private let model: ExtensionFormModel
    private var monitor: Any?

    /// Whether the open panel holds `session`: then the views that opened it leave the host running as they close.
    static func owns(_ session: ExtensionSession) -> Bool { shown?.model.session === session }

    /// Shows `session`'s newest form in a panel of its own, which ends the session as it closes.
    static func show(_ session: ExtensionSession, ext: Extension, command: Extension.Command) {
        shown?.close()
        shown = ExtensionFormPanel(session, title: "\(ext.title) › \(command.title)")
    }

    private init(_ session: ExtensionSession, title: String) {
        let model = ExtensionFormModel(session, title: title)
        self.model = model
        panel = HUD.makePanel(ExtensionFormView(model: model), surface: .extensionDetail)
        panel.escape = { [weak self] in self?.close() }
        model.close = { [weak self] in self?.close() }
        session.watch { [weak model] in Task { @MainActor in model?.redraw() } }
        // Command+Return submits from any field, as Raycast's does.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel, weak model] event in
            let returnKey = [KeyCode.returnKey, KeyCode.keypadEnter].contains(Int64(event.keyCode)) && event.modifierFlags.contains(.command)
            let window = event.windowNumber
            let taken = MainActor.assumeIsolated {
                guard returnKey, let model, window == panel?.windowNumber else { return false }
                model.submit()
                return true
            }
            return taken ? nil : event
        }
        panel.makeKeyAndOrderFront(nil)
        dlog.notice("extension: form panel shown")
    }

    private func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.orderOut(nil)
        model.session.watch { }
        model.session.close()
        if Self.shown === self { Self.shown = nil }
    }
}

/// What the panel draws: the host's newest view, a form's edits shown at once.
@Observable @MainActor
final class ExtensionFormModel {
    let session: ExtensionSession, title: String
    private(set) var view: ListOutcome?
    @ObservationIgnored var close: () -> Void = {}

    init(_ session: ExtensionSession, title: String) {
        self.session = session; self.title = title
        view = session.newest?.outcome
    }

    var form: Extension.Form? { view?.form }

    /// The host's newest answer, its stale echoes already replaced by the edits made since (ExtensionSession); an answer
    /// equal to what shows (a keystroke's own echo) draws nothing again.
    func redraw() {
        let newest = session.newest?.outcome ?? view
        if newest != view { view = newest }
    }

    /// A field's new value, shown now and sent to the host.
    func set(_ field: Extension.Form.Field, _ value: JSONValue) {
        guard let id = field.id, let handler = field.change, case .form(var form)? = view,
              let index = form.fields.firstIndex(where: { $0.id == id }) else { return }
        form.fields[index].value = value
        view = .form(form)
        session.edit(id, handler: handler, value: value)
    }

    /// The field lost the keyboard: its onBlur, when it has one (Raycast's validation runs there).
    func leave(_ field: Extension.Form.Field) {
        guard let blur = field.blur else { return }
        Task { _ = await session.invoke(blur) }
    }

    /// One of the form's actions, pressed in its host.
    func press(_ action: Extension.Item.Action) {
        guard let handler = action.handler else { return }
        Task { _ = await session.invoke(handler) }
    }

    func submit() { if let action = form?.submit { press(action) } }
}

struct ExtensionFormView: View {
    @Environment(\.ink) private var ink
    let model: ExtensionFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title).font(ink.ui(14, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                .padding(.horizontal, 18).padding(.vertical, 12)
            content
            if let form = model.form { footer(form) }
        }
        .frame(width: 540, height: 460, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        switch model.view {
        case .form(let form)?:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(form.fields.enumerated()), id: \.offset) { i, field in
                        ExtensionFormRow(field: field, model: model, first: i == 0)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 12)
            }
        case .detail(let detail)?:
            ExtensionDetailView(detail: detail) { model.press($0) }
        case .error(let why)?:
            FinePrint(text: "\(model.title) \(why)", color: ink.red).padding(18)
        case .items?, .empty?, nil:
            FinePrint(text: "Nothing to fill in here: the extension moved on to a list.").padding(18)
        }
        Spacer(minLength: 0)
    }

    /// The form's actions as buttons, the submit one primary, Command+Return named beside it.
    private func footer(_ form: Extension.Form) -> some View {
        HStack(spacing: 8) {
            Text("⌘↵ \(form.submit?.label ?? "")  ·  esc Close").font(ink.ui(11)).foregroundStyle(ink.muted)
            Spacer(minLength: 0)
            ForEach(Array(form.actions.enumerated()), id: \.offset) { _, action in
                if action.handler != nil {
                    if action == form.submit {
                        Button(action.label) { model.press(action) }.buttonStyle(.pilotPrimary)
                    } else {
                        Button(action.label) { model.press(action) }.buttonStyle(.pilot)
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }
}

/// One field: its title (with its info as ⓘ) on the left and its control on the right, a description's text alone, a
/// separator a rule; its error in red under it.
private struct ExtensionFormRow: View {
    @Environment(\.ink) private var ink
    let field: Extension.Form.Field
    let model: ExtensionFormModel
    let first: Bool

    var body: some View {
        switch field.kind {
        case .separator:
            Divider().padding(.vertical, 6)
        case .description:
            VStack(alignment: .leading, spacing: 2) {
                if let title = field.title { Text(title).font(ink.ui(12, .semibold)).foregroundStyle(ink.muted) }
                Text(field.text ?? "").foregroundStyle(ink.text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
        case .checkbox:
            VStack(alignment: .leading, spacing: 0) {
                BlockRow(first: first) {
                    Toggle(isOn: Binding(get: { field.value == .bool(true) }, set: { model.set(field, .bool($0)) })) { words(field.label ?? field.title ?? "") }
                        .toggleStyle(.pilotSwitchRow)
                }
                problem
            }
        case .textarea:
            VStack(alignment: .leading, spacing: 6) {
                words(field.title ?? "").padding(.top, 8)
                FormText(field: field, model: model, area: true)
                problem
            }
        default:
            VStack(alignment: .leading, spacing: 0) {
                BlockRow(first: first) {
                    words(field.title ?? "")
                    Spacer(minLength: 12)
                    control.frame(width: Self.fieldWidth)
                }
                problem
            }
        }
    }

    static let fieldWidth: CGFloat = 260

    private func words(_ title: String) -> some View {
        HStack(spacing: 7) {
            Text(title).foregroundStyle(ink.text)
            if let info = field.info, !info.isEmpty { InfoMark(text: info) }
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder private var problem: some View {
        if let error = field.error, !error.isEmpty { FinePrint(text: error, color: ink.red).padding(.bottom, 8) }
    }

    @ViewBuilder private var control: some View {
        switch field.kind {
        case .text, .password: FormText(field: field, model: model, area: false)
        case .dropdown:
            DropdownField(label: field.title ?? field.id ?? "", options: (field.options ?? []).map { ($0.value, $0.title) }, picked: field.string,
                          missing: field.error != nil) { model.set(field, .string($0)) }
        case .date: FormDate(field: field, model: model)
        case .file: FormFiles(field: field, model: model)
        case .checkbox, .textarea, .description, .separator: EmptyView()
        }
    }
}

/// A text field, password or text area: what is typed shows at once and goes to the host as it is typed; leaving it
/// runs its onBlur.
private struct FormText: View {
    @Environment(\.ink) private var ink
    let field: Extension.Form.Field
    let model: ExtensionFormModel
    let area: Bool
    @FocusState private var typing: Bool

    var body: some View {
        let text = Binding(get: { field.string }, set: { if $0 != field.string { model.set(field, .string($0)) } })
        let prompt = Text(field.placeholder ?? "").foregroundStyle(ink.muted)
        Group {
            if area {
                TextEditor(text: text).font(ink.ui(12.5)).scrollContentBackground(.hidden).padding(6)
                    .frame(height: 84).instrumentWell()
            } else if field.kind == .password {
                SecureField("", text: text, prompt: prompt).frame(minHeight: 24).pilotField()
            } else {
                TextField("", text: text, prompt: prompt).frame(minHeight: 24).pilotField()
            }
        }
        .overlay { if field.error != nil { RoundedRectangle(cornerRadius: 6).strokeBorder(ink.red) } }
        .focused($typing)
        .onAppear { if field.autoFocus == true { typing = true } }
        .onChange(of: typing) { if !typing { model.leave(field) } }
        .accessibilityLabel(field.title ?? field.id ?? "")
    }
}

/// A date, or a date and time: "Pick a date" while it has none, else the Mac's date field with a × that clears it.
private struct FormDate: View {
    @Environment(\.ink) private var ink
    let field: Extension.Form.Field
    let model: ExtensionFormModel

    private var date: Date? { Extension.Form.date(field.string) }

    var body: some View {
        if let date {
            HStack(spacing: 6) {
                DatePicker("", selection: Binding(get: { date }, set: { put($0) }), in: bounds,
                           displayedComponents: field.time == false ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden().datePickerStyle(.field)
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", label: "Clear \(field.title ?? "")", size: 20, glyph: 9) { model.set(field, .null) }
            }
            .fieldFace(missing: field.error != nil)
        } else {
            Button { put(field.time == false ? Calendar.current.startOfDay(for: Date()) : Date()) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "calendar").font(ink.ui(12)).foregroundStyle(ink.muted).frame(width: 16)
                    Text("Pick a date").foregroundStyle(ink.muted)
                    Spacer(minLength: 0)
                }
                .font(ink.ui(12.5)).fieldFace(missing: field.error != nil)
            }
            .buttonStyle(.kitPress)
        }
    }

    private var bounds: ClosedRange<Date> {
        let low = field.min.flatMap(Extension.Form.date) ?? .distantPast, high = field.max.flatMap(Extension.Form.date) ?? .distantFuture
        return low <= high ? low...high : low...low
    }

    /// A day-only date goes at its local midnight, as Raycast's Date type is a whole day.
    private func put(_ date: Date) {
        model.set(field, .string(Extension.Form.wireDate(field.time == false ? Calendar.current.startOfDay(for: date) : date)))
    }
}

/// A file pick: what is picked (a name, or a count), a click opening the Mac's picker with the field's kinds, × clearing.
private struct FormFiles: View {
    @Environment(\.ink) private var ink
    let field: Extension.Form.Field
    let model: ExtensionFormModel

    private var paths: [String] { if case .array(let list)? = field.value { list.compactMap(\.string) } else { [] } }

    var body: some View {
        let paths = paths
        Button(action: choose) {
            HStack(spacing: 7) {
                Image(systemName: field.folders == true && field.files == false ? "folder" : "doc").font(ink.ui(12)).foregroundStyle(ink.muted).frame(width: 16)
                Text(paths.isEmpty ? "Choose…" : paths.count == 1 ? (paths[0] as NSString).abbreviatingWithTildeInPath : "\(paths.count) items")
                    .foregroundStyle(paths.isEmpty ? ink.muted : ink.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(ink.ui(12.5))
            .padding(.trailing, paths.isEmpty ? 0 : 18)
            .fieldFace(missing: field.error != nil)
        }
        .buttonStyle(.kitPress)
        .help(paths.joined(separator: "\n"))
        .accessibilityLabel(field.title ?? field.id ?? "").accessibilityValue(paths.isEmpty ? "none" : "\(paths.count) items")
        .overlay(alignment: .trailing) {
            if !paths.isEmpty {
                IconButton(symbol: "xmark", label: "Clear \(field.title ?? "")", size: 20, glyph: 9) { model.set(field, .array([])) }.padding(.trailing, 4)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = field.files != false
        panel.canChooseDirectories = field.folders == true
        panel.allowsMultipleSelection = field.multiple != false
        panel.showsHiddenFiles = field.hidden == true
        panel.message = field.title ?? ""
        guard panel.runModal() == .OK else { return }
        model.set(field, .array(panel.urls.map { .string($0.path) }))
    }
}
