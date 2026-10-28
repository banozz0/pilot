import Foundation
import OSLog
import PilotCore

private let mediaLog = Logger(subsystem: "dev.banozz.pilot", category: "media")

/// Pauses and plays the app macOS counts as now playing (Control Centre's Now Playing): the tests pass a recorder.
@MainActor
protocol MediaControlling: AnyObject {
    /// Pauses it if it is playing; `done` hears whether it did.
    func pauseIfPlaying(_ done: @escaping @MainActor (Bool) -> Void)
    func play()
}

/// Through MediaRemote's Pause and Play commands, never a key (ADR 0001): `/usr/bin/perl` runs Contents/Helpers/
/// pilot-media.pl with pilot-media.dylib (Helpers/pilot-media), as macOS 15.4 and later tell only Apple's own programs
/// what is playing. Each step is a child of a few tens of milliseconds, off the main thread.
final class BundledMediaControl: MediaControlling {
    static let script = Bundle.main.bundleURL.appending(path: "Contents/Resources/pilot-media.pl").path
    static let library = Bundle.main.bundleURL.appending(path: "Contents/Helpers/pilot-media.dylib").path

    func pauseIfPlaying(_ done: @escaping @MainActor (Bool) -> Void) {
        run("pause") { done($0 == "paused") }
    }

    func play() { run("play") { _ in } }

    private func run(_ command: String, _ answer: @escaping @MainActor (String) -> Void) {
        guard FileManager.default.fileExists(atPath: Self.library) else {
            mediaLog.error("pilot-media is not in the bundle")
            return answer("")
        }
        Task.detached {
            let said: String
            do {
                said = try await ChildProcess.run("/usr/bin/perl", [Self.script, Self.library, command], timeout: .seconds(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                mediaLog.error("pilot-media \(command, privacy: .public): \(String(describing: error), privacy: .public)")
                said = ""
            }
            mediaLog.notice("pilot-media \(command, privacy: .public): \(said, privacy: .public)")
            await answer(said)
        }
    }
}

/// Dictation › Pause media while dictating (Sven on Build 62) and Read aloud's Pause (Q282): a take
/// pauses what is playing and plays it again as the take ends, only when it was playing. A take that ends before the pause answered plays it once
/// the answer comes.
@MainActor
final class MediaPause {
    private enum State { case idle, pausing(endedMeanwhile: Bool), paused }

    private var state = State.idle
    private let media: MediaControlling

    init(media: MediaControlling) { self.media = media }

    func takeStarted() {
        guard case .idle = state else { return }
        state = .pausing(endedMeanwhile: false)
        media.pauseIfPlaying { [weak self] paused in
            guard let self, case .pausing(let ended) = state else { return }
            state = paused && !ended ? .paused : .idle
            if paused && ended { media.play() }
        }
    }

    func takeEnded() {
        switch state {
        case .idle, .pausing(endedMeanwhile: true): break
        case .pausing: state = .pausing(endedMeanwhile: true)
        case .paused:
            state = .idle
            media.play()
        }
    }
}
