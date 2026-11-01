import Foundation
import PilotCore

extension ControlVerbs {
    /// What Sven taught dictation (Q598), read-only: `dictation.words`, the words Whisper spells as written, and
    /// `dictation.replacements`, heard → written in every model's text. Only Voice › Words changes them: the words are
    /// Whisper's prompt, which no other program writes.
    func registerSpeechCollections(_ vocabulary: @escaping @Sendable @MainActor () -> DictationVocabulary = { .shared }) {
        register(ControlCollection("dictation.words", help: "Words dictation spells as written (Whisper's prompt); Voice › Words changes them.",
                                   rowKey: "word", list: { () throws(ControlError) in
            .array(vocabulary().taught.words.map { .object(["word": .string($0)]) })
        }))
        register(ControlCollection("dictation.replacements", help: "What dictation writes for a word it hears, in every model's text; Voice › Words changes them.",
                                   rowKey: "heard", list: { () throws(ControlError) in
            .array(vocabulary().taught.replacements.map { .object(["heard": .string($0.heard), "written": .string($0.written)]) })
        }))
    }
}
