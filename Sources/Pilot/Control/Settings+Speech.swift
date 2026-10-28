import Foundation
import PilotCore

extension SettingsSchema {
    /// Read aloud's voice, speed and media on the Voice page (story 190): a voice by its identifier, or automatic.
    func registerSpeech(_ speech: ReadAloudSettings) {
        register([
            .text(ReadAloudSettings.voiceKey, "Read aloud's voice (automatic, a voice id, or kokoro/<name> once Kokoro is downloaded)", page: "voice", standard: Self.automatic,
                  read: { speech.voiceID.isEmpty ? Self.automatic : speech.voiceID },
                  write: { word throws(ControlError) in
                      if word == Self.automatic {
                          speech.voiceID = ""
                          return
                      }
                      guard speech.voices.contains(where: { $0.id == word }) else {
                          throw ControlError(.badValue, "\(word) is no installed voice: automatic, or an id from Voice › Read aloud (kokoro/af_heart once Kokoro is downloaded)")
                      }
                      speech.voiceID = word
                  }),
            .number(ReadAloudSettings.rateKey, "Read aloud's speed", page: "voice", range: ReadAloudSettings.rates,
                    standard: ReadAloudSettings.standardRate, read: { speech.rate }, write: { speech.rate = $0 }),
            .choice(ReadAloudSettings.mediaKey, "Read aloud pauses what is playing and plays it again after, or keeps it playing", page: "voice",
                    ReadAloudSettings.Media.allCases, standard: .pause, read: { speech.media }, write: { speech.media = $0 }),
        ])
    }

    private static let automatic = "automatic"

    /// The apps where Hyper+drag shows no selection pill (Sven Q215), on AI › Setup's keys.
    func registerSelection(_ tools: SelectionTools) {
        register([
            .text(SelectionPill.skipKey, "Apps where Hyper+drag shows no selection pill (bundle ids, comma-separated)", page: "ai",
                  standard: SelectionPill.standardSkip.joined(separator: ","),
                  read: { tools.skipped.joined(separator: ",") },
                  write: { tools.skipped = $0.split(separator: ",").map(String.init) }),
        ])
    }
}
