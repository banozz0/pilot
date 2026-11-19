import Foundation
import Testing
@testable import PilotCore

/// Install's packages and installed-checks (stories 81, 88, 97, 99, 100). Pure: nothing here installs anything. The
/// shipped catalogue went with Install's recommended apps (Sven, 2026-11-18, Q243).
@Suite("Install packages")
struct InstallPackageTests {
    @Test("A command is installed in Homebrew's folders or a vendor installer's (~/.local/bin), never by macOS's own /usr/bin copy; several paths are met by any one")
    func installedChecks() throws {
        let home = { (path: String) in NSString(string: path).expandingTildeInPath }
        let claude = InstallCheck.command("claude")
        #expect(claude.isMet(bundleInstalled: { _ in false }, fileExists: { $0 == home("~/.local/bin/claude") }))
        #expect(claude.isMet(bundleInstalled: { _ in false }, fileExists: { $0 == "/usr/local/bin/claude" }))
        #expect(!InstallCheck.command("ruby").isMet(bundleInstalled: { _ in true }, fileExists: { $0 == "/usr/bin/ruby" }))
        let paths = InstallCheck.paths(["~/.opencode/bin/opencode", "/opt/homebrew/bin/opencode"])
        #expect(paths.isMet(bundleInstalled: { _ in false }, fileExists: { $0 == home("~/.opencode/bin/opencode") }))
        #expect(!paths.isMet(bundleInstalled: { _ in false }, fileExists: { _ in false }))
        #expect(InstallCheck.bundle("a.b").isMet(bundleInstalled: { $0 == "a.b" }, fileExists: { _ in false }))
    }

    @Test("Each package kind has its install command and a package key; a name that is not a safe token is refused")
    func commands() {
        #expect(Package(.cask, "coteditor")?.install == "brew install --cask coteditor")
        #expect(Package(.formula, "hello")?.install == "brew install hello")
        #expect(Package(.uv, "telegram-tools")?.install == "uv tool install telegram-tools")
        #expect(Package(.cask, "banozz0/tap/easy-cd")?.key == "cask:banozz0/tap/easy-cd")
        #expect(Package(key: "formula:hello") == Package(.formula, "hello"))
        #expect(Package(.formula, "a b") == nil)
        #expect(Package(.formula, "-v") == nil)
        #expect(Package(key: "nope") == nil)
    }
}

/// The visible terminal's script (story 97): the command runs where Sven sees it, the window closes on exit 0 and stays
/// open otherwise. Run here with a harmless command and a fake success hook.
@Suite("Visible terminal")
struct VisibleRunTests {
    func run(_ command: String) throws -> (status: Int32, output: String, hooked: Bool, scriptGone: Bool) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "visible-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hook = dir.appending(path: "hooked")
        let script = dir.appending(path: "run.command")
        try VisibleRun.script(command: command, onSuccess: "touch '\(hook.path)'").write(to: script, atomically: true, encoding: .utf8)
        let p = Process(), out = Pipe()
        p.executableURL = URL(filePath: "/bin/zsh")
        p.arguments = [script.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, output, FileManager.default.fileExists(atPath: hook.path), !FileManager.default.fileExists(atPath: script.path))
    }

    @Test("Exit 0 runs the success hook and ends the script, so the window closes")
    func success() throws {
        let r = try run("echo installing")
        #expect(r.status == 0)
        #expect(r.hooked)
        #expect(r.scriptGone)
        #expect(r.output.contains("$ echo installing"))
        #expect(r.output.contains("installing"))
    }

    @Test("A failing command skips the hook and waits for Return, so the window stays open with the error")
    func failure() throws {
        let r = try run("echo boom >&2; (exit 3)")
        #expect(r.status == 3)
        #expect(!r.hooked)
        #expect(r.output.contains("boom"))
        #expect(r.output.contains("Failed with exit 3. Press Return to close."))
    }

    @Test("Without Ghostty, Terminal runs the script as the window's shell and closes the window only on a clean exit")
    func terminal() throws {
        let plist = try PropertyListSerialization.propertyList(from: VisibleRun.terminalSettings(script: "/tmp/a b.command"), format: nil)
        let d = try #require(plist as? [String: Any])
        #expect(d["CommandString"] as? String == "/bin/zsh '/tmp/a b.command'")
        #expect(d["RunCommandAsShell"] as? Bool == true)
        #expect(d["shellExitAction"] as? Int == 1)
        #expect(d["type"] as? String == "Window Settings")
    }

    @Test("Homebrew and uv's tools are on the script's PATH without a login shell")
    func path() {
        let s = VisibleRun.script(command: "true", onSuccess: "true")
        #expect(s.contains("export PATH=\"/opt/homebrew/bin:$HOME/.local/bin:$PATH\""))
    }
}

/// What Pilot installed (story 97, SPEC.md: "Install records what it installed in Pilot's store").
@Suite("Installed store")
struct InstalledStoreTests {
    @Test("A recorded install is listed by its package key; an absent file is none")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "installed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InstalledStore(url: dir.appending(path: "Pilot/installed.json"))
        #expect(try store.load().isEmpty)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try store.record(Package(.formula, "hello")!, at: at)
        #expect(try store.load() == ["formula:hello": at])
        try Data("x".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.record(Package(.formula, "hello")!, at: at) }
    }
}
