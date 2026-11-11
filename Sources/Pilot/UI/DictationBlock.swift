import AVFoundation
import PilotCore
import SwiftUI

/// Voice › Dictation (Q144; Q452: Pilot's own alone): the two binds and the dictation key, the speech models (each
/// downloaded, used and removed on its own), what shows while you speak and where with its preview, the waveform's
/// colour, and the microphone grant. Whole on Voice's front (split front and More by simplify-pages T12 until Sven,
/// 2026-11-11, after 2276).
struct DictationBlock: View {
    @Environment(Engine.self) private var engine: Engine?
    var dictation: PilotDictation = .shared
    var microphone: MicrophoneGrant = .shared

    static let note = "Your dictation keys start and stop Pilot's dictation, with a speech model on this Mac. "
        + "Mode lights' microphone light shows when it listens."

    var body: some View {
        KitBlock(title: "Dictation", symbol: "waveform", note: Self.note) {
            BlockRow(first: true) { HStack(spacing: 6) { Text("Dictate on or off"); InfoMark(text: "One press starts dictating, the next stops it.") }.frame(maxWidth: .infinity, alignment: .leading); BindKey(action: DictationModule.toggleID) }
            BlockRow { HStack(spacing: 6) { Text("Dictate while held"); InfoMark(text: "Listens while you hold the key and stops as you let go.") }.frame(maxWidth: .infinity, alignment: .leading); BindKey(action: DictationModule.holdID) }
            if let settings = engine?.settings { DictationKeyRows(settings: settings) }
            let models = dictation.models
            BlockRow { Text("Speech models").frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(models.offered, id: \.choice) { SpeechModelRow(model: $0, models: models) }
            // What shows while you speak, over the rows that set it (simplify-pages T27).
            DictationPreview(setup: .init(showIn: dictation.showIn, barSide: dictation.barSide, colour: dictation.waveColour,
                                          topBarShows: engine?.topBar.isOn ?? false),
                             words: dictation.whileSpeaking == .words)
                .padding(.vertical, 10)
            PilotDictationRows(pilot: dictation, topBarOn: engine?.topBar.isOn ?? false)
            front(models)
        }
    }

    /// The block's foot: the microphone grant and what dictation does with what you say.
    @ViewBuilder private func front(_ models: SpeechModels) -> some View {
        MicrophoneRow(microphone: microphone)
        BlockRow {
            FinePrint(text: "Pilot records while you dictate, \(models.active?.choice.name ?? "the speech model") writes it down on this Mac "
                      + "and Pilot pastes it where you type. Nothing leaves the Mac.").frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Voice's preview on More (simplify-pages T27, the prototype's pill): a screen in small (MiniDesktop) with a take where
/// the take's own Setup puts it: the floating pill at the foot, a slot in the top bar at Position, or both (the pill alone
/// while the top bar is off, as a take falls back), the words beside a smaller waveform at Words, in the Waveform colour;
/// the pill's own parts and spacing (DictationCircle, DictationWave, DictationPill's), so it looks as it will.
struct DictationPreview: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    let setup: DictationOverlay.Setup
    /// While you speak is Words.
    let words: Bool

    /// A take's levels, as a voice draws them.
    private static let levels: [Double] = [0.3, 0.7, 0.45, 0.9, 0.55, 0.2, 0.8, 0.5, 1, 0.35, 0.7, 0.25, 0.85, 0.45, 0.6, 0.4, 0.75, 0.3]
    private struct Shown: Equatable { let setup: DictationOverlay.Setup, words: Bool }

    var body: some View {
        // The window stands clear of the bar's strip.
        MiniDesktop(windows: ["Notes"], outer: 20, focused: nil)
            .overlay(alignment: .top) { if setup.inBar { bar } }
            .overlay(alignment: .bottom) { if setup.inPill { pill.padding(.bottom, 8) } }
            .frame(height: 96)
            .animation(Kit.change, value: Shown(setup: setup, words: words))
    }

    private func wave(_ bars: Int, plain: Color) -> some View {
        DictationWave(levels: Array(Self.levels.prefix(bars)), colour: setup.waveColour(plain: plain)).scaleEffect(0.8)
    }

    private var pill: some View {
        HStack(spacing: 8) {
            DictationCircle(symbol: "xmark", light: false)
            if words { Text("Meet at seven").font(ink.ui(10, .medium)).foregroundStyle(.white).lineLimit(1) }
            wave(words ? DictationOverlay.wordsBars : DictationOverlay.bars, plain: DictationWave.white)
            DictationCircle(symbol: "checkmark", light: true)
        }
        .padding(.horizontal, 6).frame(height: 30)
        .dictationSurface(Capsule())
    }

    /// Pilot's top bar in small, the take at Position.
    private var bar: some View {
        HStack(spacing: 0) {
            if setup.barSide != .left { Spacer() }
            HStack(spacing: 4) {
                wave(DictationOverlay.topBarBars, plain: BarMetrics.glyphInk(style))
                if words { Text("Meet at seven").font(ink.ui(8.5)).foregroundStyle(ink.text).lineLimit(1) }
            }
            if setup.barSide != .right { Spacer() }
        }
        .padding(.horizontal, 10).frame(height: 16).frame(maxWidth: .infinity).background(ink.surface)
    }
}

/// Pilot's own dictation: what shows while Sven speaks and where, the waveform's colour, whether the words stay on the
/// clipboard, and whether a take pauses what is playing.
private struct PilotDictationRows: View {
    @Bindable var pilot: PilotDictation
    /// Pilot's top bar is on: off, Top bar falls back to the pill and the row says so.
    let topBarOn: Bool

    static let whileSpeakingInfo = "Waveform shows your voice's level. Words shows the words as you say them, beside a smaller "
        + "waveform: a wider pill, or one line in the top bar while it has room. The words typed at the end are still the speech "
        + "model's full take."
    static let showInInfo = "Floating pill: at the foot of the screen, with ✕ and ✓. Top bar: in Pilot's top bar, where Position "
        + "says; click it to finish, Esc cancels. Both: the two at once."
    static let positionInfo = "Left: just after Pilot's mark. Centre: after the bar's centre items, which move aside by half its "
        + "width while it shows. Right: before the status items."
    static let colourInfo = "Plain: white on the pill, the bar's own ink in the top bar. Theme: the theme's signal colour. "
        + "Custom: a colour you pick."
    static let copyInfo = "On: the words stay on the clipboard after they are typed. Off: your clipboard is left as it was. "
        + "When the app you spoke to is no longer in front, the words are copied either way, as the only way to get them."

    static let pauseMediaInfo = "Pauses what is playing as you start dictating and plays it again when you stop, only if it was "
        + "playing. It reaches the app in Control Centre's Now Playing, as the keyboard's play key does; sound from anything else, "
        + "such as a call, keeps going."

    var body: some View {
        BlockRow {
            HStack(spacing: 6) { Text("While you speak"); InfoMark(text: Self.whileSpeakingInfo) }.frame(maxWidth: .infinity, alignment: .leading)
            Segments(selection: $pilot.whileSpeaking, options: PilotDictation.WhileSpeaking.allCases.map { ($0, $0.label) },
                     label: "While you speak")
        }
        BlockRow {
            HStack(spacing: 6) { Text("Show it in"); InfoMark(text: Self.showInInfo) }.frame(maxWidth: .infinity, alignment: .leading)
            Segments(selection: $pilot.showIn, options: PilotDictation.ShowIn.allCases.map { ($0, $0.label) }, label: "Show it in")
        }
        if pilot.showIn != .pill {
            BlockRow {
                HStack(spacing: 6) { Text("Position"); InfoMark(text: Self.positionInfo) }.frame(maxWidth: .infinity, alignment: .leading)
                Segments(selection: $pilot.barSide, options: [(TopBarSide.left, "Left"), (.centre, "Centre"), (.right, "Right")],
                         label: "Position in the top bar")
            }
        }
        if pilot.showIn != .pill && !topBarOn {
            BlockRow {
                FinePrint(text: "Pilot's top bar is off, so dictation shows in the floating pill. Turn the top bar on in Menu bar.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        BlockRow {
            HStack(spacing: 6) { Text("Waveform colour"); InfoMark(text: Self.colourInfo) }.frame(maxWidth: .infinity, alignment: .leading)
            ColourChoicePicker(choice: $pilot.waveColour, theme: Look.shared.theme.accent, label: "Waveform colour", plain: "Plain")
        }
        BlockRow {
            Toggle("Copy to clipboard", isOn: $pilot.copiesText).toggleStyle(.pilotSwitchRow(info: Self.copyInfo))
        }
        BlockRow {
            Toggle("Pause media while dictating", isOn: $pilot.pausesMedia).toggleStyle(.pilotSwitchRow(info: Self.pauseMediaInfo))
        }
    }
}

/// The one key that alone dictates (Q224): picked from the keys that are no Hyper key, then tapped or held.
private struct DictationKeyRows: View {
    @Bindable var settings: PilotSettings

    static let info = "Tap the key by itself to start dictating and tap it again to stop, or hold it while you talk. "
        + "Pressed with another key or a click it stays a normal modifier, so your Control shortcuts work as before."

    var body: some View {
        let offered = DictationKey.offered(layerKeys: settings.layerKeys)
        BlockRow {
            Text("Dictation key")
            InfoMark(text: Self.info)
            Spacer()
            Picker("Dictation key", selection: $settings.dictationKey) {
                ForEach(offered, id: \.self) { Text($0.label).tag($0) }
                // Picked before it became a Hyper key: shown, but Hyper has it.
                if !offered.contains(settings.dictationKey) { Text("\(settings.dictationKey.label) (a Hyper key now)").tag(settings.dictationKey) }
            }
            .labelsHidden().fixedSize()
        }
        if settings.dictationKey != .off {
            BlockRow {
                Text("Dictation key mode").frame(maxWidth: .infinity, alignment: .leading)
                Segments(selection: $settings.dictationKeyMode, options: DictationKeyMode.allCases.map { ($0, $0.label) },
                         label: "Dictation key mode")
            }
        }
    }
}

/// One speech model: its size and what sets it apart before the download, the download's progress, the one-time
/// preparing, then In use or Use, and Remove. A model that replaced another (Parakeet Ultra, 1.0.2, Q719) says while
/// dictation still uses the old one's files, and once it no longer does, offers to remove them: never on its own.
struct SpeechModelRow: View {
    @Environment(\.ink) private var ink
    let model: SpeechModel
    let models: SpeechModels

    var body: some View {
        let choice = model.choice, old = choice.replaces.map(models.model)
        BlockRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.name)
                FinePrint(text: "\(choice.size), \(choice.note)")
                if let old, models.active === old { FinePrint(text: "Until it is downloaded, dictation uses your \(old.choice.name) files.") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ModelStateControls(state: model.state, name: choice.name, size: choice.size, download: model.download, cancel: model.cancel) {
                if models.active === model { Chip(text: "in use", color: ink.green) }
                else { Button("Use") { models.pick = choice }.buttonStyle(.pilot).accessibilityLabel("Use \(choice.name)") }
                Button("Remove") { models.remove(choice) }.buttonStyle(.pilot).accessibilityLabel("Remove \(choice.name)")
            }
        }
        ModelFailureRow(state: model.state)
        // Measured only while the row shows: a walk of the old folder.
        if let old, old.hasFiles, models.active !== old, let megabytes = SpeechModel.megabytes(old.folder) {
            BlockRow {
                FinePrint(text: "\(old.choice.name), the model \(choice.name) replaced, is still on this Mac.").frame(maxWidth: .infinity, alignment: .leading)
                Button("Remove the old v3 files (\(megabytes) MB)") { models.remove(old.choice) }.buttonStyle(.pilot)
            }
        }
    }
}

/// A downloaded model's controls, as each row ends: Download with its size, the download's progress, the one-time
/// preparing, `ready` once it is on disk, or Try again. Speech models and Read aloud's Kokoro share them.
struct ModelStateControls<Ready: View>: View {
    @Environment(\.ink) private var ink
    let state: SpeechModel.State
    let name: String
    let size: String
    let download: () -> Void
    let cancel: () -> Void
    @ViewBuilder let ready: () -> Ready

    var body: some View {
        switch state {
        case .absent: Button("Download \(size)", action: download).buttonStyle(.pilot).accessibilityLabel("Download \(name)")
        case .downloading(let fraction):
            ProgressView(value: fraction).frame(width: 120).accessibilityLabel("Downloading \(name)")
            Text("\(Int(fraction * 100)) %").font(ink.ui(12)).foregroundStyle(ink.muted).monospacedDigit()
            Button("Cancel", action: cancel).buttonStyle(.pilot)
        case .preparing:
            ProgressView().controlSize(.small)
            Text("Preparing, once").font(ink.ui(12)).foregroundStyle(ink.muted)
            Button("Cancel", action: cancel).buttonStyle(.pilot)
        case .ready: ready()
        case .failed: Button("Try again", action: download).buttonStyle(.pilot)
        }
    }
}

/// Why a model's download failed, on a row of its own under it.
struct ModelFailureRow: View {
    @Environment(\.ink) private var ink
    let state: SpeechModel.State

    var body: some View {
        if case .failed(let reason) = state { BlockRow { FinePrint(text: reason, color: ink.red).frame(maxWidth: .infinity, alignment: .leading) } }
    }
}

/// The microphone grant with its fix: Allow asks macOS once; answered no, Open Settings shows the Privacy pane.
struct MicrophoneRow: View {
    @Environment(\.ink) private var ink
    var microphone: MicrophoneGrant = .shared

    var body: some View {
        BlockRow {
            Text("Microphone")
            InfoMark(text: "Pilot's own dictation records with it, and so does a screen recording with your voice.")
            Spacer()
            switch microphone.status {
            case .authorized: Chip(text: "granted", color: ink.green)
            case .notDetermined: Button("Allow") { Task { await microphone.ask() } }.buttonStyle(.pilot)
            case nil: Chip(text: "…")
            default: Button("Open Settings") { MicrophoneGrant.openSettings() }.buttonStyle(.pilot)
            }
        }
        .task { microphone.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in microphone.refresh() }
    }
}
