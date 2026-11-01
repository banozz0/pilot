import Foundation
import PilotCore

extension ControlVerbs {
    /// `pilot open`: Pilot's window on a page or a part of one, by the names pilot://open takes, old names included.
    func registerPages(_ app: ControlActions) {
        // The developer pages and their parts only while General's Developer switch is on (Q715).
        func pages() -> [String] { AppPage.allCases.filter { DeveloperPages.on || !$0.isDeveloper }.map(\.rawValue) }
        func parts() -> [JSONValue] { AppSection.allCases.filter { DeveloperPages.on || !$0.page.isDeveloper }.map { .string($0.rawValue) } }
        let sections = SetupSection.allCases.map(\.rawValue)
        register(ControlVerb("open", help: "Opens Pilot's window on a page or a part of one.",
                             usage: "pilot open <page|part> [--section <\(sections.joined(separator: "|"))>]",
                             flags: [.init("section", help: "a System section: \(sections.joined(separator: ", "))")],
                             schema: { .object(["pages": .array(pages().map(JSONValue.string)), "parts": .array(parts()),
                                                "sections": .array(sections.map(JSONValue.string))]) },
                             index: { .object(["pages": .array(pages().map(JSONValue.string))]) }) { call throws(ControlError) in
            let args = call.arguments()
            let name = try args.word(0, "page")
            guard let place = AppPlace.named(name) else {
                throw ControlError(.unknownPage, "no page \(name); pages: \(pages().joined(separator: ", ")); pilot schema lists the parts")
            }
            guard DeveloperPages.on || !place.page.isDeveloper else {
                throw ControlError(.unknownPage, "\(place.path) is a developer page and the Developer switch is off: pilot set general.developer on")
            }
            let section = args.value("section")
            let setup = section.flatMap(SetupSection.init(rawValue:))
            if let section, setup == nil {
                throw ControlError(.unknownSection, "no section \(section); sections: \(sections.joined(separator: ", "))")
            }
            app.open(place, setup)
            return .string("opened \(place.path)")
        })
    }
}
