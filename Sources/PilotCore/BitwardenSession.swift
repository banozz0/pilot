import Foundation

/// Unlocking for the fill: a visible terminal runs bw unlock, where Sven types his master password into bw itself;
/// bw's prompts go to the terminal (stderr) and only the session key goes, with --raw, into a pipe Pilot reads.
public enum BitwardenUnlock {
    /// Seconds bw's prompt stays open; then bw is ended (perl's alarm, as macOS has no timeout(1)), so no master
    /// password can be typed into it after Pilot's key tap is back on.
    public static let limit = 300
    /// How long Pilot reads the pipe once bw's shell has opened it: longer than `limit`, so the tap comes back only once
    /// bw is gone.
    public static let readWait: Duration = .seconds(limit + 5)

    static let alarmThenExec = #"$SIG{ALRM} = "DEFAULT"; sigprocmask(SIG_UNBLOCK, POSIX::SigSet->new(SIGALRM)); alarm shift; exec @ARGV"#

    public static func command(bw: String, pipe: String, limit: Int = limit) -> String {
        // SIGALRM unblocked and default first: a parent that blocked or ignored it would otherwise keep bw alive.
        // Then the terminal's echo is put back and the window closes, never a no-echo "press Return" after a timeout.
        "/usr/bin/perl -MPOSIX -e '\(alarmThenExec)' \(limit) \(VisibleRun.quoted(bw)) unlock --raw > \(VisibleRun.quoted(pipe))"
            + "; s=$?; stty sane 2>/dev/null; exit $s"
    }

    /// One unlock: Pilot's keyboard tap goes off before the terminal opens, so the master password Sven types there
    /// never reaches Pilot, and comes back on only once the pipe is done, whatever it gave. Returns the key, if any.
    @MainActor
    public static func run(pauseKeys: () -> Void, resumeKeys: () -> Void, openTerminal: () -> Void,
                           read: () async -> Data?) async -> String? {
        pauseKeys()
        defer { resumeKeys() }
        openTerminal()
        return await read().flatMap(key(from:))
    }

    /// The key bw wrote: one token of at least 20 characters, else nothing (an empty pipe, an error, a prompt).
    public static func key(from data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 20, !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }
}

/// A named pipe in a folder only Sven's account can enter, read once, then removed with its folder. Nothing lands on
/// disk: a pipe holds what passes through it only until it is read.
public struct SessionPipe: Sendable {
    public let path: URL
    private let folder: URL

    public init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "pilot-bw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        path = folder.appending(path: "session")
        guard mkfifo(path.path, 0o600) == 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Whether `fd` has data or has reached its end before `deadline`. select(), not poll() or kqueue: on macOS those
    /// never wake when a pipe's writer closes, so a finished unlock would wait out the whole deadline.
    static func readable(_ fd: Int32, by deadline: Date) -> Bool {
        let left = deadline.timeIntervalSinceNow
        guard left > 0, fd < FD_SETSIZE else { return false }
        var set = fd_set()
        withUnsafeMutableBytes(of: &set) { $0.bindMemory(to: Int32.self)[Int(fd) / 32] |= Int32(bitPattern: 1 << UInt32(fd % 32)) }
        var wait = timeval(tv_sec: Int(left), tv_usec: Int32((left - left.rounded(.down)) * 1_000_000))
        return select(fd + 1, &set, nil, nil, &wait) > 0
    }

    /// Reads what a writer sends until it closes, within `timeout` of the writer opening the pipe; a writer that never
    /// opens it (the terminal did not start) is given up on after `openWithin`. Removes the pipe either way. A GCD thread waits, not the async pool.
    public func read(timeout: Duration, openWithin: Duration = .seconds(60)) async -> Data? {
        let path = path.path, folder = folder
        let seconds = { (d: Duration) in Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        let wait = seconds(timeout), openWait = seconds(openWithin)
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                // Opening for writing ourselves ends an open() nobody else will end (the terminal never ran the command).
                let giveUp = DispatchWorkItem { let fd = open(path, O_WRONLY | O_NONBLOCK); if fd >= 0 { close(fd) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + openWait, execute: giveUp)
                var data = Data()
                let fd = open(path, O_RDONLY)
                giveUp.cancel()
                // The clock starts when the writer (the shell starting bw) opens the pipe, as bw's own limit does.
                let deadline = Date().addingTimeInterval(wait)
                if fd >= 0 {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while SessionPipe.readable(fd, by: deadline) {
                        let count = Darwin.read(fd, &buffer, buffer.count)
                        if count <= 0 { break }
                        data.append(buffer, count: count)
                    }
                    close(fd)
                }
                try? FileManager.default.removeItem(at: folder)
                done.resume(returning: data.isEmpty ? nil : data)
            }
        }
    }
}
