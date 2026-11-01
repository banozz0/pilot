import AppKit
import PilotCore
import SwiftUI

// Instrument's top bar (mockup A, pilot-redesign-A/src/topbar.html and common.css `.tb-*`; ADR 0008; card
// agent-bo-95423181): one opaque graphite or paper strip under a hairline, no boxes; the live workspace filled in the
// signal colour, a hairline between the bar's groups and before the workspaces another display shows, the app in front
// strong with its window's title quiet beside it, the running focus block on a soft signal pill, readings as small mono
// capitals beside mono values, and the clock's time in mono after its quiet date. Every item keeps its data, order,
// targets, hover, click and popover; only the drawing changes. The bar's popovers are their own surface
// (StyleSurface.barPopovers): KitPopover's Instrument branch, InstrumentStatPopover and InstrumentDropdown, with the
// hover pill, BarInk's Instrument faces and barButton below.

/// The strip's measures (topbar.html), in points.
enum InstrumentBar {
    /// Between two items: none, since each target's inset (BarMetrics.inset, 8 a side) already holds them 16 apart, the
    /// mockup's 12 to 14.
    static let spacing: CGFloat = 0
    /// The room a hairline adds before what it leads, between two items (25 from ink to ink, the mockup's 12, the rule and
    /// 12) or two workspaces (`.tb-ws b.p`'s 9).
    static let ruleRoom: CGFloat = 9
    /// A hairline's height (`.tb-sep`).
    static let ruleHeight: CGFloat = 14
    /// Between a value and its label or glyph (`.tb-rd`, `.tb-i`), and between the readings of a group (`.tb-r`).
    static let partGap: CGFloat = 5
    static let readingGap: CGFloat = 14
    /// A workspace's chip (`.tb-ws b`) and the gap between two.
    static let chip = CGSize(width: 22, height: 20)
    static let chipGap: CGFloat = 3
    /// A picked thing's ring (a picked chip's, Kit's picked state).
    static let ring: CGFloat = 1.5
    /// The focus pill (`.tb-focus`): its height, its insets, the dot's size and the gap between its parts.
    static let pillHeight: CGFloat = 22
    static let pillInset: CGFloat = 10
    static let pillGap: CGFloat = 8
    static let dot: CGFloat = 6
    /// The app in front's icon (`.tb-app img.ai`), the gap after it, and the most its window's title takes.
    static let appIcon: CGFloat = 15
    static let appGap: CGFloat = 7
    static let titleWidth: CGFloat = 260
    /// Pilot's mark (`.tb-mark`).
    static let mark: CGFloat = 14
    /// A reading's mini graph and meter (`.tb-mb`).
    static let graph = CGSize(width: 30, height: 12)
    static let meter: CGFloat = 22

    /// Where the strip's hairlines go on one side: before each item that starts a new group of the bar (Pilot and the
    /// workspaces; the apps; the readings; power, sound and input; time and focus), never beside a spacer or divider of
    /// Sven's own (topbar.html: workspaces | app, readings | sound | clock).
    static func hairlines(before slots: [BarSlot]) -> Set<Int> {
        let groups = slots.map(group)
        return Set(groups.indices.dropFirst().filter { groups[$0] != nil && groups[$0 - 1] != nil && groups[$0] != groups[$0 - 1] })
    }

    /// The bar's group a slot is in, in its order; nil for Sven's own spacers and dividers.
    private static func group(_ slot: BarSlot) -> Int? {
        switch slot.isGroup ? .readings : slot.kind.group {
        case .spacesAndWindows: [.pilot, .workspaces].contains(slot.kind) ? 0 : 1
        case .readings: 2
        case .power, .controls: 3
        case .timeAndFocus, .drops, .extensions: 4
        case .layout: nil
        }
    }

    /// The workspaces in the bar's order, this screen's first, then those another display shows (topbar.html splits
    /// workspace 4 off with a hairline: it is on the portrait display); `elsewhere` is where the second run starts, nil
    /// when every workspace is this screen's or which display holds them is not known. A workspace's display is the one
    /// showing it, else its windows' (`monitors`, TilerService.workspaceMonitors).
    static func displays(_ items: [TopBarWorkspaces.Item], here: Int?, shown: [AeroMonitorWorkspace], monitors: [String: Int])
        -> (items: [TopBarWorkspaces.Item], elsewhere: Int?) {
        guard let here else { return (items, nil) }
        let display = { (name: String) in shown.first { $0.workspace == name }?.monitorId ?? monitors[name] }
        let away = items.filter { display($0.name).map { $0 != here } ?? false }
        guard !away.isEmpty else { return (items, nil) }
        let mine = items.filter { item in !away.contains { $0.name == item.name } }
        return (mine + away, mine.isEmpty ? nil : mine.count)
    }
}

/// The timer as the focus pill says it: its title (Paused while held) and whether it is lit (a timer counting is live).
struct InstrumentBarFocus: Equatable {
    var word: String?
    var lit: Bool

}

extension InstrumentBarFocus {
    @MainActor init(_ timer: ExtensionTimer) {
        self.init(word: timer.isPaused ? "Paused" : timer.title, lit: !timer.isPaused && timer.title != nil)
    }
}

/// A slot's parts in Instrument: readings as mono capitals beside mono values, glyphs in the text colour, the timer
/// as the focus pill, the app in front strong with its window's title quiet; a reading past its threshold in the signal's
/// text colour (Instrument has no status colours, NOTES).
struct InstrumentBarParts: View {
    @Environment(\.style) private var style
    @Environment(\.barItemColours) private var itemColours
    @Environment(\.barGround) private var ground
    let items: [[BarPart]]
    var appIcon: NSImage?
    var windowTitle: String?
    var focus: InstrumentBarFocus?

    var body: some View {
        HStack(spacing: InstrumentBar.readingGap) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if item.contains(where: { if case .ring = $0 { true } else { false } }) {
                    pill(item)
                } else {
                    let warn = item.contains(.warn), level = BarLevelInk.colour(item, on: itemColours, ground: ground)
                    // Words and numbers sit on one baseline (`.tb-rd`); glyphs, graphs and meters centred.
                    HStack(alignment: item.allSatisfy(\.isWords) ? .firstTextBaseline : .center, spacing: InstrumentBar.partGap) {
                        ForEach(Array(item.enumerated()), id: \.offset) { _, part in view(part, warn: warn, level: level) }
                    }
                }
            }
        }
        .fixedSize()
    }

    /// A part; `level` is its reading's Item colour (BarLevelInk), over the signal's text past the threshold.
    @ViewBuilder private func view(_ part: BarPart, warn: Bool, level: Color? = nil) -> some View {
        let ink = level ?? style.color(warn ? \.accentText : \.text)
        switch part {
        case .label(let s): Text(s).styleText(\.barLabel).foregroundStyle(style.color(\.text3))
        case .reading(let stat): Text(stat.short).styleText(\.barLabel).foregroundStyle(style.color(\.text3)).accessibilityLabel(stat.title)
        case .value(let s, let widest): value(s, widest: widest, role: \.mono, ink: ink)
        case .text(let s), .date(let s): Text(s).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1)
        case .time(let s): Text(s).styleText(\.barTime).monospacedDigit().foregroundStyle(style.color(\.text)).lineLimit(1)
        case .graph(let points):
            Sparkline(points: points).frame(width: InstrumentBar.graph.width, height: InstrumentBar.graph.height).foregroundStyle(level ?? style.color(warn ? \.accentText : \.text2))
        case .bar(let share): InstrumentMeter(share: share).frame(width: InstrumentBar.meter)
        case .symbol(let name): Image(systemName: name).font(style.font(\.barIcon)).foregroundStyle(ink)
        case .mark: InstrumentMark(size: InstrumentBar.mark).foregroundStyle(style.color(\.text2))
        case .ring: Circle().fill(style.color(\.accent)).frame(width: InstrumentBar.dot, height: InstrumentBar.dot)
        case .badge(let s): Text(s).styleText(\.barStrong).foregroundStyle(style.color(\.text)).lineLimit(1)
        case .workspaces(let names, let current, let app):
            HStack(spacing: InstrumentBar.chipGap) {
                ForEach(names, id: \.self) { name in
                    InstrumentWorkspaceChip(label: BarParts.workspaceLabel(name, app: name == current ? app : nil), current: name == current,
                                            focused: name == current, occupied: true)
                }
            }
        case .dots(let count, let current):
            HStack(spacing: InstrumentBar.chipGap) {
                ForEach(0..<count, id: \.self) { i in
                    Circle().fill(style.color(i == current ? \.accent : \.line3)).frame(width: InstrumentBar.dot, height: InstrumentBar.dot)
                }
            }
        case .app(let name, let showsName):
            HStack(spacing: InstrumentBar.appGap) {
                if let appIcon { Image(nsImage: appIcon).resizable().interpolation(.high).frame(width: InstrumentBar.appIcon, height: InstrumentBar.appIcon) }
                if showsName || appIcon == nil { Text(name).styleText(\.barStrong).foregroundStyle(style.color(\.text)).lineLimit(1).fixedSize() }
                // `.tb-app span.ell`: the window's own title, quiet, cut at its end past the room the bar gives it.
                if showsName, let title = windowTitle, !title.isEmpty, title != name {
                    Text(title).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: InstrumentBar.titleWidth, alignment: .leading)
                }
            }
        case .strength(let bars):
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(BarParts.strengthHeights.enumerated()), id: \.offset) { i, h in
                    RoundedRectangle(cornerRadius: 1).fill(style.color(i < bars ? \.text : \.line3)).frame(width: 3, height: h)
                }
            }
        case .space(let points): Color.clear.frame(width: points, height: 1)
        case .divider: InstrumentRule(vertical: true, role: \.line2, length: InstrumentBar.ruleHeight)
        case .warn, .level: EmptyView()
        case .extensionItem(let face):
            ExtensionBarGlyph(face: face, ink: style.color(\.text2), font: style.font(\.mono)) { tone in
                // Item colours: a warning amber, an alert red, as the readings; off, the signal's text.
                switch (itemColours, tone) {
                case (true, .warn): BarLevelInk.status(\.amber, on: ground)
                case (true, .alert): BarLevelInk.status(\.problem, on: ground)
                default: style.color(tone == .fine ? \.text : \.accentText)
                }
            }
        }
    }

    /// A number held to the width of `widest`, so the item never jumps as it changes.
    private func value(_ s: String, widest: String?, role: KeyPath<StyleTypography, TypeRole>, ink: Color) -> some View {
        ZStack(alignment: .leading) {
            if let widest { Text(widest).hidden() }
            Text(s)
        }
        .styleText(role).monospacedDigit().foregroundStyle(ink)
    }

    /// The timer as `.tb-focus`: a dot, its title and its countdown on a soft signal pill while it counts; on the raised
    /// fill, the dot quiet, while held.
    private func pill(_ item: [BarPart]) -> some View {
        let lit = focus?.lit ?? true
        return HStack(spacing: InstrumentBar.pillGap) {
            Circle().fill(style.color(lit ? \.accent : \.text3)).frame(width: InstrumentBar.dot, height: InstrumentBar.dot)
            if let word = focus?.word { Text(word).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1).fixedSize() }
            ForEach(Array(item.enumerated()), id: \.offset) { _, part in
                if case .value(let s, let widest) = part { value(s, widest: widest, role: \.barTime, ink: style.color(lit ? \.accentText : \.text)) }
            }
        }
        .padding(.horizontal, InstrumentBar.pillInset).frame(height: InstrumentBar.pillHeight)
        .background(style.color(lit ? \.accentSoft : \.raised), in: .rect(cornerRadius: style.radii.control, style: .continuous))
    }
}

private extension BarPart {
    /// Words or numbers, which sit on a baseline.
    var isWords: Bool {
        switch self {
        case .label, .reading, .value, .text, .date, .time, .badge, .warn, .level: true
        default: false
        }
    }
}

/// A workspace (`.tb-ws b`): its number in mono; the live one (shown here with the focus) filled in the signal colour,
/// one shown here while another display has the focus raised on a hairline, the focused one elsewhere in the signal's
/// text colour, an occupied one in the text colour, an empty one quiet. The icons style adds its apps' icons
/// (WorkspaceAppIcons).
struct InstrumentWorkspaceChip: View {
    @Environment(\.style) private var style
    let label: String
    let current: Bool
    let focused: Bool
    let occupied: Bool
    var workspace: OccupiedWorkspace?

    var body: some View {
        // `.tb-ws b`: Geist Mono 500 at 11.5 in a box a point rounder than a chip's (the panels lane's measures).
        let radius = style.radii.control - 1
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let live = current && focused
        HStack(spacing: InstrumentBar.partGap) {
            Text(label).font(style.font(\.key, size: 11.5)).monospacedDigit().lineLimit(1).fixedSize()
            if let workspace, !workspace.apps.isEmpty { WorkspaceAppIcons(workspace: workspace, lit: current) }
        }
        .foregroundStyle(style.color(live ? \.onAccent : focused ? \.accentText : current || occupied ? \.text : \.text3))
        .padding(.horizontal, label.count > 1 || workspace != nil ? InstrumentBar.partGap : 0)
        .frame(minWidth: InstrumentBar.chip.width, minHeight: InstrumentBar.chip.height)
        .background { if live { shape.fill(style.color(\.accent)) } }
        .instrumentRaised(current && !live, radius: radius)
        .fixedSize()
    }
}

extension View {
    /// A hairline before this item when `on`, in `room` added at its leading edge, halfway between the ink before it
    /// (`gap` and the room away) and its own: the strip's groups, another display's workspaces.
    func instrumentRuleBefore(_ on: Bool, gap: CGFloat) -> some View { modifier(InstrumentRuleBefore(on: on, gap: gap)) }
}

private struct InstrumentRuleBefore: ViewModifier {
    let on: Bool
    let gap: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.leading, on ? InstrumentBar.ruleRoom : 0)
            .background(alignment: .leading) {
                if on { InstrumentRule(vertical: true, role: \.line2, length: InstrumentBar.ruleHeight).offset(x: (InstrumentBar.ruleRoom - gap - 1) / 2) }
            }
    }
}

/// The hover's pill in Instrument: the raised fill on a hairline ring, as a picked row is raised.
struct InstrumentHoverPill: ViewModifier {
    @Environment(\.style) private var style
    let lit: Bool

    func body(content: Content) -> some View {
        if style.kind == .instrument {
            content.background {
                if lit {
                    let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
                    shape.fill(style.color(\.raised)).overlay { shape.strokeBorder(style.color(\.line)) }.padding(.vertical, 3)
                }
            }
        } else {
            content.modifier(BarHoverPill(lit: lit))
        }
    }
}

/// The tooltip: one line on the panel colour, a key's hairline ring and edge, the control's corner.
struct InstrumentBarTooltip: View {
    @Environment(\.style) private var style
    let text: String

    var body: some View {
        Text(text).styleText(\.caption).foregroundStyle(style.color(\.text)).lineLimit(1).fixedSize()
            .padding(.horizontal, InstrumentBar.pillInset).frame(height: InstrumentBar.pillHeight)
            .styleSurface(\.key, fill: \.panel, radius: \.control)
    }
}

extension BarInk {
    /// Drawn in Instrument.
    var instrument: Bool { style.kind == .instrument }
    /// A popover's title: Instrument's Geist 600 13, else BarInk's headline.
    @MainActor var title: Font { instrument ? style.font(\.title) : headline }
    /// Numbers: Instrument's Geist Mono, else BarInk's mono.
    @MainActor func readout(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        instrument ? Ink(style: style).mono(size, weight: weight) : mono(size, weight: weight)
    }
    /// Small words under a heading: Instrument's caption, else BarInk's detail.
    @MainActor var words: Font { instrument ? style.font(\.caption) : detail }
    /// A rule across a popover: Instrument's hairline, Toybox's ink.
    @MainActor var rule: Color { instrument ? style.color(\.line) : style.color(\.outline) }
    /// A holiday in the clock's popover (Sven, 2026-10-23, Q418): red in every style, as a destructive action is
    /// (Ink.destructive); Toybox's salmon faint on cream, so a third of its ink outline in it on a light theme.
    @MainActor var holiday: Color {
        if instrument { return Ink(style: style).destructive }
        let red = style.colors.problem
        return style.dark ? Color(red) : Color(Paint(Contrast.hex(Contrast.mix(Contrast.rgb(style.colors.outline.rgb), Contrast.rgb(red.rgb), 0.3))))
    }
}

extension View {
    /// A popover's button: Instrument's raised or primary, else the kit's (`.pilot`, `.pilotPrimary`).
    func barButton(primary: Bool = false) -> some View { modifier(BarButton(primary: primary)) }
}

private struct BarButton: ViewModifier {
    @Environment(\.style) private var style
    let primary: Bool

    func body(content: Content) -> some View {
        if style.kind == .instrument {
            content.buttonStyle(InstrumentButtonStyle(kind: primary ? .primary : .raised))
        } else if primary {
            content.buttonStyle(.pilotPrimary)
        } else {
            content.buttonStyle(.pilot)
        }
    }
}

/// A reading's popover in Instrument (Home's This Mac in mockup A): a line per reading with its name, its last minutes as
/// a line ending in the signal's dot and its value in mono; then each reading's rows under its mono capitals on
/// hairlines, the busiest processes quieter; then the way into This Mac. The same rows and words as StatPopover.
struct InstrumentStatPopover: View {
    @Environment(\.style) private var style
    let popover: StatPopover

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 4) {
                ForEach(popover.stats, id: \.self) { stat in
                    if let value = MenuBarStats.value(stat, values: popover.values, raw: popover.latest) {
                        HStack(spacing: 12) {
                            Text(stat.title).styleText(\.body).foregroundStyle(style.color(\.text2)).frame(width: 90, alignment: .leading)
                            if stat.graphable {
                                InstrumentSpark(values: MenuBarStats.graph(stat, history: popover.history)).frame(width: 120, height: 22)
                            }
                            Spacer(minLength: 8)
                            Text(value).styleText(\.mono).monospacedDigit().foregroundStyle(style.color(\.text))
                        }
                        .frame(minHeight: 30)
                    }
                }
            }
            ForEach(popover.stats, id: \.self) { stat in
                let rows = MenuBarStats.rows(stat, in: popover.rows), busiest = popover.busiest[stat] ?? []
                InstrumentEyebrow(text: stat.title).padding(.top, 16).padding(.bottom, 6)
                VStack(spacing: 0) {
                    if rows.isEmpty { line(Text("No reading on this Mac").foregroundStyle(style.color(\.text3)), nil, first: true) }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        line(Text(row.name).foregroundStyle(style.color(\.text)), Text(row.value).foregroundStyle(style.color(\.text)), first: index == 0)
                            .help(row.explanation)
                    }
                    ForEach(Array(busiest.enumerated()), id: \.element.id) { index, row in
                        line(Text(row.name).foregroundStyle(style.color(\.text2)), Text(row.value).foregroundStyle(style.color(\.text2)),
                             first: rows.isEmpty && index == 0, middle: true)
                    }
                }
            }
            Button("Open This Mac in Pilot", action: popover.openHome).buttonStyle(InstrumentButtonStyle(kind: .raised)).padding(.top, 16)
        }
        .barPopover(width: 360)
    }

    /// A row on a hairline: its name, then its value in mono.
    private func line(_ name: Text, _ value: Text?, first: Bool, middle: Bool = false) -> some View {
        HStack(spacing: 10) {
            name.styleText(\.body).lineLimit(1).truncationMode(middle ? .middle : .tail)
            Spacer(minLength: 8)
            value?.styleText(\.mono).monospacedDigit()
        }
        .frame(minHeight: 30)
        .overlay(alignment: .top) { if !first { InstrumentRule() } }
    }
}
