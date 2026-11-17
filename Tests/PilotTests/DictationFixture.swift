import AppKit
@testable import Pilot

/// PILOT_SANDBOX_DICTATION=<folder> (sandbox E2E): Pilot's own dictation as a take runs it, with nothing on the Mac touched.
/// `<folder>/pilot-dictate` is the helper (a link to Helpers/pilot-dictate's release build) and `<folder>/Speech/<model>`
/// a model, an APFS clone of one on disk (`cp -cR`), compiled once with `pilot-dictate prepare`. The pill draws nothing
/// and `pilot dictation` reads it; the words go into an offscreen text field, written whole to `<folder>/field.txt` after
/// each paste; tips and a copy go to `<folder>/dictation.log`. The front app is a constant, so a take types where it
/// was spoken. With a dev Info.plist (PILOT_SANDBOX_INFO), `pilot dictation feed <wav>` then `pilot run dictation.toggle`
/// plays the file as the take's microphone.
@MainActor
enum DictationFixture {
    static func install(_ folder: String?) {
        guard let folder = folder.map({ URL(filePath: $0, directoryHint: .isDirectory) }) else { return }
        let field = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        let log = { FileDockAutohide.append($0, to: folder.appending(path: "dictation.log")) }
        var helper = BundledDictateHelper()
        helper.path = folder.appending(path: "pilot-dictate").path
        PilotDictation.standIn = { PilotDictation(
            models: SpeechModels(base: folder.appending(path: "Speech", directoryHint: .isDirectory), helper: helper),
            helper: helper,
            paste: { text, _ in
                field.insertText(text, replacementRange: field.selectedRange())
                try? Data(field.string.utf8).write(to: folder.appending(path: "field.txt"))
            },
            copy: { log("copied: \($0)") },
            frontApp: { 1 }, secureInput: { false },
            tell: { text, _, _ in log("tip: \(text)") },
            show: DictationOverlay(shows: false),
            media: Silent()) }
    }

    /// Nothing playing, and nothing paused or played.
    final class Silent: MediaControlling {
        func pauseIfPlaying(_ done: @escaping @MainActor (Bool) -> Void) { done(false) }
        func play() {}
    }
}
