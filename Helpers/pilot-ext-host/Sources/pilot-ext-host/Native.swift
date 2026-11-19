import CryptoKit
import Foundation
import JavaScriptCore

// What the prelude's Node subset and fetch stand on (ADR 0017, T3): files, children, HTTP, hashes and URL parsing, each a
// plain function on `__native`. None throws into JavaScript: a failure comes back as `{"error": <code>, "message": …}`,
// which the prelude turns into Node's error with that `code`. Nothing here opens, copies or shows anything on the Mac:
// those go to Pilot as action lines, so Pilot performs them, or `pilot ext run` answers them unperformed.

/// A child an extension started (child_process): its pipes, read on the main queue, and whether the run waits for it.
struct Child {
    let pid: pid_t
    var stdin: Int32?
    var open = 0, exited = false, counted: Bool
    let detached: Bool
}

/// A value handed across queues as it is: built on one, read on the main queue once.
struct Handed: @unchecked Sendable { let value: Any }

extension Host {
    func installSystem(into native: JSValue) {
        func add(_ name: String, _ block: Any) { native.setObject(block, forKeyedSubscript: name as NSString) }
        // MARK: Files
        add("fsRead", { (path: String) -> Any in
            do { return String(decoding: try Data(contentsOf: URL(filePath: path)), as: UTF8.self) } catch { return Host.failure(error, path) }
        } as @convention(block) (String) -> Any)
        add("fsWrite", { (path: String, text: String, append: Bool) -> Any in
            do {
                if append, let handle = FileHandle(forWritingAtPath: path) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(text.utf8))
                } else {
                    try Data(text.utf8).write(to: URL(filePath: path), options: .atomic)
                }
                return true
            } catch { return Host.failure(error, path) }
        } as @convention(block) (String, String, Bool) -> Any)
        add("fsStat", { (path: String, follow: Bool) -> Any in
            var info = stat()
            guard (follow ? stat(path, &info) : lstat(path, &info)) == 0 else { return Host.failure(errno: errno, path) }
            let type = info.st_mode & S_IFMT
            func ms(_ t: timespec) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1_000_000 }
            return ["size": Double(info.st_size), "mode": Int(info.st_mode), "mtimeMs": ms(info.st_mtimespec), "birthtimeMs": ms(info.st_birthtimespec),
                    "isFile": type == S_IFREG, "isDirectory": type == S_IFDIR, "isSymbolicLink": type == S_IFLNK]
        } as @convention(block) (String, Bool) -> Any)
        add("fsList", { (path: String) -> Any in
            do { return try FileManager.default.contentsOfDirectory(atPath: path).sorted() } catch { return Host.failure(error, path) }
        } as @convention(block) (String) -> Any)
        add("fsMakeFolder", { (path: String, recursive: Bool) -> Any in
            do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: recursive); return true } catch { return Host.failure(error, path) }
        } as @convention(block) (String, Bool) -> Any)
        add("fsRemove", { (path: String, folder: Bool) -> Any in
            guard (folder ? rmdir(path) : unlink(path)) == 0 else { return Host.failure(errno: errno, path) }
            return true
        } as @convention(block) (String, Bool) -> Any)
        add("fsRemoveAll", { (path: String) -> Any in
            do { try FileManager.default.removeItem(atPath: path); return true } catch { return Host.failure(error, path) }
        } as @convention(block) (String) -> Any)
        add("fsMove", { (from: String, to: String) -> Any in
            rename(from, to) == 0 ? true : Host.failure(errno: errno, from)
        } as @convention(block) (String, String) -> Any)
        add("fsCopy", { (from: String, to: String) -> Any in
            copyfile(from, to, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 ? true : Host.failure(errno: errno, from)
        } as @convention(block) (String, String) -> Any)
        add("fsReal", { (path: String) -> Any in
            guard let real = realpath(path, nil) else { return Host.failure(errno: errno, path) }
            defer { free(real) }
            return String(decoding: UnsafeRawBufferPointer(start: real, count: strlen(real)), as: UTF8.self)
        } as @convention(block) (String) -> Any)

        // MARK: The process and the system
        add("env", { () -> Any in ProcessInfo.processInfo.environment } as @convention(block) () -> Any)
        add("cwd", { () -> Any in FileManager.default.currentDirectoryPath } as @convention(block) () -> Any)
        add("hostname", { () -> Any in
            var name = [UInt8](repeating: 0, count: 256)
            return name.withUnsafeMutableBufferPointer { buffer in
                buffer.withMemoryRebound(to: CChar.self) { gethostname($0.baseAddress, $0.count) } == 0
                    ? String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self) : "localhost"
            }
        } as @convention(block) () -> Any)
        add("osRelease", { () -> Any in
            var info = utsname()
            uname(&info)
            return withUnsafeBytes(of: info.release) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        } as @convention(block) () -> Any)
        add("noView", { [unowned self] in runDeadline = 29.5 } as @convention(block) () -> Void)
        add("hash", { (algorithm: String, text: String) -> Any in
            Host.digest(algorithm, Data(text.utf8)).map(Host.hex)
                ?? ["error": "ERR_CRYPTO_INVALID_DIGEST", "message": "Pilot has no digest \(algorithm)"]
        } as @convention(block) (String, String) -> Any)
        add("random", { (count: Int) -> Any in
            var bytes = [UInt8](repeating: 0, count: max(0, min(count, 65_536)))
            arc4random_buf(&bytes, bytes.count)
            return Host.hex(bytes)
        } as @convention(block) (Int) -> Any)
        add("parseURL", { (input: String, base: String) -> Any in Host.parse(input, base: base) ?? NSNull() } as @convention(block) (String, String) -> Any)

        // MARK: HTTP
        add("fetch", { [unowned self] (id: Int, request: [String: Any]) in fetch(id, request) } as @convention(block) (Int, [String: Any]) -> Void)

        // MARK: Children
        add("spawn", { [unowned self] (id: Int, file: String, args: [String], options: [String: Any]) -> Any in
            spawn(id, file, args, options)
        } as @convention(block) (Int, String, [String], [String: Any]) -> Any)
        add("spawnSync", { (file: String, args: [String], options: [String: Any], input: String) -> Any in
            Host.spawnSync(file, args, options, input: input)
        } as @convention(block) (String, [String], [String: Any], String) -> Any)
        add("childWrite", { [unowned self] (id: Int, text: String) in
            guard let fd = children[id]?.stdin else { return }
            Data(text.utf8).withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        } as @convention(block) (Int, String) -> Void)
        add("childEnd", { [unowned self] (id: Int) in
            guard let fd = children[id]?.stdin else { return }
            close(fd)
            children[id]?.stdin = nil
        } as @convention(block) (Int) -> Void)
        add("childKill", { [unowned self] (id: Int, signal: Int32) -> Bool in
            guard let child = children[id], !child.exited else { return false }
            return kill(child.pid, signal) == 0
        } as @convention(block) (Int, Int32) -> Bool)
        add("unref", { [unowned self] (id: Int) in
            guard children[id]?.counted == true else { return }
            children[id]?.counted = false
            pending -= 1
            settle()
        } as @convention(block) (Int) -> Void)
    }

    // MARK: Failures

    /// A failure as the prelude reads it: Node's code (ENOENT and the rest) and its message.
    static func failure(errno code: Int32, _ path: String) -> [String: Any] {
        let names: [Int32: String] = [ENOENT: "ENOENT", EACCES: "EACCES", EEXIST: "EEXIST", ENOTDIR: "ENOTDIR", EISDIR: "EISDIR",
                                      ENOTEMPTY: "ENOTEMPTY", EPERM: "EPERM", EXDEV: "EXDEV", EINVAL: "EINVAL", ELOOP: "ELOOP"]
        let name = names[code] ?? "EIO"
        return ["error": name, "message": "\(name): \(String(cString: strerror(code))), '\(path)'"]
    }

    static func failure(_ error: any Error, _ path: String) -> [String: Any] {
        let ns = error as NSError
        if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain { return failure(errno: Int32(posix.code), path) }
        if ns.domain == NSPOSIXErrorDomain { return failure(errno: Int32(ns.code), path) }
        switch ns.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return failure(errno: ENOENT, path)
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return failure(errno: EACCES, path)
        case NSFileWriteFileExistsError: return failure(errno: EEXIST, path)
        default: return ["error": "EIO", "message": "EIO: \(ns.localizedDescription), '\(path)'"]
        }
    }

    // MARK: Hashes and URLs

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }

    static func digest(_ algorithm: String, _ data: Data) -> [UInt8]? {
        switch algorithm.lowercased().replacingOccurrences(of: "-", with: "") {
        case "md5": Array(Insecure.MD5.hash(data: data))
        case "sha1": Array(Insecure.SHA1.hash(data: data))
        case "sha256": Array(SHA256.hash(data: data))
        case "sha384": Array(SHA384.hash(data: data))
        case "sha512": Array(SHA512.hash(data: data))
        default: nil
        }
    }

    /// `input` against `base` (empty for none) as a URL's parts, its path, query and fragment kept percent-encoded; nil
    /// when it is not an absolute URL.
    static func parse(_ input: String, base: String) -> [String: Any]? {
        let baseURL = base.isEmpty ? nil : URL(string: base)
        guard base.isEmpty || baseURL?.scheme != nil, let url = URL(string: input, relativeTo: baseURL)?.absoluteURL,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: true), let scheme = parts.scheme else { return nil }
        var out: [String: Any] = ["protocol": scheme.lowercased() + ":", "pathname": parts.percentEncodedPath]
        out["hostname"] = parts.percentEncodedHost ?? ""
        out["port"] = parts.port.map(String.init) ?? ""
        out["username"] = parts.percentEncodedUser ?? ""
        // The userinfo's second half goes as `pass`.
        out["pass"] = parts.percentEncodedPassword ?? ""
        out["search"] = parts.percentEncodedQuery.map { $0.isEmpty ? "" : "?" + $0 } ?? ""
        out["hash"] = parts.percentEncodedFragment.map { $0.isEmpty ? "" : "#" + $0 } ?? ""
        out["slashes"] = url.absoluteString.dropFirst(scheme.count + 1).hasPrefix("//")
        return out
    }

    // MARK: fetch

    /// One request, answered to `__pilotFetched(id, …)` with its status, headers and body as text, or an error; it keeps
    /// the run alive until then. An ephemeral session: no cookie or cache is written to disk.
    func fetch(_ id: Int, _ request: [String: Any]) {
        guard let text = request["url"] as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return call("__pilotFetched", [id, ["error": "Pilot fetches only http and https URLs: \(request["url"] ?? "")"]])
        }
        var made = URLRequest(url: url)
        made.httpMethod = (request["method"] as? String)?.uppercased() ?? "GET"
        for pair in request["headers"] as? [[String]] ?? [] where pair.count == 2 { made.addValue(pair[1], forHTTPHeaderField: pair[0]) }
        if let body = request["body"] as? String { made.httpBody = Data(body.utf8) }
        pending += 1
        Host.session.dataTask(with: made) { data, response, error in
            var answer: [String: Any] = [:]
            if let error {
                answer["error"] = error.localizedDescription
            } else if let http = response as? HTTPURLResponse {
                answer["status"] = http.statusCode
                answer["statusText"] = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                answer["url"] = http.url?.absoluteString ?? text
                answer["headers"] = http.allHeaderFields.map { [String(describing: $0.key).lowercased(), String(describing: $0.value)] }
                answer["body"] = String(decoding: data ?? Data(), as: UTF8.self)
            } else {
                answer["error"] = "no HTTP answer"
            }
            let handed = Handed(value: answer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending -= 1
                    self.call("__pilotFetched", [id, handed.value])
                    self.settle()
                }
            }
        }.resume()
    }

    static let session = URLSession(configuration: .ephemeral)

    // MARK: Children

    /// Starts `file` (looked up on PATH) with `args`: its own session when `detached`, so Pilot's stop of the host's tree
    /// passes it by once the host is gone; stdio `ignore` gives it /dev/null, else three pipes read here. Every other
    /// descriptor is closed in it, so it never holds Pilot's pipe. Answers its pid, or the failure.
    func spawn(_ id: Int, _ file: String, _ args: [String], _ options: [String: Any]) -> Any {
        let detached = options["detached"] as? Bool == true, ignore = options["stdio"] as? String == "ignore"
        let started: Started
        do { started = try Host.start(file, args, options, pipes: !ignore, detached: detached) } catch { return Host.failure(errno: error.code, file) }
        var child = Child(pid: started.pid, stdin: started.stdin, counted: true, detached: detached)
        for (fd, stream) in [(started.stdout, "stdout"), (started.stderr, "stderr")] {
            guard let fd else { continue }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    let count = read(fd, &buffer, buffer.count)
                    if count > 0 {
                        self?.call("__pilotChild", [id, stream, String(decoding: buffer.prefix(count), as: UTF8.self)])
                    } else {
                        source.cancel()
                        close(fd)
                        self?.childPart(id) { $0.open -= 1 }
                    }
                }
            }
            child.open += 1
            source.resume()
        }
        children[id] = child
        pending += 1
        let pid = started.pid
        Thread.detachNewThread {
            let ended = Handed(value: Host.reap(pid))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let (code, signal) = ended.value as! (Any, Any)
                    self.call("__pilotChild", [id, "exit", code, signal])
                    self.childPart(id) { $0.exited = true }
                }
            }
        }
        return Int(pid)
    }

    /// Changes child `id`, and once it has exited and both its pipes ended, says `close` and stops waiting for it.
    private func childPart(_ id: Int, _ change: (inout Child) -> Void) {
        guard var child = children[id] else { return }
        change(&child)
        children[id] = child
        guard child.exited, child.open <= 0 else { return }
        if let fd = child.stdin { close(fd) }
        children[id] = nil
        call("__pilotChild", [id, "close"])
        if child.counted { pending -= 1 }
        settle()
    }

    /// At the host's exit: SIGTERM to each child still running that is not detached, as Pilot's stop of the tree would.
    func stopChildren() {
        for child in children.values where !child.exited && !child.detached { kill(child.pid, SIGTERM) }
    }

    /// Waits for `pid` to end: its exit code and signal name, each NSNull when it has none.
    nonisolated static func reap(_ pid: pid_t) -> (code: Any, signal: Any) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        let signalled = status & 0x7f
        return signalled == 0 ? (Int((status >> 8) & 0xff), NSNull()) : (NSNull(), signalName(signalled))
    }

    nonisolated static func signalName(_ signal: Int32) -> String {
        [SIGTERM: "SIGTERM", SIGKILL: "SIGKILL", SIGINT: "SIGINT", SIGHUP: "SIGHUP", SIGPIPE: "SIGPIPE", SIGABRT: "SIGABRT"][signal] ?? "SIG\(signal)"
    }

    struct SpawnFailure: Error { let code: Int32 }
    struct Started { let pid: pid_t, stdin: Int32?, stdout: Int32?, stderr: Int32? }

    /// posix_spawnp with every descriptor but 0, 1 and 2 closed in the child, in `options["cwd"]` with `options["env"]`.
    static func start(_ file: String, _ args: [String], _ options: [String: Any], pipes: Bool, detached: Bool) throws(SpawnFailure) -> Started {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT) | Int32(POSIX_SPAWN_SETSIGMASK)
        if detached { flags |= Int32(POSIX_SPAWN_SETSID) }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var ours: [Int32] = [], theirs: [Int32] = []
        func pipePair() throws(SpawnFailure) -> (read: Int32, write: Int32) {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw SpawnFailure(code: errno) }
            return (fds[0], fds[1])
        }
        var stdin: Int32?, stdout: Int32?, stderr: Int32?
        if pipes {
            let input = try pipePair(), output = try pipePair(), errors = try pipePair()
            posix_spawn_file_actions_adddup2(&actions, input.read, 0)
            posix_spawn_file_actions_adddup2(&actions, output.write, 1)
            posix_spawn_file_actions_adddup2(&actions, errors.write, 2)
            (stdin, stdout, stderr) = (input.write, output.read, errors.read)
            ours = [input.write, output.read, errors.read]
            theirs = [input.read, output.write, errors.write]
            for fd in ours { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        if let cwd = options["cwd"] as? String, !cwd.isEmpty { posix_spawn_file_actions_addchdir(&actions, cwd) }
        let environment = (options["env"] as? [String: Any]).map { $0.map { "\($0.key)=\($0.value)" } }
            ?? ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = withCStrings([file] + args) { argv in
            withCStrings(environment) { envp in posix_spawnp(&pid, file, &actions, &attributes, argv, envp) }
        }
        for fd in theirs { close(fd) }
        guard status == 0 else {
            for fd in ours { close(fd) }
            throw SpawnFailure(code: status)
        }
        return Started(pid: pid, stdin: stdin, stdout: stdout, stderr: stderr)
    }

    /// Runs `file` to its end with `input` on its stdin: its status (or signal), stdout and stderr, as spawnSync answers.
    static func spawnSync(_ file: String, _ args: [String], _ options: [String: Any], input: String) -> Any {
        let started: Started
        do { started = try start(file, args, options, pipes: true, detached: false) } catch { return Host.failure(errno: error.code, file) }
        // Piped, so all three are there.
        let (stdin, stdout, stderr) = (started.stdin!, started.stdout!, started.stderr!)
        let errors = Drain(stderr)
        Thread.detachNewThread { errors.run() }
        Data(input.utf8).withUnsafeBytes { _ = write(stdin, $0.baseAddress, $0.count) }
        close(stdin)
        let output = Drain(stdout)
        output.run()
        errors.done.wait()
        let (status, signal) = reap(started.pid)
        return ["status": status, "signal": signal,
                "stdout": String(decoding: output.data, as: UTF8.self), "stderr": String(decoding: errors.data, as: UTF8.self), "pid": Int(started.pid)]
    }
}

/// Reads a descriptor to its end, then closes it.
final class Drain: @unchecked Sendable {
    let fd: Int32, done = DispatchSemaphore(value: 0)
    var data = Data()
    init(_ fd: Int32) { self.fd = fd }
    func run() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) } else if count < 0, errno == EINTR { continue } else { break }
        }
        close(fd)
        done.signal()
    }
}

/// `strings` as a NULL-ended C array for the length of `body`.
func withCStrings<T>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> T) -> T {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
