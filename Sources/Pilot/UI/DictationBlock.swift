import AVFoundation
import PilotCore
import SwiftUI

/// Voice › Dictation (Q144; Q452: Pilot's own alone): the two binds and the dictation key, the speech models (each
/// downloaded, used and removed on its own), what the pill shows, and the microphone grant.
struct DictationBlock: View {
    @Environment(Engine.self) private var engine: Engine?
    let dictation: PilotDictation
    let microphone: MicrophoneGrant

    init(dictation: PilotDictation = .shared, microphone: MicrophoneGrant = .shared) {
        self.dictation = dictation
        self.microphone = microphone
    }

    static let note = "Your dictation keys start and stop Pilot's dictation, with a speech model on this Mac. "
        + "Mode lights' microphone light shows when it listens."

    var body: some View {
        KitBlock(title: "Dictation", symbol: "waveform", note: Self.note) {
            BlockRow(first: true) { HStack(spacing: 6) { Text("Dictate on or off"); InfoMark(text: "One press starts dictating, the next stops it.") }.frame(maxWidth: .infinity, alignment: .leading); BindKey(action: DictationModule.toggleID) }
            BlockRow { HStack(spacing: 6) { Text("Dictate while held"); InfoMark(text: "Listens while you hold the key and stops as you let go.") }.frame(maxWidth: .infinity, alignment: .leading); BindKey(action: DictationModule.holdID) }
            if let settings = engine?.settings { DictationKeyRows(settings: settings) }
            let models = dictation.models
            BlockRow { Text("Speech models").frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(models.all, id: \.choice) { SpeechModelRow(model: $0, models: models) }
            PilotDictationRows(pilot: dictation)
            MicrophoneRow(microphone: microphone)
            BlockRow {
                FinePrint(text: "Pilot records while you dictate, \(models.active?.choice.name ?? "the speech model") writes it down on this Mac "
                          + "and Pilot pastes it where you type. Nothing leaves the Mac.").frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Pilot's own dictation: what the pill shows while Sven speaks, whether the words stay on the clipboard, and whether a
/// take pauses what is playing.
private struct PilotDictationRows: View {
    @Bindable var pilot: PilotDictation

    static let whileSpeakingInfo = "Waveform shows the small pill with your voice's level. Words shows a wider pill with the words "
        + "as you say them. The words typed at the end are still the speech model's full take."
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
/// preparing, then In use or Use, and Remove.
struct SpeechModelRow: View {
    @Environment(\.ink) private var ink
    let model: SpeechModel
    let models: SpeechModels

    var body: some View {
        let choice = model.choice
        BlockRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.name)
                FinePrint(text: "\(choice.size), \(choice.note)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ModelStateControls(state: model.state, name: choice.name, size: choice.size, download: model.download, cancel: model.cancel) {
                if models.active === model { Chip(text: "in use", color: ink.green) }
                else { Button("Use") { models.pick = choice }.buttonStyle(.pilot).accessibilityLabel("Use \(choice.name)") }
                Button("Remove") { models.remove(choice) }.buttonStyle(.pilot).accessibilityLabel("Remove \(choice.name)")
            }
        }
        ModelFailureRow(state: model.state)
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
