import CryptoKit
import Foundation
@testable import Pilot
import PilotCore
import Testing

/// Sandbox E2E's host (AGENTS.md), a harness, not a test: with PILOT_SANDBOX=<socket>, the app's whole verb set and an
/// Engine that never launches, served on that socket from this run's throwaway folder and defaults: never Sven's socket,
/// stores or running Pilot. It holds until the `<socket>.hold` file it writes is removed, or 10 minutes pass. Drive it
/// with `PILOT_SOCKET=<socket> .build/debug/PilotCLI …`; plain `swift test` skips it.
@MainActor
@Suite("sandbox host")
struct SandboxHost {
    nonisolated static let socket = ProcessInfo.processInfo.environment["PILOT_SANDBOX"]

    @Test("Serves the app's verbs on PILOT_SANDBOX until its hold file goes", .enabled(if: socket != nil))
    func serve() async throws {
        let path = URL(filePath: try #require(Self.socket))
        let hold = path.appendingPathExtension("hold")
        // Before the verbs: registering reads Engine.shared, which is weak.
        let engine = Engine()
        // PILOT_SANDBOX_ALLOW=1 answers every Allow yes and prints its question, so a gated verb runs on the throwaway stores
        // without a prompt on Sven's screen (P49's publish, against a local bare remote).
        if ProcessInfo.processInfo.environment["PILOT_SANDBOX_ALLOW"] == "1" {
            AllowPrompt.gate.decider = { ask, _ in print("ALLOW asked: \(ask.text)"); return true }
        }
        // A test run's bundle has no Pilot Info.plist: the app's, so `status --part update` names the feed a bundle would, or
        // PILOT_SANDBOX_INFO's, a built bundle's Contents/Info.plist, to read the route that build takes.
        let info = ProcessInfo.processInfo.environment["PILOT_SANDBOX_INFO"].map { URL(filePath: $0) }
            ?? URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Info.plist")
        let status = ControlStatus()
        status.updates = PilotUpdates(info: NSDictionary(contentsOf: info) as? [String: Any])
        // PILOT_SANDBOX_HOME_BLOCKS=<file>: Home's layout as a build saved it, written to this run's defaults before its store
        // first reads them, so `pilot list home-blocks` shows what that layout converts to on first launch (P91), its
        // extensions' pages listed as installed.
        var homeBlocks = HomeBlockStores()
        if let file = ProcessInfo.processInfo.environment["PILOT_SANDBOX_HOME_BLOCKS"] {
            let defaults = UserDefaults.pilot(), bytes = try Data(contentsOf: URL(filePath: file))
            let sha = { (data: Data?) in data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "none" }
            defaults.set(bytes, forKey: HomeLayoutStore.key)
            print("home.blocks sha256 before: \(sha(bytes))")
            let store = HomeLayoutStore(defaults: defaults)
            print("home.blocks sha256 after:  \(sha(defaults.data(forKey: HomeLayoutStore.key)))")
            print("home.blocks.lanes kept: \(defaults.data(forKey: HomeLayoutStore.lanesKey)?.count ?? 0) bytes; grid \(store.layout.grid.map(String.init) ?? "none"); "
                  + "drawn as the default: \(store.layout == .standard)")
            fflush(stdout)
            homeBlocks.layout = { store }
            // Its extensions' pages as installed, so their rows list too.
            let pages = store.layout.rows.compactMap { HomeLayout.extensionID($0.id) }.map { ExtensionPages.Link(id: $0, title: $0, icon: "🧩") }
            homeBlocks.pages = { pages }
        }
        let served = ControlSocket(path: path, verbs: ControlSocket.registered(status: status, homeBlocks: homeBlocks))
        #expect(served.start())
        defer { served.stop() }
        try Data().write(to: hold)
        let deadline = Date.now.addingTimeInterval(600)
        while FileManager.default.fileExists(atPath: hold.path(percentEncoded: false)) && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        withExtendedLifetime(engine) {}
    }
}
