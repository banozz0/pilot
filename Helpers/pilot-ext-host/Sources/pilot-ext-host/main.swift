import Foundation
import JavaScriptCore

// pilot-ext-host (ADR 0017): one run of one Raycast-format extension command, in one fresh JSContext that dies with the
// process, never reused (Tinycast reused one and broke React's scheduler). Pilot starts it as
//   pilot-ext-host --prelude <pilot-ext-prelude.js> <command.js>
// and speaks its private wire, ADR 0010's lines: a run message on stdin, then query, invoke (a press of a callback by its
// handler id, T2) and close messages; each commit that changes the view is a list, detail or error line on stdout, so
// data that arrives after the first render fills the view in. A query or invoke with a `seq` is answered by the next
// line, which carries it back as `ack`. A no-view command (T3) prints hud and action lines instead, as ADR 0010's
// programs do. Stdout carries nothing else: the extension's console goes to stderr. Once stdin ends or a close comes,
// the host exits as soon as nothing is left to do (no timer, fetch or counted child pending, then a 150 ms drain for
// effects), and by a deadline at the latest, inside Pilot's own: 1.7 s from the start of a run that ended its input at
// once (Pilot's 2 s list limit), 29.5 s for a no-view run (Pilot's 30 s), 0.4 s from a close (Pilot stops it at 0.5 s).
// At its exit it stops the children it started that are still running, except a detached one, which outlives it as
// Node's does (Native.swift).

/// Writes one line to stdout or stderr, unbuffered.
func put(_ line: String, to handle: FileHandle) { handle.write(Data((line + "\n").utf8)) }

@MainActor final class Host {
    static let drain: TimeInterval = 0.15, closeDeadline: TimeInterval = 0.4
    /// A run's deadline from its start: a view's, or a no-view command's once the prelude says it is one.
    var runDeadline: TimeInterval = 1.7

    let context: JSContext
    /// The bundle's CommonJS factory, once it loaded.
    private var factory: JSValue
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var started = false, inputOpen = true, closing = false
    /// Work that keeps a run alive past its input's end: fetches in flight and children not unref'd (Native.swift).
    var pending = 0
    var children: [Int: Child] = [:]
    private let born = Date()

    /// Loads the prelude and the bundle's CommonJS factory; a failure is the run's error line.
    init(prelude: URL, bundle: URL) throws {
        guard let context = JSContext() else { throw HostError("JavaScriptCore made no context") }
        self.context = context
        context.name = "pilot-ext-host"
        let preludeSource = try String(contentsOf: prelude, encoding: .utf8)
        let bundleSource: String
        do { bundleSource = try String(contentsOf: bundle, encoding: .utf8) } catch { throw HostError("its command file \(bundle.lastPathComponent) does not read") }
        factory = JSValue(undefinedIn: context)
        context.exceptionHandler = { [unowned self] _, exception in self.uncaught(exception) }
        installNative()
        context.evaluateScript(preludeSource, withSourceURL: prelude)
        guard context.objectForKeyedSubscript("__pilotStart")?.isObject == true else { throw HostError("the prelude did not load") }
        // The bundle as Raycast's build emits it, CommonJS: wrapped once so its module, exports and require are the host's.
        guard let made = context.evaluateScript("(function (module, exports, require) {\n\(bundleSource)\n})", withSourceURL: bundle),
              made.isObject else { throw HostError("its command file does not load") }
        factory = made
    }

    private func installNative() {
        let native = JSValue(newObjectIn: context)!
        let write: @convention(block) (String) -> Void = { line in put(line, to: .standardOutput) }
        let log: @convention(block) (String, String) -> Void = { level, text in put("[\(level)] \(text)", to: .standardError) }
        let setTimer: @convention(block) (Int, Double) -> Void = { [unowned self] id, ms in self.arm(id, after: ms) }
        let clearTimer: @convention(block) (Int) -> Void = { [unowned self] id in self.timers.removeValue(forKey: id)?.cancel() }
        native.setObject(write, forKeyedSubscript: "write" as NSString)
        native.setObject(log, forKeyedSubscript: "log" as NSString)
        native.setObject(setTimer, forKeyedSubscript: "setTimer" as NSString)
        native.setObject(clearTimer, forKeyedSubscript: "clearTimer" as NSString)
        installSystem(into: native)
        context.setObject(native, forKeyedSubscript: "__native" as NSString)
    }

    // MARK: Messages from Pilot

    func received(_ line: String) {
        guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else { return }
        switch type {
        case "run" where !started:
            started = true
            let parsed = context.objectForKeyedSubscript("JSON").invokeMethod("parse", withArguments: [line])!
            call("__pilotStart", [factory, parsed])
        case "query": call("__pilotQuery", [message["text"] as? String ?? "", Host.seq(message)])
        case "invoke": call("__pilotInvoke", [message["handler"] as? String ?? "", Host.seq(message)])
        case "close":
            closing = true
            call("__pilotClose", [])
            deadline(Host.closeDeadline)
            settle()
        default: break
        }
    }

    func inputEnded() {
        inputOpen = false
        guard started else { return finish() }
        deadline(max(0.05, runDeadline - Date().timeIntervalSince(born)))
        settle()
    }

    /// A request's number, or null when it has none.
    static func seq(_ message: [String: Any]) -> Any { (message["seq"] as? Int).map { $0 as Any } ?? NSNull() }

    func call(_ name: String, _ arguments: [Any]) {
        context.objectForKeyedSubscript(name)?.call(withArguments: arguments)
    }

    // MARK: Timers and the exit

    private func arm(_ id: Int, after ms: Double) {
        timers.removeValue(forKey: id)?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0, ms) / 1000)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fire(id) } }
        timers[id] = timer
        timer.resume()
    }

    private func fire(_ id: Int) {
        timers.removeValue(forKey: id)?.cancel()
        call("__pilotFire", [id])
        settle()
    }

    /// Once input has ended or a close came and nothing is pending, exits after the drain unless work began meanwhile.
    func settle() {
        guard closing || !inputOpen, timers.isEmpty, pending == 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Host.drain) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.timers.isEmpty, self.pending == 0 else { return }
                self.finish()
            }
        }
    }

    private func deadline(_ seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in MainActor.assumeIsolated { self?.finish() } }
    }

    private func finish() {
        stopChildren()
        exit(0)
    }

    /// An exception no JS caught, from a timer or a call into the context: its error line, and its stack on stderr.
    private func uncaught(_ exception: JSValue?) {
        let text = exception?.toString() ?? "an error"
        put("[uncaught] \(text) \(exception?.objectForKeyedSubscript("stack")?.toString() ?? "")", to: .standardError)
        put(Host.errorLine(text), to: .standardOutput)
    }

    static func errorLine(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["type": "error", "text": String(text.prefix(300))])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

struct HostError: Error { let text: String; init(_ text: String) { self.text = text } }

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, arguments[0] == "--prelude" else {
    put("usage: pilot-ext-host --prelude <pilot-ext-prelude.js> <command.js>", to: .standardError)
    exit(64)
}
let host: Host
do {
    host = try Host(prelude: URL(filePath: arguments[1]), bundle: URL(filePath: arguments[2]))
} catch {
    put(Host.errorLine((error as? HostError)?.text ?? error.localizedDescription), to: .standardOutput)
    exit(0)
}
Thread.detachNewThread {
    while let line = readLine() { DispatchQueue.main.async { MainActor.assumeIsolated { host.received(line) } } }
    DispatchQueue.main.async { MainActor.assumeIsolated { host.inputEnded() } }
}
dispatchMain()
