import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95423048 (after Raycast's @raycast.argument1 to 3): a script command that takes arguments asks for them
/// in Hyper+Space, the words typed after its title, and gets them as $1 $2 $3. Nothing here runs a script.
@Suite("Script arguments")
struct ScriptArgumentTests {
    static let flights = ScriptCommand(file: "flights.sh", header: """
        #!/bin/bash
        # @raycast.title Flights
        # @raycast.argument1 { "type": "text", "placeholder": "from city", "percentEncoded": true }
        # @raycast.argument2 { "type": "text", "placeholder": "to city", "optional": true }
        """)
    static let size = ScriptCommand(file: "size.sh", header: """
        # @raycast.title Window size
        # @raycast.argument1 { "type": "dropdown", "placeholder": "size", "data": [{"title": "Small", "value": "s"}, {"title": "Large", "value": "l"}] }
        """)
    static let login = ScriptCommand(file: "login.sh", header: """
        # @raycast.title Log in
        # @raycast.argument1 { "type": "password", "placeholder": "password" }
        """)
    static let tag = ScriptCommand(file: "tag.sh", header: """
        # @raycast.title Tag
        # @raycast.argument1 { "type": "text", "placeholder": "tag", "optional": true }
        """)

    @Test("Raycast's argument lines parse in order with their placeholder, optional and percentEncoded; bad ones are left out")
    func parse() {
        let args = Self.flights.arguments
        #expect(args.map(\.placeholder) == ["from city", "to city"])
        #expect(args.map(\.optional) == [false, true])
        #expect(args.map(\.percentEncoded) == [true, false])
        #expect(args.map(\.kind) == [.text, .text])
        #expect(Self.flights.needsArguments && !Self.flights.takesPassword)
        #expect(Self.size.arguments.first?.kind == .dropdown([.init(title: "Small", value: "s"), .init(title: "Large", value: "l")]))
        #expect(Self.login.takesPassword)
        // Raycast's deprecated secure flag is a password too.
        #expect(ScriptCommand(file: "a.sh", header: "# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"pin\", \"secure\": true }").takesPassword)
        #expect(!Self.tag.needsArguments && Self.tag.arguments.count == 1)
        // Bad JSON, a fourth argument, a dropdown without data and a gap all leave the script listed with what came before.
        let odd = ScriptCommand(file: "odd.sh", header: """
            # @raycast.title Odd
            # @raycast.argument1 { "type": "text", "placeholder": "one" }
            # @raycast.argument2 { not json }
            # @raycast.argument3 { "type": "text", "placeholder": "three" }
            # @raycast.argument4 { "type": "text", "placeholder": "four" }
            """)
        #expect(odd.title == "Odd" && odd.arguments.map(\.placeholder) == ["one"])
        #expect(ScriptCommand(file: "d.sh", header: "# @raycast.argument1 { \"type\": \"dropdown\", \"placeholder\": \"x\" }").arguments.isEmpty)
        #expect(ScriptCommand(file: "n.sh", header: "").arguments.isEmpty)
    }

    @Test("The words split one per argument, the last taking the rest; a double-quoted phrase stays one")
    func words() {
        #expect(ScriptCommand.words("malta rome", count: 2) == ["malta", "rome"])
        #expect(ScriptCommand.words("malta new york", count: 2) == ["malta", "new york"])
        #expect(ScriptCommand.words("\"san juan\" new york", count: 2) == ["san juan", "new york"])
        #expect(ScriptCommand.words("  malta  ", count: 2) == ["malta"])
        #expect(ScriptCommand.words("a b c d", count: 3) == ["a", "b", "c d"])
        #expect(ScriptCommand.words("\"quoted rest\"", count: 1) == ["quoted rest"])
        #expect(ScriptCommand.words("", count: 2) == [])
    }

    @Test("Values: required ones must be there, a dropdown takes a title or value and passes the value, percentEncoded encodes")
    func values() {
        // Only the first is percentEncoded.
        #expect(Self.flights.values(for: "san josé") == ["san", "josé"])
        #expect(Self.flights.values(for: "\"san josé\" rome") == ["san%20jos%C3%A9", "rome"])
        #expect(Self.flights.values(for: "malta") == ["malta", ""])
        #expect(Self.flights.values(for: "") == nil)
        #expect(Self.size.values(for: "large") == ["l"])
        #expect(Self.size.values(for: "S") == ["s"])
        #expect(Self.size.values(for: "huge") == nil)
        #expect(Self.tag.values(for: "") == [""])
    }

    @Test("Typing the title, a space and the words answers first with the filled run; its id carries the values")
    func answers() throws {
        let scripts = [Self.flights, Self.size, Self.login, Self.tag]
        let run = try #require(ScriptCommand.answers(for: "flights malta rome", in: scripts).first)
        #expect(run.isAnswer && run.title == "Run Flights" && run.fills == nil)
        #expect(run.detail == "from city malta · to city rome")
        guard case .action(let id) = run.target else { Issue.record("not an action"); return }
        #expect(ScriptCommand.file(inAction: id) == "flights.sh")
        #expect(ScriptCommand.arguments(inAction: id) == ["malta", "rome"])
        #expect(ScriptCommand.arguments(inAction: Self.flights.actionID) == nil)
        // Case ignored; a dropdown answered by its title.
        #expect(ScriptCommand.answers(for: "WINDOW SIZE small", in: scripts).first.map(\.target) == .action(Self.size.actionID(arguments: ["s"])))
        // A title with nothing after it, another script's title or a script without arguments: no answer.
        #expect(ScriptCommand.answers(for: "flights", in: scripts).isEmpty)
        #expect(ScriptCommand.answers(for: "flightsx malta", in: scripts).isEmpty)
        #expect(ScriptCommand.answers(for: "zip a", in: [ScriptCommand(file: "zip.sh", header: "")]).isEmpty)
        // A password is never typed into the search.
        #expect(ScriptCommand.answers(for: "log in hunter2", in: scripts).isEmpty)
    }

    @Test("A word a dropdown does not offer gives no answer; a missing required word answers with what it takes, Return typing a space")
    func unfilled() throws {
        #expect(ScriptCommand.answers(for: "window size huge", in: [Self.size]).isEmpty)
        let two = ScriptCommand(file: "two.sh", header: """
            # @raycast.title Two
            # @raycast.argument1 { "type": "text", "placeholder": "name" }
            # @raycast.argument2 { "type": "dropdown", "placeholder": "size", "data": [{"title": "Small", "value": "s"}, {"title": "Large", "value": "l"}] }
            """)
        let row = try #require(ScriptCommand.answers(for: "two ana", in: [two]).first)
        #expect(row.title == "Run Two" && row.detail == "size: Small or Large")
        #expect(row.fills == "two ana ")
        #expect(row.target == .action(two.actionID))
        #expect(ScriptCommand.answers(for: "two ana huge", in: [two]).isEmpty)
    }

    @Test("A run's values count only by presence, so an encoded dropdown value runs (Moody EcNC-D0gD9g)")
    func encodedDropdown() throws {
        let city = ScriptCommand(file: "city.sh", header: """
            # @raycast.title City
            # @raycast.argument1 { "type": "dropdown", "placeholder": "city", "percentEncoded": true, "data": [{"title": "NY", "value": "new york"}] }
            """)
        let run = try #require(ScriptCommand.answers(for: "city ny", in: [city]).first)
        guard case .action(let id) = run.target else { Issue.record("not an action"); return }
        let values = try #require(ScriptCommand.arguments(inAction: id))
        #expect(values == ["new%20york"])
        #expect(!city.lacksArguments(values))
        #expect(city.lacksArguments([]) && city.lacksArguments([""]))
    }

    @Test("An argument's value reaches the script single-quoted after its path, empty optional ones too")
    func line() {
        #expect(ScriptCommand.line(path: "/S/f.sh", arguments: []) == "'/S/f.sh'")
        #expect(ScriptCommand.line(path: "/S/f.sh", arguments: ["it's", ""]) == "'/S/f.sh' 'it'\\''s' ''")
        // An id's arguments survive a slash, a colon and a quote.
        let id = Self.flights.actionID(arguments: ["a/b:c", "\"d\""])
        #expect(ScriptCommand.file(inAction: id) == "flights.sh")
        #expect(ScriptCommand.arguments(inAction: id) == ["a/b:c", "\"d\""])
    }

    @Test("A script row needing an argument fills the search with its title and a space; one with only optional ones runs")
    func rowFills() {
        let scripts = [Self.flights, Self.tag, Self.login]
        #expect(ScriptCommand.fills(scripts) == [Self.flights.actionID: "Flights "])
        let rows = MenuEntries.build(apps: [], actions: ScriptCommand.actions([], with: scripts), store: BindStore(defaults: [:]), roleApps: [:],
                                     menu: "apps.launcher", openID: { $0 }, running: [], fills: ScriptCommand.fills(scripts))
        #expect(rows.first { $0.target == .action(Self.flights.actionID) }?.fills == "Flights ")
        #expect(rows.first { $0.target == .action(Self.tag.actionID) }?.fills == nil)
    }
}
