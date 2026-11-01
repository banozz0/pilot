import Foundation
import PilotCore

/// What `pilot fonts` reaches: Install › Use fonts in's app rows, read and written as the page does. The tests and the
/// sandbox host get FontPlaces.standard's throwaway home, so Sven's configs are never read or written there.
@MainActor
final class ControlFonts {
    let places = FontPlaces.standard
    var gate = AllowPrompt.gate

    /// One place as its row shows it, the apps not on this Mac too.
    func row(_ place: FontPlace) -> JSONValue {
        let row = FontUse.row(place, places: places, earlier: places.earlier()), file = places.file(place).path(percentEncoded: false)
        var answer: [String: JSONValue] = [
            "id": .string(place.id), "app": .string(place.app), "place": .string(place.place), "installed": .bool(FontUse.installed(place)),
            "path": .string("~/" + place.path), "file": .string(file),
            "font": row.font.map(JSONValue.string) ?? .null, "mono": .bool(place.mono), "restart": .bool(row.restart),
        ]
        if let problem = row.problem { answer["problem"] = .string(problem) }
        // What Undo sets again: a family, or default when the app had none set.
        if let earlier = row.earlier { answer["undo"] = .string(earlier.value.map(place.family) ?? "default") }
        return .object(answer)
    }

    func place(_ id: String) throws(ControlError) -> FontPlace {
        guard let place = FontPlace.known.first(where: { $0.id == id }) else {
            throw ControlError(.badValue, "no font place \(id); pilot fonts lists them")
        }
        return place
    }

    /// Writes as the row's pick or Undo does, then answers the row.
    func change(_ place: FontPlace, _ write: (FontPlaces) throws(FontProblem) -> Bool) throws(ControlError) -> JSONValue {
        do { try FontUse.apply(place, places, write) } catch { throw ControlError(.badValue, "\(place.title): \(error)") }
        return row(place)
    }
}

extension ControlVerbs {
    /// `pilot fonts [use <id> <family> | undo <id>]`: the font each app uses, set in that app's own config (macOS has no
    /// system-wide font), after Allow. Pilot's own two are the settings fonts.ui and fonts.mono.
    func registerFonts(_ app: ControlFonts) {
        let words = ["use", "undo"]
        let detail: [String: String] = [
            "use": "pilot fonts use <id> <family>: sets that app's font in its own config, only the font's key changed; the first change keeps a backup and the font it had, for undo.",
            "undo": "pilot fonts undo <id>: sets the font the app had before Pilot first changed it.",
        ]
        register(ControlVerb("fonts", help: "Lists the apps whose font Pilot sets (Install › Use fonts in) with each one's font, or sets or undoes one. Pilot's own: pilot set fonts.ui|fonts.mono.",
                             usage: "pilot fonts [use <id> <family> | undo <id>]", flags: [],
                             schema: { .object(["subcommands": .array(words.map(JSONValue.string)), "rowKey": .string("id")]) },
                             index: { .object(["subcommands": .array(words.map(JSONValue.string))]) },
                             detail: { detail[$0] }) { call throws(ControlError) in
            let args = call.arguments()
            guard let word = args.positional.first else { return .array(FontPlace.known.map(app.row)) }
            guard words.contains(word) else { throw ControlError(.badValue, "no fonts \(word); subcommands: \(words.joined(separator: ", "))") }
            let place = try app.place(try args.word(1, "id (pilot fonts lists them)"))
            if word == "undo" {
                return try await app.gate.allow(ControlGate.Ask("Undo \(place.title) font", "back to the font it had before Pilot"), peer: call.peer) { () throws(ControlError) in
                    try app.change(place) { places throws(FontProblem) in try places.undo(place) }
                }
            }
            let family = args.positional.dropFirst(2).joined(separator: " ")
            guard let installed = InstalledFonts.match(family) else {
                throw ControlError(.badValue, family.isEmpty ? "missing family" : "no font family \(family) on this Mac")
            }
            return try await app.gate.allow(ControlGate.Ask("Set \(place.title) font", installed), peer: call.peer) { () throws(ControlError) in
                try app.change(place) { places throws(FontProblem) in try places.use(installed, in: place) }
            }
        })
    }
}
