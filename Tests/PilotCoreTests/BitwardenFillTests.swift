import Foundation
import Testing
@testable import PilotCore

/// Bitwarden fill login (card agent-bo-95422814, Sven's yes 2026-10-05): the logins for the site in front, typed into
/// the focused field. Every secret here is a fake, and the vault is a fake: swift test never runs the real bw.
@Suite("Bitwarden fill login")
@MainActor
struct BitwardenFillTests {
    static let password = "fake-Pa55word!", username = "sven-fake@example.com", session = "fake-SESSION-key"

    static func login(_ id: String, _ name: String, _ uri: String, user: String = username, password: String = password) -> BitwardenFill.Login {
        .init(id: id, name: name, username: user, password: password, uris: [uri])
    }

    final class FakeVault: BitwardenVault {
        var status: BitwardenFill.Status = .unlocked
        var logins: [BitwardenFill.Login] = []
        var asked: [String] = []
        /// What unlock does: nil leaves it locked.
        var unlocking: BitwardenFill.Status?
        func currentStatus() async throws -> BitwardenFill.Status { asked.append("status"); return status }
        func unlock() async -> Bool {
            asked.append("unlock")
            guard let unlocking else { return false }
            status = unlocking
            return unlocking == .unlocked
        }
        func logins(for host: String) async throws -> [BitwardenFill.Login] { asked.append("logins \(host)"); return logins }
    }

    /// Everything the fill says, logs, shows in a pick list or types, to check no secret escapes where it must not.
    final class Record {
        var said: [String] = [], logged: [String] = [], picked: [[BitwardenFill.Choice]] = [], typed: [(String, String)] = []
        var choose: Int? = 1
    }

    func filler(_ vault: FakeVault, url: String?, _ record: Record) -> BitwardenFill.Filler {
        BitwardenFill.Filler(vault: vault, frontURL: { url.flatMap(URL.init(string:)) },
                             pick: { choices in record.picked.append(choices); return record.choose.map { choices[$0].id } },
                             type: { record.typed.append(($0, $1)) },
                             say: { record.said.append($0) }, log: { record.logged.append($0) })
    }

    @Test("github.com matches its own logins and its subdomains', never gitlab.com's")
    func matching() {
        let logins = [Self.login("1", "GitHub", "https://github.com/login"), Self.login("2", "Gist", "https://gist.github.com"),
                      Self.login("3", "GitLab", "https://gitlab.com"), Self.login("4", "Bare host", "github.com")]
        #expect(BitwardenFill.matches(logins, host: "github.com").map(\.id) == ["1", "2", "4"])
        #expect(BitwardenFill.matches(logins, host: "api.github.com").map(\.id) == ["1", "4"])
        #expect(BitwardenFill.matches(logins, host: "notgithub.com").isEmpty)
    }

    @Test("One match fills at once: username, Tab, password into the focused field")
    func oneMatch() async {
        let vault = FakeVault(), record = Record()
        vault.logins = [Self.login("1", "GitHub", "https://github.com")]
        await filler(vault, url: "https://github.com/login", record).run()
        #expect(record.picked.isEmpty)
        #expect(record.typed.count == 1 && record.typed[0] == (Self.username, Self.password))
        #expect(record.said == ["Filled the login for github.com"])
    }

    @Test("Two matches ask with a pick list of names and usernames only; Escape fills nothing")
    func pickList() async {
        let vault = FakeVault(), record = Record()
        vault.logins = [Self.login("1", "GitHub work", "https://github.com", user: "work@example.com", password: "fake-one"),
                        Self.login("2", "GitHub home", "https://github.com", user: "home@example.com", password: "fake-two")]
        await filler(vault, url: "https://github.com", record).run()
        #expect(record.picked.first?.map(\.name) == ["GitHub work", "GitHub home"])
        #expect(record.picked.first?.map(\.username) == ["work@example.com", "home@example.com"])
        #expect(record.typed.count == 1 && record.typed[0] == ("home@example.com", "fake-two"))
        record.choose = nil
        await filler(vault, url: "https://github.com", record).run()
        #expect(record.typed.count == 1)
    }

    @Test("No password, username or session ever reaches what is said, logged or listed")
    func noSecretsOut() async {
        let vault = FakeVault(), record = Record()
        vault.logins = [Self.login("1", "GitHub", "https://github.com"), Self.login("2", "Second", "https://github.com", user: "other@example.com")]
        await filler(vault, url: "https://github.com", record).run()
        let out = record.said + record.logged + record.picked.flatMap { $0.map { "\($0.id) \($0.name)" } }
        for secret in [Self.password, Self.username, "other@example.com"] {
            #expect(!out.contains { $0.contains(secret) }, "\(secret) escaped")
        }
        #expect(!String(describing: vault.logins).contains(Self.password))
    }

    @Test("A locked vault, nothing in front, or no match: each is said and nothing is typed; locked asks bw nothing more")
    func refusals() async {
        let vault = FakeVault(), record = Record()
        vault.status = .locked
        await filler(vault, url: "https://github.com", record).run()
        #expect(record.said == ["Bitwarden CLI is locked"])
        #expect(vault.asked == ["status", "unlock"])
        vault.status = .unlocked
        await filler(vault, url: nil, record).run()
        #expect(record.said.last == "No web address in front")
        await filler(vault, url: "https://nothing.example", record).run()
        #expect(record.said.last == "No Bitwarden login for nothing.example")
        #expect(record.typed.isEmpty)
    }

    @Test("Locked: the vault is unlocked, then the login fills; an unlock that fails stops there")
    func unlocks() async {
        let vault = FakeVault(), record = Record()
        vault.status = .locked
        vault.unlocking = .unlocked
        vault.logins = [Self.login("1", "GitHub", "https://github.com")]
        await filler(vault, url: "https://github.com", record).run()
        #expect(vault.asked == ["status", "unlock", "logins github.com"])
        #expect(record.typed.count == 1)
        vault.status = .locked
        vault.unlocking = nil
        await filler(vault, url: "https://github.com", record).run()
        #expect(record.typed.count == 1)
        #expect(record.said.last == "Bitwarden CLI is locked")
    }

    @Test("The session lives in the vault's memory or Pilot's own environment and reaches bw only through its environment")
    func session() async throws {
        var calls: [(arguments: [String], environment: [String: String])] = []
        let items = #"[{"id":"1","name":"GitHub","type":1,"login":{"username":"u","password":"p","uris":[{"uri":"https://github.com"}]}}]"#
        let runner: BitwardenCLIVault.Runner = { arguments, environment in
            calls.append((arguments, environment))
            return arguments.first == "status" ? #"{"status":"unlocked"}"# : arguments.first == "list" ? items : ""
        }
        // No session anywhere: locked, and bw is not run.
        let vault = BitwardenCLIVault(environment: ["PATH": "/usr/bin"], run: runner, unlocker: { Self.session })
        #expect(try await vault.currentStatus() == .locked)
        #expect(calls.isEmpty)
        // Unlocked through the app's unlocker: the key goes to bw in its environment, never its arguments.
        #expect(await vault.unlock())
        #expect(try await vault.currentStatus() == .unlocked)
        #expect(try await vault.logins(for: "github.com").map(\.name) == ["GitHub"])
        #expect(calls.map(\.arguments) == [["status"], ["list", "items", "--url", "https://github.com"]])
        #expect(calls.allSatisfy { $0.environment["BW_SESSION"] == Self.session && $0.environment["PATH"] == "/usr/bin" })
        #expect(!calls.contains { $0.arguments.joined().contains(Self.session) })
        #expect(!String(describing: vault).contains(Self.session))
        // Lock: bw lock with the key, then the key is gone.
        await vault.lock()
        #expect(calls.last?.arguments == ["lock"])
        let before = calls.count
        #expect(try await vault.currentStatus() == .locked)
        #expect(calls.count == before)
        // A session Pilot was started with also counts.
        let started = BitwardenCLIVault(environment: ["BW_SESSION": Self.session], run: runner)
        #expect(try await started.currentStatus() == .unlocked)
    }

    @Test("A key bw no longer takes is let go when bw says locked")
    func staleKey() async throws {
        var status = #"{"status":"unlocked"}"#, calls = 0
        let vault = BitwardenCLIVault(environment: [:], run: { _, _ in calls += 1; return status }, unlocker: { Self.session })
        #expect(await vault.unlock())
        #expect(try await vault.currentStatus() == .unlocked)
        status = #"{"status":"locked"}"#
        #expect(try await vault.currentStatus() == .locked)
        let before = calls
        #expect(try await vault.currentStatus() == .locked)
        #expect(calls == before)  // no key left, so bw is not asked again
    }

    @Test("bw's item list parses logins only; a card or a note is left out")
    func parse() throws {
        let json = #"""
        [{"id":"1","name":"GitHub","type":1,"login":{"username":"u","password":"p","uris":[{"uri":"https://github.com"},{"uri":"github.dev"}]}},
         {"id":"2","name":"Card","type":3,"card":{}},
         {"id":"3","name":"No password","type":1,"login":{"username":"u2","uris":[]}}]
        """#
        let logins = try BitwardenFill.parseItems(Data(json.utf8))
        #expect(logins.map(\.id) == ["1"])
        #expect(logins.first?.uris == ["https://github.com", "github.dev"])
        #expect(try BitwardenFill.parseStatus(Data(#"{"status":"unauthenticated"}"#.utf8)) == .loggedOut)
    }
}
