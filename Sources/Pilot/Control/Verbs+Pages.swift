import Foundation
import PilotCore

extension ControlVerbs {
    /// `pilot open`: Pilot's window on a page or a part of one, by the names pilot://open takes, old names included.
    func registerPages(_ app: ControlActions) {
        func pages() -> [String] { AppPage.allCases.map(\.rawValue) }
        func parts() -> [JSONValue] { AppSection.allCases.filter(\.shown).map { .string($0.rawValue) } }
        let sections = SetupSection.allCases.map(\.rawValue)
        register(ControlVerb("open", help: "Opens Pilot's window on a page or a part of one; --where and --find only say where, opening nothing.",
                             usage: "pilot open <page|part|pilot://open link> [--section <\(sections.joined(separator: "|"))>] [--where] | pilot open --find <words>",
                             flags: [.init("section", help: "a System section: \(sections.joined(separator: ", "))"),
                                     .init("where", help: "say where the name or link lands from the tab bar (Tools › Captures), opening nothing", takesValue: false),
                                     .init("find", help: "Pilot's pages these words find, grouped under their tab path, with the parts and the settings (and their values) they found, best first, opening nothing")],
                             schema: { .object(["pages": .array(pages().map(JSONValue.string)), "parts": .array(parts()),
                                                "sections": .array(sections.map(JSONValue.string))]) },
                             index: { .object(["pages": .array(pages().map(JSONValue.string))]) }) { call throws(ControlError) in
            let args = call.arguments(switches: ["where"])
            // Reads (simplify-pages T7): where a search, a name or a pilot://open link lands, the window left as it is.
            // A search answers Home's grouped results (pilot-ui-redesign T5): each page under its tab path, what `pilot
            // open` takes to open it, and the parts and settings found, each setting with its value, read after the match.
            if let words = args.value("find") {
                let schema = SettingsSchema.live
                return .array(SettingsSearch.grouped(words, settings: schema.sorted).map { group in
                    .object(["group": .string(group.path(count: PanelTabs.count)), "open": .string(group.page.rawValue),
                             "parts": .array(group.parts.map { .object(["title": .string($0.title), "open": .string($0.rawValue)]) }),
                             "settings": .array(group.settings.map { setting in
                                 .object(["key": .string(setting.key), "label": .string(setting.label),
                                          "value": (try? schema.get(setting.key)) ?? .null])
                             })])
                })
            }
            let name = try args.word(0, "page")
            if args.flags.contains("where") {
                let place = name.hasPrefix("pilot://") ? URL(string: name).flatMap(AppPlace.linked) : AppPlace.named(name)
                guard let place else { throw ControlError(.unknownPage, "\(name) lands nowhere: no page, part or old name") }
                return .string(place.tabPath(count: PanelTabs.count))
            }
            guard let place = AppPlace.named(name) else {
                throw ControlError(.unknownPage, "no page \(name); pages: \(pages().joined(separator: ", ")); pilot schema lists the parts")
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
