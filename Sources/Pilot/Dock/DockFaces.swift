import AppKit
import PilotCore
import SwiftUI

/// The dock's widgets, drawn for the dock (design round 3, Sven 2026-11-13, Q214 B, label over value; build 2454:
/// "extensions dont look clear in dock"): a 24 pt glyph beside small capitals in text2 over a 17 pt semibold value, in
/// full ink, a warning amber and an alert red. Not the bar's 12 pt parts scaled up.
enum DockFaceMetrics {
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
    let widget: DockWidget
    let reader: DockWidgetSources
    let store: BarItemsStore
    /// Remove from Dock edits these; nil in a render.
    var dock: DockController?
    @State private var anchor = ScreenAnchor.Box()

    var body: some View {
        let shown = reader.body(widget)
        Button { click(shown) } label: { DockWidgetBodyView(widget: widget, shown: shown).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .background(ScreenAnchor(box: anchor, rightClick: { showMenu() }))
            .help(help(shown))
    }

    private func help(_ body: DockWidgetBody) -> String {
        guard case .setUp(let why) = body else { return widget.title }
        return "\(widget.title): " + DockWidgetBodyView.setUpWords(why)
    }

    private func click(_ body: DockWidgetBody) {
        if case .setUp(let why) = body { return setUp(why) }
        let view = anchor.view
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
        case .system: _ = AppsModule.open(bundle: AppsModule.resolved(.activityMonitor))
        case .battery: NSWorkspace.shared.open(Self.batterySettings)
        case .nextEvent:
            let now = reader.sources.readings.now
            let next = DockFaces.timed(reader.calendar.events).first { $0.end > now }
            if let url = next?.url { NSWorkspace.shared.open(url) } else { _ = AppsModule.open(bundle: Self.calendarApp) }
        case .timeline: _ = AppsModule.open(bundle: Self.calendarApp)
        }
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

    /// The right-click menu: the extension's page where it has one, Remove from Dock, Edit widgets (Menu bar's Dock card).
    private func showMenu() {
        guard let view = anchor.view else { return }
        BarPanel.shared.close()
        var rows: [BarMenu.Row] = []
        if let id = widget.extensionID, reader.extensionBar.items.first(where: { $0.id == id })?.hasPage == true {
            rows += [.pick("Open \(widget.title) page") { AppWindowController.shared.openExtensionPage(id) }, .separator]
        }
        rows += [.pick("Remove from Dock") { [dock, widget] in try? dock?.settings.remove(widget) },
                 .pick("Edit widgets…") { AppWindowController.shared.open(.menuBar) }]
        BarMenu.show(rows, under: view)
    }

    static let calendarApp = "com.apple.iCal"
    static let batterySettings = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
    static let bluetoothSettings = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!
}

/// A widget's body as drawn: its faces side by side, its timeline, or a Set up face.
struct DockWidgetBodyView: View {
    @Environment(\.ink) private var ink
    let widget: DockWidget
    let shown: DockWidgetBody

    var body: some View {
        switch shown {
        case .faces(let faces):
            HStack(spacing: DockFaceMetrics.faceGap) {
                ForEach(Array(faces.enumerated()), id: \.offset) { _, face in DockFaceView(face: face) }
            }
        case .timeline(let timeline): DockTimelineView(timeline: timeline)
        case .setUp:
            DockFaceView(face: DockFace(glyph: .symbol(widget.symbol), label: widget.title, value: "Set up"), setUp: true)
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

/// One face: its glyph beside small capitals over the value (treatment B).
struct DockFaceView: View {
    @Environment(\.ink) private var ink
    let face: DockFace
    /// Set up: the glyph quiet, the words in full ink (never the accent, which is red on some themes).
    var setUp = false

    var body: some View {
        HStack(spacing: 9) {
            glyph
            VStack(alignment: .leading, spacing: 1) {
                Text(face.label.uppercased()).font(ink.mono(10, weight: .semibold)).tracking(0.6).foregroundStyle(ink.text2).lineLimit(1)
                Text(face.value).font(ink.ui(DockFaceMetrics.value, .semibold)).monospacedDigit()
                    .foregroundStyle(setUp ? ink.text : toneInk ?? ink.text).lineLimit(1)
            }
            .frame(maxWidth: 190, alignment: .leading)
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
        let g = DockFaceMetrics.glyph
        switch face.glyph {
        case .symbol(let name, let multicolor):
            Image(systemName: name).font(.system(size: g * 0.86, weight: .medium))
                .symbolRenderingMode(multicolor ? .multicolor : .monochrome).foregroundStyle(setUp ? ink.text2 : ink.text)
                .frame(width: g, height: g)
        case .provider(let icon):
            ProviderGlyph(icon: icon).fill(icon.brand ?? ink.text).frame(width: g * 0.9, height: g * 0.9).frame(width: g, height: g)
        case .day(let weekday, let date):
            VStack(spacing: -1) {
                Text(weekday).font(.system(size: 8, weight: .bold)).foregroundStyle(BarLevelInk.status(\.problem, on: nil))
                Text(date).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(ink.text)
            }
            .frame(width: g + 8, height: g + 8)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ink.text.opacity(0.10)))
        case .image(let data):
            Group {
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: g * 0.5, weight: .semibold)).foregroundStyle(ink.text)
                }
            }
            .frame(width: g + 8, height: g + 8)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .ring(let share):
            ZStack {
                Circle().stroke(ink.text.opacity(0.18), lineWidth: 2.5)
                Circle().trim(from: 0, to: share).stroke(ink.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: g * 0.82, height: g * 0.82).frame(width: g, height: g)
        }
    }
}

/// The day timeline's wider face: small capitals over a bar of the day's hours, each event a block in its calendar's
/// colour, now a line in the ink, the bar spanning 8 to 20 or wider for an event outside them.
struct DockTimelineView: View {
    @Environment(\.ink) private var ink
    let timeline: DockTimeline

    var body: some View {
        let width = DockFaceMetrics.timelineWidth
        HStack(spacing: 9) {
            Image(systemName: "calendar.day.timeline.left").font(.system(size: DockFaceMetrics.glyph * 0.86, weight: .medium))
                .foregroundStyle(ink.text).frame(width: DockFaceMetrics.glyph, height: DockFaceMetrics.glyph)
            VStack(alignment: .leading, spacing: 5) {
                Text(timeline.label.uppercased()).font(ink.mono(10, weight: .semibold)).tracking(0.6).foregroundStyle(ink.text2).lineLimit(1)
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.text.opacity(0.14)).frame(width: width, height: 12)
                    ForEach(Array(timeline.spans.enumerated()), id: \.offset) { _, span in
                        let start = timeline.at(span.start) * width, end = timeline.at(span.end) * width
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(span.colour.map { Color($0) } ?? ink.accent)
                            .frame(width: max(3, end - start), height: 12)
                            .offset(x: start)
                    }
                    Capsule().fill(ink.text).frame(width: 2, height: 18).offset(x: timeline.at(timeline.now) * width - 1)
                }
                .frame(width: width, height: 18, alignment: .leading)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(timeline.label), \(timeline.spans.map(\.title).joined(separator: ", "))")
    }
}
