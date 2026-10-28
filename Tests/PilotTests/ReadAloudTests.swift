import AppKit
import PilotCore
import Testing
@testable import Pilot

/// Read aloud (story 190): the key and the service speak the selection through a fake speaker, so no test plays a
/// sound; the key again stops it; a password field speaks nothing; the voice follows the text's language.
@MainActor
@Suite("Read aloud")
struct ReadAloudTests {
    @MainActor final class FakeSpeaker: Speaker {
        var spoken: [(text: String, voice: String?, rate: Float)] = []
        var stops = 0
        private var done: (@MainActor () -> Void)?
        var isSpeaking: Bool { done != nil }

        func speak(_ text: String, voice: String?, rate: Float, done: @escaping @MainActor () -> Void) {
            spoken.append((text, voice, rate))
            self.done = done
        }

        func stop() {
            stops += 1
            finish()
        }

        /// The speech reaching its end.
        func finish() {
            let done = done
            self.done = nil
            done?()
        }
    }

    /// What the HUD was asked: the tips, the lasting tip's words, and how often it was taken down.
    @MainActor final class Record {
        var tips: [String] = []
        var shown: [String] = []
        var hidden = 0
        var stop: (@MainActor () -> Void)?
    }

    static let voices = [
        SpeechVoice(id: "en.samantha", name: "Samantha", language: "en-US", quality: .standard),
        SpeechVoice(id: "en.ava", name: "Ava", language: "en-US", quality: .premium),
        SpeechVoice(id: "en.daniel", name: "Daniel", language: "en-GB", quality: .premium),
        SpeechVoice(id: "es.monica", name: "Mónica", language: "es-ES", quality: .standard),
        SpeechVoice(id: "es.paulina", name: "Paulina", language: "es-MX", quality: .enhanced),
    ]

    static let english = "The quick brown fox jumps over the lazy dog, and then it runs back into the forest."
    static let spanish = "El rápido zorro marrón salta sobre el perro perezoso y luego vuelve corriendo al bosque."

    func reader(_ r: Record, speaker: FakeSpeaker, selection: String? = english, secure: Bool = false) -> ReadAloud {
        let settings = ReadAloudSettings(defaults: UserDefaults(suiteName: testSuite())!)
        settings.installed = { Self.voices }
        settings.preferred = { ["en-GB", "es-CO"] }
        let reader = ReadAloud()
        reader.speaker = speaker
        reader.media = MediaPause(media: PilotDictationTests.FakeMedia())
        reader.settings = settings
        reader.secureInput = { secure }
        reader.selection = { selection }
        reader.tip = { r.tips.append($0) }
        reader.showReading = { text, stop in
            r.shown.append(text)
            r.stop = stop
            return { r.hidden += 1 }
        }
        return reader
    }

    /// Lets the read of the selection run.
    func settle() async { for _ in 0..<5 { await Task.yield() } }

    @Test("The key reads the selection in the best voice for its language, at the set speed, under the Reading aloud tip")
    func reads() async {
        let r = Record(), speaker = FakeSpeaker()
        let reader = reader(r, speaker: speaker)
        reader.settings.rate = 0.6
        reader.toggle()
        await settle()
        #expect(speaker.spoken.map(\.text) == [Self.english])
        // Ava and Daniel are both premium; the Mac's en-GB puts Daniel first.
        #expect(speaker.spoken.first?.voice == "en.daniel" && speaker.spoken.first?.rate == 0.6)
        #expect(r.shown == ["Reading aloud · Daniel"] && reader.isBusy)
        speaker.finish()
        #expect(r.hidden == 1 && !reader.isBusy)
    }

    @Test("The key again stops the speech and takes the tip down; the tip's Stop does the same")
    func stops() async {
        let r = Record(), speaker = FakeSpeaker()
        let reader = reader(r, speaker: speaker)
        reader.toggle()
        await settle()
        reader.toggle()
        #expect(speaker.stops == 1 && r.hidden == 1 && !reader.isBusy && speaker.spoken.count == 1)
        reader.toggle()
        await settle()
        r.stop?()
        #expect(speaker.stops == 2 && r.hidden == 2 && !reader.isBusy && speaker.spoken.count == 2)
    }

    @Test("A press while the selection is still being read cancels it, and nothing is spoken")
    func cancelsRead() async {
        let r = Record(), speaker = FakeSpeaker()
        let reader = reader(r, speaker: speaker)
        reader.selection = { try? await Task.sleep(for: .seconds(5)); return Self.english }
        reader.toggle()
        #expect(reader.isBusy)
        reader.toggle()
        await settle()
        #expect(!reader.isBusy && speaker.spoken.isEmpty && r.shown.isEmpty)
    }

    @Test("A password field speaks nothing and says why; no selection says so")
    func refuses() async {
        let r = Record(), speaker = FakeSpeaker()
        reader(r, speaker: speaker, secure: true).toggle()
        await settle()
        reader(r, speaker: speaker, selection: nil).toggle()
        await settle()
        #expect(speaker.spoken.isEmpty && r.shown.isEmpty && r.tips == [QuickFix.password, SelectionBox.nothingSelected])
    }

    @Test("The service reads the text it was handed, stopping what was being read")
    func service() {
        let r = Record(), speaker = FakeSpeaker()
        let reader = reader(r, speaker: speaker)
        reader.read(service: Self.english)
        reader.read(service: Self.spanish)
        #expect(speaker.spoken.map(\.text) == [Self.english, Self.spanish] && speaker.stops == 2)
        // Paulina's enhanced voice beats Mónica's standard one.
        #expect(speaker.spoken.last?.voice == "es.paulina" && r.shown.last == "Reading aloud · Paulina")
    }

    @Test("A picked voice reads its own language; text in another language, or none known, goes to that language's best")
    func pick() {
        let voices = Self.voices
        #expect(SpeechVoice.pick(for: "en", among: voices, picked: "en.samantha", preferred: [])?.id == "en.samantha")
        #expect(SpeechVoice.pick(for: "es", among: voices, picked: "en.samantha", preferred: [])?.id == "es.paulina")
        #expect(SpeechVoice.pick(for: nil, among: voices, picked: "en.samantha", preferred: [])?.id == "en.samantha")
        #expect(SpeechVoice.pick(for: nil, among: voices, picked: nil, preferred: []) == nil)
        #expect(SpeechVoice.pick(for: "en", among: voices, picked: "gone", preferred: [])?.id == "en.ava")
        #expect(SpeechVoice.pick(for: "ja", among: voices, picked: nil, preferred: []) == nil)
        #expect(SpeechVoice.language(of: Self.spanish) == "es" && SpeechVoice.language(of: Self.english) == "en")
        #expect(SpeechVoice.base("zh-Hans") == "zh" && SpeechVoice.base("en_GB") == "en")
    }

    @Test("The System page lists the Mac's own languages first, the best voices first within one")
    func listed() {
        let ids = SpeechVoice.listed(Self.voices, preferred: ["es-CO", "en-GB"]).map(\.id)
        #expect(ids == ["es.monica", "es.paulina", "en.daniel", "en.ava", "en.samantha"])
    }

    @Test("Read selected text aloud is on Hyper+Ctrl+R, a key nothing else holds, listed in Trigger")
    func action() {
        let key = Key("r", .ctrl)
        let engine = Engine()
        #expect(engine.registry.actions[ReadAloud.id]?.label == "Read selected text aloud")
        #expect(engine.registry.defaults.filter { $0.value == key }.map(\.key) == [ReadAloud.id])
        #expect(!PilotDefault.binds.values.contains(key) && !MyBinds.extras.values.contains(key))
        #expect(MenuLayout.rows[.trigger]?.last == .action(ReadAloud.id))
        // AbilitiesTests checks its line; Try would read Pilot's own window.
        #expect(!Abilities.canTry(ReadAloud.id))
    }

    @Test("Read Aloud with Pilot hands the pasteboard's text over and returns nothing; no text says so; Info.plist offers it")
    func pilotServices() throws {
        var read: [String] = []
        let services = PilotServices(read: { read.append($0) })
        let board = NSPasteboard(name: NSPasteboard.Name("dev.banozz.pilot.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        var error: NSString?
        board.clearContents()
        board.setString("hello there", forType: .string)
        services.readText(board, userData: nil, error: &error)
        #expect(read == ["hello there"] && error == nil)
        board.clearContents()
        board.setString(" \n", forType: .string)
        services.readText(board, userData: nil, error: &error)
        #expect(read == ["hello there"] && error == "No text selected")
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let service = try #require((plist["NSServices"] as? [[String: Any]])?.first { $0["NSMessage"] as? String == "readText" })
        #expect((service["NSMenuItem"] as? [String: String])?["default"] == "Read Aloud with Pilot")
        #expect(service["NSPortName"] as? String == "Pilot" && service["NSRequiredContext"] != nil)
        #expect(service["NSSendTypes"] as? [String] == ["public.utf8-plain-text"] && service["NSReturnTypes"] == nil)
    }

    @Test("pilot get|set speech.voice and speech.rate: automatic or an installed voice, the speed in its range")
    func settings() async {
        let speech = ReadAloudSettings(defaults: UserDefaults(suiteName: testSuite())!)
        speech.installed = { Self.voices }
        let schema = SettingsSchema(), verbs = ControlVerbs()
        schema.registerSpeech(speech)
        verbs.registerSettings(schema) { _, _, _ in true }
        func ask(_ verb: String, _ args: String...) async -> ControlAnswer { await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil) }
        #expect(await ask("get", "speech.voice").result == .string("automatic"))
        #expect(await ask("get", "speech.rate").result == .number(ReadAloudSettings.standardRate))
        #expect(await ask("set", "speech.voice", "en.ava").ok && speech.voiceID == "en.ava")
        #expect(await ask("set", "speech.voice", "nobody").error?.code == .badValue && speech.voiceID == "en.ava")
        #expect(await ask("set", "speech.voice", "automatic").ok && speech.voiceID.isEmpty)
        #expect(await ask("set", "speech.rate", "0.65").ok && speech.rate == 0.65)
        #expect(!(await ask("set", "speech.rate", "1").ok) && speech.rate == 0.65)
    }
}

extension ReadAloudTests {
    @Test("▶ on the Voice page speaks a line in that voice, in its language, in place of what was speaking")
    func preview() {
        let speaker = FakeSpeaker()
        let r = reader(Record(), speaker: speaker)
        var ended = 0
        r.preview(Self.voices[4]) { ended += 1 }
        #expect(speaker.spoken.last?.voice == "es.paulina" && speaker.spoken.last?.text == "Hola, soy Paulina. Así sueno leyendo tu texto.")
        r.preview(Self.voices[1]) { ended += 1 }
        #expect(ended == 1 && speaker.spoken.last?.text == "Hello, I'm Ava. This is how I sound reading your text.")
        speaker.finish()
        #expect(ended == 2)
    }

    @Test("The list's words: the short name, the quality chip, the place")
    func listWords() {
        let eddy = SpeechVoice(id: "x", name: "Eddy (English (UK))", language: "en-GB", quality: .standard)
        #expect(eddy.shortName == "Eddy" && eddy.tier == nil && eddy.place == "United Kingdom")
        #expect(Self.voices[1].tier == "Premium" && Self.voices[4].tier == "Enhanced")
        #expect(SpeechVoice(id: "p", name: "Sven", language: "en-US", quality: .standard, personal: true).tier == "Personal")
    }

    @Test("The list groups voices by language, the Mac's own languages first, the rest apart")
    func sections() {
        let thomas = SpeechVoice(id: "fr.thomas", name: "Thomas", language: "fr-FR", quality: .standard)
        let listed = SpeechVoice.listed(Self.voices + [thomas], preferred: ["en-GB", "es-CO"])
        let (mine, rest) = SpeechVoice.sections(listed, preferred: ["en-GB", "es-CO"])
        #expect(mine.map(\.heading) == ["English", "Spanish"] && mine[0].voices.count == 3 && mine[1].voices.count == 2)
        #expect(rest == [SpeechVoice.Section(heading: "French", voices: [thomas])])
    }
}

extension ReadAloudTests {
    /// What macOS lists on a Mac with no voice downloaded (2026-10-17): compact and super-compact copies, Eloquence's,
    /// MacinTalk's, and the Siri voice under two ids.
    static let mac = [
        SpeechVoice(id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: .standard),
        SpeechVoice(id: "com.apple.voice.super-compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: .standard),
        SpeechVoice(id: "com.apple.eloquence.en-US.Eddy", name: "Eddy", language: "en-US", quality: .standard),
        SpeechVoice(id: "com.apple.speech.synthesis.voice.Fred", name: "Fred", language: "en-US", quality: .standard),
        SpeechVoice(id: "com.apple.siri.natural.Simone", name: "Voice 2", language: "en-US", quality: .enhanced),
        SpeechVoice(id: "com.apple.ttsbundle.gryphon-neural_Simone_en-US_premium", name: "Voice 2", language: "en-US", quality: .enhanced),
        SpeechVoice(id: "com.apple.voice.premium.en-US.Ava", name: "Ava (Premium)", language: "en-US", quality: .premium),
        SpeechVoice(id: "com.apple.voice.enhanced.en-US.Ava", name: "Ava (Enhanced)", language: "en-US", quality: .enhanced),
        SpeechVoice(id: "com.apple.voice.super-compact.es-MX.Paulina", name: "Paulina", language: "es-MX", quality: .standard),
    ]

    @Test("The list shows Premium and Enhanced voices and the compact ones' downloads, each name and language once")
    func shown() {
        let ids = Set(SpeechVoice.shown(Self.mac).map(\.id))
        #expect(ids == ["com.apple.voice.premium.en-US.Ava", "com.apple.siri.natural.Simone", "com.apple.voice.compact.en-US.Samantha",
                        "com.apple.voice.super-compact.es-MX.Paulina"])
        let listed = SpeechVoice.listed(SpeechVoice.shown(Self.mac), preferred: ["en-US"])
        #expect(listed.map(\.isBest) == [true, true, false, false] && listed.first?.id == "com.apple.voice.premium.en-US.Ava")
    }

    @Test("Automatic takes Premium, then Enhanced, then compact, never Eloquence's Eddy before Samantha")
    func automatic() {
        let english = Self.mac.filter { $0.quality == .standard }
        #expect(SpeechVoice.pick(for: "en", among: english, picked: nil, preferred: ["en-US"])?.id == "com.apple.voice.compact.en-US.Samantha")
        #expect(SpeechVoice.pick(for: "en", among: Self.mac, picked: nil, preferred: ["en-US"])?.id == "com.apple.voice.premium.en-US.Ava")
    }

    @Test("A compact voice picked before moves to the best installed in its language, else Automatic")
    func settle() {
        let settings = ReadAloudSettings(defaults: UserDefaults(suiteName: testSuite())!)
        settings.installed = { Self.mac }
        settings.voiceID = "com.apple.voice.compact.en-US.Samantha"
        _ = settings.voices
        #expect(settings.voiceID == "com.apple.voice.premium.en-US.Ava")
        let spanish = ReadAloudSettings(defaults: UserDefaults(suiteName: testSuite())!)
        spanish.installed = { Self.mac }
        spanish.voiceID = "com.apple.voice.super-compact.es-MX.Paulina"
        _ = spanish.voices
        #expect(spanish.voiceID.isEmpty)
        let kept = ReadAloudSettings(defaults: UserDefaults(suiteName: testSuite())!)
        kept.installed = { Self.mac }
        kept.voiceID = "com.apple.siri.natural.Simone"
        _ = kept.voices
        #expect(kept.voiceID == "com.apple.siri.natural.Simone")
    }
}
