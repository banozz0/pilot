import AppKit
import PilotCore
import SwiftUI

/// Voice (2026-10-16, Sven could not find Dictation on Open with): Pilot's dictation and Read
/// aloud's key, speed and voice (story 190, was System › Keyboard), one page in Tools.
struct VoicePage: View {
    var speech: ReadAloudSettings = .shared
    /// The voices it lists (SpeechVoice.shown) by language, read when the page first shows, never at launch, and again
    /// when a download lands.
    @State private var sections: (mine: [SpeechVoice.Section], rest: [SpeechVoice.Section]) = ([], [])

    static let intro = "Talk to your Mac and have it read to you."

    var body: some View {
        KitPage(intro: Self.intro) {
            DictationBlock()
            // One column (the designer's layout A, round 2), "Fix a recent take" above the two lists (Q598).
            DictationTakesBlock(takes: .shared, vocabulary: .shared)
            DictationWordsBlock(vocabulary: .shared)
            DictationReplacementsBlock(vocabulary: .shared)
            ReadAloudBlock(speech: speech, mine: sections.mine, rest: sections.rest)
        }
        .task(id: "\(speech.personal) \(speech.revision)") {
            let preferred = Locale.preferredLanguages
            sections = SpeechVoice.sections(SpeechVoice.listed(SpeechVoice.shown(speech.voices), preferred: preferred), preferred: preferred)
        }
    }
}

/// Read aloud's key, speed and media (Q282), Kokoro's download (Q264), then its voice as a list (Sven Q219, Q238): Automatic first,
/// Kokoro's voices once downloaded, then per language the installed Premium and Enhanced voices and the Enhanced voices
/// still to download, ▶ on each to hear it, each voice once, the Mac's own languages first and the rest behind More
/// languages, English's other accents and Kokoro's lower-graded voices behind their own More, Sven's Personal Voice
/// behind macOS's ask (hidden where the Mac has none, Q220), and the way to the free Premium voices, which only System
/// Settings downloads.
struct ReadAloudBlock: View {
    @Environment(\.ink) private var ink
    @Bindable var speech: ReadAloudSettings
    var kokoro: KokoroModel = .shared
    /// The Mac's own languages' voices and the Personal Voice; the rest, behind More languages (SpeechVoice.sections).
    let mine: [SpeechVoice.Section]
    let rest: [SpeechVoice.Section]
    @State private var previewing: String?
    @State private var unfolded = false
    /// The sections whose More is open, by heading.
    @State private var opened: Set<String> = []

    static let kokoroInfo = "Voices made by a neural network, far more natural than Apple's, running on this Mac: nothing you "
        + "read leaves it. Once downloaded, Automatic reads English in Kokoro's best voice; Apple's voices read other languages, "
        + "and English too if Kokoro cannot."

    static let mediaInfo = "Pause stops what is playing as reading starts and plays it again when reading ends or you stop it, "
        + "only if Pilot paused it. It reaches the app in Control Centre's Now Playing; Keep playing leaves it as it is."

    /// Accessibility › Spoken Content, where System voice › Manage Voices downloads Premium and Enhanced voices.
    static let moreVoices = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!

    var body: some View {
        let others = rest.reduce(0) { $0 + $1.voices.count }
        KitBlock(title: "Read aloud", symbol: "speaker.wave.2", note: "Speaks the text you selected in the voice you pick here.") {
            BlockRow(first: true) {
                HStack(spacing: 6) { Text("Read selected text aloud"); InfoMark(text: "Reads out the text you have selected, in any app.") }.frame(maxWidth: .infinity, alignment: .leading)
                BindKey(action: ReadAloud.id)
            }
            BlockRow {
                HStack(spacing: 6) { Text("Speed"); InfoMark(text: "How fast the voice reads, whichever voice is picked.") }.frame(maxWidth: .infinity, alignment: .leading)
                KitSlider(value: $speech.rate, range: ReadAloudSettings.rates, step: 0.05, label: "Read aloud speed")
            }
            BlockRow {
                HStack(spacing: 6) { Text("Media playing"); InfoMark(text: Self.mediaInfo) }.frame(maxWidth: .infinity, alignment: .leading)
                Segments(selection: $speech.media, options: ReadAloudSettings.Media.allCases.map { ($0, $0.label) }, label: "Media playing")
            }
            KokoroRow(model: kokoro)
            BlockRow {
                pick("") {
                    TitledText(title: Text("Automatic"), detail: kokoro.isReady ? "Kokoro for English, else the best voice for the text's language"
                               : "The best voice for the text's language").padding(.vertical, 4)
                }
            }
            languages(mine)
            if others > 0 {
                more("languages", count: others, open: unfolded) { unfolded.toggle() }
                if unfolded { languages(rest) }
            }
            if speech.personal != .unsupported { personal }
            BlockRow {
                Image(systemName: "arrow.down.circle").foregroundStyle(ink.muted).frame(width: 18).accessibilityHidden(true)
                TitledText(title: Text("Get better voices"), detail: "Premium and Enhanced voices are free downloads in System Settings › Accessibility › Spoken Content")
                    .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                Button { NSWorkspace.shared.open(Self.moreVoices) } label: { Chip(text: "Open", symbol: "arrow.up.right") }
                    .buttonStyle(.kitPress).help("Opens System Settings › Accessibility › Spoken Content")
            }
        }
        // Kokoro's ▶ lines are made while the page is open, never at idle.
        .onAppear { kokoro.renderSamples(true) }
        .onDisappear {
            kokoro.renderSamples(false)
            if previewing != nil { ReadAloud.shared.stop() }
        }
    }

    /// Each language's heading, then its voices.
    @ViewBuilder private func languages(_ sections: [SpeechVoice.Section]) -> some View {
        ForEach(sections, id: \.heading) { section in
            BlockRow {
                Text(section.heading.isEmpty ? "YOURS" : section.heading.uppercased()).font(ink.ui(11, .semibold)).foregroundStyle(ink.muted)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(section.voices, id: \.id) { voice in row(voice) }
            if !section.more.isEmpty {
                let open = opened.contains(section.heading)
                more(section.heading == SpeechVoice.kokoroHeading ? "Kokoro voices" : "accents", count: section.more.count, open: open) {
                    if open { opened.remove(section.heading) } else { opened.insert(section.heading) }
                }
                if open { ForEach(section.more, id: \.id) { voice in row(voice) } }
            }
        }
    }

    /// A disclosure row: More <what> (n voices), Fewer <what> once open.
    private func more(_ what: String, count: Int, open: Bool, toggle: @escaping () -> Void) -> some View {
        BlockRow {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                    Text(open ? "Fewer \(what)" : "More \(what) (\(count) \(count == 1 ? "voice" : "voices"))")
                }
                .foregroundStyle(ink.link).contentShape(.rect)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    @ViewBuilder private func row(_ voice: SpeechVoice) -> some View {
        if voice.isBest { installed(voice) } else { download(voice) }
    }

    /// A voice still to download: its Enhanced version is in System Settings, which alone downloads voices; ▶ plays the
    /// compact copy macOS already has.
    private func download(_ voice: SpeechVoice) -> some View {
        BlockRow {
            Image(systemName: "arrow.down.circle").foregroundStyle(ink.muted).frame(width: 18).accessibilityHidden(true)
            Text(voice.shortName).foregroundStyle(ink.muted)
            Chip(text: "Enhanced")
            Text(voice.place).foregroundStyle(ink.muted).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Button { NSWorkspace.shared.open(Self.moreVoices) } label: { Chip(text: "Get", symbol: "arrow.up.right") }
                .buttonStyle(.kitPress).help("Download \(voice.shortName) (Enhanced) in System Settings › Accessibility › Spoken Content")
            hear(voice)
        }
    }

    private func installed(_ voice: SpeechVoice) -> some View {
        BlockRow {
            pick(voice.id) {
                Text(voice.shortName)
                if let tier = voice.tier { Chip(text: tier, color: voice.quality == .premium || voice.personal || voice.neural ? ink.green : nil) }
                Text(voice.place).foregroundStyle(ink.muted).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            hear(voice)
        }
    }

    /// ▶ on every voice row: a line in that voice; again, or another ▶, stops it.
    private func hear(_ voice: SpeechVoice) -> some View {
        let playing = previewing == voice.id
        return Button {
            if playing { return ReadAloud.shared.stop() }
            ReadAloud.shared.preview(voice) { if previewing == voice.id { previewing = nil } }
            previewing = voice.id
        } label: {
            Image(systemName: playing ? "stop.circle.fill" : "play.circle").font(.system(size: 18))
                .foregroundStyle(playing ? ink.accentInk : ink.muted).contentShape(.rect)
        }
        .buttonStyle(.plain).help(playing ? "Stop" : "Hear \(voice.shortName)").accessibilityLabel(playing ? "Stop" : "Hear \(voice.shortName)")
    }

    /// A row that picks `id` (empty: Automatic) when clicked, its tick lit while picked.
    private func pick(_ id: String, @ViewBuilder label: () -> some View) -> some View {
        let on = speech.voiceID == id
        return Button { speech.voiceID = id } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? ink.accentInk : ink.muted).frame(width: 18)
                label()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }

    private var personal: some View {
        BlockRow {
            Image(systemName: "person.wave.2").foregroundStyle(ink.muted).frame(width: 18).accessibilityHidden(true)
            let detail = switch speech.personal {
            case .denied: "Not allowed: System Settings › Privacy & Security › Personal Voice"
            case .allowed: "Allowed: it is in the list under Yours once you made one in Accessibility › Personal Voice"
            default: "macOS asks once before Pilot may read in your voice"
            }
            TitledText(title: Text("Your Personal Voice"), detail: detail).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            if speech.personal == .notAsked {
                Button { speech.askPersonal() } label: { Chip(text: "Allow") }.buttonStyle(.kitPress)
            }
        }
    }
}

/// Kokoro's model (Q264): its size and credit before the download, the download's progress, the one-time preparing, then
/// on this Mac with Remove, as Voice › Dictation's speech models.
struct KokoroRow: View {
    @Environment(\.ink) private var ink
    let model: KokoroModel

    var body: some View {
        BlockRow {
            Image(systemName: "waveform").foregroundStyle(ink.muted).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { Text("Kokoro neural voices"); InfoMark(text: ReadAloudBlock.kokoroInfo) }
                FinePrint(text: "\(KokoroModel.size), \(KokoroModel.note)")
            }
            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            ModelStateControls(state: model.state, name: "Kokoro", size: KokoroModel.size, download: model.download, cancel: model.cancel) {
                Chip(text: "on this Mac", color: ink.green)
                Button("Remove") { model.remove() }.buttonStyle(.pilot).accessibilityLabel("Remove Kokoro")
            }
        }
        ModelFailureRow(state: model.state)
    }
}
