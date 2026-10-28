import Foundation
import PilotCore
import Synchronization
import Testing
@testable import Pilot

/// `pilot get|set|settings` part 1 (AI helper T4): every key round-trips through the store object its page binds to,
/// on throwaway defaults, a fake Ghostty, a fake login item and fake Keychains. Nothing of Sven's is read or written,
/// and the running Pilot is never touched: the verbs are asked through the registry the socket answers from.
@MainActor
@Suite("Settings schema")
struct SettingsSchemaTests {
    final class FakeKey: StoredKey {
        let saved = Mutex<String?>(nil)
        func read() -> String? { saved.withLock { $0 } }
        func exists() -> Bool { saved.withLock { $0 != nil } }
        func write(_ value: String?) throws { saved.withLock { $0 = value } }
    }

    /// The stores the pages bind to, each a test's own, and the verbs over them.
    @MainActor final class Rig {
        let defaults: UserDefaults
        let settings: PilotSettings
        let look: Look
        let clipboard: ClipboardHistory
        let files: FileSearchSettings
        let passwords: PasswordSettings
        let folders: PilotFolders
        let giphy = FakeKey()
        let ai: AISettings
        /// Each flip a session switch hands on.
        @MainActor final class Flips { var log: [Bool] = [] }
        /// Home's Hyper switch and the dropdown's Clipboard switch.
        let hyperFlips = Flips(), recordingFlips = Flips()
        let hyper: SessionSwitch, recording: SessionSwitch
        let schema = SettingsSchema()
        let verbs = ControlVerbs()
        /// Every question the gate was asked.
        var asked: [String] = []

        /// `lists` seeds each provider's last Refresh, so every model key has a pick besides its default.
        init(allow: Bool = true, lists: Bool = true) {
            defaults = UserDefaults(suiteName: testSuite())!
            if lists {
                for (provider, ids) in [AIProvider.codex: ["gpt-5"], .openAI: ["gpt-5"], .ollama: ["llama3.2", "qwen3"]] {
                    defaults.set(ids, forKey: AISettings.listKey(provider))
                }
            }
            settings = PilotSettings(defaults: defaults, loginItem: LoginItem(service: .init(status: { .enabled }, register: {}, unregister: {})))
            look = Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), defaults: defaults)
            clipboard = ClipboardHistory(defaults: defaults)
            files = FileSearchSettings(defaults: defaults)
            files.onExcludedChange = {}
            passwords = PasswordSettings(defaults: defaults)
            folders = PilotFolders(defaults: defaults)
            ai = AISettings(defaults: defaults, keys: AISettingsTests.FakeKeys(), http: AISettingsTests.NoNetwork())
            hyper = SessionSwitch { [hyperFlips] in hyperFlips.log.append($0) }
            recording = SessionSwitch { [recordingFlips] in recordingFlips.log.append($0) }
            schema.registerPart1(general: (settings, hyper), look: look, clipboard: clipboard, recording: recording, files: files,
                                 passwords: passwords, folders: folders, giphy: giphy, ai: ai)
            let schema = schema
            verbs.registerSettings(schema) { [unowned self] key, value, _ in
                asked.append("\(key)=\(value)")
                return allow
            }
        }

        func ask(_ verb: String, _ args: String...) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil)
        }

        func value(_ key: String) async throws -> JSONValue {
            let answer = await ask("get", key)
            #expect(answer.ok, "get \(key): \(answer.error?.message ?? "")")
            return try #require(answer.result)
        }
    }

    /// Free words have no choices to pick from, so each has its own non-default value here; a text key added without
    /// one fails the round trip by name.
    static let folderA = FileManager.default.temporaryDirectory.appending(path: "pilot-settings-a-\(UUID().uuidString.prefix(8))")
    static let folderB = FileManager.default.temporaryDirectory.appending(path: "pilot-settings-b-\(UUID().uuidString.prefix(8))")
    static let textSamples: [String: String] = [
        "folders.repos": folderA.path(percentEncoded: false), "folders.gifs": folderB.path(percentEncoded: false),
        "ai.model.claudeCode": "opus", "ai.model.codex": "gpt-5",
        "ai.model.anthropicAPI": "claude-opus-5-5", "ai.model.openAI": "gpt-5",
        "ai.model.ollama": "qwen3", "ai.model.openAICompatible": "my-model",
        "ai.baseURL.ollama": "http://localhost:1234", "ai.baseURL.openAICompatible": "https://example.test/v1",
        "bar.clock": "EEE HH:mm", "keySwaps": "escape:tab,leftControl:f19",
    ]

    /// Keys whose store has no value of its own but reads UserDefaults on each get.
    static let computedOverDefaults: Set = ["launchAtLogin"]

    /// A valid value that is not the key's default, as the command types it, and as `get` answers it.
    static func sample(_ setting: SettingKey) -> (word: String, value: JSONValue)? {
        switch setting.kind {
        case .bool:
            let on = setting.standard != .bool(true)
            return (on ? "on" : "off", .bool(on))
        case .int(let range):
            let n = setting.standard == .number(Double(range.lowerBound)) ? range.upperBound : range.lowerBound
            return (String(n), .number(Double(n)))
        case .number(let range):
            let n = setting.standard == .number(range.lowerBound) ? range.upperBound : range.lowerBound
            return (String(n), .number(n))
        case .choice(let choices):
            return choices.first { .string($0) != setting.standard }.map { ($0, .string($0)) }
        case .choices(let all):
            // Every choice at once, never the default list of one; Hyper keys take one side of a modifier (P68).
            let choices = setting.key == "layerKey" ? all.filter { !$0.hasPrefix("right") } : all
            return (choices.joined(separator: ","), .array(choices.map(JSONValue.string)))
        case .colour:
            return ("#FF3366", .string("#FF3366"))
        case .text:
            return textSamples[setting.key].map { ($0, .string($0)) }
        case .secret:
            return nil
        }
    }

    @Test("Every key: set to a valid non-default value, get reads it back from the store, not from UserDefaults")
    func roundTrip() async throws {
        for folder in [Self.folderA, Self.folderB] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { for folder in [Self.folderA, Self.folderB] { try? FileManager.default.removeItem(at: folder) } }
        let rig = Rig()
        let keys = rig.schema.sorted.filter { $0.kind != .secret }
        #expect(keys.count >= 45)
        for setting in keys {
            let sample = try #require(Self.sample(setting), "no non-default sample for \(setting.key)")
            #expect(try await rig.value(setting.key) != sample.value, "\(setting.key) already holds its sample")
            let set = await rig.ask("set", setting.key, sample.word)
            #expect(set.ok && set.result == sample.value, "set \(setting.key) \(sample.word): \(set.error?.message ?? "\(String(describing: set.result))")")
            // Only the store answers: a value written behind its back is not what get reads. PilotSettings.launchAtLogin
            // is itself computed over UserDefaults (Engine.swift), so the store reads the write too.
            if !Self.computedOverDefaults.contains(setting.key) {
                rig.defaults.set("written behind the store's back", forKey: setting.key)
            }
            #expect(try await rig.value(setting.key) == sample.value, "\(setting.key) did not read back")
        }
    }

    @Test("A change lands on the very store objects the pages bind to")
    func sameStores() async {
        let rig = Rig()
        _ = await rig.ask("set", "look.glass", "on")
        _ = await rig.ask("set", "look.theme", "orchid")
        _ = await rig.ask("set", "clipboard.keepCount", "42")
        _ = await rig.ask("set", "clipboard.keepDays", "forever")
        _ = await rig.ask("set", "quickTapEscape", "off")
        _ = await rig.ask("set", "passwords.length", "32")
        _ = await rig.ask("set", "ai.effort.codex", "high")
        _ = await rig.ask("set", "translate.home", "es")
        _ = await rig.ask("set", "look.windowLayout", "tabs")
        _ = await rig.ask("set", "look.menuLayout", "rail")
        #expect(rig.look.glass && rig.look.theme.id == "orchid" && rig.look.windowShape == .tabs && rig.look.menuLayout == .rail)
        #expect(rig.clipboard.settings.keepCount == 42 && rig.clipboard.settings.keepDays == nil)
        #expect(!rig.settings.quickTapEscape && rig.passwords.length == 32 && rig.ai.effort(for: .codex) == .high)
        // Picking the second language as the first swaps the pair, as Launcher's Translate block does.
        #expect(rig.settings.translatePair == TranslatePair(home: "es", other: "en"))
    }

    @Test("A fresh store reads each key's schema default")
    func defaults() async throws {
        let rig = Rig(lists: false)
        for setting in rig.schema.sorted {
            #expect(try await rig.value(setting.key) == setting.standard, "\(setting.key)'s default")
        }
    }

    @Test("A wrong type answers bad-value, past the range out-of-range, an unknown key unknown-key")
    func refusals() async {
        let rig = Rig()
        for (args, code) in [(["look.glass", "maybe"], ControlError.Code.badValue), (["look.transparency", "lots"], .badValue),
                             (["look.transparency", "101"], .outOfRange), (["look.defocusShakeWithin", "0.1"], .outOfRange),
                             (["passwords.length", "8"], .outOfRange), (["look.style", "neon"], .badValue),
                             (["look.windowBorderColour", "red"], .badValue), (["folders.repos", "/no/such/folder"], .badValue),
                             (["folders.repos", "relative/path"], .badValue), (["ai.model.claudeCode", "gpt-5"], .badValue),
                             (["ai.baseURL.ollama", "ftp://host"], .badValue), (["no.such.key", "1"], .unknownKey),
                             (["look.glass"], .badRequest)] {
            let answer = await rig.verbs.answer(ControlRequest(verb: "set", args: args), peer: nil)
            #expect(!answer.ok && answer.error?.code == code, "set \(args.joined(separator: " "))")
        }
        #expect(await rig.ask("get", "no.such.key").error?.code == .unknownKey)
        #expect(rig.look.transparency == 33 && !rig.look.glass)
    }

    @Test("The AI and GIPHY keys refuse a value given as a word with keychain-only, and only set or unset on get")
    func secrets() async throws {
        let rig = Rig()
        let secrets = rig.schema.sorted.filter { $0.kind == .secret }.map(\.key)
        #expect(secrets == ["ai.key.anthropicAPI", "ai.key.openAI", "ai.key.openAICompatible", "giphy.key"])
        try rig.ai.setKey("sk-t1", for: .openAI)
        try rig.giphy.write("gif-t1")
        for key in secrets {
            let set = await rig.ask("set", key, "sk-t2")
            #expect(set.error?.code == .keychainOnly && set.error?.message.contains("--stdin") == true, "set \(key)")
            #expect(set.error?.message.contains("sk-t2") == false, "set \(key) echoed the value")
            let saved = key == "ai.key.openAI" || key == "giphy.key"
            #expect(try await rig.value(key) == .string(saved ? "set" : "unset"), "get \(key)")
        }
        #expect(rig.ai.keys.key(.openAI) == "sk-t1" && rig.giphy.read() == "gif-t1" && rig.asked.isEmpty)
    }

    /// `set <key> --stdin` with the value in the request's secret, as the command sends it.
    static func piped(_ rig: Rig, _ args: [String], _ secret: String?) async -> ControlAnswer {
        await rig.verbs.answer(ControlRequest(verb: "set", args: args, secret: secret), peer: nil)
    }

    @Test("set --stdin saves an AI or GIPHY key trimmed after Allow and answers set; --unset removes it; the value is never asked or answered")
    func secretsFromStdin() async throws {
        let rig = Rig()
        let saved = await Self.piped(rig, ["ai.key.openAI", "--stdin"], "  sk-t1\n")
        #expect(saved.result == .string("set") && rig.ai.keys.key(.openAI) == "sk-t1" && rig.ai.hasKey(.openAI))
        #expect(await Self.piped(rig, ["giphy.key", "--stdin"], "gif-t1\n").result == .string("set") && rig.giphy.read() == "gif-t1")
        let removed = await Self.piped(rig, ["ai.key.openAI", "--unset"], nil)
        #expect(removed.result == .string("unset") && rig.ai.keys.key(.openAI) == nil && !rig.ai.hasKey(.openAI))
        let shown = "a new one from stdin, kept in the Keychain (not shown)"
        #expect(rig.asked == ["ai.key.openAI=\(shown)", "giphy.key=\(shown)", "ai.key.openAI=unset, removed from the Keychain"])
        let line = String(decoding: ControlLine.encode(saved), as: UTF8.self)
        #expect(!line.contains("sk-t1") && !rig.asked.joined().contains("sk-t1") && !rig.asked.joined().contains("gif-t1"))
    }

    @Test("set --stdin refuses an empty pipe, a plain key, extra words and --stdin with --unset before asking; Deny keeps the key")
    func secretsRefused() async throws {
        let rig = Rig()
        try rig.giphy.write("gif-t1")
        for (args, secret, code) in [(["giphy.key", "--stdin"], " \n", ControlError.Code.badValue), (["giphy.key", "--stdin"], nil, .badValue),
                                     (["look.glass", "--stdin"], "on", .badValue), (["giphy.key", "gif-t2", "--stdin"], "gif-t2", .badRequest),
                                     (["giphy.key", "--stdin", "--unset"], "gif-t2", .badRequest), (["--stdin"], "gif-t2", .badRequest)] {
            let answer = await Self.piped(rig, args, secret)
            #expect(answer.error?.code == code, "set \(args.joined(separator: " "))")
            #expect(answer.error?.message.contains("gif-t2") == false)
        }
        #expect(rig.giphy.read() == "gif-t1" && rig.asked.isEmpty && !rig.look.glass)

        let denying = Rig(allow: false)
        try denying.giphy.write("gif-t1")
        let denied = await Self.piped(denying, ["giphy.key", "--stdin"], "gif-t2")
        #expect(denied.error?.code == .denied && denied.error?.message.contains("gif-t2") == false && denying.giphy.read() == "gif-t1")
        #expect(await Self.piped(denying, ["giphy.key", "--unset"], nil).error?.code == .denied && denying.giphy.read() == "gif-t1")
        // The app's own default never asks, so a key changes only with the Allow prompt wired.
        let verbs = ControlVerbs()
        verbs.registerSettings(rig.schema)
        let pageOnly = await verbs.answer(ControlRequest(verb: "set", args: ["giphy.key", "--unset"]), peer: nil)
        #expect(pageOnly.error?.code == .denied && rig.giphy.read() == "gif-t1")
    }

    @Test("layerKey waits on the Allow gate: Deny answers denied and changes nothing; a plain key never asks")
    func gate() async {
        let denying = Rig(allow: false)
        let denied = await denying.ask("set", "layerKey", "rightOption")
        #expect(denied.error?.code == .denied && denying.settings.layerKeys == [.capsLock])
        _ = await denying.ask("set", "quickTapEscape", "off")
        #expect(denying.asked == ["layerKey=rightOption"] && !denying.settings.quickTapEscape)

        let allowing = Rig()
        #expect(await allowing.ask("set", "layerKey", "rightCommand").ok && allowing.settings.layerKeys == [.rightCommand])
        // A bad value is refused before Sven is asked.
        #expect(await allowing.ask("set", "layerKey", "fn").error?.code == .badValue)
        #expect(await allowing.ask("set", "layerKey", "capsLock,fn").error?.code == .badValue)
        #expect(await allowing.ask("set", "layerKey", ",").error?.code == .badValue, "never none")
        // More than one key: comma-separated, any order, read back Caps Lock first.
        #expect(await allowing.ask("set", "layerKey", "rightCommand, capsLock").result == .array([.string("capsLock"), .string("rightCommand")]))
        #expect(allowing.settings.layerKeys == [.capsLock, .rightCommand])
        #expect(await allowing.ask("get", "layerKey").result == .array([.string("capsLock"), .string("rightCommand")]))
        #expect(allowing.asked == ["layerKey=rightCommand", "layerKey=rightCommand, capsLock"])
        // P68: both sides of one modifier would leave it nowhere: refused with the word, before plan and Allow.
        for twins in ["leftOption,rightOption", "leftControl, rightControl", "rightCommand,leftCommand"] {
            #expect(await allowing.ask("set", "layerKey", twins).error?.code == .badValue, "\(twins)")
        }
        #expect(allowing.settings.layerKeys == [.capsLock, .rightCommand])
        #expect(allowing.asked == ["layerKey=rightCommand", "layerKey=rightCommand, capsLock"], "never asked")
        #expect(await allowing.ask("set", "layerKey", "capsLock,leftControl").ok && allowing.settings.layerKeys == [.capsLock, .leftControl])
        #expect(Rig().schema.sorted.filter(\.confirms).map(\.key)
                == ["ai.key.anthropicAPI", "ai.key.openAI", "ai.key.openAICompatible", "giphy.key", "keySwaps", "layerKey"])
    }

    @Test("Until the Allow prompt is wired, the app's own decider denies a confirmed setting")
    func pageOnly() async {
        let rig = Rig()
        let verbs = ControlVerbs()
        verbs.registerSettings(rig.schema)
        let answer = await verbs.answer(ControlRequest(verb: "set", args: ["layerKey", "rightOption"]), peer: nil)
        #expect(answer.error?.code == .denied && rig.settings.layerKeys == [.capsLock])
    }

    @Test("settings lists every key with its type and page, --page narrows it, and schema carries the same list")
    func listing() async throws {
        let rig = Rig()
        guard case .array(let all)? = await rig.ask("settings").result,
              case .array(let look)? = await rig.ask("settings", "--page", "look").result else { Issue.record("no list"); return }
        guard case .object(let first) = look[0] else { Issue.record("not an object"); return }
        #expect(first["page"] == .string("look") && first["type"] != nil && first["label"] != nil && first["default"] != nil)
        #expect(all.count == rig.schema.keys.count && look.count == 7)
        let nowhere = await rig.ask("settings", "--page", "nowhere")
        #expect(nowhere.error?.code == .unknownPage && nowhere.error?.message.contains("look") == true)
        guard case .object(let schema) = rig.verbs.schema, case .array(let verbs)? = schema["verbs"] else { Issue.record("no schema"); return }
        #expect(verbs.contains(.object(["name": .string("settings"), "help": .string(rig.verbs.verbs["settings"]!.help),
                                        "usage": .string("pilot settings [--page <page> | --find \"<words>\"]"), "schema": .array(all),
                                        "flags": .array([.object(["name": .string("page"), "help": .string("one page's settings, a page as open names it"),
                                                                  "value": .bool(true)]),
                                                         .object(["name": .string("find"), "help": .string("the settings whose key, title or page hold these words, the best first"),
                                                                  "value": .bool(true)])])])))
        #expect(Set(rig.verbs.verbs.keys).isSuperset(of: ["get", "set", "settings"]))
    }

    @Test("hyper.on and clipboard.recording flip the session switches the pages flip, once; a second set changes nothing")
    func sessionSwitches() async throws {
        let rig = Rig()
        #expect(try await rig.value("hyper.on") == .bool(true) && rig.hyper.isOn)
        #expect(await rig.ask("set", "hyper.on", "off").result == .bool(false))
        #expect(await rig.ask("set", "hyper.on", "off").result == .bool(false))
        #expect(await rig.ask("set", "clipboard.recording", "off").result == .bool(false))
        #expect(await rig.ask("set", "clipboard.recording", "on").result == .bool(true))
        #expect(rig.hyperFlips.log == [false] && !rig.hyper.isOn && rig.recordingFlips.log == [false, true] && rig.recording.isOn)
    }

    @Test("Help says what a key takes and lists a page's keys without reading a value; the index names the pages; flags are checked")
    func helpAndIndex() async throws {
        let rig = Rig()
        let get = try #require(rig.verbs.verbs["get"]?.detail), settings = try #require(rig.verbs.verbs["settings"]?.detail)
        #expect(try get("look.windowLayout") == "pilot set look.windowLayout <value>\nWindow layout, on the look page.\nTakes one of rail, tabs; default rail.")
        #expect(try get("look.menuLayout") == "pilot set look.menuLayout <value>\nHyper+Space menu, on the look page.\nTakes one of line, classic, rail; default line.")
        #expect(try get("layerKey") == "pilot set layerKey <value>\nHyper keys, on the general page.\n"
                + "Takes one or more of capsLock, leftControl, rightControl, leftOption, rightOption, leftCommand, rightCommand, comma-separated; default capsLock.\nAsks Allow first.")
        #expect(try get("giphy.key") == "pbpaste | pilot set giphy.key --stdin; pilot set giphy.key --unset removes it\nGIPHY key, on the menu page.\n"
                + "Takes its value from stdin alone, never a word; get says only set or unset; default unset.\nAsks Allow first.")
        #expect(throws: ControlError.self) { try get("no.such.key") }
        let look = try #require(try settings("look"))
        #expect(look.hasPrefix("pilot settings --page look\n") && look.contains("look.windowLayout") && look.split(separator: "\n").count == 8)
        guard case .object(let index) = rig.verbs.schemaIndex, case .array(let listed)? = index["verbs"],
              let entry = listed.first(where: { if case .object(let o) = $0 { o["name"] == .string("settings") } else { false } }),
              case .object(let part) = entry else { Issue.record("no settings entry"); return }
        #expect(part["part"] == .object(["pages": .array(["ai", "binds", "clipboard", "files", "general", "home", "look", "menu", "system", "tiling"].map(JSONValue.string))]))
        #expect(await rig.ask("get", "look.glass", "--page", "look").error?.code == .unknownFlag)
        #expect(await rig.ask("set", "look.glass", "on", "--force").error?.code == .unknownFlag && !rig.look.glass)
    }

    @Test("giphy.rating reads pg-13 until set, takes GIPHY's four ratings into the store Stickers and GIFs' rows on Launcher › Abilities set, and refuses others")
    func giphyRating() async throws {
        let rig = Rig()
        #expect(try await rig.value("giphy.rating") == .string("pg-13") && rig.folders.giphyRating == .pg13)
        #expect(await rig.ask("set", "giphy.rating", "r").result == .string("r") && rig.folders.giphyRating == .r)
        #expect(PilotFolders(defaults: rig.defaults).giphyRating == .r, "kept for the next launch")
        #expect(await rig.ask("set", "giphy.rating", "nc-17").error?.code == .badValue && rig.folders.giphyRating == .r)
        #expect(await rig.ask("set", "giphy.rating", "pg-13").result == .string("pg-13") && rig.defaults.string(forKey: "giphy.rating") == nil)
        let get = try #require(rig.verbs.verbs["get"]?.detail)
        #expect(try get("giphy.rating")?.contains("Takes one of g, pg, pg-13, r; default pg-13.") == true)
    }
}
