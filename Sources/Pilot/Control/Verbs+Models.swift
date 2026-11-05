import Foundation
import PilotCore

/// What `pilot model` reaches (P30): Voice › Dictation's speech models and Read aloud's Kokoro voices, the same objects
/// their rows' Download, Cancel and Remove press. A test hands in models on a folder of its own.
@MainActor
final class ControlModels {
    var gate = AllowPrompt.gate
    lazy var speech = SpeechModels.shared
    lazy var kokoro = KokoroModel.shared
}

extension ControlVerbs {
    /// The models by the word `pilot model` takes: the speech models by their folder names, then Kokoro.
    static let modelSubcommands = ["download", "cancel", "remove"]

    /// `model`: the Voice page's model rows (P30). Bare, it lists each model with its state; download and remove ask Allow
    /// (hundreds of MB fetched, or the folder deleted); cancel stops a download, whose files stay for the next one.
    func registerModels(_ m: ControlModels) {
        let ids = SpeechChoice.allCases.map(\.rawValue) + ["kokoro"]
        register(ControlVerb("model", help: "Voice's speech models and Read aloud's Kokoro voices: each with its size and state; download and remove ask Allow, cancel stops a download.",
                             usage: "pilot model | pilot model download|cancel|remove <model>",
                             flags: [],
                             schema: { .object(["subcommands": .array(Self.modelSubcommands.map(JSONValue.string)), "models": .array(ids.map(JSONValue.string))]) },
                             index: { .object(["subcommands": .array(Self.modelSubcommands.map(JSONValue.string))]) },
                             detail: { word in
                                 switch word {
                                 case "download": "pilot model download <model>: asks Allow, then fetches it as Download on its row does, and answers at once; pilot model reads its progress"
                                 case "cancel": "pilot model cancel <model>: stops its download; the files fetched so far stay for the next Download"
                                 case "remove": "pilot model remove <model>: asks Allow, then deletes its folder, as Remove does; dictation or Read aloud then waits for a Download again"
                                 default: nil
                                 }
                             }) { call throws(ControlError) in
            let args = call.arguments()
            guard let sub = args.positional.first else { return .array(Self.models(m).map(\.row)) }
            guard Self.modelSubcommands.contains(sub) else {
                throw ControlError(.badValue, "no model \(sub); there are \(Self.modelSubcommands.joined(separator: ", ")), or pilot model alone lists them")
            }
            let word = try args.word(1, "model: \(ids.joined(separator: ", "))")
            guard let model = Self.models(m).first(where: { $0.id == word }) else {
                throw ControlError(.badValue, "no model \(word); they are \(ids.joined(separator: ", "))")
            }
            switch sub {
            case "download": return try await Self.download(model, m, peer: call.peer)
            case "cancel": return try Self.cancel(model)
            default: return try await Self.remove(model, m, peer: call.peer)
            }
        })
    }

    /// One model as the verb sees it: its row and its row's three buttons.
    struct ModelEntry {
        let id: String, name: String, megabytes: Int, offered: Bool, picked: Bool, folder: URL
        let state: () -> SpeechModel.State
        let download: () -> Void, cancel: () -> Void, remove: () -> Void

        var row: JSONValue {
            var o: [String: JSONValue] = ["id": .string(id), "name": .string(name), "size": .string("\(megabytes) MB"), "folder": .string(folder.path)]
            switch state() {
            case .absent: o["state"] = .string("absent")
            case .downloading(let fraction): o["state"] = .string("downloading"); o["percent"] = .number((fraction * 100).rounded())
            case .preparing: o["state"] = .string("preparing")
            case .ready: o["state"] = .string("ready")
            case .failed(let why): o["state"] = .string("failed"); o["problem"] = .string(why)
            }
            if !offered { o["note"] = .string("replaced; remove deletes its old files") }
            if id != "kokoro" { o["picked"] = .bool(picked) }
            return .object(o)
        }

        var busy: Bool {
            switch state() {
            case .downloading, .preparing: true
            default: false
            }
        }
    }

    static func models(_ m: ControlModels) -> [ModelEntry] {
        let speech = m.speech, kokoro = m.kokoro
        return speech.all.map { model in
            ModelEntry(id: model.choice.rawValue, name: model.choice.name, megabytes: model.choice.megabytes,
                       offered: SpeechChoice.offered.contains(model.choice), picked: speech.pick == model.choice, folder: model.folder,
                       state: { model.state }, download: { model.download() }, cancel: { model.cancel() },
                       remove: { speech.remove(model.choice) })
        } + [ModelEntry(id: "kokoro", name: "Kokoro", megabytes: KokoroModel.megabytes, offered: true, picked: false, folder: kokoro.folder,
                        state: { kokoro.state }, download: { kokoro.download() }, cancel: { kokoro.cancel() }, remove: { kokoro.remove() })]
    }

    private static func download(_ model: ModelEntry, _ m: ControlModels, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard model.offered else { throw ControlError(.badValue, "\(model.name) is replaced and never downloads again; pilot model lists the ones on offer") }
        switch model.state() {
        case .ready: throw ControlError(.notReady, "\(model.name) is on this Mac already")
        case .downloading, .preparing: throw ControlError(.notReady, "\(model.name) is downloading already; pilot model cancel \(model.id) stops it")
        default: break
        }
        let ask = ControlGate.Ask("Download \(model.name)", "fetches about \(model.megabytes) MB into \(model.folder.path)")
        return try await m.gate.allow(ask, peer: peer) { () throws(ControlError) in
            model.download()
            log.notice("model: \(model.id, privacy: .public) download, from the pilot command")
            return model.row
        }
    }

    private static func cancel(_ model: ModelEntry) throws(ControlError) -> JSONValue {
        guard model.busy else { throw ControlError(.notReady, "\(model.name) is not downloading; pilot model reads its state") }
        model.cancel()
        log.notice("model: \(model.id, privacy: .public) download cancelled, from the pilot command")
        return model.row
    }

    private static func remove(_ model: ModelEntry, _ m: ControlModels, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard model.state() == .ready || model.busy || FileManager.default.fileExists(atPath: model.folder.path) else {
            throw ControlError(.notReady, "\(model.name) is not on this Mac")
        }
        let ask = ControlGate.Ask("Remove \(model.name)", "deletes its folder: \(model.folder.path)")
        return try await m.gate.allow(ask, peer: peer) { () throws(ControlError) in
            model.remove()
            log.notice("model: \(model.id, privacy: .public) removed, from the pilot command")
            return model.row
        }
    }
}
