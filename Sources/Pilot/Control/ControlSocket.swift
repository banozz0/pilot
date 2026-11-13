import Foundation
import OSLog
import PilotCore

private let controlLog = Logger(subsystem: "dev.banozz.pilot", category: "control")

/// The socket the pilot command talks to (ADR 0013): `pilot.sock` in Pilot's folder, 0600, answered only for a peer
/// running as Sven. Accepting and reading happen on queues of their own; each request goes to the main actor, so
/// nothing here waits on the tap's run loop or holds it.
@MainActor
final class ControlSocket {
    static let path = PilotFolder.support.appending(path: "pilot.sock")
    private static var live: ControlSocket?

    /// The changes the pilot command planned, waiting on one Allow (ControlPlan); New chat empties it.
    static let plan = ControlPlan()

    /// The app's socket, served from launch to quit, with every verb family registered before it listens.
    static func serve() {
        let socket = ControlSocket(path: path, verbs: registered())
        if socket.start() { live = socket }
    }

    /// Every verb family the app answers: a family adds its own `verbs.register…()` line here, as modules do in
    /// Engine.registerActions. Registering reads no live state, so the tests build it too; the sandbox host hands in its own
    /// `status` reads, and may hand in a Home layout store seeded from a file.
    static func registered(status: ControlStatus = ControlStatus(), homeBlocks: HomeBlockStores = HomeBlockStores()) -> ControlVerbs {
        let verbs = ControlVerbs(plan: plan)
        verbs.registerCore()
        verbs.registerThemes { try ThemeCoordinator.production() }
        verbs.registerPlan(gate: AllowPrompt.gate)
        verbs.registerGuides()
        verbs.registerLog()
        verbs.registerSettings(.live, decide: ControlVerbs.allowPrompt)
        verbs.registerMenuCollections()
        verbs.registerDesktop()
        verbs.registerWallpaper()
        verbs.registerActions(ControlActions())
        verbs.registerExtensions(ExtensionTools())
        verbs.registerWidgets(WidgetTools())
        verbs.registerAppCollections()
        verbs.registerDock()
        verbs.registerStatus(status)
        verbs.registerBindCollections(ControlActions())
        verbs.registerKeys(ControlActions())
        verbs.registerSystem(ControlSystem())
        verbs.registerJobs(ControlJobs())
        verbs.registerNetwork(NetworkTools())
        verbs.registerActivity(ControlActivity(), stats: ControlStats())
        verbs.registerClipboard(ClipboardTools())
        verbs.registerFiles(ControlFiles(), convert: ControlConvert())
        verbs.registerNotes(ControlNotes())
        verbs.registerSpeechCollections()
        verbs.registerConfigs(ControlConfigs())
        verbs.registerFonts(ControlFonts())
        verbs.registerInstall(ControlInstall())
        verbs.registerHomeBlocks(homeBlocks)
        verbs.registerAI(ControlAI())
        verbs.registerModels(ControlModels())
        verbs.registerPermits(ControlPermits())
        verbs.registerLight()
        verbs.registerUninstall()
        return verbs
    }

    let path: URL
    private let verbs: ControlVerbs
    private let queue = DispatchQueue(label: "dev.banozz.pilot.control")
    private var listener: DispatchSourceRead?

    init(path: URL, verbs: ControlVerbs) { self.path = path; self.verbs = verbs }

    /// Binds and listens; a stale file from a crash is replaced. False, with a log line, when the path is past
    /// sun_path's 104 bytes, another Pilot already answers on it, or the socket cannot be made.
    @discardableResult func start() -> Bool {
        let file = path.path(percentEncoded: false)
        var address = sockaddr_un()
        let bytes = Array(file.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            controlLog.error("no control socket: \(file, privacy: .public) is \(bytes.count) bytes, past sun_path's 104")
            return false
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !Self.answers(address) else {
            controlLog.error("no control socket: another Pilot answers on \(file, privacy: .public)")
            return false
        }
        unlink(file)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return failed("socket") }
        // Born private: no moment where another user could connect. The umask is the process's, so only around bind.
        let mask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(mask)
        guard bound == 0, chmod(file, 0o600) == 0, listen(fd, 16) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd)
            return failed("bind")
        }
        listener = Self.accepting(on: fd, queue: queue, verbs: verbs)
        controlLog.info("control socket at \(file, privacy: .public)")
        return true
    }

    /// Stops listening and removes the file; open connections finish their answers.
    func stop() {
        listener?.cancel()
        listener = nil
        unlink(path.path(percentEncoded: false))
    }

    private func failed(_ step: String) -> Bool {
        controlLog.error("no control socket: \(step, privacy: .public) failed, errno \(errno)")
        return false
    }

    /// Whether something listens at `address`: a live socket is never unlinked, a stale file or a dead socket is.
    private static func answers(_ address: sockaddr_un) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    /// Built outside the main actor, so its handlers are not taken for main-actor code when they run on `queue`.
    nonisolated private static func accepting(on fd: Int32, queue: DispatchQueue, verbs: ControlVerbs) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            // Out of descriptors: the waiting peer keeps the source firing, so pause a second instead of spinning.
            guard acceptAll(fd, verbs: verbs) else {
                source.suspend()
                queue.asyncAfter(deadline: .now() + 1) { source.resume() }
                return
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// Accepts every waiting peer; false when the process or the system is out of descriptors.
    nonisolated private static func acceptAll(_ listener: Int32, verbs: ControlVerbs) -> Bool {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return errno != EMFILE && errno != ENFILE }
            var uid = uid_t(), gid = gid_t()
            guard getpeereid(fd, &uid, &gid) == 0 else {
                controlLog.error("control socket: refused a peer whose uid could not be read, errno \(errno)")
                close(fd)
                continue
            }
            guard uid == getuid() else {
                controlLog.error("control socket: refused a peer running as uid \(uid)")
                close(fd)
                continue
            }
            var pid = pid_t()
            var size = socklen_t(MemoryLayout<pid_t>.size)
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size)
            // Accepted sockets inherit the listener's O_NONBLOCK: answers are written blocking, on the connection's queue.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            // A peer that quits mid-answer must not SIGPIPE Pilot, the process that owns the tap.
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var wait = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            ControlConnection(fd: fd, peer: ControlPeer(pid: pid, uid: uid), verbs: verbs).open()
        }
    }
}

/// One client: request lines in, answer lines out. Every field is touched only on `queue`. A client may close its
/// writing side after its request; the connection stays until every answer it is owed is written.
private final class ControlConnection: @unchecked Sendable {
    /// -1 once closed.
    private var fd: Int32
    private let peer: ControlPeer
    private let verbs: ControlVerbs
    private let queue = DispatchQueue(label: "dev.banozz.pilot.control.connection")
    /// nil once reading has stopped and the source has let go of the fd.
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var chunk = [UInt8](repeating: 0, count: 64 << 10)
    /// Requests handed to the main actor and not yet answered; reading pauses at `maxPending`, so a flood of lines never
    /// queues more than that many jobs on the tap's thread.
    private var pending = 0
    private static let maxPending = 8
    private var paused = false
    /// Set by an oversized line: answers still owed are dropped.
    private var abandoned = false

    init(fd: Int32, peer: ControlPeer, verbs: ControlVerbs) { self.fd = fd; self.peer = peer; self.verbs = verbs }

    func open() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in readAvailable() }
        // The fd may close only once the source has let go of it.
        source.setCancelHandler { [self] in self.source = nil; finishIfDone() }
        self.source = source
        source.resume()
    }

    private func readAvailable() {
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else { source?.cancel(); return }
        buffer.append(contentsOf: chunk[..<count])
        drain()
    }

    /// Hands the buffered lines on while fewer than `maxPending` wait for an answer, and pauses reading while that many do.
    private func drain() {
        var start = buffer.startIndex
        while pending < Self.maxPending, let newline = buffer[start...].firstIndex(of: 0x0A) {
            guard newline - start <= ControlLine.maxBytes else { return refuseOversized() }
            handle(buffer[start..<newline])
            start = newline + 1
        }
        buffer.removeSubrange(..<start)
        // Only a partial line is left unless the loop stopped at the cap.
        if pending < Self.maxPending, buffer.count > ControlLine.maxBytes { return refuseOversized() }
        let full = pending >= Self.maxPending
        if let source, full != paused {
            if full { source.suspend() } else { source.resume() }
            paused = full
        }
    }

    private func handle(_ line: Data) {
        guard line.contains(where: { $0 > 0x20 }) else { return }
        let request: ControlRequest
        do { request = try ControlLine.request(line) } catch { return send(.failure(nil, error)) }
        pending += 1
        Task { @MainActor [verbs, peer] in
            let answer = await verbs.answer(request, peer: peer)
            self.queue.async {
                self.pending -= 1
                self.send(answer)
                if !self.abandoned { self.drain() }
                self.finishIfDone()
            }
        }
    }

    private func refuseOversized() {
        send(.failure(nil, ControlError(.badRequest, "a request line is at most \(ControlLine.maxBytes) bytes")))
        abandoned = true
        buffer = Data()
        source?.cancel()
        // A paused source runs its cancel handler only once resumed.
        if paused { source?.resume(); paused = false }
    }

    private func send(_ answer: ControlAnswer) {
        guard fd >= 0, !abandoned else { return }
        let data = ControlLine.encode(answer)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written > 0 { offset += written } else if errno != EINTR { return }
            }
        }
    }

    private func finishIfDone() {
        guard source == nil, fd >= 0, pending == 0 || abandoned else { return }
        close(fd)
        fd = -1
    }
}
