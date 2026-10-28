import AppKit
import Foundation
import Testing
@testable import PilotCore

/// Bitwarden actions (card agent-bo-95422774; Vicinae's Bitwarden extension, rebuilt within hard limits): Pilot drives the
/// Bitwarden app's own menu items and runs `bw generate`, which needs no login. It never unlocks a vault and never reads,
/// prints or logs an item, a password or a session key. Every password here is a fake, on a private pasteboard.
@Suite("Bitwarden")
@MainActor
struct BitwardenTests {
    @Test("Search, the generator and lock are the app's own menu items, as its source names them")
    func routes() {
        #expect(Bitwarden.search == .menu(bundle: "com.bitwarden.desktop", path: ["View", "Search vault"]))
        #expect(Bitwarden.generator == .menu(bundle: "com.bitwarden.desktop", path: ["View", "Generator"]))
        #expect(Bitwarden.lock == .menu(bundle: "com.bitwarden.desktop", path: ["Bitwarden", "Lock all vaults"]))
        #expect(Bitwarden.generateArguments == ["generate", "-ulns", "--length", "20"])
    }

    @Test("A generated password goes on the pasteboard marked concealed and transient, so no clipboard history keeps it")
    func concealed() throws {
        let board = NSPasteboard(name: .init("pilot.test.bitwarden.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        Bitwarden.put("fake-Pa55word!", on: board)
        let types = try #require(board.types)
        #expect(types.contains(.string))
        #expect(types.contains(.init("org.nspasteboard.ConcealedType")))
        #expect(types.contains(.init("org.nspasteboard.TransientType")))
        #expect(board.string(forType: .string) == "fake-Pa55word!")
    }

    @Test("It says the password is copied and clears it after the wait, unless something else was copied meanwhile")
    func clears() async {
        let board = NSPasteboard(name: .init("pilot.test.bitwarden.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        var said: [String] = [], onBoard: String?
        var copyMeanwhile = false
        // `say` runs once the password is on the board and before the wait starts, so what it reads and copies there
        // is in place however late the main actor comes back; the test then awaits the wait itself, not a guessed time.
        let generator = Bitwarden.Generator(generate: { "fake-Pa55word!" }, pasteboard: board, clearAfter: .milliseconds(50),
                                            say: {
            said.append($0)
            if copyMeanwhile { board.clearContents(); board.setString("something Sven copied", forType: .string) }
            else { onBoard = board.string(forType: .string) }
        })
        await generator.run()
        #expect(said == ["Password copied; it clears in 0 s"])   // the wait here is 50 ms; Pilot's is 90 s
        #expect(onBoard == "fake-Pa55word!")
        await generator.clearing?.value
        #expect(board.string(forType: .string) == nil)

        copyMeanwhile = true
        await generator.run()
        await generator.clearing?.value
        #expect(board.string(forType: .string) == "something Sven copied")
    }

    @Test("A second press while bw runs makes no second password")
    func oneAtATime() async {
        let board = NSPasteboard(name: .init("pilot.test.bitwarden.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        var runs = 0
        let generator = Bitwarden.Generator(generate: { runs += 1; try await Task.sleep(for: .milliseconds(100)); return "fake-Pa55word!" },
                                            pasteboard: board, clearAfter: .seconds(90), say: { _ in })
        async let first: Void = generator.run()
        async let second: Void = generator.run()
        _ = await (first, second)
        #expect(runs == 1)
    }

    @Test("A failed or empty generate says so and puts nothing on the pasteboard")
    func failure() async {
        let board = NSPasteboard(name: .init("pilot.test.bitwarden.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.setString("before", forType: .string)
        var said: [String] = []
        struct NoBW: Error {}
        await Bitwarden.Generator(generate: { throw NoBW() }, pasteboard: board, clearAfter: .seconds(90), say: { said.append($0) }).run()
        await Bitwarden.Generator(generate: { " \n" }, pasteboard: board, clearAfter: .seconds(90), say: { said.append($0) }).run()
        #expect(said == ["Bitwarden's bw could not make a password", "Bitwarden's bw could not make a password"])
        #expect(board.string(forType: .string) == "before")
    }
}
