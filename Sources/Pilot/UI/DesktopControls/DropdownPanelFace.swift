import AppKit
import PilotCore
import SwiftUI

/// What the Pilot menu shows (spec desktop-controls T2, T3; one fixed menu since 2026-11-20), as plain values: no
/// engine, no live source; empty hides a part. Running, Sound and Display are the pill's too.
struct DropdownPanelValues {

    struct Problem: Hashable {
        var title: String
        var detail: String?
        /// The one button that fixes it ("Allow", "Restart", "Open"), primary when it fixes it.
        var button: String?
        var fixes = true
    }

    struct Workspace: Hashable {
        var name: String
        var apps: [NSImage] = []
        var current = false
    }

    struct Switch: Hashable {
        var which: Dropdown.Switch
        var on: Bool
        /// What it is doing now: "Hyper+Space", "57 bound", "Off" (InstrumentDropdown's tile state).
        var state: String
        /// Its glyph, Key binds' the layer key's own sign; nil draws the Caps Lock one.
        var symbol: String? = nil
    }

    struct Running: Hashable {
        var symbol: String
        var title: String
        var detail: String
        /// A clock or a share, in mono digits.
        var reading: String?
        /// A share from 0 to 1 for a download; nil for a clock.
        var share: Double?
        var canPause = false
        /// False leaves Stop out: a download that finishes on its own.
        var canStop = true
    }

    struct Command: Hashable {
        var symbol: String
        var title: String
        /// Its bind as chips, the layer key's sign first ("⇪", "Space"); empty when it has none.
        var keys: [String] = []
    }

    struct Sound: Hashable { var device: String; var level: Double; var muted = false }
    struct Display: Hashable { var name: String; var level: Double }
    var pilotOn = true
    var hyperOn = true
    /// The Launcher switch: with Key binds off, Hyper+Space still works while it is on (spec pilot-ui-redesign T20).
    var launcherOn = true
    /// Accessibility granted, a password field holding secure input, Hyper held now: Dropdown.hyperLine's inputs.
    var trusted = true
    var secureInput = false
    var held = false
    /// The layer key's sign and name ("⇪", "Caps Lock").
    var layerSign = "⇪"
    var layerName = "Caps Lock"
    var problems: [Problem] = []
    var screen = "Studio display"
    var workspaces: [Workspace] = []
    /// The tiler is down: the Workspaces card says so in place of the workspaces, and the tiler problem's Restart leads.
    var workspacesStopped = false
    var switches: [Switch] = []
    /// While Option is held: the developer rows, then the recent presses as lines of text.
    var developer: [Command] = []
    var presses: [String] = []
    var updateReady = false
    /// The build has somewhere to check (`PilotUpdates.canCheck`): false leaves Check for updates out of the footer.
    var canCheckForUpdates = true
}

/// The Pilot menu (spec desktop-controls T2, reshaped by pilot-ui-redesign T21 to S4 B, shot 4b; fixed since 2026-11-20,
/// Sven: "pilot menu should be simple"): a head with Pilot's name and the Hyper chip, then any problem in its card, the
/// four switch tiles, the workspaces, the developer rows while Option is held, and the footer's rows, Open Pilot and
/// Quit Pilot. One column at 344 pt on the pop radius, hung under Pilot's item by BarPanel from the menu bar or Pilot's
/// top bar; past the room under it the cards scroll between the head and the footer.
///
/// The switch tiles and the workspaces are cards themselves, so they stand on the panel (shot 4b); a problem and the
/// developer rows sit in a card each. On is neutral (an ink disc); the signal colour marks Hyper and the current
/// workspace alone (DESIGN.md).
struct DropdownPanelFace: View {
    /// What a press asks for; the builder (T3, T4) runs it. Indexes are into the values' lists.
    enum Action: Hashable {
        /// The pill's Controls sliders.
        enum Level: Hashable { case sound, display }
        case fix(Int), workspace(String), toggle(Dropdown.Switch), developer(Int)
        case updates, settings, quit
    }

    @Environment(\.style) private var style
    /// The room under Pilot's item (BarPanel): past it the unpinned blocks scroll.
    @Environment(\.barPopoverRoom) private var room
    let values: DropdownPanelValues
    var reduceMotion = false
    var act: (Action) -> Void = { _ in }

    static let width: CGFloat = 344

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.pop, style: .continuous)
        let head = header.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
        let rest = cards.padding(.vertical, 8)
        Group {
            if let room {
                PinnedScrollLayout(room: room) {
                    head
                    ScrollView(.vertical) { rest }
                        .scrollBounceBehavior(.basedOnSize)
                        .mask { Self.edgeFade }
                    footer
                }
            } else {
                VStack(alignment: .leading, spacing: 0) { head; rest; footer }
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .background(style.color(\.panel), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line2)) }
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pilot menu")
    }

    /// Any problem, the switch tiles, the workspaces and, while Option is held, the developer rows; a part with nothing
    /// to show is left out.
    private var cards: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !values.problems.isEmpty { section(problems) }
            if !values.switches.isEmpty { switches.padding(.horizontal, 4) }
            if values.workspacesStopped { workspacesStopped.padding(.horizontal, 4) }
            else if !values.workspaces.isEmpty { workspaces.padding(.horizontal, 4) }
            if !values.developer.isEmpty || !values.presses.isEmpty { section(developer) }
        }
        .padding(.horizontal, 8)
    }

    /// The scroll's ends fade over the 8 pt gaps, so a card passing under the head or the footer softens at rest nothing.
    private static var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 8)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 8)
        }
    }

    /// A part in its own card.
    private func section(_ content: some View) -> some View { FaceCard(padding: 12) { content } }

    // MARK: Header

    /// Pilot's mark and name (the headline while something needs fixing), the Hyper chip at the right: "Hyper · Caps
    /// Lock" in the signal colour while Hyper is live, plain while it is not. Under them, only when Hyper is not as usual,
    /// the line that says why (Key binds off, Accessibility, a password field).
    private var header: some View {
        let live = values.hyperOn && values.trusted && !values.secureInput
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                InstrumentMark(size: 15).foregroundStyle(style.color(\.text)).frame(width: 20, height: 20)
                Text(values.problems.isEmpty ? "Pilot" : Dropdown.headline(isOn: values.pilotOn, problems: values.problems.count))
                    .font(style.font(\.title, size: 15)).foregroundStyle(style.color(\.text)).lineLimit(1)
                Spacer(minLength: 8)
                hyperChip(live: live)
            }
            if !live {
                Text(Dropdown.hyperLine(hyperOn: values.hyperOn, launcherOn: values.launcherOn, trusted: values.trusted, secureInput: values.secureInput,
                                        held: values.held, layerKey: values.layerName, problems: values.problems.count))
                    .styleText(\.caption).foregroundStyle(style.color(\.text2)).padding(.leading, 28)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func hyperChip(live: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        return Text(values.held && live ? "Hyper held" : "Hyper · \(values.layerName)")
            .font(style.font(\.mono, size: 11)).lineLimit(1).fixedSize()
            .foregroundStyle(style.color(live ? \.accentText : \.text2))
            .padding(.horizontal, 8).frame(height: 24)
            .background(style.color(live ? \.accentSoft : \.sunken), in: shape)
            .overlay { shape.strokeBorder(style.color(live ? \.accentLine : \.line)) }
            .accessibilityLabel(values.held && live ? "Hyper held" : "Hyper is \(values.layerName)\(live ? "" : ", off")")
    }

    // MARK: Blocks

    private var problems: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(values.problems.enumerated()), id: \.offset) { i, problem in
                HStack(alignment: .top, spacing: 10) {
                    InstrumentTick().padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.title).styleText(\.strong).foregroundStyle(style.color(\.text))
                        if let detail = problem.detail {
                            Text(detail).styleText(\.caption).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    if let button = problem.button {
                        Button(button) { act(.fix(i)) }.buttonStyle(InstrumentButtonStyle(kind: problem.fixes ? .primary : .raised))
                    }
                }
            }
        }
    }

    private func blockHead(_ title: String, _ trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            InstrumentEyebrow(text: title, role: \.text2)
            Spacer(minLength: 6)
            if let trailing { Text(trailing).styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1) }
        }
    }

    /// The workspaces in one row of numbered tiles under their eyebrow (shot 4b); the focused one ringed in the signal's
    /// line, an empty one's number faint.
    private var workspaces: some View {
        VStack(alignment: .leading, spacing: 8) {
            InstrumentEyebrow(text: "Workspaces", role: \.text2).padding(.leading, 2).padding(.top, 6)
            HStack(spacing: 6) {
                ForEach(values.workspaces, id: \.self) { workspace in
                    let shape = RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous)
                    Button { act(.workspace(workspace.name)) } label: {
                        Text(workspace.name).font(style.font(\.key, size: 12)).lineLimit(1)
                            .foregroundStyle(style.color(workspace.current ? \.text : workspace.apps.isEmpty ? \.text3 : \.text2))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(style.color(\.raised), in: shape)
                            .overlay { shape.strokeBorder(style.color(workspace.current ? \.accentLine : \.line), lineWidth: workspace.current ? 1.5 : 1) }
                            .contentShape(shape)
                    }
                    .buttonStyle(FacePress(reduceMotion: reduceMotion))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Workspace \(workspace.name)")
                    .accessibilityValue(workspace.apps.isEmpty ? "Empty" : "\(workspace.apps.count) apps")
                    .accessibilityAddTraits(workspace.current ? .isSelected : [])
                }
            }
        }
    }

    /// The tiler is down: one sunk tile in the workspaces' place says so; the problem's Restart, above, brings them back.
    private var workspacesStopped: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous)
        return VStack(alignment: .leading, spacing: 9) {
            blockHead("Workspaces", "Stopped")
            HStack(spacing: 9) {
                FaceGlyph(symbol: "rectangle.split.3x1", on: false, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tiling is stopped").styleText(\.strong).foregroundStyle(style.color(\.text))
                    Text("The workspaces come back once it restarts").styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(style.color(\.sunken), in: shape)
            .overlay { shape.strokeBorder(style.color(\.line)) }
            .accessibilityElement(children: .combine)
        }
    }

    /// The switches as tiles, two to a row: the glyph in its disc, the name and what it does now (shot 4b).
    private var switches: some View {
        FaceColumns(items: values.switches, columns: 2, spacing: 8) { switchTile($0) }
    }

    /// What a switch does now, as a sentence: its first letter raised, unless it starts with a name such as macOS.
    static func sentence(_ words: String) -> String {
        guard let first = words.first, first.isLowercase, !words.hasPrefix("macOS") else { return words }
        return first.uppercased() + words.dropFirst()
    }

    /// On is an ink disc with the glyph cut out of it, off a hairline ring with a faint glyph: neutral both, so the signal
    /// stays Hyper's and the current workspace's.
    private func switchTile(_ item: DropdownPanelValues.Switch) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.card, style: .continuous)
        return Button { act(.toggle(item.which)) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol ?? item.which.symbol(layerKeys: [.capsLock]))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(style.color(item.on ? \.onInverse : \.text3))
                    .frame(width: 30, height: 30)
                    .background { if item.on { Circle().fill(style.color(\.inverse)) } }
                    .overlay { if !item.on { Circle().strokeBorder(style.color(\.line2)) } }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.which.title).styleText(\.strong).foregroundStyle(style.color(\.text)).lineLimit(1)
                    Text(item.state).styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(style.color(\.raised), in: shape)
            .overlay { shape.strokeBorder(style.color(\.line)) }
            .contentShape(shape)
        }
        .buttonStyle(FacePress(reduceMotion: reduceMotion))
        .accessibilityLabel(item.which.title)
        .accessibilityValue(item.on ? "On, \(item.state)" : "Off")
    }

    /// Option held: the developer rows as commands, then the recent presses as lines in mono, newest first.
    private var developer: some View {
        VStack(alignment: .leading, spacing: 4) {
            blockHead("Developer", "Option held").padding(.bottom, 4)
            ForEach(Array(values.developer.enumerated()), id: \.offset) { i, command in
                Button { act(.developer(i)) } label: { CommandRow(command: command, layerSign: values.layerSign).contentShape(Rectangle()) }
                    .buttonStyle(FacePress(reduceMotion: reduceMotion))
            }
            if !values.presses.isEmpty {
                InstrumentEyebrow(text: "Recent presses", role: \.text2).padding(.horizontal, 8).padding(.top, values.developer.isEmpty ? 0 : 8).padding(.bottom, 2)
                ForEach(Array(values.presses.enumerated()), id: \.offset) { _, line in
                    Text(line).font(style.font(\.mono, size: 11)).foregroundStyle(style.color(\.text2)).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 8).frame(minHeight: 20, alignment: .leading)
                        .help(line)
                }
            }
        }
    }

    /// The footer's rows under a hairline (shot 4b): Check for updates while the build has somewhere to check (Update
    /// ready, lit, once one waits), Open Pilot and Quit Pilot with their ⌘ keys. A row lights under the pointer, as a
    /// menu's does.
    private var footer: some View {
        VStack(spacing: 0) {
            InstrumentRule().padding(.horizontal, 14)
            VStack(spacing: 2) {
                if values.updateReady {
                    FooterRow(title: "Update ready", reduceMotion: reduceMotion, glyph: { FaceLiveDot(size: 7) }) { act(.updates) }
                } else if values.canCheckForUpdates {
                    FooterRow(title: "Check for updates", symbol: "arrow.triangle.2.circlepath", reduceMotion: reduceMotion) { act(.updates) }
                }
                FooterRow(title: "Open Pilot", symbol: "macwindow", keys: ["⌘", ","], reduceMotion: reduceMotion) { act(.settings) }
                FooterRow(title: "Quit Pilot", symbol: "power", keys: ["⌘", "Q"], reduceMotion: reduceMotion) { act(.quit) }
            }
            .padding(6)
        }
    }
}

/// One of the footer's rows: a glyph, the title, its ⌘ key faint at the right; the raised fill under the pointer.
private struct FooterRow<Glyph: View>: View {
    @Environment(\.style) private var style
    let title: String
    /// Its ⌘ key as legends, so the ⌘ sign draws as Instrument's keys draw it.
    var keys: [String] = []
    var reduceMotion = false
    @ViewBuilder var glyph: Glyph
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                glyph.frame(width: 18)
                Text(title).styleText(\.body).foregroundStyle(style.color(\.text)).lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 1) { ForEach(keys, id: \.self) { InstrumentLegend(text: $0) } }.foregroundStyle(style.color(\.text3))
            }
            .padding(.horizontal, 8).frame(minHeight: 32)
            .background(style.color(\.raised).opacity(hovered ? 1 : 0), in: RoundedRectangle(cornerRadius: style.radii.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(FacePress(reduceMotion: reduceMotion))
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(keys.joined())
    }
}

extension FooterRow where Glyph == FooterSymbol {
    init(title: String, symbol: String, keys: [String] = [], reduceMotion: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, keys: keys, reduceMotion: reduceMotion, glyph: { FooterSymbol(symbol: symbol) }, action: action)
    }
}

private struct FooterSymbol: View {
    @Environment(\.style) private var style
    let symbol: String
    var body: some View { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(style.color(\.text2)) }
}

/// The panel with a room (DropdownPanelFace): the header and pinned cards, the scroll, the footer, stacked. As tall as its
/// content until `room`; past it the scroll takes what the others leave, so the pins and the footer stay in sight.
private struct PinnedScrollLayout: Layout {
    let room: CGFloat

    private func heights(_ width: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        var heights = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)).height }
        guard heights.count == 3 else { return heights }
        heights[1] = min(heights[1], max(0, room - heights[0] - heights[2]))
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: width, height: heights(proposal.width, subviews).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (view, height) in zip(subviews, heights(bounds.width, subviews)) {
            view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: .init(width: bounds.width, height: height))
            y += height
        }
    }
}

/// One running thing: its glyph, what it is and where, its reading in mono digits, pause and stop where it has them.
struct RunningRow: View {
    @Environment(\.style) private var style
    let item: DropdownPanelValues.Running
    /// Another row in the list has Stop: a row without one keeps its place empty, so the readings line up.
    var stopColumn = false
    var reduceMotion = false
    var onPause: () -> Void = {}
    var onStop: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                FaceGlyph(symbol: item.symbol, on: true, size: 30)
                FaceLiveDot(size: 7).offset(x: 1, y: -1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).styleText(\.strong).foregroundStyle(style.color(\.text)).lineLimit(1)
                if let share = item.share {
                    ProgressBar(share: share).frame(height: 3).padding(.vertical, 3)
                } else {
                    Text(item.detail).styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let reading = item.reading {
                Text(reading).font(style.font(\.mono, size: 12)).monospacedDigit().foregroundStyle(style.color(\.text))
            }
            HStack(spacing: 4) {
                if item.canPause { roundButton("pause.fill", "Pause", onPause) }
                if item.canStop { roundButton("stop.fill", "Stop", onStop) } else if stopColumn { Color.clear.frame(width: 26, height: 26) }
            }
        }
    }

    private func roundButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(style.color(\.text))
                .frame(width: 26, height: 26)
                .background(style.color(\.raised), in: Circle())
                .overlay { Circle().strokeBorder(style.color(\.line2)) }
        }
        .buttonStyle(FacePress(reduceMotion: reduceMotion))
        .accessibilityLabel(label)
    }

    private struct ProgressBar: View {
        @Environment(\.style) private var style
        let share: Double
        var body: some View {
            GeometryReader { space in
                ZStack(alignment: .leading) {
                    Capsule(style: .circular).fill(style.color(\.sunken))
                    Capsule(style: .circular).fill(style.color(\.text2)).frame(width: space.size.width * min(max(share, 0), 1))
                }
            }
        }
    }
}

/// A command: its glyph, its title, its keys as chips, the layer key's in the signal colour.
struct CommandRow: View {
    @Environment(\.style) private var style
    let command: DropdownPanelValues.Command
    var layerSign = "⇪"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(style.color(\.text2)).frame(width: 16)
            Text(command.title).styleText(\.body).foregroundStyle(style.color(\.text)).lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 3) {
                ForEach(Array(command.keys.enumerated()), id: \.offset) { _, cap in InstrumentKey(text: cap, hyper: cap == layerSign) }
            }
        }
        .padding(.horizontal, 8).frame(minHeight: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.keys.isEmpty ? command.title
            : "\(command.title), \(command.keys.map { $0 == layerSign ? "Hyper" : $0 }.joined(separator: " "))")
    }
}
