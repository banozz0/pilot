import AppKit
import PilotCore
import SwiftUI

// Voice › Recent takes, Words and Replacements (Q598, Q599; the designer's round 2, word list layout A, one stacked
// column: pilot-1.1-previews-2.html). Each is its own block, so VoicePage orders them in one line each.

/// The words Whisper spells as written, as chips with ×, and a field that adds one.
struct DictationWordsBlock: View {
    @Environment(\.style) private var style
    @Bindable var vocabulary: DictationVocabulary
    @State private var draft = ""

    static let note = "Whisper spells these as written: names, brands, words of your own. Parakeet uses replacements only."

    var body: some View {
        KitBlock(title: "Words", symbol: "character.book.closed", note: Self.note) {
            if !vocabulary.taught.words.isEmpty {
                BlockRow(first: true) {
                    Flow(spacing: 6, lineSpacing: 6) {
                        ForEach(vocabulary.taught.words, id: \.self) { word in
                            DictationChip(text: word) { vocabulary.forget(word: word) }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            BlockRow(first: vocabulary.taught.words.isEmpty) {
                TextField("Add a word", text: $draft, prompt: Text("Add a word"))
                    .pilotField().onSubmit(add).frame(maxWidth: 260)
                Button("Add", action: add).buttonStyle(.pilot).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer(minLength: 0)
            }
        }
    }

    private func add() {
        vocabulary.learn(draft)
        draft = ""
    }
}

/// Heard → written pairs, each with ×, and a row that adds one.
struct DictationReplacementsBlock: View {
    @Environment(\.style) private var style
    @Bindable var vocabulary: DictationVocabulary
    @State private var heard = ""
    @State private var written = ""

    static let note = "Replacements run after every model: when it hears the words on the left, it writes the ones on the right."

    var body: some View {
        KitBlock(title: "Replacements", symbol: "arrow.left.arrow.right", note: Self.note) {
            ForEach(Array(vocabulary.taught.replacements.enumerated()), id: \.element) { index, pair in
                BlockRow(first: index == 0) {
                    Text(pair.heard).foregroundStyle(style.color(\.text2)).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").font(style.font(\.caption)).foregroundStyle(style.color(\.text3))
                    Text(pair.written).frame(maxWidth: .infinity, alignment: .leading)
                    Button { vocabulary.forget(pair) } label: { Image(systemName: "xmark").font(style.font(\.caption)) }
                        .buttonStyle(.plain).foregroundStyle(style.color(\.text3)).accessibilityLabel("Remove \(pair.heard)")
                }
            }
            BlockRow(first: vocabulary.taught.replacements.isEmpty) {
                TextField("Heard", text: $heard, prompt: Text("heard…")).pilotField()
                Image(systemName: "arrow.right").font(style.font(\.caption)).foregroundStyle(style.color(\.text3))
                TextField("Written", text: $written, prompt: Text("write…")).pilotField().onSubmit(add)
                Button("Add", action: add).buttonStyle(.pilot)
                    .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty || written.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        vocabulary.replace(heard, with: written)
        heard = ""
        written = ""
    }
}

/// The last 20 takes' text as the model wrote it; a click on a word asks what it should be, then learns it or always
/// replaces it. Clear empties the list.
struct DictationTakesBlock: View {
    @Environment(\.style) private var style
    @Bindable var takes: DictationTakes
    let vocabulary: DictationVocabulary

    static let note = "Your last \(DictationTake.kept) takes, text only, on this Mac. Click a word dictation got wrong to fix it."

    var body: some View {
        KitBlock(title: "Fix what you just said", symbol: "clock.arrow.circlepath", note: Self.note, trailing: {
            if !takes.takes.isEmpty { Button("Clear") { takes.clear() }.buttonStyle(.pilot) }
        }) {
            if takes.takes.isEmpty {
                BlockRow(first: true) { FinePrint(text: "Nothing yet: your takes show here after you dictate.").frame(maxWidth: .infinity, alignment: .leading) }
            }
            ForEach(Array(takes.takes.enumerated()), id: \.element.id) { index, take in
                BlockRow(first: index == 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.line(take)).styleText(\.caption).foregroundStyle(style.color(\.text3))
                        Flow(spacing: 4, lineSpacing: 2) {
                            ForEach(Array(Self.words(take.text).enumerated()), id: \.offset) { _, word in
                                TakeWord(word: word, vocabulary: vocabulary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// "18:41 · 12 s · Whisper large-v3 turbo · Messages".
    static func line(_ take: DictationTake) -> String {
        [take.at.formatted(date: .omitted, time: .shortened), take.seconds.map { "\(Int($0.rounded())) s" }, take.model, take.app]
            .compactMap(\.self).joined(separator: " · ")
    }

    static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
}

/// One word of a take: a click opens what it should be, with Learn the word and Always replace.
private struct TakeWord: View {
    @Environment(\.style) private var style
    let word: String
    let vocabulary: DictationVocabulary
    @State private var fixing = false
    @State private var written = ""

    /// The word without the punctuation around it: "cloud," is cloud.
    private var bare: String { word.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }

    var body: some View {
        Button { written = bare; fixing = true } label: { Text(word).foregroundStyle(style.color(\.text)) }
            .buttonStyle(.plain)
            .popover(isPresented: $fixing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(bare).foregroundStyle(style.color(\.text2))
                        Image(systemName: "arrow.right").font(style.font(\.caption)).foregroundStyle(style.color(\.text3))
                        TextField("Written", text: $written).pilotField().frame(width: 160).onSubmit(replace)
                    }
                    HStack(spacing: 8) {
                        Button("Learn the word") { vocabulary.learn(written); fixing = false }.buttonStyle(.pilot)
                        Button("Always replace", action: replace).buttonStyle(.pilotPrimary).disabled(written == bare)
                    }
                }
                .padding(14)
            }
            .accessibilityHint("Fix this word")
    }

    private func replace() {
        vocabulary.replace(bare, with: written)
        fixing = false
    }
}

/// A word as a chip with its ×.
private struct DictationChip: View {
    @Environment(\.style) private var style
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(text).styleText(\.body)
            Button(action: remove) { Image(systemName: "xmark").font(style.font(\.caption)) }
                .buttonStyle(.plain).foregroundStyle(style.color(\.text3)).accessibilityLabel("Remove \(text)")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(style.color(\.raised), in: Capsule())
        .overlay { Capsule().strokeBorder(style.color(\.line2)) }
    }
}
