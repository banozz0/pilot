import AppKit
import PilotCore
import SwiftUI

/// The dock's widgets, drawn for the dock (design round 3, Sven 2026-11-13, Q214 B, label over value; build 2454:
/// "extensions dont look clear in dock"): a 24 pt glyph beside small capitals in text2 over a 17 pt semibold value, in
/// full ink, a warning amber and an alert red. Not the bar's 12 pt parts scaled up.
enum DockFaceMetrics {
    /// Medium's measures; every widget face multiplies them by the dock's scale (DockScale).
    static let glyph: CGFloat = 24
    static let value: CGFloat = 17
    /// Between faces of one widget, and between widgets.
    static let faceGap: CGFloat = 16
    static let widgetGap: CGFloat = 28
    /// The day timeline's bar.
    static let timelineWidth: CGFloat = 168
}

/// One widget in the dock: its faces, its timeline or its Set up face. A click opens what it reads (an extension's
/// popover, the timer's, Calendar, Activity Monitor) or, on Set up, where it is set up; a right click lists Open page,
/// Remove from Dock and Edit widgets.
struct DockWidgetView: View {
    let slot: DockSlot
    let reader: DockWidgetSources
    let store: BarItemsStore
    /// Remove from Dock edits these; nil in a render.
    var dock: DockController?
    @State private var anchor = ScreenAnchor.Box()

    /// The built-in widget it is; an extension slot reads as the extension's own (Set up's words, the popover).
    private var widget: DockWidget? { slot.widget }

    var body: some View {
        // The stopwatch ticks by the second only while it runs, in its own view; nothing else redraws.
        if reader.ticks(slot) {
            TimelineView(.periodic(from: .now, by: 1)) { context in content(reader.body(slot, now: context.date)) }
        } else {
            content(reader.body(slot))
        }
    }

    /// One button for the widget, or one per face where each face does its own thing (a toggle, a stack).
    @ViewBuilder private func content(_ shown: DockWidgetBody) -> some View {
        Group {
            if case .faces(let faces) = shown, faces.contains(where: { $0.action != nil }) {
                DockWidgetBodyView(title: title, symbol: slot.symbol, shown: shown, act: { act($0, under: $1) })
            } else {
                Button { click(shown) } label: { DockWidgetBodyView(title: title, symbol: slot.symbol, shown: shown).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            }
        }
        .background(ScreenAnchor(box: anchor, rightClick: { showMenu() }))
        .help(help(shown))
        // Today's events again as the day turns: read in the Calendar widgets alone, so the clock's tick (each second
        // with seconds shown) redraws them, never the pill.
        .onChange(of: day) { reader.calendar.follow(now: reader.sources.readings.now) }
    }

    /// A face's own click: a toggle switches (the output lists its devices), a stack lists its files.
    private func act(_ action: DockFace.Action, under view: NSView?) {
        let readings = reader.sources.readings, extras = reader.extras
        switch action {
        // Wi-Fi and Bluetooth through the top bar's own switches.
        case .toggle(.wifi): reader.sources.perform(.radio(.wifi, on: !(readings.wifi?.on ?? false)), on: .wifi, store: store) {}
        case .toggle(.bluetooth):
            reader.sources.perform(.radio(.bluetooth, on: !(extras.bluetooth ?? false)), on: .bluetoothBatteries, store: store) {}
            Task { try? await Task.sleep(for: .seconds(2)); extras.readToggles() }
        case .toggle(.dnd): extras.toggleDND(shortcut: reader.options.dndShortcut)
        case .toggle(.mic): readings.sound.toggleMute(.input)
        // The output opens what the top bar's Volume opens.
        case .toggle(.output): barPopover([.volume], under: view)
        case .stack(let stack):
            extras.readFiles([stack])
            BarPanel.shared.toggle(dock: "dock.stack.\(stack.rawValue)", under: view, AnyView(DockLiveStack(extras: extras, stack: stack)))
        }
    }

    /// Today, for a Calendar widget only; nil for the rest, which never read the clock here.
    private var day: Date? {
        widget == .nextEvent || widget == .timeline ? Calendar.autoupdatingCurrent.startOfDay(for: reader.sources.readings.now) : nil
    }

    private var title: String { DockWidgetView.title(slot, bar: reader.extensionBar) }

    /// A slot's name in the dock and on the Dock page: a widget's title, an extension's own.
    static func title(_ slot: DockSlot, bar: ExtensionBar = .shared) -> String {
        switch slot {
        case .widget(let widget): widget.title
        case .extensionItem(let id): bar.items.first { $0.id == id }?.title ?? id
        }
    }

    private func help(_ body: DockWidgetBody) -> String {
        guard case .setUp(let why) = body else { return title }
        return "\(title): " + DockWidgetBodyView.setUpWords(why)
    }

    private func click(_ body: DockWidgetBody) {
        if case .setUp(let why) = body { return setUp(why) }
        let view = anchor.view
        guard let widget else {
            // An extension's bar answer: its popover, as the top bar opens it.
            guard let id = slot.extensionID else { return }
            return BarPanel.shared.toggle(extension: id, under: view, AnyView(ExtensionItemPopover(id: id, bar: reader.extensionBar)))
        }
        switch widget {
        case .aiUsage, .nowPlaying, .weather, .todo, .github, .markets:
            let id = widget.extensionID ?? widget.rawValue
            BarPanel.shared.toggle(extension: id, under: view, AnyView(ExtensionItemPopover(id: id, bar: reader.extensionBar)))
        case .focus:
            if reader.sources.timer.countdown == nil {
                BarPanel.shared.close()
                Engine.shared?.action("ext.pomodoro.focus")?.run()
            } else {
                BarPanel.shared.toggle([.timer], under: view, AnyView(BarPopover(kinds: [.timer], sources: reader.sources, store: store)))
            }
        // A widget a top bar item reads opens what that item opens (Sven on build 2470): the readings with their busiest
        // apps, the battery's, the clock's month and events.
        case .system: barPopover(reader.options.stats.map(BarKind.init), under: view)
        case .battery: barPopover([.battery], under: view)
        case .nextEvent, .timeline, .clock: barPopover([.clock], under: view)
        case .note:
            BarPanel.shared.close()
            NotesPanel.shared.show(note: NoteStore.scratch)
        case .stopwatch: reader.extras.stopwatch.toggle(Date())
        case .toggles, .stacks: break
        }
    }

    /// The top bar's popover for `kinds`, hung over the widget: what that item's click opens.
    private func barPopover(_ kinds: [BarKind], under view: NSView?) {
        BarPanel.shared.toggle(kinds, under: view, AnyView(BarPopover(kinds: kinds, sources: reader.sources, store: store)))
    }

    private func setUp(_ why: DockSetUp) {
        BarPanel.shared.close()
        switch why {
        case .install: AppWindowController.shared.open(AppPlace(.extensionCatalogue))
        case .settings(let id): AppWindowController.shared.open(AppPlace(.extensions), extension: id)
        case .askCalendar: Task { await reader.calendar.ask() }
        case .calendarPrivacy: NSWorkspace.shared.open(ClockCalendar.privacy)
        case .bluetooth: NSWorkspace.shared.open(Self.bluetoothSettings)
        }
    }

    /// The right-click menu: the extension's page where it has one, its settings where it has some (round 4), Remove
    /// from Dock, Edit widgets (the Dock page).
    private func showMenu() {
        guard let view = anchor.view else { return }
        BarPanel.shared.close()
        var rows: [BarMenu.Row] = []
        if let id = slot.extensionID, reader.extensionBar.items.first(where: { $0.id == id })?.hasPage == true {
            rows += [.pick("Open \(title) page") { AppWindowController.shared.openExtensionPage(id) }, .separator]
        }
        switch widget {
        case .system: rows += [.pick("Open Activity Monitor") { _ = AppsModule.open(bundle: AppsModule.resolved(.activityMonitor)) }, .separator]
        case .nextEvent, .timeline: rows += [.pick("Open Calendar") { _ = AppsModule.open(bundle: Self.calendarApp) }, .separator]
        case .stopwatch:
            let extras = reader.extras, timer = reader.sources.timer
            rows += [.pick("Reset") { extras.stopwatch.reset() }]
            rows += [5, 10, 25].map { minutes in
                .pick("Start a \(minutes) min timer") { timer.start(.init(title: "Timer", seconds: minutes * 60), owner: .init(id: "dock", title: "Dock")) }
            }
            rows.append(.separator)
        default: break
        }
        if DockPageFocus.hasSettings(slot) {
            rows.append(.pick("Widget settings…") { [slot] in DockPageFocus.shared.open(slot) })
        }
        // The top bar's sides, left or right of the apps (Sven, 2026-11-13).
        if let dock {
            let other: TopBarSide = dock.settings.side(slot) == .left ? .right : .left
            rows.append(.pick("Move to \(other.rawValue)") { [slot] in dock.settings.move(slot, to: other) })
        }
        rows += [.pick("Remove from Dock") { [dock, slot] in try? dock?.settings.remove(slot) },
                 .pick("Edit widgets…") { DockPageFocus.shared.open(nil) }]
        BarMenu.show(rows, under: view)
    }

    static let calendarApp = "com.apple.iCal"
    static let bluetoothSettings = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!
}

/// A widget's body as drawn: its faces side by side, its timeline, or a Set up face.
struct DockWidgetBodyView: View {
    @Environment(\.ink) private var ink
    /// The dock's size against Medium's (DockScale): every measure below scales with the icons.
    @Environment(\.dockScale) private var k
    /// Its name and symbol, drawn on its Set up face.
    let title: String
    let symbol: String
    let shown: DockWidgetBody
    /// Each face with an action is its own button, told its action and where it is drawn (for its panel).
    var act: ((DockFace.Action, NSView?) -> Void)? = nil

    var body: some View {
        switch shown {
        case .faces(let faces):
            HStack(spacing: DockFaceMetrics.faceGap * k) {
                ForEach(Array(faces.enumerated()), id: \.offset) { _, face in
                    if let act, let action = face.action { DockFaceButton(face: face) { act(action, $0) } } else { DockFaceView(face: face) }
                }
            }
        case .timeline(let timeline): DockTimelineView(timeline: timeline)
        case .setUp:
            DockFaceView(face: DockFace(glyph: .symbol(symbol), label: title, value: "Set up"), setUp: true)
        }
    }

    static func setUpWords(_ why: DockSetUp) -> String {
        switch why {
        case .install(let id): "install the \(id) extension from the catalogue"
        case .settings: "its extension needs a setting; click to open it"
        case .askCalendar: "click to let Pilot read Calendar"
        case .calendarPrivacy: "Calendar access is off; turn it on in Privacy & Security › Calendars"
        case .bluetooth: "no battery and no Bluetooth device reporting one"
        }
    }
}

extension DockWidgetBodyView {
    init(widget: DockWidget, shown: DockWidgetBody) { self.init(title: widget.title, symbol: widget.symbol, shown: shown) }
}

/// A face that is its own button: its view, its click told where it is drawn.
struct DockFaceButton: View {
    let face: DockFace
    let click: (NSView?) -> Void
    @State private var anchor = ScreenAnchor.Box()

    var body: some View {
        Button { click(anchor.view) } label: { DockFaceView(face: face).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .background(ScreenAnchor(box: anchor))
            .help("\(face.label): \(face.value)")
    }
}

/// A stack's panel over the files as last read, so a read finishing after it opens fills it.
struct DockLiveStack: View {
    let extras: DockExtras
    let stack: DockStack

    var body: some View {
        DockStackPanel(stack: stack, files: extras.files[stack] ?? []) { file in
            BarPanel.shared.close()
            FilesWindows.shared.newWindow(file.url.deletingLastPathComponent(), selecting: file.url)
        } openFolder: {
            BarPanel.shared.close()
            if let folder = extras.files[stack]?.first?.url.deletingLastPathComponent() { FilesWindows.shared.newWindow(folder) }
        }
    }
}

/// One face: its glyph beside small capitals over the value (treatment B).
struct DockFaceView: View {
    @Environment(\.ink) private var ink
    /// The dock's size against Medium's (DockScale): every measure below scales with the icons.
    @Environment(\.dockScale) private var k
    let face: DockFace
    /// Set up: the glyph quiet, the words in full ink (never the accent, which is red on some themes).
    var setUp = false

    var body: some View {
        switch face.kind {
        case .toggle(let on): toggle(on)
        case .flip: flip
        case .reading: reading
        }
    }

    /// A toggle: its glyph in a round button, lit in the accent while on, dimmed while it cannot be read.
    private func toggle(_ on: Bool?) -> some View {
        Image(systemName: glyphName).font(.system(size: 15 * k, weight: .semibold))
            .foregroundStyle(on == true ? ink.onAccent : on == nil ? ink.text2 : ink.text)
            .frame(width: 36 * k, height: 36 * k)
            .background(Circle().fill(on == true ? ink.accent : ink.text.opacity(0.10)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(face.label) \(face.value)")
    }

    private var glyphName: String { if case .symbol(let name, _) = face.glyph { name } else { "circle" } }

    /// Flip cards: the label over each digit on a card of its own, the separators between them bare.
    private var flip: some View {
        VStack(alignment: .leading, spacing: 3 * k) {
            Text(face.label.uppercased()).font(ink.mono(10 * k, weight: .semibold)).tracking(0.6 * k).foregroundStyle(ink.text2).lineLimit(1)
            HStack(spacing: 2 * k) {
                ForEach(Array(face.value.enumerated()), id: \.offset) { _, character in
                    if character.isNumber {
                        Text(String(character)).font(.system(size: 18 * k, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(ink.text)
                            .frame(width: 16 * k, height: 24 * k)
                            .background(RoundedRectangle(cornerRadius: 4 * k, style: .continuous).fill(ink.text.opacity(0.12)))
                            .overlay(Rectangle().fill(ink.text.opacity(0.18)).frame(height: 1))
                    } else {
                        Text(String(character)).font(.system(size: 16 * k, weight: .bold)).foregroundStyle(ink.text2)
                    }
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(face.label) \(face.value)")
    }

    @ViewBuilder private var reading: some View {
        // A face with no words (Now playing's Just ♫): its glyph alone.
        if face.label.isEmpty, face.value.isEmpty {
            glyph.accessibilityLabel(face.words)
        } else {
            words
        }
    }

    private var words: some View {
        HStack(spacing: 9 * k) {
            glyph
            VStack(alignment: .leading, spacing: 1 * k) {
                Text(face.label.uppercased()).font(ink.mono(10 * k, weight: .semibold)).tracking(0.6 * k).foregroundStyle(ink.text2).lineLimit(1)
                Text(face.value).font(ink.ui(DockFaceMetrics.value * k, .semibold)).monospacedDigit()
                    .foregroundStyle(setUp ? ink.text : toneInk ?? ink.text).lineLimit(1)
            }
            .frame(maxWidth: 190 * k, alignment: .leading)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(face.label) \(face.value)")
    }

    /// Item colours: a warning amber, an alert the theme's red; fine in plain ink.
    private var toneInk: Color? {
        switch face.tone {
        case .warn: BarLevelInk.status(\.amber, on: nil)
        case .alert: BarLevelInk.status(\.problem, on: nil)
        default: nil
        }
    }

    @ViewBuilder private var glyph: some View {
        let g = DockFaceMetrics.glyph * k
        switch face.glyph {
        case .symbol(let name, let multicolor):
            Image(systemName: name).font(.system(size: g * 0.86, weight: .medium))
                .symbolRenderingMode(multicolor ? .multicolor : .monochrome).foregroundStyle(setUp ? ink.text2 : ink.text)
                .frame(width: g, height: g)
        case .provider(let icon):
            ProviderGlyph(icon: icon).fill(icon.brand ?? ink.text).frame(width: g * 0.9, height: g * 0.9).frame(width: g, height: g)
        case .day(let weekday, let date):
            VStack(spacing: -1 * k) {
                Text(weekday).font(.system(size: 8 * k, weight: .bold)).foregroundStyle(BarLevelInk.status(\.problem, on: nil))
                Text(date).font(.system(size: 15 * k, weight: .semibold)).monospacedDigit().foregroundStyle(ink.text)
            }
            .frame(width: g + 8 * k, height: g + 8 * k)
            .background(RoundedRectangle(cornerRadius: 7 * k, style: .continuous).fill(ink.text.opacity(0.10)))
        case .image(let data):
            Group {
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: g * 0.5, weight: .semibold)).foregroundStyle(ink.text)
                }
            }
            .frame(width: g + 8 * k, height: g + 8 * k)
            .clipShape(RoundedRectangle(cornerRadius: 6 * k, style: .continuous))
        case .emoji(let text):
            Text(text).font(.system(size: g * 0.82)).frame(width: g, height: g)
        case .analog(let hour, let minute):
            ZStack {
                Circle().stroke(ink.text.opacity(0.35), lineWidth: 1.5 * k)
                Capsule().fill(ink.text).frame(width: 2 * k, height: g * 0.26).offset(y: -g * 0.13).rotationEffect(.degrees(hour * 30))
                Capsule().fill(ink.text).frame(width: 1.5 * k, height: g * 0.38).offset(y: -g * 0.19).rotationEffect(.degrees(minute * 6))
                Circle().fill(ink.accent).frame(width: 3 * k, height: 3 * k)
            }
            .frame(width: g, height: g)
        case .gauge(let share):
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3 * k).stroke(ink.text.opacity(0.45), lineWidth: 1.5 * k)
                RoundedRectangle(cornerRadius: 2 * k).fill(toneInk ?? ink.text).frame(width: max(2 * k, (g * 1.1 - 4 * k) * share)).padding(2 * k)
            }
            .frame(width: g * 1.1, height: g * 0.55).frame(height: g)
        case .dots(let filled, let count):
            HStack(spacing: 2 * k) {
                ForEach(0..<count, id: \.self) { i in Circle().fill(i < filled ? toneInk ?? ink.text : ink.text.opacity(0.18)).frame(width: 5 * k, height: 5 * k) }
            }
            .frame(height: g)
        case .ring(let share):
            ZStack {
                Circle().stroke(ink.text.opacity(0.18), lineWidth: 2.5 * k)
                Circle().trim(from: 0, to: share).stroke(ink.accent, style: StrokeStyle(lineWidth: 2.5 * k, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: g * 0.82, height: g * 0.82).frame(width: g, height: g)
        }
    }
}

/// The day timeline's wider face: small capitals over a bar of the day's hours, each event a block in its calendar's
/// colour, now a line in the ink, the bar spanning 8 to 20 or wider for an event outside them.
struct DockTimelineView: View {
    @Environment(\.ink) private var ink
    /// The dock's size against Medium's (DockScale): every measure below scales with the icons.
    @Environment(\.dockScale) private var k
    let timeline: DockTimeline

    var body: some View {
        let width = DockFaceMetrics.timelineWidth * k, glyph = DockFaceMetrics.glyph * k
        HStack(spacing: 9 * k) {
            Image(systemName: "calendar.day.timeline.left").font(.system(size: glyph * 0.86, weight: .medium))
                .foregroundStyle(ink.text).frame(width: glyph, height: glyph)
            VStack(alignment: .leading, spacing: 5 * k) {
                Text(timeline.label.uppercased()).font(ink.mono(10 * k, weight: .semibold)).tracking(0.6 * k).foregroundStyle(ink.text2).lineLimit(1)
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.text.opacity(0.14)).frame(width: width, height: 12 * k)
                    ForEach(Array(timeline.spans.enumerated()), id: \.offset) { _, span in
                        let start = timeline.at(span.start) * width, end = timeline.at(span.end) * width
                        RoundedRectangle(cornerRadius: 3 * k, style: .continuous)
                            .fill(span.colour.map { Color($0) } ?? ink.accent)
                            .frame(width: max(3 * k, end - start), height: 12 * k)
                            .offset(x: start)
                    }
                    Capsule().fill(ink.text).frame(width: 2 * k, height: 18 * k).offset(x: timeline.at(timeline.now) * width - 1)
                }
                .frame(width: width, height: 18 * k, alignment: .leading)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(timeline.label), \(timeline.spans.map(\.title).joined(separator: ", "))")
    }
}

/// The widgets' measures against the icons (Sven on build 2479, 2026-11-14: at Small "the widgets still show much larger
/// then the app icons"): DockFaceMetrics are Medium's, and each size scales them by its icon over Medium's, so a widget
/// keeps one ratio to the icons at Small, Medium and Large.
enum DockScale {
    static func of(_ size: DockSize) -> CGFloat { CGFloat(size.icon / DockSize.medium.icon) }
}

extension EnvironmentValues {
    @Entry var dockScale: CGFloat = 1
}
