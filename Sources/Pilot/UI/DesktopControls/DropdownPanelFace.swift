import AppKit
import PilotCore
import SwiftUI

/// What the tall Dropdown panel shows (spec desktop-controls T2, T3, T4), as plain values: no engine, no live source. T3
/// fills it from today's Dropdown blocks, T4 adds the optional ones and the saved order; nil or empty hides a block.
struct DropdownPanelValues {
    /// The blocks in the order they draw; empty draws `defaultOrder`. A block left out is hidden, but Status always
    /// leads, the developer rows follow the commands while Option is held, and the footer always closes.
    var order: [Dropdown.Block] = []
    /// Blocks held above the scroll, in `order`'s order: once the panel meets `barPopoverRoom`, the rest scroll under them.
    var pinned: Set<Dropdown.Block> = []

    /// Today's order, the optional blocks before the commands, as T4's `Dropdown.Layout.arrangeable` lists them.
    static let defaultOrder: [Dropdown.Block] = [.status, .workspaces, .quickSwitches, .extensions, .now, .sound, .connections, .display,
                                                 .media, .stats, .rows, .developer]

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
        /// What it is doing now: `Dropdown.Switch.state`.
        var state: String
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
    struct Connections: Hashable {
        var wifiOn: Bool
        /// 0 to 3 bars. Never the network's name: that needs Location, which Pilot never asks (WiFiPopover).
        var wifiBars: Int
        var bluetoothOn: Bool
        var bluetoothDetail: String
    }
    struct Display: Hashable { var name: String; var level: Double }
    /// One extension's bar item in the Extensions card: its emoji, title, a line under it (or why it has nothing), and
    /// the bar's text.
    struct Extension: Hashable {
        var emoji: String
        var title: String
        var text: String
        var detail: String?
        var problem: String?
    }
    struct Media: Hashable {
        var title: String
        var artist: String
        var art: NSImage?
        var playing: Bool
    }
    struct Stats: Hashable {
        var cpu: Int
        var memoryUsed: Double
        var memoryTotal: Double
        var battery: Int?
        var charging = false
    }

    var pilotOn = true
    var hyperOn = true
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
    var running: [Running] = []
    var commands: [Command] = []
    /// How many of `commands` lead the card, the rest behind All commands; 0 lists every command under a plain head.
    var pinnedCommands = 0
    /// While Option is held: the developer rows, then the recent presses as lines of text.
    var developer: [Command] = []
    var presses: [String] = []
    var sound: Sound?
    var connections: Connections?
    var display: Display?
    var media: Media?
    var stats: Stats?
    var extensions: [Extension] = []
    var updateReady = false
    /// The build has somewhere to check (`PilotUpdates.canCheck`): false leaves Check for updates out of the footer.
    var canCheckForUpdates = true
}

/// The tall Pilot menu (spec desktop-controls T2): reference 1794159386534's attachment, hierarchy and density with
/// Pilot's own blocks: status with any problem first, the workspaces, six switches, what is running, the optional
/// sound, connections, display, media and stats blocks (off by default), the commands with their keys, and the
/// footer. One column at 344 pt on the pop radius, hung under Pilot's item by BarPanel as today's Dropdown is.
///
/// Each block sits in its own card, as the reference groups them (Sven's pick A, 2026-11-10, over one sheet between
/// hairlines).
struct DropdownPanelFace: View {
    /// What a press asks for; the builder (T3, T4) runs it. Indexes are into the values' lists.
    enum Action: Hashable {
        enum Connection: Hashable { case wifi, bluetooth }
        enum Level: Hashable { case sound, display }
        enum Media: Hashable { case previous, playPause, next }
        case arrange, fix(Int), workspace(String), toggle(Dropdown.Switch), pause(Int), stop(Int)
        case connection(Connection), level(Level, Double), media(Media), command(Int), allCommands, developer(Int), extensionPage(Int)
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
        let cards = Self.cards(values)
        let rest = column(cards.rest).padding(.top, cards.rest.isEmpty ? 0 : 8).padding(.bottom, 8)
        Group {
            if let room {
                PinnedScrollLayout(room: room) {
                    top(cards.pinned)
                    ScrollView(.vertical) { rest }
                        .scrollBounceBehavior(.basedOnSize)
                        .mask { Self.edgeFade }
                    footer
                }
            } else {
                VStack(alignment: .leading, spacing: 0) { top(cards.pinned); rest; footer }
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .background(style.color(\.panel), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line2)) }
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pilot menu")
    }

    /// The header and the pinned cards, which stay put while the rest scroll.
    private func top(_ pinned: [[Dropdown.Block]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, pinned.isEmpty ? 4 : 12)
            if !pinned.isEmpty { column(pinned) }
        }
    }

    private func column(_ cards: [[Dropdown.Block]]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cards, id: \.self) { card in
                section(VStack(alignment: .leading, spacing: 12) { ForEach(card, id: \.self) { block($0) } })
            }
        }
        .padding(.horizontal, 8)
    }

    /// The scroll's ends fade over the 8 pt gaps, so a card passing under the pins or the footer softens at rest nothing.
    private static var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 8)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 8)
        }
    }

    /// The blocks as cards in draw order, split at the pins: Status first whatever `order` says, the developer rows after
    /// the commands when `order` leaves them out, a block with nothing to show dropped, and Sound and Brightness sharing
    /// one card when they sit together.
    static func cards(_ values: DropdownPanelValues) -> (pinned: [[Dropdown.Block]], rest: [[Dropdown.Block]]) {
        var order: [Dropdown.Block] = []
        for block in [.status] + (values.order.isEmpty ? DropdownPanelValues.defaultOrder : values.order) where block != .footer && !order.contains(block) {
            order.append(block)
        }
        if !order.contains(.developer) { order.insert(.developer, at: order.firstIndex(of: .rows).map { $0 + 1 } ?? order.endIndex) }
        let shown = order.filter { shows($0, values) }
        func grouped(_ blocks: [Dropdown.Block]) -> [[Dropdown.Block]] {
            blocks.reduce(into: []) { cards, block in
                if let last = cards.last, last.count == 1, Set(last + [block]) == [.sound, .display] { cards[cards.count - 1].append(block) }
                else { cards.append([block]) }
            }
        }
        return (grouped(shown.filter(values.pinned.contains)), grouped(shown.filter { !values.pinned.contains($0) }))
    }

    private static func shows(_ block: Dropdown.Block, _ values: DropdownPanelValues) -> Bool {
        switch block {
        case .status: !values.problems.isEmpty
        case .workspaces: !values.workspaces.isEmpty || values.workspacesStopped
        case .quickSwitches: !values.switches.isEmpty
        case .now: !values.running.isEmpty
        case .rows: !values.commands.isEmpty
        case .developer: !values.developer.isEmpty || !values.presses.isEmpty
        case .sound: values.sound != nil
        case .connections: values.connections != nil
        case .display: values.display != nil
        case .media: values.media != nil
        case .stats: values.stats != nil
        case .extensions: !values.extensions.isEmpty
        case .footer: false
        }
    }

    @ViewBuilder private func block(_ block: Dropdown.Block) -> some View {
        switch block {
        case .status: problems
        case .workspaces: if values.workspacesStopped { workspacesStopped } else { workspaces }
        case .quickSwitches: switches
        case .now: running
        case .rows: commands
        case .developer: developer
        case .sound: if let sound = values.sound { self.sound(sound) }
        case .connections: if let connections = values.connections { self.connections(connections) }
        case .display: if let display = values.display { self.display(display) }
        case .media: if let media = values.media { self.media(media) }
        case .stats: if let stats = values.stats { self.stats(stats) }
        case .extensions: extensions
        case .footer: EmptyView()
        }
    }

    /// A block in its own card.
    private func section(_ content: some View) -> some View { FaceCard(padding: 12) { content } }

    // MARK: Extensions

    /// The extensions' bar items Sven picked (Q74 A, his pick of the mock-up, 2026-11-11): a row each, its emoji, title, a
    /// line under it (why it has nothing, muted behind a warning glyph), the bar's text at the right; a row opens its page
    /// (Q76).
    private var extensions: some View {
        VStack(alignment: .leading, spacing: 10) {
            blockHead("Extensions", "\(values.extensions.count) in the menu")
            ForEach(Array(values.extensions.enumerated()), id: \.offset) { i, item in
                Button { act(.extensionPage(i)) } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Text(item.emoji).font(.system(size: 15)).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).styleText(\.strong).foregroundStyle(style.color(\.text)).lineLimit(1)
                            if let problem = item.problem {
                                // Muted with a warning glyph: Instrument's warn is its signal colour, kept for Hyper and live.
                                Label(problem, systemImage: "exclamationmark.triangle").labelStyle(.titleAndIcon)
                                    .styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1).help(problem)
                            } else if let detail = item.detail {
                                Text(detail).styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1).help(detail)
                            }
                        }
                        Spacer(minLength: 6)
                        Text(item.text).font(style.font(\.mono, size: 12)).monospacedDigit().lineLimit(1)
                            .foregroundStyle(style.color(item.problem == nil ? \.text : \.text3))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(FacePress(reduceMotion: reduceMotion))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.problem ?? [item.text, item.detail].compactMap { $0 }.joined(separator: ", "))
                .accessibilityHint("Opens its page")
            }
        }
    }

    // MARK: Header

    /// Pilot's mark, the headline, Hyper's key in the signal colour; the arrange button at the right (T4's edit list).
    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            InstrumentMark(size: 22).foregroundStyle(style.color(\.text)).frame(width: 30, height: 30)
                .background(style.color(\.raised), in: RoundedRectangle(cornerRadius: style.radii.control, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: style.radii.control, style: .continuous).strokeBorder(style.color(\.line2)) }
            VStack(alignment: .leading, spacing: 3) {
                Text(Dropdown.headline(isOn: values.pilotOn, problems: values.problems.count))
                    .font(style.font(\.title, size: 14)).foregroundStyle(style.color(\.text))
                HStack(spacing: 5) {
                    if values.hyperOn, values.problems.isEmpty, values.trusted, !values.held {
                        Text("Hyper is")
                        InstrumentKey(text: values.layerSign, hyper: true)
                        Text(values.layerName)
                    } else {
                        Text(Dropdown.hyperLine(hyperOn: values.hyperOn, trusted: values.trusted, secureInput: values.secureInput,
                                                held: values.held, layerKey: values.layerName, problems: values.problems.count))
                    }
                }
                .styleText(\.caption).foregroundStyle(style.color(\.text2))
            }
            Spacer(minLength: 0)
            Button { act(.arrange) } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(style.color(\.text2)).frame(width: 28, height: 28)
                    .background(style.color(\.raised), in: Circle())
                    .overlay { Circle().strokeBorder(style.color(\.line)) }
            }
            .buttonStyle(FacePress(reduceMotion: reduceMotion))
            .help("Arrange the menu")
            .accessibilityLabel("Arrange the menu")
        }
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

    /// The workspaces in one row: the number in mono over its apps; the focused one ringed in the signal's line.
    private var workspaces: some View {
        VStack(alignment: .leading, spacing: 9) {
            blockHead("Workspaces", values.screen)
            HStack(spacing: 5) {
                ForEach(values.workspaces, id: \.self) { workspace in
                    let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
                    Button { act(.workspace(workspace.name)) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(workspace.name).font(style.font(\.key, size: 11))
                            .foregroundStyle(style.color(workspace.current ? \.accentText : workspace.apps.isEmpty ? \.text2 : \.text))
                        HStack(spacing: -3) {
                            ForEach(Array(workspace.apps.prefix(3).enumerated()), id: \.offset) { _, icon in
                                Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                            }
                        }
                        .frame(height: 15)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
                    .background(style.color(workspace.current ? \.panel : \.sunken), in: shape)
                    .overlay { shape.strokeBorder(style.color(workspace.current ? \.accentLine : \.line), lineWidth: workspace.current ? 1.5 : 1) }
                    .contentShape(shape)
                    }
                    .buttonStyle(FacePress(reduceMotion: reduceMotion))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Workspace \(workspace.name)")
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

    /// The six switches: two columns of tiles with the glyph, the name and what it does now.
    private var switches: some View {
        FaceColumns(items: values.switches, columns: 2) { switchTile($0) }
    }

    /// What a switch does now, as a sentence: its first letter raised, unless it starts with a name such as macOS.
    static func sentence(_ words: String) -> String {
        guard let first = words.first, first.isLowercase, !words.hasPrefix("macOS") else { return words }
        return first.uppercased() + words.dropFirst()
    }

    private func switchTile(_ item: DropdownPanelValues.Switch) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous)
        return Button { act(.toggle(item.which)) } label: {
            HStack(spacing: 9) {
                FaceGlyph(symbol: item.which.symbol(layerKeys: [.capsLock]), on: item.on, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.which.title).styleText(\.strong).foregroundStyle(style.color(item.on ? \.text : \.text2)).lineLimit(1)
                    Text(Self.sentence(item.state)).styleText(\.small)
                        .foregroundStyle(style.color(\.text2)).lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(style.color(item.on ? \.panel : \.sunken), in: shape)
            .overlay { shape.strokeBorder(style.color(item.on ? \.line2 : \.line)) }
            .contentShape(shape)
        }
        .buttonStyle(FacePress(reduceMotion: reduceMotion))
        .accessibilityLabel(item.which.title)
        .accessibilityValue(item.on ? "On" : "Off")
    }

    /// What runs now: a recording, a focus timer, a download, each with its reading and its buttons.
    private var running: some View {
        VStack(alignment: .leading, spacing: 9) {
            blockHead("Running now", values.running.count == 1 ? "1 active" : "\(values.running.count) active")
            let stopColumn = values.running.contains(where: \.canStop)
            ForEach(Array(values.running.enumerated()), id: \.offset) { i, item in
                RunningRow(item: item, stopColumn: stopColumn, reduceMotion: reduceMotion, onPause: { act(.pause(i)) }, onStop: { act(.stop(i)) })
            }
        }
    }

    /// Wi-Fi and Bluetooth as two tiles, as the reference has them, without the network's name.
    private func connections(_ value: DropdownPanelValues.Connections) -> some View {
        HStack(spacing: 6) {
            connection(.wifi, value.wifiOn ? "wifi" : "wifi.slash", "Wi-Fi", value.wifiOn ? Self.signal(value.wifiBars) : "Off", on: value.wifiOn)
            connection(.bluetooth, "antenna.radiowaves.left.and.right", "Bluetooth", value.bluetoothOn ? value.bluetoothDetail : "Off", on: value.bluetoothOn)
        }
    }

    static func signal(_ bars: Int) -> String {
        switch bars {
        case 3...: "On · Strong signal"
        case 2: "On · Good signal"
        case 1: "On · Weak signal"
        default: "On · No network"
        }
    }

    private func connection(_ kind: Action.Connection, _ symbol: String, _ title: String, _ detail: String, on: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous)
        return Button { act(.connection(kind)) } label: {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                FaceGlyph(symbol: symbol, on: on, size: 28)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(style.color(\.text3))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).styleText(\.strong).foregroundStyle(style.color(\.text))
                Text(detail).styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color(\.panel), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line)) }
        .contentShape(shape)
        }
        .buttonStyle(FacePress(reduceMotion: reduceMotion))
    }

    /// Sound and brightness, one slider each with its reading; side by side in the order they share one card.
    private func sound(_ sound: DropdownPanelValues.Sound) -> some View {
        level(.sound, sound.muted ? "speaker.slash" : "speaker.wave.2", "Sound", sound.device, sound.muted ? "Muted" : "\(Int(sound.level * 100)) %",
              sound.level, muted: sound.muted)
    }

    private func display(_ display: DropdownPanelValues.Display) -> some View {
        level(.display, "sun.max", "Brightness", display.name, "\(Int(display.level * 100)) %", display.level)
    }

    private func level(_ kind: Action.Level, _ symbol: String, _ title: String, _ detail: String, _ reading: String, _ value: Double, muted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(style.color(\.text2)).frame(width: 16)
                Text(title).styleText(\.strong).foregroundStyle(style.color(\.text))
                Text(detail).styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1)
                Spacer(minLength: 4)
                Text(reading).font(style.font(\.mono, size: 11)).monospacedDigit().foregroundStyle(style.color(\.text2))
            }
            FaceSlider(value: value, muted: muted, label: title) { act(.level(kind, $0)) }
        }
    }

    private func media(_ value: DropdownPanelValues.Media) -> some View {
        HStack(spacing: 10) {
            FaceArt(image: value.art, size: CGSize(width: 38, height: 38), radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(value.title).styleText(\.strong).foregroundStyle(style.color(\.text)).lineLimit(1)
                Text(value.artist).styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                mediaButton("backward.fill", "Previous", .previous)
                mediaButton(value.playing ? "pause.fill" : "play.fill", value.playing ? "Pause" : "Play", .playPause)
                mediaButton("forward.fill", "Next", .next)
            }
        }
    }

    private func mediaButton(_ symbol: String, _ label: String, _ media: Action.Media) -> some View {
        Button { act(.media(media)) } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(style.color(\.text))
                .frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(FacePress(reduceMotion: reduceMotion))
        .accessibilityLabel(label)
    }

    /// Battery, CPU and memory as three readings, the number large in mono digits (the reference's bottom row).
    private func stats(_ value: DropdownPanelValues.Stats) -> some View {
        HStack(spacing: 6) {
            if let battery = value.battery {
                reading(value.charging ? "battery.100.bolt" : "battery.75", "Battery", "\(battery)", "%", value.charging ? "Charging" : "On battery")
            }
            reading("cpu", "CPU", "\(value.cpu)", "%", "In use")
            reading("memorychip", "Memory", String(format: "%.1f", value.memoryUsed), "GB", "of \(Int(value.memoryTotal)) GB")
        }
    }

    private func reading(_ symbol: String, _ title: String, _ number: String, _ unit: String, _ detail: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                Text(title).styleText(\.small)
            }
            .foregroundStyle(style.color(\.text2))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(number).font(style.font(\.mono, size: 20)).monospacedDigit().foregroundStyle(style.color(\.text))
                Text(unit).styleText(\.small).foregroundStyle(style.color(\.text2))
            }
            Text(detail).styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color(\.panel), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line)) }
    }

    /// The commands with their keys under one head. With some pinned, those lead and the rest wait behind All commands;
    /// with none pinned, every command is listed and there is no All commands row.
    private var commands: some View {
        let pinned = min(values.pinnedCommands, values.commands.count)
        let shown = pinned == 0 ? values.commands.count : pinned
        return VStack(alignment: .leading, spacing: 4) {
            blockHead("Commands", pinned == 0 ? nil : "\(pinned) pinned").padding(.bottom, 4)
            ForEach(Array(values.commands.prefix(shown).enumerated()), id: \.offset) { i, command in
                Button { act(.command(i)) } label: { CommandRow(command: command, layerSign: values.layerSign).contentShape(Rectangle()) }
                    .buttonStyle(FacePress(reduceMotion: reduceMotion))
            }
            if shown < values.commands.count {
                Button { act(.allCommands) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 12, weight: .medium)).foregroundStyle(style.color(\.text2)).frame(width: 16)
                        Text("All commands").styleText(\.body).foregroundStyle(style.color(\.text))
                        Spacer()
                        Text("\(values.commands.count - shown) more").styleText(\.small).foregroundStyle(style.color(\.text2))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(style.color(\.text3))
                    }
                    .padding(.horizontal, 8).frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FacePress(reduceMotion: reduceMotion))
                .accessibilityLabel("All commands, \(values.commands.count - shown) more")
            }
        }
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

    /// Check for updates at the left (lit while one is ready, left out when the build has nowhere to check), Settings and
    /// Quit with their keys at the right.
    private var footer: some View {
        VStack(spacing: 0) {
            InstrumentRule()
            HStack(spacing: 14) {
                if values.canCheckForUpdates || values.updateReady { updates }
                Spacer(minLength: 0)
                Button { act(.settings) } label: {
                    HStack(spacing: 5) { Image(systemName: "gearshape").font(.system(size: 11, weight: .medium)); Text("Settings"); InstrumentKey(text: "⌘,") }
                }
                .buttonStyle(FacePress(reduceMotion: reduceMotion))
                Button { act(.quit) } label: { HStack(spacing: 5) { Text("Quit"); InstrumentKey(text: "⌘Q") } }
                    .buttonStyle(FacePress(reduceMotion: reduceMotion))
            }
            .styleText(\.caption).foregroundStyle(style.color(\.text2))
            .padding(.horizontal, 14).frame(height: 40)
        }
    }
}

extension DropdownPanelFace {
    fileprivate var updates: some View {
        Button { act(.updates) } label: {
            HStack(spacing: 6) {
                if values.updateReady { FaceLiveDot() } else {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .medium))
                }
                Text(values.updateReady ? "Update ready" : "Check for updates")
            }
        }
        .buttonStyle(FacePress(reduceMotion: reduceMotion))
    }
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
