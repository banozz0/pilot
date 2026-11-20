import Foundation
import JavaScriptCore

// pilot-ext-host (ADR 0017): one run of one Raycast-format extension command, in one fresh JSContext that dies with the
// process, never reused (Tinycast reused one and broke React's scheduler). Pilot starts it as
//   pilot-ext-host --prelude <pilot-ext-prelude.js> <command.js>
// and speaks its private wire, ADR 0010's lines: a run message on stdin, then query, invoke (a press of a callback by its
// handler id, T2, with a form field's or a submit's `value`, T10) and close messages; each commit that changes the view is a list, detail or error line on stdout, so
// data that arrives after the first render fills the view in. A query or invoke with a `seq` is answered by the next
// line, which carries it back as `ack`. A no-view command (T3) prints hud and action lines instead, as ADR 0010's
// programs do. Stdout carries nothing else: the extension's console goes to stderr. Once stdin ends or a close comes,
// the host exits as soon as nothing is left to do (no timer, fetch or counted child pending, then a 150 ms drain for
// effects), and by a deadline at the latest, inside Pilot's own: 1.7 s from the start of a run that ended its input at
// once (Pilot's 2 s list limit), 29.5 s for a no-view run (Pilot's 30 s), 0.4 s from a close (Pilot stops it at 0.5 s).
// At its exit it stops the children it started that are still running, except a detached one, which outlives it as
// Node's does (Native.swift). An open view's run may ask Pilot (T11): an `ask` line (`id`, `what`: `ai` with its `prompt`,
// or `selection`) that Pilot answers on stdin with an `answer` line carrying the same `id` and its `text` or `error`;
// the run is held until it comes, its run deadline too (Pilot's own timeout still stops it). Once stdin ended, nothing
// can answer, so an ask then fails at once. A one-shot run whose run message says `"answers": true` keeps its stdin open
// for answers: it ends as if its input had ended at once, while its asks are still answered. A menu-bar command's bar
// render (T12) has 9.5 s (Pilot gives it 10 s) and ends once the prelude says it is ready (its MenuBarExtra committed,
// not loading, every picture landed) and still is after the drain, timers and fetches left behind, as Raycast unloads a
// menu-bar command then.

/// Writes one line to stdout or stderr, unbuffered.
func put(_ line: String, to handle: FileHandle) { handle.write(Data((line + "\n").utf8)) }

/// A run's line to Pilot, recorded first under --measure (T7); the installer writes through put() and is never measured.
@MainActor func answer(_ line: String) {
    Measure.wrote(line)
    put(line, to: .standardOutput)
}

@MainActor final class Host {
    static let drain: TimeInterval = 0.15, closeDeadline: TimeInterval = 0.4, answerGrace: TimeInterval = 0.5
    /// A run's deadline from its start: a view's, or a no-view command's once the prelude says it is one.
    var runDeadline: TimeInterval = 1.7

    let context: JSContext
    /// The bundle's CommonJS factory, once it loaded.
    private var factory: JSValue
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var started = false, inputOpen = true, closing = false
    /// Work that keeps a run alive past its input's end: fetches in flight and children not unref'd (Native.swift).
    var pending = 0
    /// Asks waiting for Pilot's answer (T11), counted in `pending` too: a run deadline that passes while any waits
    /// (`late`) ends the run only once the last is answered, after a grace for what the answer draws.
    private var asking = 0, late = false
    /// A one-shot run whose stdin Pilot keeps for answers (T11): it ends as one whose input ended, stdin still open.
    private var once = false
    /// A bar render's MenuBarExtra is ready to end (T12).
    private var barReady = false
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
        let write: @convention(block) (String) -> Void = { line in answer(line) }
        let log: @convention(block) (String, String) -> Void = { level, text in put("[\(level)] \(text)", to: .standardError) }
        let setTimer: @convention(block) (Int, Double) -> Void = { [unowned self] id, ms in self.arm(id, after: ms) }
        let clearTimer: @convention(block) (Int) -> Void = { [unowned self] id in self.timers.removeValue(forKey: id)?.cancel() }
        native.setObject(write, forKeyedSubscript: "write" as NSString)
        native.setObject(log, forKeyedSubscript: "log" as NSString)
        native.setObject(setTimer, forKeyedSubscript: "setTimer" as NSString)
        native.setObject(clearTimer, forKeyedSubscript: "clearTimer" as NSString)
        // An ask waiting for Pilot's answer holds the run as a fetch does (T11): +1 as it goes out, -1 as it is answered.
        let hold: @convention(block) (Int) -> Void = { [unowned self] delta in
            asking += delta
            pending += delta
            if asking == 0, late {
                late = false
                deadline(Host.answerGrace, held: true)
            }
            settle()
        }
        native.setObject(hold, forKeyedSubscript: "hold" as NSString)
        // A bar render (T12): its deadline, and whether it is ready to end.
        let menuBar: @convention(block) () -> Void = { [unowned self] in runDeadline = 9.5 }
        let barReady: @convention(block) (Bool) -> Void = { [unowned self] ready in
            self.barReady = ready
            guard ready else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Host.drain) { [weak self] in
                MainActor.assumeIsolated { if self?.barReady == true { self?.finish() } }
            }
        }
        native.setObject(menuBar, forKeyedSubscript: "menuBar" as NSString)
        native.setObject(barReady, forKeyedSubscript: "barReady" as NSString)
        installSystem(into: native)
        SQLiteBridge.install(into: native)  // node:sqlite, read-only (T7)
        Bytes.install(into: native)  // file descriptors, zlib and byte hashes (T26)
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
            if message["answers"] as? Bool == true { runsOnce() }
        case "query": call("__pilotQuery", [message["text"] as? String ?? "", Host.seq(message)])
        case "invoke":
            // A form's press carries a value (T10), parsed in the context as the run message is, so a date or a list
            // of paths arrives as JavaScript's own.
            let value = message["value"] == nil ? JSValue(undefinedIn: context)!
                : context.objectForKeyedSubscript("JSON").invokeMethod("parse", withArguments: [line]).objectForKeyedSubscript("value")!
            call("__pilotInvoke", [message["handler"] as? String ?? "", Host.seq(message), value])
        case "answer":
            // An answer to the run's own ask (T11), parsed in the context as the run message is.
            call("__pilotAnswer", [context.objectForKeyedSubscript("JSON").invokeMethod("parse", withArguments: [line])!])
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
        // Asks still waiting can no longer be answered (T11): they fail, and later ones fail at once.
        call("__pilotInputEnded", [])
        if !once { runDeadlineFromStart() }
        settle()
    }

    /// A one-shot run Pilot answers asks in (T11): it ends as one whose input ended at once, its stdin kept for answers.
    private func runsOnce() {
        once = true
        runDeadlineFromStart()
        settle()
    }

    private func runDeadlineFromStart() { deadline(max(0.05, runDeadline - Date().timeIntervalSince(born)), held: true) }

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
        guard closing || !inputOpen || once, timers.isEmpty, pending == 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Host.drain) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.timers.isEmpty, self.pending == 0 else { return }
                self.finish()
            }
        }
    }

    /// Exits after `seconds`; `held`, a run deadline, waits while an ask is unanswered (T11, `late`), a close's never.
    private func deadline(_ seconds: TimeInterval, held: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if held, self.asking > 0 { return self.late = true }
                self.finish()
            }
        }
    }

    private func finish() {
        stopChildren()
        Measure.exit()
        exit(0)
    }

    /// An exception no JS caught, from a timer or a call into the context: its error line, and its stack on stderr.
    private func uncaught(_ exception: JSValue?) {
        let text = exception?.toString() ?? "an error"
        put("[uncaught] \(text) \(exception?.objectForKeyedSubscript("stack")?.toString() ?? "")", to: .standardError)
        answer(Host.errorLine(text))
    }

    static func errorLine(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["type": "error", "text": String(text.prefix(300))])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

struct HostError: Error { let text: String; init(_ text: String) { self.text = text } }

var arguments = Array(CommandLine.arguments.dropFirst())
Measure.take(&arguments)  // --measure (T7): the harness's record of every call, none acting on the Mac
// The GitHub install route's two steps (Install.swift) run no JSContext and keep none of a run's deadlines.
if let mode = arguments.first, Installer.modes.contains(mode) { Installer.run(arguments) }
guard arguments.count == 3, arguments[0] == "--prelude" else {
    put("usage: pilot-ext-host --prelude <pilot-ext-prelude.js> <command.js>", to: .standardError)
    exit(64)
}
let host: Host
do {
    host = try Host(prelude: URL(filePath: arguments[1]), bundle: URL(filePath: arguments[2]))
} catch {
    answer(Host.errorLine((error as? HostError)?.text ?? error.localizedDescription))
    Measure.exit()
    exit(0)
}
Thread.detachNewThread {
    while let line = readLine() { DispatchQueue.main.async { MainActor.assumeIsolated { Measure.read(line); host.received(line) } } }
    DispatchQueue.main.async { MainActor.assumeIsolated { host.inputEnded() } }
}
dispatchMain()
