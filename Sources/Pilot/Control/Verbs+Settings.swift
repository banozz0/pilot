import Foundation
import PilotCore

extension ControlVerbs {
    /// The question a confirmed setting asks: the prompt, a plan's row and the plan's cover all build it here, so they match.
    /// Live window pictures ask with their warning, as the Window shelf block shows it before Live turns on (Q662).
    static func settingAsk(_ key: String, _ shown: String) -> ControlGate.Ask {
        if let detail = aiSettingAsk(key, shown) { return .init("Set \(key)", detail) }
        return .init("Set \(key)", key == ShelfPictures.key && shown == ShelfPictureMode.live.rawValue ? "live. \(ShelfPictures.liveWarning)" : shown)
    }

}

extension SettingsSchema {
    /// The app's settings, on the live stores the pages bind to, made on the first `get`, `set` or `settings`, so launch
    /// opens no store (nor AISettings' Keychain checks) early.
    static let live: SettingsSchema = {
        let schema = SettingsSchema()
        schema.registerPart1(general: Engine.shared.map { ($0.settings, $0.hyperSwitch) }, look: .shared, clipboard: .shared, recording: .clipboard,
                             files: .shared, passwords: .shared, folders: .shared, giphy: Giphy.keychain, ai: .shared)
        schema.registerStats(views: .shared, bar: .shared)
        schema.registerImageText(.shared)
        schema.registerSpeech(.shared)
        schema.registerSelection(.shared)
        schema.registerCaptures(.shared)
        schema.registerWebApps(.shared)
        schema.registerHiddenApps(.shared)
        schema.registerMenuRoot(.shared)
        if CataloguePublish.available { schema.registerExtensionPublish() }
        if let engine = Engine.shared {
            schema.registerRings(engine.rings.store)
            schema.registerPart2(settings: engine.settings, list: engine.workspaceList, snapshots: engine.snapshots, block: engine.pilotBlock,
                                 bar: .shared, topBar: engine.topBar, wallpaper: .shared, recommendations: .shared, pilotSwitch: engine.pilotSwitch)
        } else {
            log.error("settings: asked before the engine was up, so General and part 2's keys are missing until Pilot restarts")
        }
        return schema
    }()

    /// Part 1's families, one per page; the app and the tests register the same ones.
    /// General's needs the engine's settings and Hyper switch, so it is left out until the engine is up.
    func registerPart1(general: (settings: PilotSettings, hyper: SessionSwitch)?, look: Look, clipboard: ClipboardHistory, recording: SessionSwitch,
                       files: FileSearchSettings, passwords: PasswordSettings, folders: PilotFolders, giphy: any StoredKey, ai: AISettings,
                       fonts: PilotFonts = .shared) {
        if let general { registerGeneral(general.settings, hyper: general.hyper) }
        registerLook(look)
        registerFonts(fonts)
        registerClipboard(clipboard, recording: recording)
        registerMenu(files: files, passwords: passwords, folders: folders, giphy: giphy)
        registerAI(ai)
    }

    /// Part 2's families (AI helper T5): the engine's stores, so all or none. A test passes its own notes counter and
    /// folder change, so it never lists Sven's notes.
    func registerPart2(settings: PilotSettings, list: WorkspaceList, snapshots: WorkspaceSnapshots, block: PilotBlockStore, bar: BarItemsStore,
                       topBar: TopBarController, wallpaper: WallpaperSettings, recommendations: Recommendations, pilotSwitch: any PilotSwitching,
                       dictation: PilotDictation = .shared, pictures: ShelfPictures = .shared,
                       notesIn: @escaping @MainActor (URL) -> Int = { NotesFolder.notes(in: $0).count },
                       changeNotes: @escaping @MainActor (URL) throws -> Void = { try NotesPanel.shared.changeFolder(to: $0, move: false) }) {
        registerWorkspaces(list: list, snapshots: snapshots)
        registerTiling(block: block, settings: settings, pictures: pictures)
        registerBar(bar, topBar: topBar)
        registerSystem(settings: settings, wallpaper: wallpaper, recommendations: recommendations, pilotSwitch: pilotSwitch,
                       dictation: dictation, notesIn: notesIn, changeNotes: changeNotes)
    }

    /// Flips a switch that changes in a task of its own (the top bar) and returns once it went through:
    /// bad-value with its reason when it refused. Already there, nothing is flipped.
    static func flip(_ flipping: any Flipping, to on: Bool) async throws(ControlError) {
        guard flipping.isOn != on else { return }
        flipping.set(on)
        while flipping.busy {
            await withCheckedContinuation { done in withObservationTracking { _ = flipping.busy } onChange: { done.resume() } }
        }
        if let problem = flipping.problem { throw ControlError(.badValue, problem) }
    }
}

/// A switch that flips in a task of its own and says when it is busy and why it refused.
@MainActor
protocol Flipping: AnyObject {
    var isOn: Bool { get }
    var busy: Bool { get }
    var problem: String? { get }
    func set(_ on: Bool)
}

extension ControlVerbs {
    /// Asks Sven before a change whose page confirms it; true for Allow. The Allow gate (task T3) plugs in here.
    typealias SettingsDecider = @MainActor (_ key: String, _ value: String, ControlPeer?) async -> Bool

    /// A confirmed setting changes only on its page: the default, so a test never shows the prompt.
    static let pageOnly: SettingsDecider = { _, _, _ in false }

    /// The app's: Pilot's Allow prompt, through the gate's clock, so no answer in 60 s denies.
    static let allowPrompt: SettingsDecider = { key, value, peer in
        (try? await AllowPrompt.gate.allow(settingAsk(key, value), peer: peer) {}) != nil
    }

    /// `pilot get`, `pilot set` and `pilot settings`, over `schema`, read when first asked. `help get|set <key>` says what
    /// a key takes, `help settings <page>` lists a page's keys, and the schema index names the pages; none reads a value.
    func registerSettings(_ schema: @autoclosure @escaping @Sendable @MainActor () -> SettingsSchema, decide: @escaping SettingsDecider = pageOnly) {
        let keyHelp: @Sendable @MainActor (String) throws(ControlError) -> String? = { key throws(ControlError) in try schema().setting(key).help }
        register(ControlVerb("get", help: "A setting's value.", usage: "pilot get <key>", flags: [], detail: keyHelp) { call throws(ControlError) in
            try schema().get(call.arguments().word(0, "key"))
        })
        register(ControlVerb("set", help: "Changes a setting; its page shows it at once.",
                             usage: "pilot set <key> <value>; a secret: pbpaste | pilot set <key> --stdin, or --unset",
                             flags: [.init("stdin", help: "a secret's value from the command's stdin, never a word; asks Allow", takesValue: false),
                                     .init("unset", help: "removes a secret from the Keychain; asks Allow", takesValue: false)],
                             detail: keyHelp, plan: { call throws(ControlError) in
            let arguments = call.arguments()
            // A secret never waits in a plan: it asks on its own, and its value rides on this request alone.
            guard !arguments.has("stdin"), !arguments.has("unset") else { return nil }
            let words = arguments.positional
            guard words.count == 2 else { throw ControlError(.badRequest, "pilot set <key> <value>: one key and one value (quote a value with spaces)") }
            let setting = try schema().setting(words[0])
            _ = try setting.value(words[1])
            return .init("Set \(setting.key)", old: ControlPlan.word(try schema().get(setting.key)) ?? "none", new: words[1],
                         asks: setting.confirms ? Self.settingAsk(setting.key, words[1]) : nil,
                         readback: ControlRequest(verb: "get", args: [setting.key]))
        }, inverse: { call throws(ControlError) in
            let key = try call.arguments().word(0, "key")
            guard let old = ControlPlan.word(try schema().get(key)) else { return .cannot("its old value is no word set can take back") }
            return .requests([ControlRequest(verb: "set", args: [key, old])])
        }) { call throws(ControlError) in
            let arguments = call.arguments()
            let words = arguments.positional
            let stdin = arguments.has("stdin"), unset = arguments.has("unset")
            // What the prompt and a denial show: the word, or for a secret what happens to it, never its value, which
            // rides in call.secret alone.
            let setting: SettingKey, value: JSONValue, shown: String
            if stdin || unset {
                guard words.count == 1, stdin != unset else {
                    throw ControlError(.badRequest, "pilot set <key> --stdin (the value piped in) or pilot set <key> --unset: the key alone")
                }
                setting = try schema().setting(words[0])
                value = try setting.secret(call.secret, unset: unset)
                shown = unset ? "unset, removed from the Keychain" : "a new one from stdin, kept in the Keychain (not shown)"
            } else {
                guard words.count == 2 else { throw ControlError(.badRequest, "pilot set <key> <value>: one key and one value (quote a value with spaces)") }
                setting = try schema().setting(words[0])
                value = try setting.value(words[1])
                shown = words[1]
            }
            // A plan's Allow showed this very change (ControlApproval); anything else asks.
            if setting.confirms, !ControlApproval.covers(Self.settingAsk(setting.key, shown)), await !decide(setting.key, shown, call.peer) {
                throw ControlError(.denied, "not allowed: set \(setting.key) to \(shown)")
            }
            return try await setting.apply(value)
        })
        register(ControlVerb("settings", help: "Every setting with its type, range, default and value; --page narrows it, --find searches it.",
                             usage: "pilot settings [--page <page> | --find \"<words>\"]",
                             flags: [.init("page", help: "one page's settings, a page as open names it"),
                                     .init("find", help: "the settings whose key, title or page hold these words, the best first")],
                             schema: { .array(schema().sorted.map(\.described)) },
                             index: { .object(["pages": .array(schema().pages.map(JSONValue.string))]) },
                             detail: { page throws(ControlError) in
                                 let keys = try schema().on(page)
                                 return (["pilot settings --page \(page)"] + ControlVerb.columns(keys.map { ($0.key, $0.label) }, prefix: "  ")).joined(separator: "\n")
                             }) { call throws(ControlError) in
            let args = call.arguments()
            if args.has("find") { return .array(schema().find(try args.required("find")).map(\.described)) }
            guard let page = args.value("page") else { return .array(schema().sorted.map(\.described)) }
            return .array(try schema().on(page).map(\.described))
        })
    }
}

extension SettingsSchema {
    /// Every page with a setting, sorted.
    var pages: [String] { Set(keys.values.map(\.page)).sorted() }

    /// The most a find answers.
    static let found = 15

    /// `settings --find`: the keys whose title, key and page match, ranked as the window's and Hyper+Space's settings
    /// search ranks (FuzzyRanker, typos forgiven), a title match first. Matched on the words alone, so no value is read
    /// before the cut.
    func find(_ text: String) -> [SettingKey] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return Array(FuzzyRanker.rank(sorted, query: text, title: { "\($0.label) \($0.key) \($0.page)" },
                                      prefer: { FuzzyRanker.score(text, in: $0.label) == nil ? 0 : 1 }).prefix(Self.found))
    }

    /// The keys on `page`, or unknown-page naming the pages there are.
    func on(_ page: String) throws(ControlError) -> [SettingKey] {
        let listed = sorted.filter { $0.page == page }
        guard !listed.isEmpty else { throw ControlError(.unknownPage, "no settings on page \(page); pages: \(pages.joined(separator: ", "))") }
        return listed
    }
}

extension SettingKey {
    /// `pilot help get <key>`: what it is, what it takes, its default and whether it asks Allow; never its value.
    var help: String {
        let takes = switch kind {
        case .bool: "on or off"
        case .int(let range): "a whole number, \(range.lowerBound) to \(range.upperBound)"
        case .number(let range): "a number, \(range.lowerBound) to \(range.upperBound)"
        case .choice(let choices): "one of \(choices.joined(separator: ", "))"
        case .choices(let choices): "one or more of \(choices.joined(separator: ", ")), comma-separated"
        case .text: "a word or path its page checks"
        case .colour: "theme or #RRGGBB"
        case .secret: "its value from stdin alone, never a word; get says only set or unset"
        }
        let standard = ControlPlan.word(self.standard) ?? "none"
        let usage = kind == .secret ? SettingKey.piped(key) : "pilot set \(key) <value>"
        return ([usage, "\(label), on the \(page) page.", "Takes \(takes); default \(standard)."]
                + (confirms ? ["Asks Allow first."] : [])).joined(separator: "\n")
    }
}
