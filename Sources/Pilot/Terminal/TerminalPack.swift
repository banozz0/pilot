import CryptoKit
import Darwin
import Foundation
import PilotCore
import Security

/// The terminal as a download (T76, plan pilot-terminal-download, Sven Q897-Q900): libghostty is a signed dylib Pilot
/// fetches on the first Hyper+T, installs in Application Support/Pilot/Terminal/<sha256>/libghostty.dylib and loads with
/// dlopen into its own process, which holds Accessibility and Input Monitoring. So nothing loads unchecked:
/// - The pin (TerminalPackPin.swift, written by Scripts/build-terminal-pack.sh) is compiled into Pilot, under Pilot's own
///   signature: the zip's size and SHA-256 and the dylib's SHA-256. A hash fetched beside the pack would prove nothing.
/// - A download must match the zip's pin before it is unpacked, and its quarantine flag is cleared only after that.
/// - Every load, not only the first: no symbolic link at the folder or the file, no quarantine flag, the dylib's SHA-256
///   read through a descriptor that follows no link, then its signature: identifier dev.banozz.pilot.terminal and the very
///   certificate that signed the running Pilot (SecCodeCopySelf), so the check follows Pilot's identity to Developer ID at
///   T15. A Pilot signed ad hoc or not at all loads no pack.
/// - Install unpacks into a staging folder inside Terminal/, checks it in full, and renames it into place: a half-written
///   pack never sits where a load looks.
/// Until T15 a check-then-dlopen race remains: a process running as Sven could swap the file between the check and the
/// map. Without the hardened runtime the same user can already inject into Pilot (DYLD_INSERT_LIBRARIES, a writable bundle),
/// so the Mac is no less safe than before; T15's library validation checks the signature as the file is mapped.
enum TerminalPack {
    /// The pack this Pilot loads: the release asset's file name, the zip's byte count and SHA-256, the dylib's SHA-256.
    struct Pin: Sendable, Equatable {
        let file: String
        let bytes: Int
        let sha256: String
        let dylibSHA256: String
        /// The SHA-1 of the certificate that signed it, for the tests; Pilot checks a pack against its own certificate.
        let leaf: String

        /// The download's size as the first press says it, "5 MB".
        var megabytes: Int { max(1, Int((Double(bytes) / 1_000_000).rounded())) }
    }

    struct Failure: Error, Equatable, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }

        static let unsigned = Failure("This Pilot is not signed with a certificate, so it loads no terminal pack")
        static let offline = Failure("No connection: the terminal downloads when you're online")
        static let oversized = Failure("The terminal download ran past its pinned size; Pilot stopped it")
        static let short = Failure("The terminal file is shorter than its pinned size; Pilot refuses it")
    }

    static let identifier = "dev.banozz.pilot.terminal"
    static let dylibName = "libghostty.dylib"
    static let quarantine = "com.apple.quarantine"

    /// Application Support/Pilot/Terminal: one folder per pack, named by its dylib's SHA-256.
    static var folder: URL { PilotFolder.support.appending(path: "Terminal", directoryHint: .isDirectory) }

    /// Where `pin`'s pack lives once installed.
    static func dylib(_ pin: Pin = pin, in folder: URL = folder) -> URL {
        folder.appending(path: pin.dylibSHA256, directoryHint: .isDirectory).appending(path: dylibName)
    }

    /// Whether `pin`'s pack is on disk as a plain file (its checks run at load).
    static func isInstalled(_ pin: Pin = pin, in folder: URL = folder) -> Bool { isPlainFile(dylib(pin, in: folder)) }

    /// The release asset built for this Pilot's version, never `latest`: an older Pilot fetches the pack built for its own
    /// ghostty.h. A build of Sven's own (build-app.sh's PILOT_DEV or debug) names its own zip instead, PilotTerminalURL; the
    /// pin checks those bytes the same way.
    static func url(for pin: Pin = pin, info: [String: Any]? = Bundle.main.infoDictionary) -> URL? {
        if let own = info?["PilotTerminalURL"] as? String { return URL(string: own) }
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        return URL(string: "https://github.com/banozz0/pilot/releases/download/v\(version)/\(pin.file)")
    }

    // MARK: Trust

    /// The requirement a pack must meet: Pilot's pack identifier, signed by the certificate whose SHA-1 is `leaf`.
    static func requirement(leaf: String) -> String { "identifier \"\(identifier)\" and certificate leaf = H\"\(leaf)\"" }

    /// The running Pilot's own requirement for its pack, read once; a Pilot with no certificate (ad hoc, swift run) has none.
    static func pilotRequirement() throws -> String {
        guard let ownRequirement else { throw Failure.unsigned }
        return ownRequirement
    }

    private static let ownRequirement: String? = {
        var me: SecCode?
        var mine: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine else { return nil }
        return leaf(of: mine).map(requirement(leaf:))
    }()

    /// The SHA-1 of a signature's leaf certificate in hex, as `codesign -d -r-` prints it; nil for no certificate.
    static func leaf(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
    }

    /// The checks every load runs, in order; each failure says which one refused the file.
    static func verify(_ dylib: URL, sha256: String, requirement: String) throws {
        let path = dylib.path(percentEncoded: false)
        guard isPlainFile(dylib), isPlainDirectory(dylib.deletingLastPathComponent()) else {
            throw Failure("The terminal pack is not a plain file; Pilot refuses it")
        }
        guard !isQuarantined(dylib) else { throw Failure("The terminal pack is quarantined; Pilot loads only the pack it fetched and checked") }
        guard try hash(path) == sha256 else { throw Failure("The terminal pack does not match this Pilot's pin; Pilot refuses it") }
        var code: SecStaticCode?
        var wanted: SecRequirement?
        guard SecStaticCodeCreateWithPath(dylib as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &wanted) == errSecSuccess, let wanted else {
            throw Failure("The terminal pack's signature cannot be read")
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), wanted)
        guard status == errSecSuccess else {
            let why = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            throw Failure("The terminal pack is not signed as Pilot is (\(why)); Pilot refuses it")
        }
    }

    /// Checks the pack and maps it: the calls, or why not. Off the main thread: the first map after an install takes
    /// about 266 ms (T75), past the 250 ms hang line.
    static func load(_ dylib: URL, sha256: String, requirement: String) throws -> GhosttyAPI {
        try verify(dylib, sha256: sha256, requirement: requirement)
        guard let handle = dlopen(dylib.path(percentEncoded: false), RTLD_NOW | RTLD_LOCAL) else {
            throw Failure("The terminal pack did not load: \(dlerror().map { String(cString: $0) } ?? "no reason given")")
        }
        return try GhosttyAPI(handle: handle)
    }

    // MARK: Install

    /// Installs a downloaded zip: its size and SHA-256 must match the pin before anything reads it; it unpacks into a
    /// staging folder in `folder`, the dylib is checked in full there, and the folder is renamed into place. A pack
    /// already in place stays when it passes its checks. The installed dylib.
    static func install(zip: URL, pin: Pin, requirement: String, in folder: URL = folder) async throws -> URL {
        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path(percentEncoded: false))[.size] as? Int) ?? -1
        guard size == pin.bytes, try hash(zip.path(percentEncoded: false)) == pin.sha256 else {
            throw Failure("The terminal download did not match its checksum")
        }
        // Pilot's own downloads carry no quarantine flag (no LSFileQuarantineEnabled); one is cleared only now, past the pin.
        removexattr(zip.path(percentEncoded: false), quarantine, XATTR_NOFOLLOW)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard isPlainDirectory(folder) else { throw Failure("Pilot's Terminal folder is not a plain folder; Pilot refuses it") }
        let stage = folder.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: stage) }
        _ = try await ChildProcess.run("/usr/bin/ditto", ["-x", "-k", "--noqtn", zip.path(percentEncoded: false), stage.path(percentEncoded: false)],
                                       timeout: .seconds(60))
        let staged = stage.appending(path: dylibName)
        guard try fm.contentsOfDirectory(atPath: stage.path(percentEncoded: false)) == [dylibName] else {
            throw Failure("The terminal download holds something other than its pack")
        }
        // ditto --noqtn carries no quarantine flag over; verify refuses one all the same.
        try verify(staged, sha256: pin.dylibSHA256, requirement: requirement)
        let target = dylib(pin, in: folder)
        let place = target.deletingLastPathComponent()
        if rename(stage.path(percentEncoded: false), place.path(percentEncoded: false)) != 0 {
            // Another install got there first: kept when it passes, replaced when it does not.
            if (try? verify(target, sha256: pin.dylibSHA256, requirement: requirement)) != nil { return target }
            try? fm.removeItem(at: place)
            guard rename(stage.path(percentEncoded: false), place.path(percentEncoded: false)) == 0 else {
                throw Failure("The terminal pack could not be put in place: \(String(cString: strerror(errno)))")
            }
        }
        return target
    }

    /// Pilot's launch: the folders of other packs and any staging left by a quit go. True when an older pack was there and
    /// this Pilot's is not, a changed pack after an update, which the caller fetches in the background; the older folder
    /// stays until the new one is in, so a failed fetch tries again at the next launch.
    @discardableResult
    static func sweep(keeping pin: Pin = pin, in folder: URL = folder) -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return false }
        let installed = isInstalled(pin, in: folder)
        var older = false
        for name in names where name != pin.dylibSHA256 {
            if name.hasPrefix(".staging-") || installed { try? fm.removeItem(at: folder.appending(path: name)) } else { older = true }
        }
        return older
    }

    /// Settings' Remove: the packs on disk go; the one mapped stays until Pilot quits.
    static func remove(in folder: URL = folder) throws {
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: Fetch

    /// The pinned pack from `url`, its share done reported as it arrives, then installed. Cancelling the task stops the
    /// download; a failure leaves nothing behind.
    static func fetch(_ pin: Pin, from url: URL, requirement: String, in folder: URL = folder,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        tblog.notice("terminal pack: downloading \(pin.file, privacy: .public), \(pin.bytes) bytes")
        let zip = try await download(url, limit: pin.bytes, progress: progress)
        defer { try? FileManager.default.removeItem(at: zip) }
        let installed = try await install(zip: zip, pin: pin, requirement: requirement, in: folder)
        tblog.notice("terminal pack: installed \(pin.dylibSHA256.prefix(8), privacy: .public)")
        return installed
    }

    /// The bytes at `url`, never more than `limit`: a download running past the pin's size stops there.
    private static func download(_ url: URL, limit: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appending(path: "pilot-terminal-\(UUID().uuidString).zip")
        if url.isFileURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? -1
            guard size <= limit else { throw Failure.oversized }
            guard size == limit else { throw Failure.short }
            try FileManager.default.copyItem(at: url, to: out)
            progress(1)
            return out
        }
        let fetch = Fetch(to: out, limit: Int64(limit), progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: fetch, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                fetch.done = continuation
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    /// One download's delegate: progress in whole percents as bytes arrive, the file moved out before URLSession deletes it.
    private final class Fetch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let to: URL
        let limit: Int64
        let progress: @Sendable (Double) -> Void
        var done: CheckedContinuation<URL, Error>?
        private var moved: Result<URL, Error>?
        private var percent = -1
        private var oversized = false

        init(to: URL, limit: Int64, progress: @escaping @Sendable (Double) -> Void) { self.to = to; self.limit = limit; self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite _: Int64) {
            guard totalBytesWritten <= limit else {
                oversized = true
                downloadTask.cancel()
                return
            }
            let share = Double(totalBytesWritten) / Double(limit)
            guard Int(share * 100) != percent else { return }
            percent = Int(share * 100)
            progress(share)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { moved = .failure(Failure("The terminal download failed (HTTP \(status))")); return }
            moved = Result { try FileManager.default.moveItem(at: location, to: to); return to }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                                                   .timedOut, .dnsLookupFailed, .dataNotAllowed]
                let code = (error as? URLError)?.code ?? .unknown
                done?.resume(throwing: oversized ? Failure.oversized : code == .cancelled ? CancellationError()
                    : offline.contains(code) ? Failure.offline : Failure(error.localizedDescription))
            } else {
                done?.resume(with: moved ?? .failure(Failure("The terminal download ended empty")))
            }
            done = nil
        }
    }

    // MARK: Files

    /// SHA-256 in hex, read through a descriptor that follows no link.
    static func hash(_ path: String) throws -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("The terminal pack cannot be read: \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path(percentEncoded: false), quarantine, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    private static func isPlainFile(_ url: URL) -> Bool { mode(url).map { $0 & S_IFMT == S_IFREG } ?? false }
    private static func isPlainDirectory(_ url: URL) -> Bool { mode(url).map { $0 & S_IFMT == S_IFDIR } ?? false }

    /// lstat's mode: a link is itself, never what it points to.
    private static func mode(_ url: URL) -> mode_t? {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0 ? info.st_mode : nil
    }
}
