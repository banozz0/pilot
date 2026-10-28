import AppKit
import Foundation

/// Bitwarden actions (card agent-bo-95422774; Vicinae's Bitwarden extension, rebuilt within Sven's limits): Pilot drives
/// the Bitwarden app's own menu items and runs `bw generate`, which needs no login. Pilot never unlocks a vault and never
/// reads, prints or logs an item, a password or a session key; a generated password goes only onto the pasteboard.
public enum Bitwarden {
    public static let bundle = "com.bitwarden.desktop"

    /// Menu titles from the desktop app's source, apps/desktop/src/main/menu (menu.view.ts, menu.first.ts) with the
    /// English strings in apps/desktop/src/locales/en/messages.json, github.com/bitwarden/clients, read 2026-10-05.
    public static let search = DriveRoute.menu(bundle: bundle, path: ["View", "Search vault"])
    public static let generator = DriveRoute.menu(bundle: bundle, path: ["View", "Generator"])
    public static let lock = DriveRoute.menu(bundle: bundle, path: ["Bitwarden", "Lock all vaults"])

    /// 20 characters from upper, lower, digits and specials: Bitwarden's own generator, offline, no account.
    public static let generateArguments = generateArguments(length: 20, symbols: true)

    /// bw generate's arguments for `length` characters, specials only with `symbols` (Defaults › Passwords, story 160).
    public static func generateArguments(length: Int, symbols: Bool) -> [String] {
        ["generate", symbols ? "-ulns" : "-uln", "--length", String(length)]
    }

    /// The password as text, marked concealed and transient.
    public static func put(_ password: String, on board: NSPasteboard) {
        board.declareTypes([.string, .concealed, .transient], owner: nil)
        board.setString(password, forType: .string)
        board.setData(Data(), forType: .concealed)
        board.setData(Data(), forType: .transient)
    }

    /// One press of Generate a password: bw makes it, the pasteboard gets it, Pilot's alert says so, and the pasteboard
    /// is cleared after the wait unless something else was copied meanwhile. The password itself is never said or logged.
    @MainActor
    public final class Generator {
        private let generate: @MainActor () async throws -> String
        private let pasteboard: NSPasteboard
        /// How long the password stays copied; the app sets it from Defaults › Passwords before each run.
        public var clearAfter: Duration
        private let say: @MainActor (String) -> Void

        public init(generate: @escaping @MainActor () async throws -> String = Generator.runBW, pasteboard: NSPasteboard = .general,
                    clearAfter: Duration = .seconds(90), say: @escaping @MainActor (String) -> Void) {
            self.generate = generate
            self.pasteboard = pasteboard
            self.clearAfter = clearAfter
            self.say = say
        }

        public static let runBW: @MainActor () async throws -> String = { try await runBW(Bitwarden.generateArguments) }

        public static func runBW(_ arguments: [String]) async throws -> String {
            guard let bw = Homebrew.cli("bw") else { throw CocoaError(.fileNoSuchFile) }
            return try await ChildProcess.run(bw, arguments, timeout: .seconds(20))
        }

        /// One run at a time: bw starts slowly, and a second press must not copy a second password.
        private var running = false
        /// The last run's wait to clear the pasteboard, so a test awaits it rather than a guessed time.
        private(set) var clearing: Task<Void, Never>?

        public func run() async {
            guard !running else { return }
            running = true
            defer { running = false }
            let password = (try? await generate())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !password.isEmpty else { return say("Bitwarden's bw could not make a password") }
            Bitwarden.put(password, on: pasteboard)
            let written = pasteboard.changeCount
            say("Password copied; it clears in \(clearAfter.components.seconds) s")
            let board = pasteboard, wait = clearAfter
            clearing = Task { @MainActor in
                try? await Task.sleep(for: wait)
                if board.changeCount == written { board.clearContents() }
            }
        }
    }
}
