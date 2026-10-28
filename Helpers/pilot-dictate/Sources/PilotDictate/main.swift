// pilot-dictate: Pilot's own dictation (story 194) in a process that lives only while it works, so Whisper's model and
// the audio engine leave with it. Pilot reads one line per event on stdout:
//   pilot-dictate download <folder> <model>     progress <0…1> while files arrive, then preparing; exit 0 once ready
//   pilot-dictate listen <folder> [--words]   listening once the microphone records, loaded once the model is up, and
//                                         level <four 0…1 numbers> ten times a second while it records; with --words,
//                                         partial <JSON string> as the words so far change; Pilot closes stdin to stop
//                                         (cancel on stdin drops the take), then text <JSON string>
//   pilot-dictate prepare <folder>        compiles the model for this helper unless it already did: prepared, or nothing
//   pilot-dictate transcribe <folder> <file>   text <JSON string> for a recorded file (the tests, a check by hand)
//   pilot-dictate speak <folder> <voice> <speed> [--out <file>]   Read aloud's Kokoro voice (Speak): reads the text from
//                                         stdin to its end, says loaded once the voice is up and speaking with the first
//                                         sound, and exits 0 once all of it played; Pilot stops it by ending the process.
//                                         With --out, a WAV of it instead of the speakers. Kokoro's folder takes
//                                         download <folder> kokoro/english, and prepare, too.
//   pilot-dictate samples <folder> <voice> <line> [<voice> <line>]...   each Kokoro voice's ▶ line to
//                                         <folder>/samples/<voice>.wav unless it is there; exits 0 once all are.
// The model's name is Pilot's to give (SpeechModel.Choice, Dictate.Model reads it); the other commands read it from the
// folder's ready file.
// Any failure is error <reason> and a non-zero exit; error microphone when macOS has not allowed Pilot to record, and
// error no input device, exit 4, when the Mac has no microphone. A microphone gone mid-take says input lost, then the
// take so far as text.
import Dictate
import Foundation
import os

/// One line at a time: level lines come from the audio thread and partials from their own task, and a pipe keeps only
/// writes under 512 bytes whole.
let saying = OSAllocatedUnfairLock()

func say(_ line: String) {
    saying.withLock { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
}

func text(_ value: String) -> String {
    "text " + String(decoding: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
}

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: pilot-dictate download <folder> <model> | listen <folder> [--words] | prepare <folder> | transcribe <folder> <file> | speak <folder> <voice> <speed> [--out <file>] | samples <folder> (<voice> <line>)...\n".utf8))
    exit(2)
}

/// Waits for stdin to end, or for a line saying cancel; true when cancelled. Ten minutes at most: a take left running
/// stops itself.
func stopOrCancel() async -> Bool {
    await withCheckedContinuation { done in
        let answered = OSAllocatedUnfairLock(initialState: false)
        let answer: @Sendable (Bool) -> Void = { cancelled in
            if answered.withLock({ was in defer { was = true }; return !was }) { done.resume(returning: cancelled) }
        }
        Thread.detachNewThread {
            var cancelled = false
            while let line = readLine() { if line == "cancel" { cancelled = true; break } }
            answer(cancelled)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600) { answer(false) }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { usage() }
let base = URL(filePath: arguments[1])
// Kokoro's files, FluidAudio's caches and Core ML's compile of them stay in its folder (Speak.useFolder).
if arguments[0] == "speak" || arguments.count == 3 && arguments[2] == Speak.modelName || Speak.isKokoro(base) { Speak.useFolder(base) }
do {
    switch arguments[0] {
    case "download" where arguments.count == 3:
        // The last whole percent said, so Pilot hears a hundred lines, not one per chunk.
        let shown = OSAllocatedUnfairLock(initialState: -1)
        let progress: @Sendable (Double) -> Void = { fraction in
            let percent = Int(fraction * 100)
            if shown.withLock({ last in defer { last = percent }; return percent != last }) { say("progress \(String(format: "%.2f", fraction))") }
        }
        if arguments[2] == Speak.modelName { try await Speak.download(to: base, progress: progress, preparing: { say("preparing") }) }
        else { try await Dictate.download(to: base, model: arguments[2], progress: progress, preparing: { say("preparing") }) }
    case "listen":
        // No microphone at all: said before the grant is read, which could ask for it.
        guard Dictate.hasInputDevice else { say(Dictate.noInput); exit(4) }
        guard Dictate.microphoneAllowed else { say("error microphone"); exit(3) }
        // Pilot gone or the take dropped: nothing to type.
        let take = try await Dictate.listen(base, words: arguments.dropFirst(2).contains("--words"), said: say) {
            await stopOrCancel() || getppid() == 1
        }
        if let take { say(text(take)) }
    case "prepare":
        // A background chore: efficiency cores, so it never competes with what Sven is doing.
        setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
        if try await Speak.isKokoro(base) ? Speak.prepare(base) : Dictate.prepare(base) { say("prepared") }
    case "transcribe" where arguments.count == 3:
        let kit = try await Dictate.load(base)
        say(text(try await Dictate.transcribe(kit, try Dictate.samples(of: URL(filePath: arguments[2])))))
    case "speak" where arguments.count == 4 || arguments.count == 6 && arguments[4] == "--out":
        guard let speed = Float(arguments[3]) else { usage() }
        let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        try await Speak.speak(base, text: text, voice: arguments[2], speed: speed,
                              to: arguments.count == 6 ? URL(filePath: arguments[5]) : nil, said: say)
    case "samples" where arguments.count >= 4 && arguments.count % 2 == 0:
        try await Speak.samples(base, stride(from: 2, to: arguments.count, by: 2).map { (arguments[$0], arguments[$0 + 1]) })
    default: usage()
    }
} catch is Dictate.NoInputDevice {
    say(Dictate.noInput)
    exit(4)
} catch {
    say("error \(String(describing: error).replacingOccurrences(of: "\n", with: " "))")
    exit(1)
}
