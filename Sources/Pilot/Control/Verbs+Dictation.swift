import AVFoundation
import PilotCore

extension ControlVerbs {
    /// `dictation`, registered in a dev build alone (PilotUpdates.devBuild), so a release has no such verb: the take and its
    /// pill, and `feed`, which arms a sound file the next take plays in the microphone's place (PilotDictation.feed). The
    /// site's video shows real dictation that way with no one speaking (Sven, 2026-11-17: "it should be something we do
    /// internally"); the take then starts as usual, by the key, a bind or `pilot run dictation.toggle`.
    func registerDictationFeed() {
        register(ControlVerb("dictation", help: "Dev builds only: the take and its pill; feed arms a sound file the next take plays in the microphone's place.",
                             usage: "pilot dictation | pilot dictation feed <file>|off", flags: []) { call throws(ControlError) in
            let args = call.arguments(), dictation = PilotDictation.shared
            guard let sub = args.positional.first else { return .object(Self.dictationState(dictation)) }
            guard sub == "feed" else { throw ControlError(.badValue, "no subcommand \(sub); pilot dictation feed <file>, or pilot dictation alone") }
            let path = try args.word(1, "a sound file, or off")
            guard path != "off" else { dictation.arm(nil); return .object(Self.dictationState(dictation)) }
            let file = ExtensionTools.folder((path as NSString).expandingTildeInPath, cwd: call.cwd)
            guard let audio = try? AVAudioFile(forReading: file) else { throw ControlError(.badValue, "\(file.path) is not a sound file Pilot reads") }
            dictation.arm(file)
            var state = Self.dictationState(dictation)
            state["seconds"] = .number((Double(audio.length) / audio.fileFormat.sampleRate * 100).rounded() / 100)
            state["armedMinutes"] = .number(PilotDictation.feedMinutes)
            return .object(state)
        })
    }

    /// The take's state, the armed feed, and what the pill shows now.
    static func dictationState(_ dictation: PilotDictation) -> [String: JSONValue] {
        var state: [String: JSONValue] = ["state": .string("\(dictation.state)"), "feed": dictation.armedFeed.map { .string($0.path) } ?? .null]
        if let pill = dictation.show as? DictationOverlay {
            state["pill"] = .object(["phase": .string("\(pill.phase)"), "inPill": .bool(pill.inPill), "inBar": .bool(pill.inBar),
                                     "levels": .array(pill.levels.map { .number(($0 * 100).rounded() / 100) }), "words": .string(pill.words)])
        }
        return state
    }
}
