import AppKit
import PilotCore
import SwiftUI

/// What the pill shows (spec desktop-controls T2, T5, T7), as plain values: the selected view and each view's content.
/// T5 fills Music from NowPlaying, T7 the rest from ExtensionBar, the Dropdown's Now block and the Controls blocks. A nil
/// or empty part draws that view's empty state.
struct PillValues {
    enum Page: CaseIterable, Hashable {
        case music, extensions, activity, controls

        var title: String {
            switch self {
            case .music: "Music"
            case .extensions: "Extensions"
            case .activity: "Activity"
            case .controls: "Controls"
            }
        }

        var symbol: String {
            switch self {
            case .music: "music.note"
            case .extensions: "puzzlepiece.extension"
            case .activity: "waveform.path.ecg"
            case .controls: "switch.2"
            }
        }
    }

    struct Music: Hashable {
        var title: String
        var artist: String
        var album: String?
        var art: NSImage?
        var playing: Bool
        var elapsed: String
        var length: String
        var progress: Double
        var source: String
    }

    struct Extension: Hashable {
        var symbol: String
        var name: String
        /// The short reading the compact face shows ("14°", "3").
        var value: String
        var detail: String
    }

    struct Control: Hashable {
        var symbol: String
        var title: String
        var detail: String
        var on: Bool
    }

    var page = Page.music
    /// The views the user keeps, in order (T7's list); the tabs show these.
    var pages = Page.allCases
    var music: Music?
    var extensions: [Extension] = []
    var running: [DropdownPanelValues.Running] = []
    var controls: [Control] = []
    var sound: DropdownPanelValues.Sound?
    var display: DropdownPanelValues.Display?
    /// The row the keys lit in the open drop, wearing the focus ring; nil draws none.
    var highlight: Int?

    /// How many rows the view showing can light: its items, or an empty state's button.
    var rows: Int {
        switch page {
        case .music: music == nil ? 1 : 0
        case .extensions: extensions.isEmpty ? 1 : extensions.count
        case .activity: running.count
        case .controls: controls.count
        }
    }
}

// MARK: Compact

/// The pill on the top bar: a capsule whose face is the selected view at a glance, a chevron that turns while its drop is
/// open. 24 pt high in a 32 pt bar; its width follows what it says, capped so a long title truncates.
struct PillCompactFace: View {
    @Environment(\.style) private var style
    let values: PillValues
    var open = false

    static let height: CGFloat = 24

    var body: some View {
        HStack(spacing: 8) {
            content
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                .foregroundStyle(style.color(\.text3))
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .padding(.leading, 6).padding(.trailing, 9)
        .frame(height: Self.height)
        .frame(maxWidth: 340)
        .fixedSize()
        .background(style.color(open ? \.raised : \.sunken), in: Capsule(style: .circular))
        .overlay { Capsule(style: .circular).strokeBorder(style.color(open ? \.line2 : \.line)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pill, \(values.page.title)")
        .accessibilityValue(Self.summary(values))
        .accessibilityAddTraits(.isButton)
        .help(Self.summary(values))
    }

    /// What the compact face says, in words: VoiceOver's value and the tooltip, so a truncated title stays reachable.
    static func summary(_ values: PillValues) -> String {
        switch values.page {
        case .music:
            guard let music = values.music else { return "Nothing playing" }
            return "\(music.title), \(music.artist)\(music.playing ? "" : ", paused")"
        case .extensions:
            return values.extensions.isEmpty ? "No extensions" : values.extensions.prefix(3).map { "\($0.name) \($0.value)" }.joined(separator: ", ")
        case .activity:
            guard let first = values.running.first else { return "Nothing running" }
            let more = values.running.count > 1 ? ", and \(values.running.count - 1) more" : ""
            return "\(first.title)\(first.reading.map { " \($0)" } ?? "")\(more)"
        case .controls:
            var parts: [String] = []
            if let sound = values.sound { parts.append(sound.muted ? "Sound muted" : "Sound \(Int(sound.level * 100)) percent") }
            if let display = values.display { parts.append("Brightness \(Int(display.level * 100)) percent") }
            parts += values.controls.prefix(2).map { "\($0.title) \($0.on ? "on" : "off")" }
            return parts.joined(separator: ", ")
        }
    }

    @ViewBuilder private var content: some View {
        switch values.page {
        case .music:
            if let music = values.music {
                FaceArt(image: music.art, size: CGSize(width: 16, height: 16), radius: 4)
                HStack(spacing: 5) {
                    Text(music.title).styleText(\.strong).foregroundStyle(style.color(\.text))
                    Text(music.artist).styleText(\.caption).foregroundStyle(style.color(\.text2))
                }
                .lineLimit(1)
                Equaliser(playing: music.playing)
            } else {
                quiet(.music, "Nothing playing")
            }
        case .extensions:
            if values.extensions.isEmpty {
                quiet(.extensions, "No extensions")
            } else {
                HStack(spacing: 11) {
                    ForEach(Array(values.extensions.prefix(3).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 4) {
                            Image(systemName: item.symbol).font(.system(size: 10.5, weight: .medium)).foregroundStyle(style.color(\.text2))
                            Text(item.value).font(style.font(\.mono, size: 11.5)).monospacedDigit().foregroundStyle(style.color(\.text))
                        }
                    }
                }
                .padding(.leading, 4)
            }
        case .activity:
            if let first = values.running.first {
                HStack(spacing: 6) {
                    FaceLiveDot(size: 7).padding(.leading, 4)
                    Text(first.title).styleText(\.strong).foregroundStyle(style.color(\.text)).lineLimit(1)
                    if let reading = first.reading {
                        Text(reading).font(style.font(\.mono, size: 11.5)).monospacedDigit().foregroundStyle(style.color(\.text2))
                    }
                    if values.running.count > 1 {
                        Text("+\(values.running.count - 1)").font(style.font(\.key, size: 10)).foregroundStyle(style.color(\.text2))
                            .padding(.horizontal, 5).frame(height: 16)
                            .background(style.color(\.raised), in: Capsule(style: .circular))
                            .overlay { Capsule(style: .circular).strokeBorder(style.color(\.line2)) }
                    }
                }
            } else {
                quiet(.activity, "Nothing running")
            }
        case .controls:
            HStack(spacing: 11) {
                if let sound = values.sound {
                    reading(sound.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", sound.muted ? "Muted" : "\(Int(sound.level * 100))")
                }
                if let display = values.display { reading("sun.max.fill", "\(Int(display.level * 100))") }
                ForEach(values.controls.prefix(2), id: \.self) { control in
                    Image(systemName: control.symbol).font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(style.color(control.on ? \.text : \.text3))
                }
            }
            .padding(.leading, 4)
        }
    }

    private func quiet(_ page: PillValues.Page, _ words: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: page.symbol).font(.system(size: 10.5, weight: .medium))
            Text(words).styleText(\.caption)
        }
        .foregroundStyle(style.color(\.text2))
        .padding(.leading, 4)
    }

    private func reading(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(style.color(\.text2))
            Text(value).font(style.font(\.mono, size: 11.5)).monospacedDigit().foregroundStyle(style.color(\.text))
        }
    }
}

/// Four bars in the signal colour while something plays (live), flat in the third text colour while paused. Drawn still:
/// T5 may move them with a TimelineView, never under Reduce Motion.
struct Equaliser: View {
    @Environment(\.style) private var style
    let playing: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(Array([0.55, 1, 0.7, 0.4].enumerated()), id: \.offset) { _, height in
                Capsule(style: .circular).fill(style.color(playing ? \.accent : \.text3))
                    .frame(width: 2, height: playing ? 11 * height : 3)
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

// MARK: Drop

/// The pill's drop (spec desktop-controls T2): one shell under the pill with the view tabs on top and the selected view
/// below. It hangs from the bar's lower edge; glass is T6's to judge, so offscreen it is the panel colour flat.
///
/// The drop's top flares into the bar with concave shoulders and takes the solid bar's own ground, so bar and drop read
/// as one shape grown down from the pill (Sven's pick A, 2026-11-10, over a square-topped panel hung flush).
///
/// `openness` runs 0 to 1 as the drop opens (T5 animates it with `DesktopMotion.open`): the drop slides out from behind
/// the bar, its content following; under Reduce Motion it stands at full size and fades in instead.
struct PillDropFace: View {
    /// What a press asks for; the builder (T5, T7) runs it. A control is named by its title; running items by index.
    enum Action: Hashable {
        enum Transport: Hashable { case previous, playPause, next }
        case select(PillValues.Page), choosePages, transport(Transport), toggle(String)
        case level(DropdownPanelFace.Action.Level, Double), pause(Int), stop(Int), empty(PillValues.Page)
        /// An extension's item by its place: its page (Return on the lit item).
        case extensionPage(Int)
    }

    @Environment(\.style) private var style
    let values: PillValues
    var openness: CGFloat = 1
    var reduceMotion = false
    var act: (Action) -> Void = { _ in }

    static let width: CGFloat = 600
    static let shoulder: CGFloat = 12

    var body: some View {
        let inset = Self.shoulder
        let content = VStack(alignment: .leading, spacing: 0) {
            tabs.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 10)
            InstrumentRule().padding(.horizontal, 14)
            page.padding(16).frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            hints.padding(.horizontal, 16).padding(.bottom, 12)
        }
        .padding(.horizontal, inset)
        .frame(width: Self.width + 2 * inset, alignment: .topLeading)

        // The solid bar's own ground (TopBarColour.themeGround), so bar and drop are one fill.
        let fill = style.color(\.canvas), line = style.color(\.line2)
        content
            .background { shape.fill(fill) }
            .overlay { stroke.stroke(line, lineWidth: 1) }
            .clipShape(shape)
            // Opening: the drop slides down from behind the bar, its foot first (the bar's edge clips it), or under
            // Reduce Motion stands at full size and fades in.
            .visualEffect { [openness, reduceMotion] face, proxy in
                face.offset(y: reduceMotion ? 0 : -(1 - openness) * proxy.size.height)
            }
            .clipped()
            .opacity(reduceMotion ? openness : 1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pill, \(values.page.title)")
    }

    /// Whether `row` wears the focus ring.
    private func lit(_ row: Int) -> Bool { values.highlight == row }

    /// One line of keys at the drop's foot, for the view showing.
    private var hints: some View {
        HStack(spacing: 13) {
            FaceHint(keys: ["←", "→"], label: "Views")
            if values.page == .music, values.music != nil {
                FaceHint(keys: ["Space"], label: "Play")
                FaceHint(keys: ["⇧", "←", "→"], label: "Skip")
            } else if values.rows > 0 {
                FaceHint(keys: ["↑", "↓"], label: "Move")
                FaceHint(keys: ["↵"], label: returns)
            }
            if values.page == .activity, let item = running, item.canPause, item.canStop { FaceHint(keys: ["Delete"], label: "Stop") }
            Spacer(minLength: 0)
            FaceHint(keys: ["Esc"], label: "Close")
        }
    }

    /// What Return does on the view showing.
    private var returns: String {
        switch values.page {
        case .music: "Open"
        case .extensions: values.extensions.isEmpty ? "Choose" : "Open page"
        case .activity: running?.canPause == true ? "Pause" : "Stop"
        case .controls: "Switch"
        }
    }

    /// The Activity entry Return acts on: the lit one, else the first. It pauses one that can pause, else stops it.
    private var running: DropdownPanelValues.Running? { values.highlight.map { values.running[$0] } ?? values.running.first }

    private var shape: ShoulderShape { ShoulderShape(shoulder: Self.shoulder, corner: style.radii.pop) }

    /// The edge drawn on the sides and the foot, never along the top where the drop meets the bar.
    private var stroke: ShoulderShape { ShoulderShape(shoulder: Self.shoulder, corner: style.radii.pop, open: true) }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(values.pages, id: \.self) { page in
                let selected = page == values.page
                Button { act(.select(page)) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: page.symbol).font(.system(size: 11, weight: .medium))
                        Text(page.title).styleText(selected ? \.strong : \.caption)
                    }
                    .foregroundStyle(style.color(selected ? \.text : \.text2))
                    .padding(.horizontal, 10).frame(height: 28)
                    .background { if selected { Capsule(style: .circular).fill(style.color(\.raised)) } }
                    .overlay { if selected { Capsule(style: .circular).strokeBorder(style.color(\.line2)) } }
                    .contentShape(Capsule(style: .circular))
                }
                .buttonStyle(FacePress(reduceMotion: reduceMotion))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Button { act(.choosePages) } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .medium)).foregroundStyle(style.color(\.text2))
                    .frame(width: 28, height: 28).contentShape(Circle())
            }
            .buttonStyle(FacePress(reduceMotion: reduceMotion))
            .help("Choose the pill's views")
            .accessibilityLabel("Choose the pill's views")
        }
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        switch values.page {
        case .music:
            if let music = values.music { musicPage(music) } else {
                FaceEmpty(symbol: "music.note", title: "Nothing playing",
                          detail: "Play something in Music, Spotify or a browser and it shows here.", button: "Open Music", lit: lit(0),
                          action: { act(.empty(.music)) }).padding(.top, 14)
            }
        case .extensions:
            if values.extensions.isEmpty {
                FaceEmpty(symbol: "puzzlepiece.extension", title: "No extensions in the pill",
                          detail: "Pick the extensions you want here in Menu bar.", button: "Choose extensions", lit: lit(0),
                          action: { act(.empty(.extensions)) }).padding(.top, 14)
            } else { extensionsPage }
        case .activity:
            if values.running.isEmpty {
                FaceEmpty(symbol: "checkmark", title: "Nothing running",
                          detail: "Recordings, focus timers and downloads show here while they run.").padding(.top, 26)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(values.running.enumerated()), id: \.offset) { i, item in
                        RunningRow(item: item, reduceMotion: reduceMotion, onPause: { act(.pause(i)) }, onStop: { act(.stop(i)) })
                            .padding(6).focusBorder(on: lit(i), radius: style.radii.control + 2).padding(-6)
                    }
                }
            }
        case .controls: controlsPage
        }
    }

    private func musicPage(_ music: PillValues.Music) -> some View {
        HStack(alignment: .top, spacing: 18) {
            FaceArt(image: music.art, size: CGSize(width: 148, height: 148), radius: style.radii.card)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if music.playing { Equaliser(playing: true) }
                    Text(music.playing ? "PLAYING IN \(music.source.uppercased())" : "PAUSED IN \(music.source.uppercased())")
                        .styleText(\.eyebrow).foregroundStyle(style.color(\.text2))
                }
                Text(music.title).font(style.font(\.title, size: 19)).foregroundStyle(style.color(\.text)).lineLimit(1).help(music.title).padding(.top, 8)
                Text([music.artist, music.album].compactMap { $0 }.joined(separator: " · "))
                    .styleText(\.body).foregroundStyle(style.color(\.text2)).lineLimit(1).padding(.top, 2)
                Spacer(minLength: 12)
                VStack(spacing: 5) {
                    GeometryReader { space in
                        ZStack(alignment: .leading) {
                            Capsule(style: .circular).fill(style.color(\.sunken))
                            Capsule(style: .circular).fill(style.color(\.text2)).frame(width: space.size.width * music.progress)
                        }
                    }
                    .frame(height: 4)
                    HStack {
                        Text(music.elapsed)
                        Spacer()
                        Text(music.length)
                    }
                    .font(style.font(\.mono, size: 10.5)).monospacedDigit().foregroundStyle(style.color(\.text2))
                }
                HStack(spacing: 10) {
                    transport("backward.fill", "Previous", .previous, size: 30)
                    Button { act(.transport(.playPause)) } label: {
                        Image(systemName: music.playing ? "pause.fill" : "play.fill").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(style.color(\.onInverse))
                            .frame(width: 40, height: 40)
                            .background(style.color(\.inverse), in: Circle())
                    }
                    .buttonStyle(FacePress(reduceMotion: reduceMotion))
                    .accessibilityLabel(music.playing ? "Pause" : "Play")
                    transport("forward.fill", "Next", .next, size: 30)
                    Spacer(minLength: 12)
                    if let sound = values.sound {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(style.color(\.text3))
                        FaceSlider(value: sound.level, muted: sound.muted, label: "Volume") { act(.level(.sound, $0)) }.frame(width: 120)
                    }
                }
                .padding(.top, 10)
            }
            .frame(height: 148)
        }
    }

    private func transport(_ symbol: String, _ label: String, _ what: Action.Transport, size: CGFloat) -> some View {
        Button { act(.transport(what)) } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(style.color(\.text))
                .frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(FacePress(reduceMotion: reduceMotion))
        .accessibilityLabel(label)
    }

    private var extensionsPage: some View {
        FaceColumns(items: Array(values.extensions.indices), columns: 3, spacing: 8) { row in
            let item = values.extensions[row]
            let shape = RoundedRectangle(cornerRadius: style.radii.card, style: .continuous)
            // A click opens the extension's page, as Return on the lit card does (Sven Q153).
            Button { act(.extensionPage(row)) } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(style.color(\.text2))
                        Text(item.name).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1)
                    }
                    Text(item.value).font(style.font(\.mono, size: 22)).monospacedDigit().foregroundStyle(style.color(\.text)).lineLimit(1)
                    Text(item.detail).styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1).help(item.detail)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(style.color(\.raised), in: shape)
                .overlay { shape.strokeBorder(style.color(\.line)) }
                .focusBorder(on: lit(row), radius: style.radii.card)
                .contentShape(shape)
            }
            .buttonStyle(FacePress(reduceMotion: reduceMotion))
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens its page")
        }
    }


    /// Switch tiles on the left, sound and brightness on the right: reference 1794160682763's Controls.
    private var controlsPage: some View {
        HStack(alignment: .top, spacing: 16) {
            FaceColumns(items: Array(values.controls.indices), columns: 2) { row in
                    let control = values.controls[row]
                    let shape = RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous)
                    Button { act(.toggle(control.title)) } label: {
                    HStack(spacing: 9) {
                        FaceGlyph(symbol: control.symbol, on: control.on, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(control.title).styleText(\.strong).foregroundStyle(style.color(control.on ? \.text : \.text2)).lineLimit(1)
                            Text(control.detail).styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(style.color(control.on ? \.raised : \.sunken), in: shape)
                    .overlay { shape.strokeBorder(style.color(control.on ? \.line2 : \.line)) }
                    .focusBorder(on: lit(row), radius: style.radii.control + 2)
                    .contentShape(shape)
                    }
                    .buttonStyle(FacePress(reduceMotion: reduceMotion))
                    .accessibilityElement(children: .ignore).accessibilityLabel(control.title)
                    .accessibilityValue(control.on ? "On" : "Off")
            }
            .frame(width: 332)
            VStack(alignment: .leading, spacing: 18) {
                if let sound = values.sound {
                    level(.sound, sound.muted ? "speaker.slash" : "speaker.wave.2", "Sound", sound.device, sound.muted ? "Muted" : "\(Int(sound.level * 100)) %",
                          sound.level, muted: sound.muted)
                }
                if let display = values.display {
                    level(.display, "sun.max", "Brightness", display.name, "\(Int(display.level * 100)) %", display.level)
                }
            }
            .padding(.top, 4)
        }
    }

    private func level(_ kind: DropdownPanelFace.Action.Level, _ symbol: String, _ title: String, _ detail: String, _ reading: String, _ value: Double, muted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(style.color(\.text2)).frame(width: 14)
                Text(title).styleText(\.strong).foregroundStyle(style.color(\.text))
                Spacer(minLength: 4)
                Text(reading).font(style.font(\.mono, size: 11)).monospacedDigit().foregroundStyle(style.color(\.text2))
            }
            FaceSlider(value: value, muted: muted, label: title) { act(.level(kind, $0)) }
            Text(detail).styleText(\.small).foregroundStyle(style.color(\.text2)).lineLimit(1)
        }
    }
}

/// The shoulders join: concave quarter-curves at the top that flare `shoulder` points into the bar, straight sides, the
/// pop radius at the foot. `open` leaves the top edge out, for the stroke.
struct ShoulderShape: Shape {
    let shoulder: CGFloat
    let corner: CGFloat
    var open = false

    func path(in rect: CGRect) -> Path {
        let s = shoulder, r = min(corner, (rect.width - 2 * s) / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s), control: CGPoint(x: rect.minX + s, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s + r, y: rect.maxY), control: CGPoint(x: rect.minX + s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - r), control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - s, y: rect.minY))
        if !open { path.closeSubpath() }
        return path
    }
}
