import AppKit
import Darwin
import Foundation
import Testing
@testable import Pilot

extension TerminalSuites {
    /// The engine checks of the bar drops spike (T1, branch spike/bar-drop-terminal), run on the libghostty T11 builds from
    /// source: a shell in a borderless window never ordered in, every check read off Ghostty's screen buffer, never pixels.
    /// `/bin/zsh -f` keeps Sven's rc files out, and Ghostty runs without his config unless PILOT_GHOSTTY_USER_CONFIG=1.
    @MainActor @Suite(.serialized) struct TerminalSpikeTests {
        nonisolated static let env = ProcessInfo.processInfo.environment

        static func until(_ seconds: Double, _ done: () -> Bool) -> Bool { TerminalDropTests.until(seconds, done) }

        /// A started shell at its prompt, in a window holding its view.
        static func shell(_ command: String = "/bin/zsh -f") -> (NSWindow, TerminalSurface) {
            // PILOT_GHOSTTY_USER_CONFIG=1 runs every check under Sven's own Ghostty config, as the drop does.
            TerminalDropTests.useBuiltResources()
            GhosttyRuntime.userConfig = env["PILOT_GHOSTTY_USER_CONFIG"] == "1"
            let term = TerminalSurface(command: command)
            let window = NSWindow(contentRect: term.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = term
            window.makeFirstResponder(term)
            term.start()
            #expect(until(15) { term.screenText().contains("%") }, "no prompt: \(term.screenText())")
            return (window, term)
        }

        static func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
            TerminalDropTests.keyEvent(chars, code, flags, window: window)
        }

        @Test("A shell echoes a marker read off Ghostty's screen; hidden, it still answers")
        func marker() throws {
            let (window, term) = Self.shell()
            defer { term.terminate(); window.close() }
            term.type("echo SPIKE_$((6*7))\r")
            #expect(Self.until(10) { term.screenText().contains("SPIKE_42") }, "\(term.screenText())")
            window.contentView = nil
            term.type("echo HIDDEN_$((5*5))\r")
            #expect(Self.until(10) { term.screenText().contains("HIDDEN_25") })
        }

        @Test("Escape, Control+C and Shift+Return reach the shell through Ghostty's own key handling")
        func keys() throws {
            let (window, term) = Self.shell()
            defer { term.terminate(); window.close() }
            term.type("cat -v\r")
            #expect(Self.until(5) { term.screenText().contains("cat -v") })
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            term.keyDown(with: Self.key("\u{1b}", 53, in: window))
            term.keyDown(with: Self.key("\r", 36, in: window))
            // The tty echoes ESC as ^[, then cat prints the line back: two ^[ means the byte reached the pty.
            #expect(Self.until(5) { term.screenText().components(separatedBy: "^[").count - 1 >= 2 }, "\(term.screenText())")
            term.keyDown(with: Self.key("c", 8, .control, in: window))
            #expect(Self.until(5) { term.screenText().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%") })

            // As Claude Code asks for it: the kitty keyboard protocol on, Shift+Return arrives as its own sequence, not a bare CR.
            term.type("printf '\\e[>1u'; cat -v\r")
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            term.keyDown(with: Self.key("\r", 36, .shift, in: window))
            term.keyDown(with: Self.key("\r", 36, in: window))
            #expect(Self.until(5) { term.screenText().contains("^[[13;2u") }, "\(term.screenText())")
        }

        /// Claude Code in the terminal (PILOT_LIVE=1): draws its screen, Ctrl+C twice quits it. No prompt is sent, so no model call.
        @Test("Claude Code draws in Ghostty and quits on Ctrl+C twice", .enabled(if: env["PILOT_LIVE"] == "1"))
        func claudeCode() throws {
            let (window, term) = Self.shell()
            defer { term.terminate(); window.close() }
            term.type("cd; PATH=$HOME/.local/bin:/opt/homebrew/bin:$PATH claude --model haiku --effort low\r")
            #expect(Self.until(30) { let s = term.screenText(); return s.contains("╭") || s.contains("Claude Code") || s.contains("trust") })
            // Keys before Claude Code is up are dropped: wait for its footer. No key that could send a prompt: Return,
            // Shift+Return and bash mode ("!") each start a model turn.
            _ = Self.until(20) { term.screenText().contains("shift+tab") }
            term.keyDown(with: Self.key("\u{1b}", 53, in: window))
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            term.keyDown(with: Self.key("c", 8, .control, in: window))
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            term.keyDown(with: Self.key("c", 8, .control, in: window))
            #expect(Self.until(10) { term.screenText().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%") }, "\(term.screenText())")
        }

        /// Sven's ~/.config/ghostty as the drop reads it (PILOT_GHOSTTY_USER_CONFIG=1): it parses clean, the look comes with it.
        @Test("The user's Ghostty config loads clean", .enabled(if: env["PILOT_GHOSTTY_USER_CONFIG"] == "1"))
        func userConfig() throws {
            let report = GhosttyRuntime.userConfigReport()
            print("[ghostty] user config: font-size \(report.fontSize) · diagnostics \(report.diagnostics)")
            #expect(report.fontSize > 0 && report.diagnostics.isEmpty)
        }

        /// Ghostty's own terminfo and shell integration are found (build-ghosttykit.sh's, which Pilot.app carries): TERM is
        /// xterm-ghostty and the shell can read its entry.
        @Test("TERM is xterm-ghostty and its terminfo resolves")
        func terminfo() throws {
            let (window, term) = Self.shell()
            defer { term.terminate(); window.close() }
            term.type("echo TERM_IS_$TERM; infocmp \"$TERM\" >/dev/null && echo TI_OK\r")
            #expect(Self.until(10) { term.screenText().contains("TERM_IS_xterm-ghostty") && term.screenText().contains("TI_OK") }, "\(term.screenText())")
        }

        /// The idle cost the terminal adds (PILOT_SPIKE_IDLE=1): footprint and CPU of this test host, before Ghostty, shown,
        /// and hidden with the shell alive for 60 s. Deltas count; the host is not Pilot.
        @Test("Idle cost, shown and hidden", .enabled(if: env["PILOT_SPIKE_IDLE"] == "1"))
        func idle() throws {
            func footprintMB() -> Double {
                var info = rusage_info_v0()
                _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V0, $0) } }
                return Double(info.ri_phys_footprint) / 1_048_576
            }
            func cpuSeconds() -> Double {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            }
            func cpuPercent(over seconds: Double) -> Double {
                let start = cpuSeconds()
                RunLoop.main.run(until: Date().addingTimeInterval(seconds))
                return (cpuSeconds() - start) / seconds * 100
            }
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            let before = footprintMB(), beforeCPU = cpuPercent(over: 10)
            let (window, term) = Self.shell()
            defer { term.terminate(); window.close() }
            let shownCPU = cpuPercent(over: 20), shown = footprintMB()
            window.contentView = nil
            let hiddenCPU = cpuPercent(over: 60), hidden = footprintMB()
            print(String(format: "[ghostty] idle: before %.1f MB %.2f%% · shown +%.1f MB %.2f%% · hidden 60 s +%.1f MB %.2f%%",
                         before, beforeCPU, shown - before, shownCPU, hidden - before, hiddenCPU))
        }
    }
}
