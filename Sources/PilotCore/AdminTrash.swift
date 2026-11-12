import Foundation

/// The Trash for an item macOS refuses Sven's own account, the way Finder does it: with an administrator's password.
/// An App Store app is a folder owned by root, and a folder moved to another folder has its own ".." rewritten, which
/// needs write access to the folder itself; so the plain move fails with permission denied though /Applications lets an
/// admin rename in it. FileManager.trashItem and NSWorkspace.recycle never ask, and NSWorkspace.Authorization needs an
/// entitlement Apple grants on request and has no move. So Pilot asks macOS's own prompt through Standard Additions'
/// `do shell script … with administrator privileges` in a child osascript (no app is targeted, so no Automation ask, and
/// never NSAppleScript on the main thread), which runs `/bin/mv -n` into the item's Trash under a name not taken there.
/// The item lands there still root's, without Finder's Put Back.
public enum AdminTrash {
    /// Runs osascript with these arguments and returns its stdout; a non-zero exit throws ChildProcess.Failure.
    public typealias Run = @Sendable (_ arguments: [String]) async throws -> String

    /// The password prompt was cancelled: nothing moved.
    public struct Cancelled: Error, LocalizedError, Equatable {
        public let name: String
        public var errorDescription: String? { "\(name) stays where it is: the administrator password was cancelled" }
    }

    /// The script: argv is the item, where it goes and the prompt's words, each quoted for the shell, never spliced in.
    static let script = ["on run argv",
                         "do shell script \"/bin/mv -n \" & quoted form of item 1 of argv & \" \" & quoted form of item 2 of argv "
                            + "with prompt (item 3 of argv) with administrator privileges",
                         "end run"]

    public static let osascript: Run = { arguments in
        try await ChildProcess.run("/usr/bin/osascript", arguments, timeout: .seconds(600))
    }

    /// Whether `error` is a move refused for permission (EACCES, anywhere in its underlying errors, Cocoa's no-permission
    /// codes without a POSIX cause, or the Finder-era afpAccessDenied): the one failure an administrator can get past.
    /// EPERM is not one: it is a privacy block (App Management, Full Disk Access) a password does not lift.
    public static func refused(_ error: Error) -> Bool {
        var next: NSError? = error as NSError, posix: Int?
        var cocoa = false
        while let e = next {
            if e.domain == NSPOSIXErrorDomain, posix == nil { posix = e.code }
            if e.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(e.code) { cocoa = true }
            if e.domain == NSOSStatusErrorDomain, e.code == -5000 { return true }
            next = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return posix.map { $0 == Int(EACCES) } ?? cocoa
    }

    /// The plain Trash first; refused for permission, the administrator's move. Never asks in an isolated test run.
    @MainActor public static func trash(_ url: URL, plain: (URL) throws -> URL, run: Run = osascript) async throws -> URL {
        do { return try plain(url) } catch where refused(error) && !isIsolatedTestRun { return try await move(url, run: run) }
    }

    /// `trash` for a caller that answers on the main thread: the plain Trash at once, as before; only a refusal waits, for
    /// the prompt, off the tap's thread, then answers.
    @MainActor public static func trash(_ url: URL, plain: (URL) throws -> URL, run: @escaping Run = osascript,
                                        done: @escaping @MainActor (Result<URL, any Error>) -> Void) {
        do { done(.success(try plain(url))) } catch where refused(error) && !isIsolatedTestRun {
            Task {
                do { done(.success(try await move(url, run: run))) } catch { done(.failure(error)) }
            }
        } catch { done(.failure(error)) }
    }

    /// Moves `url` into its volume's Trash (`into`, else the Trash FileOps finds) after macOS's administrator prompt, and
    /// answers where it went, checked by its inode: the source gone, the same item at the new name.
    public static func move(_ url: URL, into trash: URL? = nil, run: Run = osascript, now: Date = .now) async throws -> URL {
        let path = url.path(percentEncoded: false), name = url.lastPathComponent
        guard let folder = trash ?? FileOps.volumeTrash(url.deletingLastPathComponent()) else {
            throw Problem("\(name) could not go to the Trash: its volume has no Trash")
        }
        var before = Darwin.stat()
        guard lstat(path, &before) == 0 else { throw Problem("\(name) is not there any more") }
        let target = free(name, in: folder, now: now)
        do {
            _ = try await run(script.map { ["-e", $0] }.flatMap(\.self)
                              + [path, target.path(percentEncoded: false), "Pilot wants to move \(name) to the Trash."])
        } catch let failure as ChildProcess.Failure where failure.message.contains("-128") {
            throw Cancelled(name: name)
        } catch let failure as ChildProcess.Failure {
            throw Problem("\(name) could not go to the Trash: \(failure.message)")
        }
        var after = Darwin.stat()
        guard lstat(path, &after) != 0, lstat(target.path(percentEncoded: false), &after) == 0,
              after.st_ino == before.st_ino, after.st_dev == before.st_dev else {
            throw Problem("\(name) did not reach the Trash at \(target.path(percentEncoded: false))")
        }
        return target
    }

    /// A name not taken in `folder`: the item's own, else with the time as Finder adds it ("WhatsApp 17.33.05.app"),
    /// else that and a number.
    static func free(_ name: String, in folder: URL, now: Date) -> URL {
        let file = URL(filePath: name), ext = file.pathExtension, base = file.deletingPathExtension().lastPathComponent
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH.mm.ss"
        let dot = ext.isEmpty ? "" : ".\(ext)", time = clock.string(from: now)
        let names = [name] + ([""] + (2...99).map { " \($0)" }).map { "\(base) \(time)\($0)\(dot)" }
        var spot = Darwin.stat()
        let pick = names.first { lstat(folder.appending(path: $0).path(percentEncoded: false), &spot) != 0 } ?? "\(base) \(UUID().uuidString)\(dot)"
        return folder.appending(path: pick)
    }

    /// A failure in words: what stayed where.
    public struct Problem: Error, LocalizedError, Equatable {
        public let message: String
        init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
