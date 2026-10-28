import AVFoundation
import NaturalLanguage
import PilotCore

/// An installed voice as Read aloud picks among them (story 190): AVSpeechSynthesisVoice's facts, which a test can make.
struct SpeechVoice: Equatable, Hashable, Sendable {
    enum Quality: Comparable, Sendable { case standard, enhanced, premium }

    let id: String
    let name: String
    /// A BCP 47 tag, as AVSpeechSynthesisVoice gives it: en-US, es-MX.
    let language: String
    let quality: Quality
    /// Sven's own Personal Voice, listed only once macOS allowed Pilot to use it.
    var personal = false
    /// A Kokoro voice (Sven Q264), by its place in hexgrad's grades (KokoroVoice); nil for Apple's.
    var neuralRank: Int?

    var base: String { Self.base(language) }
    var neural: Bool { neuralRank != nil }

    /// A voice worth listing (Sven Q238, "best Apple voices"): Premium or Enhanced, his Personal Voice, or Kokoro's.
    var isBest: Bool { quality >= .enhanced || personal || neural }

    /// A compact copy of an Apple voice (com.apple.voice.compact or super-compact): its Enhanced version is a free
    /// download in System Settings › Accessibility › Spoken Content. Eloquence's Eddy and friends and the old MacinTalk
    /// voices have none.
    var hasDownload: Bool { id.contains(".compact.") || id.contains(".super-compact.") }

    /// How good it sounds, best first: Kokoro's voices by their grade, Premium, Enhanced, compact, super-compact, then the
    /// rest (Eloquence, MacinTalk). So Automatic reads English in Kokoro's best voice once it is downloaded.
    var rank: Int {
        if let neuralRank { return neuralRank - 100 }
        if quality == .premium { return 0 }
        if quality == .enhanced || personal { return 1 }
        if id.contains(".compact.") { return 2 }
        return id.contains(".super-compact.") ? 3 : 4
    }

    /// The voices macOS has installed, the novelty voices (Bells, Zarvox) left out, and the Personal Voice unless macOS
    /// allowed Pilot to use it. Read only when speech starts or the Voice page shows, never at launch.
    static func installed() -> [SpeechVoice] {
        let personal = AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized
        return AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
            let mine = voice.voiceTraits.contains(.isPersonalVoice)
            guard !voice.voiceTraits.contains(.isNoveltyVoice), !mine || personal else { return nil }
            let quality: Quality = switch voice.quality {
            case .premium: .premium
            case .enhanced: .enhanced
            default: .standard
            }
            return SpeechVoice(id: voice.identifier, name: voice.name, language: voice.language, quality: quality, personal: mine)
        }
    }

    /// The text's language by NLLanguageRecognizer, as a base code (en, es); nil when it cannot tell, as for a word or two,
    /// and `pick` then keeps the picked voice or the Mac's language.
    /// Its guess must be at least even odds: on a short selection it guesses anyway ("git status" Indonesian at 0.32,
    /// "Pilot" Catalan at 0.20; Danish and Indonesian voices read English on 17 and 18 Oct), where real text scores high ("hola"
    /// Spanish 0.56, "swift build" English 0.73, "Okay sounds good" 0.85; P62 probe).
    static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        guard let (language, odds) = recognizer.languageHypotheses(withMaximum: 1).first, language != .undetermined, odds >= 0.5 else { return nil }
        return base(language.rawValue)
    }

    /// The voice for text in `language`: the picked one when the text is in its language or the language is unknown,
    /// else the best installed for the language by `rank`, then the Mac's own languages in order (en-GB on a British
    /// Mac), then by name. Unknown with none picked reads in the Mac's first language, so Automatic keeps Kokoro for a
    /// short English selection. Nil leaves it to the system's voice.
    static func pick(for language: String?, among voices: [SpeechVoice], picked: String?, preferred: [String]) -> SpeechVoice? {
        let chosen = picked.flatMap { id in voices.first { $0.id == id } }
        if let chosen, language == nil || chosen.base == language { return chosen }
        guard let language = language ?? preferred.first.map(base) else { return nil }
        let tags = preferred.map { $0.lowercased() }
        func rank(_ voice: SpeechVoice) -> Int { tags.firstIndex(of: voice.language.lowercased()) ?? .max }
        return voices.filter { $0.base == language }.min { a, b in (a.rank, rank(a), a.name) < (b.rank, rank(b), b.name) }
    }

    /// The voices as the System page lists them: the Mac's own languages first, then by language, the best voices first.
    static func listed(_ voices: [SpeechVoice], preferred: [String]) -> [SpeechVoice] {
        let bases = preferred.map(base)
        func rank(_ voice: SpeechVoice) -> Int { bases.firstIndex(of: voice.base) ?? .max }
        return voices.sorted { a, b in (rank(a), a.language, a.rank, a.name) < (rank(b), b.language, b.rank, b.name) }
    }

    /// What Voice › Read aloud lists (Q238): the installed Premium and Enhanced voices, then each compact voice whose
    /// Enhanced version is not installed yet, as a download; each name in each language once, the better copy kept
    /// (Samantha's compact and super-compact are one row, the Siri voice's two ids one).
    static func shown(_ voices: [SpeechVoice]) -> [SpeechVoice] {
        var best: [String: SpeechVoice] = [:]
        for voice in voices where voice.isBest || voice.hasDownload {
            let key = "\(voice.shortName)|\(voice.language)|\(voice.neural)"
            if let kept = best[key], (kept.rank, kept.id) <= (voice.rank, voice.id) { continue }
            best[key] = voice
        }
        return Array(best.values)
    }

    /// One heading of Voice › Read aloud's list and its voices; an empty heading is Sven's own (Personal Voice). `more`
    /// waits behind the section's own disclosure: English's other accents, Kokoro's lower-graded voices.
    struct Section: Equatable {
        let heading: String
        let voices: [SpeechVoice]
        var more: [SpeechVoice] = []
    }

    static let kokoroHeading = "Kokoro"

    /// The listed voices under a heading per language, in their order: Kokoro's best first, the Mac's own languages and
    /// the Personal Voice (`mine`), then the rest, which the page folds behind More languages. English shows its US and
    /// UK voices, and any English the Mac itself speaks; Ireland, India, South Africa and the rest fold behind More
    /// accents (Sven, Build 64: "only UK and US default").
    static func sections(_ listed: [SpeechVoice], preferred: [String]) -> (mine: [Section], rest: [Section]) {
        let bases = Set(preferred.map(base))
        let english = Set(["en-us", "en-gb"] + preferred.map { $0.lowercased().replacingOccurrences(of: "_", with: "-") })
        func folds(_ voice: SpeechVoice) -> Bool {
            if let rank = voice.neuralRank { return rank > KokoroVoice.shownRank }
            return voice.base == "en" && !voice.personal && !english.contains(voice.language.lowercased())
        }
        func grouped(_ voices: [SpeechVoice]) -> [Section] {
            voices.reduce(into: [Section]()) { sections, voice in
                let heading = voice.personal ? "" : voice.neural ? kokoroHeading : Translate.name(voice.base)
                if let last = sections.last, last.heading == heading {
                    sections[sections.count - 1] = Section(heading: heading, voices: last.voices + [voice])
                } else {
                    sections.append(Section(heading: heading, voices: [voice]))
                }
            }
            .map { Section(heading: $0.heading, voices: $0.voices.filter { !folds($0) }, more: $0.voices.filter(folds)) }
        }
        let apple = listed.filter { !$0.neural }
        let mine = apple.filter { $0.personal || bases.contains($0.base) }
        let neural = listed.filter(\.neural).sorted { ($0.rank, $0.name) < ($1.rank, $1.name) }
        return (grouped(neural) + grouped(mine), grouped(apple.filter { !mine.contains($0) }))
    }

    /// The language part of a tag: en-US and en_US are en, zh-Hans is zh.
    static func base(_ tag: String) -> String {
        String(tag.prefix { $0 != "-" && $0 != "_" }).lowercased()
    }

    /// What ▶ says on the Voice page, in the voice's language where Pilot has the words, else in English.
    var sample: String {
        let line = switch base {
        case "es": "Hola, soy %@. Así sueno leyendo tu texto."
        case "fr": "Bonjour, je suis %@. Voici comment je lis votre texte."
        case "de": "Hallo, ich bin %@. So klinge ich, wenn ich deinen Text vorlese."
        case "it": "Ciao, sono %@. Ecco come leggo il tuo testo."
        case "pt": "Olá, eu sou %@. É assim que leio o seu texto."
        default: "Hello, I'm %@. This is how I sound reading your text."
        }
        return String(format: line, shortName)
    }

    /// The name without macOS's language note: "Eddy (English (UK))" is Eddy.
    var shortName: String { name.split(separator: " (").first.map(String.init) ?? name }

    /// The quality as the list's chip says it; nil for a standard voice.
    var tier: String? {
        if personal { return "Personal" }
        if neural { return "Neural" }
        return switch quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        case .standard: nil
        }
    }

    /// Where the voice speaks: "United States" of English (United States), else the whole language name.
    var place: String {
        let whole = Translate.name(language)
        guard let open = whole.firstIndex(of: "("), whole.hasSuffix(")") else { return whole }
        return String(whole[whole.index(after: open)..<whole.index(before: whole.endIndex)])
    }
}
