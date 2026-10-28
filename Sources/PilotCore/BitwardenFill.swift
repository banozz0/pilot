import Foundation

/// Where the fill reads logins: the bw CLI in the app, a fake in tests (card agent-bo-95422814).
@MainActor
public protocol BitwardenVault: AnyObject {
    func currentStatus() async throws -> BitwardenFill.Status
    func logins(for host: String) async throws -> [BitwardenFill.Login]
    /// Unlocks it for the fill; true once it is unlocked.
    func unlock() async -> Bool
}

/// Bitwarden fill login (card agent-bo-95422814, Sven's explicit yes on 2026-10-05, Q&A card jCQITKnS-R8 item 5): the
/// logins Bitwarden keeps for the site in front, one picked when there are several, typed into the focused field. Pilot
/// never sees the master password (Sven types it into bw in a visible terminal); a password, a username or a session
/// key is never said, logged, listed or put on a pasteboard, only typed.
public enum BitwardenFill {
    public enum Status: Equatable, Sendable { case unlocked, locked, loggedOut }

    /// One login, held only while it is typed. Its description hides the secrets, so no log line or interpolation can
    /// show them by accident.
    public struct Login: Equatable, Sendable, CustomStringConvertible {
        public let id: String
        public let name: String
        public let username: String
        public let password: String
        public let uris: [String]

        public init(id: String, name: String, username: String, password: String, uris: [String]) {
            self.id = id; self.name = name; self.username = username; self.password = password; self.uris = uris
        }

        public var description: String { "Login(\(id))" }
    }

    /// A pick-list row: the item's name and username, never the password.
    public struct Choice: Equatable, Sendable {
        public let id: String
        public let name: String
        public let username: String
    }

    public static let locked = "Bitwarden CLI is locked"

    /// The logins whose saved address is the host in front, a subdomain of it, or a parent of it (a login saved for
    /// github.com fills on api.github.com, one saved for gist.github.com fills on github.com); never a look-alike.
    public static func matches(_ logins: [Login], host: String) -> [Login] {
        let front = host.lowercased()
        return logins.filter { login in
            login.uris.contains { uri in
                guard let saved = Self.host(of: uri) else { return false }
                return saved == front || front.hasSuffix("." + saved) || saved.hasSuffix("." + front)
            }
        }
    }

    static func host(of uri: String) -> String? {
        let text = uri.contains("://") ? uri : "https://" + uri
        return URL(string: text)?.host?.lowercased()
    }

    /// `bw list items`: logins with a password only; cards, notes and identities are left out.
    public static func parseItems(_ data: Data) throws -> [Login] {
        let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard item["type"] as? Int == 1, let id = item["id"] as? String, let login = item["login"] as? [String: Any],
                  let password = login["password"] as? String, !password.isEmpty else { return nil }
            let uris = (login["uris"] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String }
            return Login(id: id, name: item["name"] as? String ?? "", username: login["username"] as? String ?? "", password: password, uris: uris)
        }
    }

    /// `bw status`: unlocked, locked, or not logged in at all.
    public static func parseStatus(_ data: Data) throws -> Status {
        switch (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String {
        case "unlocked": .unlocked
        case "unauthenticated": .loggedOut
        default: .locked
        }
    }

    /// One press of the bind. `type` gets the username and the password and types them; `say` and `log` only ever get
    /// outcomes, hosts and counts.
    @MainActor
    public final class Filler {
        private let vault: any BitwardenVault
        private let frontURL: @MainActor () async -> URL?
        private let pick: @MainActor ([Choice]) async -> String?
        private let type: @MainActor (_ username: String, _ password: String) -> Void
        private let say: @MainActor (String) -> Void
        private let log: @MainActor (String) -> Void
        private var running = false

        public init(vault: any BitwardenVault, frontURL: @escaping @MainActor () async -> URL?,
                    pick: @escaping @MainActor ([Choice]) async -> String?,
                    type: @escaping @MainActor (_ username: String, _ password: String) -> Void,
                    say: @escaping @MainActor (String) -> Void, log: @escaping @MainActor (String) -> Void) {
            self.vault = vault; self.frontURL = frontURL; self.pick = pick; self.type = type; self.say = say; self.log = log
        }

        public var isRunning: Bool { running }

        public func run() async {
            guard !running else { return }
            running = true
            defer { running = false }
            guard let host = await frontURL()?.host?.lowercased(), !host.isEmpty else { return say("No web address in front") }
            var status: Status
            do { status = try await vault.currentStatus() } catch {
                log("fill: bw status failed (\(Swift.type(of: error)))")
                return say("Bitwarden CLI did not answer")
            }
            if status == .locked, await vault.unlock() { status = .unlocked }
            switch status {
            case .locked: log("fill: locked"); return say(BitwardenFill.locked)
            case .loggedOut: log("fill: logged out"); return say("Bitwarden CLI is not logged in: run bw login in a terminal first")
            case .unlocked: break
            }
            let found: [Login]
            do { found = BitwardenFill.matches(try await vault.logins(for: host), host: host) } catch {
                log("fill: bw list failed (\(Swift.type(of: error)))")
                return say("Bitwarden CLI could not list logins")
            }
            log("fill: \(found.count) logins for \(host)")
            guard !found.isEmpty else { return say("No Bitwarden login for \(host)") }
            var chosen = found[0]
            if found.count > 1 {
                guard let id = await pick(found.map { Choice(id: $0.id, name: $0.name, username: $0.username) }),
                      let picked = found.first(where: { $0.id == id }) else { return log("fill: nothing picked") }
                chosen = picked
            }
            type(chosen.username, chosen.password)
            say("Filled the login for \(host)")
        }
    }
}

/// The bw CLI as the fill's vault. The session key lives here, in memory only (Sven's option 1, 2026-10-05): never on
/// disk, in defaults, the keychain, a log or a pasteboard, and its description never shows it. It reaches bw as
/// BW_SESSION in bw's environment, never its arguments (which `ps` lists). With no key (and none in Pilot's own
/// environment) the vault counts as locked and bw is not run; `unlock` asks the app's unlocker (a visible terminal
/// Sven types his master password into, bw's key coming back through a pipe), `lock` runs bw lock and lets the key go.
@MainActor
public final class BitwardenCLIVault: BitwardenVault, CustomStringConvertible {
    public typealias Runner = @MainActor (_ arguments: [String], _ environment: [String: String]) async throws -> String
    private let base: [String: String]
    private let run: Runner
    private let unlocker: @MainActor () async -> String?
    private var key: String?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, run: @escaping Runner = BitwardenCLIVault.runBW,
                unlocker: @escaping @MainActor () async -> String? = { nil }) {
        base = environment
        self.run = run
        self.unlocker = unlocker
    }

    public static let runBW: Runner = { arguments, environment in
        guard let bw = Homebrew.cli("bw") else { throw CocoaError(.fileNoSuchFile) }
        return try await ChildProcess.run(bw, arguments, environment: environment, timeout: .seconds(20))
    }

    nonisolated public var description: String { "BitwardenCLIVault" }

    /// Pilot's environment with the session as BW_SESSION; nil with no session at all.
    private var environment: [String: String]? {
        var environment = base
        if let key { environment["BW_SESSION"] = key }
        return (environment["BW_SESSION"] ?? "").isEmpty ? nil : environment
    }

    public func currentStatus() async throws -> BitwardenFill.Status {
        guard let environment else { return .locked }
        let status = try BitwardenFill.parseStatus(Data(try await run(["status"], environment).utf8))
        if status == .locked { key = nil }  // a key bw no longer takes is no use to keep
        return status
    }

    /// Only after currentStatus said unlocked.
    public func logins(for host: String) async throws -> [BitwardenFill.Login] {
        try BitwardenFill.parseItems(Data(try await run(["list", "items", "--url", "https://\(host)"], environment ?? base).utf8))
    }

    public func unlock() async -> Bool {
        guard let key = await unlocker() else { return false }
        self.key = key
        return true
    }

    /// bw lock, then the key is let go.
    public func lock() async {
        if let environment { _ = try? await run(["lock"], environment) }
        key = nil
    }
}
