import AppKit
import Darwin
import PilotCore
import Testing
@testable import Pilot

/// The terminal suites, one at a time: each starts shells under /usr/bin/login, and TerminalSurface.shellPID tells its
/// shell by the one login that appeared since it started, so two suites starting shells at once would blur it.
@Suite(.serialized) @MainActor struct TerminalSuites {}

extension TerminalSuites {
    /// The terminal's bar drop (spec Bar drops T6, T11): `terminal.drop` and the bar's TERMINAL item open the same drop, a
    /// Ghostty shell whose view has the keyboard; hiding keeps the shell; Escape reaches it through the drop's key path
    /// (BarDrops.key, then the view), as the panel's monitor sends it. Every check reads the terminal's screen buffer.
    /// `/bin/zsh -f` keeps Sven's rc files out, and Ghostty runs without his config unless PILOT_GHOSTTY_USER_CONFIG=1; no key
    /// here sends a prompt.
    @Suite("Terminal drop", .serialized)
    @MainActor
    struct TerminalDropTests {
        static func until(_ seconds: Double, _ done: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            return done()
        }

        /// Ghostty's resources as build-ghosttykit.sh leaves them, which Pilot.app carries in Resources: the test host is no
        /// bundle, so libghostty is pointed at them.
        static func useBuiltResources() {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../.build/ghosttykit/resources/ghostty")
            setenv("GHOSTTY_RESOURCES_DIR", dir.standardizedFileURL.path, 1)
        }

        /// A terminal drop over drops on BarDropPanelTests' made-up screen, not yet open; its tips land in `tips`, never on screen.
        static func drop(make: @escaping () -> TerminalSurface = { TerminalSurface(command: "/bin/zsh -f") },
                         tips: @escaping (String) -> Void = { Issue.record("unexpected tip: \($0)") }) -> (BarDrops, TerminalDrop) {
            useBuiltResources()
            GhosttyRuntime.userConfig = ProcessInfo.processInfo.environment["PILOT_GHOSTTY_USER_CONFIG"] == "1"
            let drops = BarDropPanelTests.drops()
            return (drops, TerminalDrop(drops: drops, make: make, tip: tips))
        }

        /// The drop open, its shell's view holding the keyboard and sitting at its prompt.
        static func shown(_ drops: BarDrops, _ drop: TerminalDrop) throws -> TerminalSurface {
            #expect(drops.isOpen(.terminal))
            let surface = try #require(drop.surface)
            #expect(drops.window(.terminal)?.firstResponder === surface, "the shell's view has the keyboard")
            #expect(until(15) { surface.screenText().contains("%") }, "no prompt: \(surface.screenText())")
            return surface
        }

        /// Opened by its registered action, as Hyper+T runs it.
        static func opened() throws -> (BarDrops, TerminalDrop, TerminalSurface) {
            let (drops, drop) = drop()
            var registry = ActionRegistry()
            TerminalDrop.register(into: &registry, drop: { drop })
            let action = try #require(registry.actions[TerminalDrop.actionID])
            #expect(action.label == "Drop the terminal" && action.tier == .v1)
            // Hyper+T runs inside the tap's callback: it returns at once, and the drop opens on the run loop's next pass.
            let pressed = ContinuousClock.now
            action.run()
            let returned = pressed.duration(to: .now)
            #expect(!drops.isOpen(.terminal) && returned < .milliseconds(20), "the tap waited \(returned) on the open")
            #expect(until(10) { drops.isOpen(.terminal) })
            print("[terminal] Hyper+T returned in \(returned); the drop was open after \(pressed.duration(to: .now))")
            return (drops, drop, try shown(drops, drop))
        }

        /// The shell's pid, as it prints it.
        static func pid(_ surface: TerminalSurface) -> pid_t {
            let tag = "PID\(Int.random(in: 1000...9999))"
            surface.type("echo \(tag)=$$\r")
            var pid: pid_t = 0
            _ = until(10) {
                let screen = surface.screenText()
                guard let match = screen.range(of: "\(tag)=[0-9]+", options: .regularExpression) else { return false }
                pid = pid_t(screen[match].dropFirst(tag.count + 1)) ?? 0
                return true
            }
            return pid
        }

        /// A key down as AppKit builds it: Control turns a letter into its control character, the unmodified letter beside it.
        static func keyEvent(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], window: NSWindow?,
                             at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
            let typed = flags.contains(.control) ? String(UnicodeScalar(chars.unicodeScalars.first!.value & 0x1F)!) : chars
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: time, windowNumber: window?.windowNumber ?? 0,
                                    context: nil, characters: typed, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }

        /// `code` pressed in the drop: its key path first, the view after unless taken, as the panel's local monitor does.
        static func press(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], in drops: BarDrops, _ surface: TerminalSurface,
                          at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            guard !drops.key(in: .terminal, code, flags, chars, at: time) else { return }
            surface.keyDown(with: keyEvent(chars, code, flags, window: drops.window(.terminal), at: time))
        }

        @Test("terminal.drop opens a shell that echoes; hidden, it keeps its pid; reopened, the same shell answers", .pilotFocus)
        func opensAndKeeps() throws {
            let (drops, drop, surface) = try Self.opened()
            defer { drops.hideAll(); surface.terminate() }
            surface.type("echo MARK_$((6*7))\r")
            #expect(Self.until(10) { surface.screenText().contains("MARK_42") }, "\(surface.screenText())")
            let pid = Self.pid(surface)
            #expect(pid > 0)
            drop.toggle()
            #expect(!drops.isOpen(.terminal))
            #expect(kill(pid, 0) == 0, "hiding ended shell \(pid)")
            surface.type("echo HIDDEN_$((5*5))\r")
            #expect(Self.until(10) { surface.screenText().contains("HIDDEN_25") }, "the hidden shell stopped answering")
            drop.toggle()
            #expect(drops.isOpen(.terminal) && drop.surface === surface)
            #expect(drops.window(.terminal)?.firstResponder === surface, "reopened, the shell's view has the keyboard again")
            #expect(Self.pid(surface) == pid, "reopened, a different shell")
        }

        /// Build 46: the bar item opened an empty grey panel that took no keys; it now runs the drop's own toggle.
        @Test("The bar's TERMINAL item opens the same drop as Hyper+T: the shell, holding the keyboard, typed into", .pilotFocus)
        func barItem() throws {
            let (drops, drop) = Self.drop()
            BarDropLights.toggleDrop(.terminal, terminal: drop)
            let surface = try Self.shown(drops, drop)
            defer { drops.hideAll(); surface.terminate() }
            for (chars, code) in [("e", 14), ("c", 8), ("h", 4), ("o", 31), (" ", 49), ("T", 17), ("Y", 16), ("P", 35), ("E", 14), ("D", 2)] as [(String, UInt16)] {
                Self.press(chars, code, chars.uppercased() == chars && chars != " " ? .shift : [], in: drops, surface)
            }
            Self.press("\r", 36, in: drops, surface)
            #expect(Self.until(10) { surface.screenText().components(separatedBy: "TYPED").count >= 3 }, "keys did not reach the shell: \(surface.screenText())")
            BarDropLights.toggleDrop(.terminal, terminal: drop)
            #expect(!drops.isOpen(.terminal))
        }

        /// Pilot's drop runs the login shell and closes the moment it exits. A named command, as here, makes libghostty wait
        /// for a key first (wait-after-command), which then closes it the same way.
        @Test("The shell exiting closes the drop; the next open starts a fresh shell", .pilotFocus)
        func exitCloses() throws {
            let (drops, drop, surface) = try Self.opened()
            defer { drops.hideAll(); surface.terminate() }
            let first = Self.pid(surface)
            surface.type("exit\r")
            #expect(Self.until(10) { kill(first, 0) != 0 }, "the shell did not exit")
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            Self.press("a", 0, in: drops, surface)
            #expect(Self.until(10) { !drops.isOpen(.terminal) && !surface.started }, "the drop stayed after the shell exited")
            drop.toggle()
            _ = try Self.shown(drops, drop)
            let second = Self.pid(surface)
            #expect(second > 0 && second != first)
        }

        @Test("The drop's header names the shell and the folder it is in now: zsh · ~, then zsh · /usr after cd", .pilotFocus)
        func header() throws {
            let (drops, _, surface) = try Self.opened()
            defer { drops.hideAll(); surface.terminate() }
            #expect(surface.shellName == "zsh")
            #expect(surface.shellPID == Self.pid(surface), "shellPID is not the shell's own $$")
            #expect(TerminalDropChrome.detail(surface) == "zsh · ~")
            surface.type("cd /usr\r")
            #expect(Self.until(5) { TerminalDropChrome.detail(surface) == "zsh · /usr" }, "\(TerminalDropChrome.detail(surface))")
        }

        /// Moody, T11: Ghostty's own Cmd+W (close_surface) freed the surface, hanging up a running shell and what ran in it.
        @Test("Cmd+W hides the drop and the running shell lives on; the next open is the same shell", .pilotFocus)
        func commandW() throws {
            let (drops, drop, surface) = try Self.opened()
            defer { drops.hideAll(); surface.terminate() }
            let pid = Self.pid(surface)
            #expect(surface.performKeyEquivalent(with: Self.keyEvent("w", 13, .command, window: drops.window(.terminal))), "Cmd+W is Ghostty's")
            #expect(Self.until(5) { !drops.isOpen(.terminal) }, "Cmd+W left the drop open")
            #expect(surface.started && kill(pid, 0) == 0, "Cmd+W ended shell \(pid)")
            drop.toggle()
            _ = try Self.shown(drops, drop)
            #expect(Self.pid(surface) == pid, "reopened on a different shell")
        }

        /// A terminal whose libghostty never starts.
        final class DeadSurface: TerminalSurface {
            var tries = 0
            override func start() -> Bool { tries += 1; return false }
        }

        @Test("A terminal that does not start drops nothing, says so, and is tried again on the next open")
        func failedStart() throws {
            let dead = DeadSurface(command: "/bin/zsh -f")
            var tips: [String] = []
            let (drops, drop) = Self.drop(make: { dead }, tips: { tips.append($0) })
            drop.toggle()
            #expect(!drops.isOpen(.terminal) && drops.window(.terminal) == nil, "a blank drop opened")
            #expect(tips == ["The terminal did not start; Pilot's log says why"])
            drop.toggle()
            #expect(dead.tries == 2 && tips.count == 2 && !drops.isOpen(.terminal))
        }

        @Test("One Escape reaches the shell and the drop stays; Control+C reaches it too", .pilotFocus)
        func keys() throws {
            let (drops, _, surface) = try Self.opened()
            defer { drops.hideAll(); surface.terminate() }
            func escapes() -> Int { surface.screenText().components(separatedBy: "^[").count - 1 }
            surface.type("cat -v\r")
            #expect(Self.until(5) { surface.screenText().contains("cat -v") })
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            // The tty echoes ESC as ^[, then cat prints the line back: two ^[ means the byte reached the pty.
            Self.press("\u{1b}", 53, in: drops, surface)
            #expect(drops.isOpen(.terminal), "one Escape is the shell's")
            Self.press("\r", 36, in: drops, surface)
            #expect(Self.until(5) { escapes() >= 2 }, "\(surface.screenText())")
            Self.press("c", 8, .control, in: drops, surface)
            #expect(Self.until(5) { surface.screenText().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%") })
        }
    }
}
