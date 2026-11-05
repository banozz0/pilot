import AppKit
import Foundation
import Observation
import PilotCore

/// One change Set up makes (Onboarding 1.1, T54, variant C): the seven helpers, two keys, two file kinds, two downloads and
/// two Pilot settings, 15 in all.
enum SetupItem: String, CaseIterable, Codable, Hashable {
    case homebrew, mole, mas, ffmpeg, webp, npm, cargo
    case filesKey, notesKey, txt, md, dictation, voices, launchAtLogin, command

    var group: SetupGroup {
        switch self {
        case .homebrew, .mole, .mas, .ffmpeg, .webp, .npm, .cargo: .helpers
        case .filesKey, .notesKey: .keys
        case .txt, .md: .fileKinds
        case .dictation, .voices: .downloads
        case .launchAtLogin, .command: .pilot
        }
    }

    /// Install › Helpers' helper it is; nil for ffmpeg, webp and the rest.
    var helper: Helper? {
        switch self {
        case .homebrew: .homebrew
        case .mole: .mole
        case .mas: .mas
        case .npm: .npm
        case .cargo: .cargo
        default: nil
        }
    }

    /// The Homebrew formula it installs as; nil for Homebrew and what is not a formula.
    var formula: String? {
        switch self {
        case .ffmpeg: ConvertTool.ffmpeg.formula
        case .webp: ConvertTool.cwebp.formula
        default: helper?.package?.name
        }
    }

    /// The command that is there once it installed.
    var command: String? {
        switch self {
        case .ffmpeg: ConvertTool.ffmpeg.rawValue
        case .webp: ConvertTool.cwebp.rawValue
        default: helper?.command
        }
    }

    /// Its name on the run's line.
    var short: String {
        if let helper { return helper.name }
        return switch self {
        case .ffmpeg: "ffmpeg"
        case .webp: "webp"
        case .filesKey: "Files → Pilot Files"
        case .notesKey: "Notes → Pilot Notes"
        case .txt: ".txt → Pilot"
        case .md: ".md → Pilot"
        case .dictation: "dictation model"
        case .voices: "voices"
        case .launchAtLogin: "launch at login"
        case .command: "the pilot command"
        default: rawValue
        }
    }

    /// Its row's title in Pick by hand.
    var title: String {
        switch self {
        case .filesKey: "Files key opens Pilot Files"
        case .notesKey: "Notes key opens Pilot Notes"
        case .txt: ".txt files open in Pilot"
        case .md: ".md files open in Pilot"
        case .dictation: "Dictation: \(OnboardingSetup.speech.name)"
        case .voices: "Read aloud voices"
        case .launchAtLogin: "Launch Pilot at login"
        case .command: "The pilot command"
        default: short
        }
    }

    /// What it gives, a helper by the feature it serves (Q555).
    @MainActor var detail: String {
        switch self {
        case .homebrew: "Update reads its list of apps and tools; Install and Remove use it too. Asks your Mac's password in Terminal."
        case .mole: "Clean's preview, the clean itself, and Disk usage · installs through Homebrew"
        case .mas: "App Store apps in Update too; Install gets free App Store apps itself"
        case .ffmpeg: "Convert: to MP3 and GIF"
        case .webp: "Convert: to WebP"
        case .npm: "Install's search and Update: npm packages (comes with Node, runs last)"
        case .cargo: "Install's search and Update: Rust crates (comes with Rust, runs last)"
        case .filesKey: "Hyper+F opens Pilot's own file window instead of Finder"
        case .notesKey: "the Notes key opens Pilot's quick notes instead of an app"
        case .txt: "a .txt file you double-click opens in Pilot's text window"
        case .md: "a .md file you double-click opens in Pilot, formatted"
        case .dictation: "\(OnboardingSetup.speech.size) · \(OnboardingSetup.speech.note)"
        case .voices: "Kokoro's natural English voices, US and UK, run on this Mac · \(KokoroModel.size)"
        case .launchAtLogin: "so Pilot is there after a restart"
        case .command: "lets a terminal or an AI agent read and change Pilot; links ~/.local/bin/pilot"
        }
    }

    /// The key it sets, and the file kind.
    var role: AppRole? { self == .filesKey ? .files : self == .notesKey ? .notes : nil }
    var kind: FileKind? {
        switch self {
        case .txt: FileKinds.groups.lazy.flatMap(\.kinds).first { $0.id == "public.plain-text" }
        case .md: FileKinds.groups.lazy.flatMap(\.kinds).first { $0.id == "net.daringfireball.markdown" }
        default: nil
        }
    }
}

/// Set up's groups, in the run's order.
enum SetupGroup: CaseIterable, Hashable {
    case helpers, keys, fileKinds, downloads, pilot

    /// In SetupItem's order, which is the run's: npm and cargo last, as they bring Node and Rust and take the longest
    /// (T54's call).
    var items: [SetupItem] { SetupItem.allCases.filter { $0.group == self } }

    var title: String {
        switch self {
        case .helpers: "Helpers"
        case .keys: "Keys"
        case .fileKinds: "File kinds"
        case .downloads: "Downloads"
        case .pilot: "Pilot"
        }
    }

    var symbol: String {
        switch self {
        case .helpers: "shippingbox"
        case .keys: "command"
        case .fileKinds: "doc.text"
        case .downloads: "arrow.down.circle"
        case .pilot: "power"
        }
    }

    /// The fork card's line for it.
    @MainActor var line: String {
        switch self {
        case .helpers: "helpers: " + items.map(\.short).joined(separator: ", ")
        case .keys: "keys: Files → Pilot Files, Notes → Pilot Notes"
        case .fileKinds: "file kinds: .txt and .md open in Pilot"
        case .downloads: "downloads: dictation model and voices, \(OnboardingSetup.speech.megabytes + KokoroModel.megabytes) MB"
        case .pilot: "launch at login, the pilot command"
        }
    }
}

/// Everything Set up touches on the Mac, one seam: the app's real objects, or a sandbox's recorder.
@MainActor
protocol SetupSystem: AnyObject {
    var picks: AppRolePicks { get }
    var defaultApps: DefaultAppsSystem { get }
    /// Whether a helper's command is on this Mac.
    func installed(_ item: SetupItem) -> Bool
    /// A download's state: ready when it is on this Mac.
    func download(_ item: SetupItem) -> SpeechModel.State
    /// The dictation model picked now, by raw value; nil when none is.
    var speechPick: String? { get }
    /// Whether any dictation model is on this Mac: then Set up downloads none.
    var hasSpeechModel: Bool { get }
    func startDownloads(dictation: Bool, voices: Bool)
    /// Deletes a download Set up made; the dictation pick goes back to `pick`.
    func removeDownload(_ item: SetupItem, pick: String?)
    var launchesAtLogin: Bool { get }
    /// Sets launch at login; why it did not take, else nil.
    func launchAtLogin(_ on: Bool) -> String?
    var commandLinked: Bool { get }
    /// Links or unlinks `~/.local/bin/pilot`; why it did not take, else nil.
    func linkCommand(_ on: Bool) -> String?
    /// The status file the helpers' run writes, and what it holds now.
    var statusPath: String { get }
    func readStatus() -> String?
    /// Writes `script` to a file and runs it in a visible terminal window; nil when it could not be written.
    func runScript(_ script: String, title: String) -> String?
    /// A command in a visible terminal window (an undo's `brew uninstall`).
    func runInTerminal(_ command: String, title: String, onSuccess: String)
}

/// Pilot's real objects, the same ones Settings changes.
@MainActor
final class LiveSetupSystem: SetupSystem {
    var picks: AppRolePicks { .shared }
    let defaultApps: DefaultAppsSystem = LaunchServicesDefaults()

    func installed(_ item: SetupItem) -> Bool {
        if let helper = item.helper { return helper.path() != nil }
        return item.command.flatMap { Homebrew.cli($0) } != nil
    }

    func download(_ item: SetupItem) -> SpeechModel.State {
        item == .voices ? KokoroModel.shared.state : SpeechModels.shared.model(OnboardingSetup.speech).state
    }

    var speechPick: String? { SpeechModels.shared.pick?.rawValue }
    var hasSpeechModel: Bool { SpeechModels.shared.active != nil }

    func startDownloads(dictation: Bool, voices: Bool) {
        ExtrasDownloads.shared.start(speech: dictation ? OnboardingSetup.speech : nil, voices: voices, upscaler: false)
    }

    func removeDownload(_ item: SetupItem, pick: String?) {
        if item == .voices { return KokoroModel.shared.remove() }
        SpeechModels.shared.remove(OnboardingSetup.speech)
        SpeechModels.shared.pick = pick.flatMap(SpeechChoice.init)
    }

    var launchesAtLogin: Bool { LoginItem.shared.status == .enabled }

    func launchAtLogin(_ on: Bool) -> String? {
        guard let engine = Engine.shared else { return "Pilot's engine is not running" }
        engine.settings.launchAtLogin = on
        return LoginItem.shared.problem
    }

    var commandLinked: Bool { CommandLineLink.shared.state == .linked }

    func linkCommand(_ on: Bool) -> String? {
        let link = CommandLineLink.shared
        if on { link.makeLink() } else { link.removeLink() }
        if link.state == .noCommand { return "this copy of Pilot carries no pilot command" }
        return (link.state == .linked) == on ? nil : link.problem ?? "~/.local/bin/pilot belongs to something else"
    }

    var statusPath: String {
        PilotFolder.support.appending(path: "setup-run.txt").path(percentEncoded: false)
    }

    /// At most `SetupScript.statusLimit` bytes: the file is the user's to write, so a huge one is never read whole.
    func readStatus() -> String? {
        guard let handle = FileHandle(forReadingAtPath: statusPath) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: Self.statusLimit)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Seven helpers write a few lines each; 64 KB is far past any real run.
    static let statusLimit = 64 * 1024

    func runScript(_ script: String, title: String) -> String? {
        let file = FileManager.default.temporaryDirectory.appending(path: "pilot-setup-\(UUID().uuidString).zsh")
        do {
            // A last run's file would read as this one's until the script empties it.
            try? FileManager.default.removeItem(atPath: statusPath)
            try FileManager.default.createDirectory(at: URL(filePath: statusPath).deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return "the run's script was not written: \(error.localizedDescription)"
        }
        VisibleTerminal.run("/bin/zsh \(VisibleRun.quoted(file.path(percentEncoded: false)))", title: title, onSuccess: VisibleRun.waitForReturn)
        return nil
    }

    func runInTerminal(_ command: String, title: String, onSuccess: String) {
        VisibleTerminal.run(command, title: title, onSuccess: onSuccess)
    }
}

/// Set up (Onboarding 1.1, T54; build note `specs/onboarding-variants.build.md`): Set up everything or Pick by hand, then
/// one run that shows each change and undoes any of it. Every change records its before-state as it runs, and the ledger
/// is saved, so Undo puts back exactly what was there: a change that was already in place is never part of a run, so an
/// undo never removes what this Mac had before. The run carries on after the window closes; the helpers run in one
/// visible Terminal window (SetupScript), whose status file is read once a second only while something is running.
@Observable @MainActor
final class OnboardingSetup {
    static let shared = OnboardingSetup(system: LiveSetupSystem())

    /// The dictation model Set up downloads: the one Sven uses (his prefs, `dictation.model` = whisperTurbo).
    nonisolated static let speech = SpeechChoice.whisperTurbo

    enum Phase: Equatable { case fork, pick, run }

    /// One change as it stands.
    enum State: Codable, Equatable {
        case waiting, running(String), done
        case failed(String)
        case undoing, undone
        case undoFailed(String)

        /// The state in words, on the run's line.
        var words: String {
            switch self {
            case .waiting: "waiting"
            case .running(let what): what
            case .done: "done"
            case .failed(let why): "failed: \(why)"
            case .undoing: "undoing"
            case .undone: "undone"
            case .undoFailed(let why): "undo failed: \(why)"
            }
        }

        /// The state without its words or share: what is saved changes only with it.
        var kind: String {
            switch self {
            case .waiting: "waiting"
            case .running: "running"
            case .done: "done"
            case .failed: "failed"
            case .undoing: "undoing"
            case .undone: "undone"
            case .undoFailed: "undoFailed"
            }
        }

        /// Whether it ended: done, failed or undone.
        var settled: Bool {
            switch self {
            case .waiting, .running, .undoing: false
            default: true
            }
        }
    }

    struct Change: Codable, Equatable {
        var state: State
        /// What was there before: the key's pick, the kind's app, the dictation pick; nil for nothing or Automatic.
        var before: String?
    }

    var phase = Phase.fork
    /// What is on this Mac already, read when Set up shows: never part of a run.
    private(set) var onMac: Set<SetupItem> = []
    /// Pick by hand's ticks: nothing at first.
    private(set) var picked: Set<SetupItem> = []
    /// The run: each change made, in the plan's order, saved.
    private(set) var ledger: [SetupItem: Change] = [:]
    /// Why the run could not start, said under it.
    private(set) var problem: String?

    @ObservationIgnored let system: SetupSystem
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let openWith: DefaultAppsModel
    /// When a state last changed; see `refresh`.
    @ObservationIgnored private var heard = Date()
    static let quietLimit: TimeInterval = 30 * 60
    /// The quiet limit's marks (reviewer, T54): not final. `refresh` at launch and as the run's list shows looks again,
    /// so a helper that installed once its password was typed shows done, with its Undo.
    static let quietReason = "nothing heard for 30 minutes; Pilot looks again when this list shows, or install it from \(AppPlace(.helpers).path)"
    static let stillReason = "still on this Mac; the Terminal window says why"
    static let ledgerKey = "setup.ledger"
    /// Set by Run setup again, cleared by a run's start: the fork shows at the next launch, the record kept (Q848).
    static let againKey = "setup.again"

    init(system: SetupSystem, defaults: UserDefaults = .pilot()) {
        self.system = system
        self.defaults = defaults
        openWith = DefaultAppsModel(kinds: [SetupItem.txt, .md].compactMap(\.kind), system: system.defaultApps)
        if let data = defaults.data(forKey: Self.ledgerKey), let saved = try? JSONDecoder().decode([SetupItem: Change].self, from: data) {
            ledger = saved
            phase = saved.isEmpty || defaults.bool(forKey: Self.againKey) ? .fork : .run
        }
        refresh()
        if isLive { watch() }
    }

    // MARK: Before the run

    func load() {
        onMac = Set(SetupItem.allCases.filter(isOnMac))
        picked.subtract(onMac)
        noAppBefore = [SetupItem.txt, .md].filter { item in !onMac.contains(item) && item.kind?.handlers.first.flatMap(system.defaultApps.current) == nil }
    }

    /// The file kinds with no app on this Mac: their Undo cannot put "none" back, which the fork says first.
    private(set) var noAppBefore: [SetupItem] = []

    /// Settings › General's Run setup again (Sven, Q847, Q848): a run in progress resumes; otherwise the fork shows again,
    /// read afresh, offering only what is not set up. Nothing is undone, and the record of what is still in place is
    /// kept with its before-states, so its Undo stays; so are the quiet marks, which a later look may still settle.
    func again() {
        refresh()
        guard !isLive else { phase = .run; return }
        ledger = ledger.filter { ($0.value.state == .done && isOnMac($0.key)) || $0.value.state == .failed(Self.quietReason)
            || $0.value.state == .undoFailed(Self.stillReason) }
        picked = []
        defaults.set(true, forKey: Self.againKey)
        save()
        phase = .fork
        log.notice("setup: run again")
    }

    private func isOnMac(_ item: SetupItem) -> Bool {
        switch item {
        case .homebrew, .mole, .mas, .ffmpeg, .webp, .npm, .cargo: system.installed(item)
        case .filesKey, .notesKey: item.role.map { system.picks.picks[$0] == AppRolePicks.pilot } ?? false
        case .txt, .md: item.kind?.handlers.first.flatMap(system.defaultApps.current) == AppRolePicks.pilot
        // A download already under way counts as on this Mac (reviewer, T54): Set up never starts it twice.
        case .dictation: system.hasSpeechModel || Self.underWay(system.download(item))
        case .voices: system.download(item) == .ready || Self.underWay(system.download(item))
        case .launchAtLogin: system.launchesAtLogin
        case .command: system.commandLinked
        }
    }

    private static func underWay(_ state: SpeechModel.State) -> Bool {
        switch state {
        case .downloading, .preparing: true
        default: false
        }
    }

    /// Set up everything's changes: all but what is on this Mac or still held by the record (a quiet mark Run setup
    /// again kept, which a later look settles; `start` never runs one twice).
    var everything: [SetupItem] { SetupItem.allCases.filter { !onMac.contains($0) && ledger[$0] == nil } }

    /// A formula needs Homebrew: ticking one ticks Homebrew, and unticking Homebrew unticks them while it is missing.
    func set(_ item: SetupItem, _ on: Bool) {
        guard !onMac.contains(item), ledger[item] == nil else { return }
        if on { picked.insert(item) } else { picked.remove(item) }
        guard !onMac.contains(.homebrew) else { return }
        if on && item.formula != nil { picked.insert(.homebrew) }
        if !on && item == .homebrew { picked.subtract(SetupGroup.helpers.items) }
    }

    // MARK: The run

    /// Starts `items` in the plan's order: keys, Pilot's settings and file kinds at once, then the downloads, then the
    /// helpers' Terminal run. Each records what was there before it changes it.
    func start(_ items: [SetupItem]) {
        let run = SetupItem.allCases.filter { items.contains($0) && !onMac.contains($0) && ledger[$0] == nil }
        problem = nil
        phase = .run
        defaults.set(false, forKey: Self.againKey)
        guard !run.isEmpty else { return }
        for item in run { ledger[item] = Change(state: .waiting) }
        log.notice("setup: \(run.map(\.rawValue).joined(separator: ", "), privacy: .public)")

        for item in run {
            switch item {
            case .filesKey, .notesKey:
                guard let role = item.role else { continue }
                ledger[item]?.before = system.picks.picks[role]
                system.picks.set(role, AppRolePicks.pilot)
                ledger[item]?.state = .done
            case .launchAtLogin:
                ledger[item]?.state = system.launchAtLogin(true).map(State.failed) ?? .done
            case .command:
                ledger[item]?.state = system.linkCommand(true).map(State.failed) ?? .done
            default: break
            }
        }
        let kinds = run.filter { $0.kind != nil }
        if !kinds.isEmpty { Task { await setKinds(kinds) } }

        let dictation = run.contains(.dictation), voices = run.contains(.voices)
        if dictation { ledger[.dictation]?.before = system.speechPick }
        if dictation || voices { system.startDownloads(dictation: dictation, voices: voices) }

        let helpers = run.filter { $0.group == .helpers }
        if !helpers.isEmpty {
            let script = SetupScript.script(helpers.compactMap(step), status: system.statusPath)
            heard = Date()
            if let failure = system.runScript(script, title: "Set up Pilot's helpers") {
                for item in helpers { ledger[item]?.state = .failed(failure) }
            }
        }
        save()
        refresh()
        watch()
    }

    /// A helper's step: its install, the command that proves it, and Install's record of a formula.
    private func step(_ item: SetupItem) -> SetupScript.Step? {
        guard let check = item.command else { return nil }
        if item == .homebrew { return SetupScript.Step(id: item.rawValue, command: Helper.homebrew.install, check: check, label: "Homebrew's installer") }
        guard let formula = item.formula, let package = Package(.formula, formula) else { return nil }
        return SetupScript.Step(id: item.rawValue, command: package.install, check: check, hook: InstallModule.hook("installed", key: package.key))
    }

    /// Each kind through Default apps' own code, which reads the change back: Pilot only where macOS lists it for the kind.
    private func setKinds(_ items: [SetupItem]) async {
        openWith.load()
        for item in items {
            guard let kind = item.kind else { continue }
            let row = openWith.rows[kind.id]
            ledger[item]?.before = row?.current
            guard row?.choices.contains(where: { $0.bundle == AppRolePicks.pilot }) == true else {
                ledger[item]?.state = .failed("macOS does not list Pilot for \(kind.title) files on this Mac")
                continue
            }
            ledger[item]?.state = .running("setting")
            await openWith.change(kind, to: AppRolePicks.pilot)
            ledger[item]?.state = openWith.rows[kind.id]?.message.map(State.failed) ?? .done
        }
        save()
    }

    /// Whether anything still runs: a helper or download not settled, or a helper's undo in Terminal.
    var isLive: Bool { ledger.values.contains { !$0.state.settled } }

    /// Once a second while something runs; stops itself once nothing does.
    private func watch() {
        guard timer == nil, isLive else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Reads the helpers' status file once, each download's state, and whether an undone helper is gone. Saves when a
    /// state changes kind (a download's percentage alone is not saved). Nothing heard for `quietLimit` ends what still
    /// runs, so the poll never outlives a Terminal window that was killed or an undo that was cancelled.
    func refresh() {
        let before = ledger
        let helpers = ledger.keys.filter { $0.group == .helpers }
        let quiet = State.failed(Self.quietReason)
        let pending = helpers.filter { ledger[$0]?.state == .waiting || ledger[$0]?.state == quiet || isRunning($0) }
        if !pending.isEmpty, let text = system.readStatus() {
            let read = SetupScript.read(text, ids: helpers.map(\.rawValue))
            for item in pending {
                switch read.outcomes[item.rawValue] {
                // Only a final reading replaces a quiet mark (reviewer, T54): "installing" would leave it live with no poll.
                case .installing?: if ledger[item]?.state != quiet { ledger[item]?.state = .running("installing") }
                case .done?: ledger[item]?.state = .done
                case .failed(let why)?: ledger[item]?.state = .failed(Self.retry(why))
                case nil: if read.finished { ledger[item]?.state = .failed(Self.retry("the run ended before it")) }
                }
            }
        }
        for item in [SetupItem.dictation, .voices] where ledger[item].map({ (!$0.state.settled && $0.state != .undoing) || $0.state == quiet }) == true {
            let now = system.download(item)
            if ledger[item]?.state == quiet {
                switch now {
                case .ready: ledger[item]?.state = .done
                case .failed(let why): ledger[item]?.state = .failed(why)
                default: break
                }
                continue
            }
            ledger[item]?.state = switch now {
            case .absent: .waiting
            case .downloading(let share): .running("downloading \(Int(share * 100))%")
            case .preparing: .running("preparing")
            case .ready: .done
            case .failed(let why): .failed(why)
            }
        }
        // A quiet file kind reads the current default: Pilot's is done, anything else failed with where to set it.
        for item in [SetupItem.txt, .md] where ledger[item]?.state == quiet {
            guard let kind = item.kind else { continue }
            ledger[item]?.state = kind.handlers.first.flatMap(system.defaultApps.current) == AppRolePicks.pilot ? .done
                : .failed("macOS did not take Pilot for \(kind.title) files; pick it in \(AppPlace(.openWith).path)")
        }
        let still = State.undoFailed(Self.stillReason)
        for item in helpers where (ledger[item]?.state == .undoing || ledger[item]?.state == still) && !system.installed(item) {
            ledger[item]?.state = .undone
        }
        if ledger != before { heard = Date() }
        if isLive, Date().timeIntervalSince(heard) > Self.quietLimit {
            for (item, change) in ledger where !change.state.settled { ledger[item]?.state = change.state == .undoing ? still : quiet }
        }
        if ledger.mapValues(\.state.kind) != before.mapValues(\.state.kind) { save() }
        if !isLive { timer?.invalidate(); timer = nil }
    }

    /// A helper's failure line names where to try again: onboarding never reruns one (reviewer, T54).
    private static func retry(_ why: String) -> String { "\(why); install it from \(AppPlace(.helpers).path)" }

    private func isRunning(_ item: SetupItem) -> Bool { if case .running? = ledger[item]?.state { true } else { false } }

    private func save() {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.ledgerKey) }
    }

    // MARK: Undo

    /// The changes Undo can put back: done, in the plan's order; no helper while the Terminal run still installs one.
    func undoable(_ group: SetupGroup) -> [SetupItem] {
        let busy = group == .helpers && group.items.contains { ledger[$0].map { !$0.state.settled } ?? false }
        return busy ? [] : group.items.filter { ledger[$0]?.state == .done }
    }

    /// What Undo asks first: removing Homebrew removes everything installed through it.
    static let homebrewWarning = "Removing Homebrew also removes every app and tool installed through it, not only Pilot's helpers."

    /// Puts each back: a helper is removed in Terminal (Homebrew by its own uninstaller, which takes the rest with it), a
    /// key goes back to its pick or Automatic, a file kind to its app, a download is deleted, launch at login goes off,
    /// the pilot command is unlinked. Only what this run changed; the caller asks first for Homebrew (`homebrewWarning`).
    func undo(_ items: [SetupItem]) {
        let items = items.filter { undoable($0.group).contains($0) }
        guard !items.isEmpty else { return }
        log.notice("setup: undo \(items.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        let helpers = items.filter { $0.group == .helpers }
        if !helpers.isEmpty {
            let formulas = helpers.compactMap(\.formula).compactMap { Package(.formula, $0) }
            if helpers.contains(.homebrew) {
                system.runInTerminal(Self.homebrewUninstall, title: "Remove Homebrew", onSuccess: VisibleRun.waitForReturn)
            } else {
                let hooks = formulas.map { InstallModule.hook("removed", key: $0.key) }
                system.runInTerminal("brew uninstall \(formulas.map(\.name).joined(separator: " "))", title: "Remove Pilot's helpers",
                                     onSuccess: (hooks + [VisibleRun.waitForReturn]).joined(separator: "; "))
            }
            // Homebrew's uninstaller takes every formula with it.
            let going = helpers.contains(.homebrew) ? undoable(.helpers) : helpers
            for item in going { ledger[item]?.state = .undoing }
        }
        for item in items {
            switch item {
            case .filesKey, .notesKey:
                guard let role = item.role else { continue }
                system.picks.set(role, ledger[item]?.before)
                ledger[item]?.state = .undone
            case .dictation, .voices:
                system.removeDownload(item, pick: ledger[item]?.before)
                ledger[item]?.state = .undone
            case .launchAtLogin:
                ledger[item]?.state = system.launchAtLogin(false).map(State.undoFailed) ?? .undone
            case .command:
                ledger[item]?.state = system.linkCommand(false).map(State.undoFailed) ?? .undone
            default: break
            }
        }
        let kinds = items.filter { $0.kind != nil }
        if !kinds.isEmpty { Task { await restoreKinds(kinds) } }
        heard = Date()
        save()
        watch()
    }

    private func restoreKinds(_ items: [SetupItem]) async {
        openWith.load()
        for item in items {
            guard let kind = item.kind else { continue }
            guard let before = ledger[item]?.before else {
                ledger[item]?.state = .undoFailed("this Mac had no app for \(kind.title) files before; pick one in Open with")
                continue
            }
            ledger[item]?.state = .undoing
            await openWith.change(kind, to: before)
            ledger[item]?.state = openWith.rows[kind.id]?.message.map(State.undoFailed) ?? .undone
        }
        save()
    }

    /// Homebrew's own uninstaller, which asks before it removes anything.
    static let homebrewUninstall = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)""#

    // MARK: What the screens say

    /// The run's title: "Setting up · 8 of 15" while it runs, then what came of it.
    var title: String {
        let total = ledger.count, failed = ledger.values.count { if case .failed = $0.state { true } else { false } }
        if total == 0 { return "Nothing to set up" }
        if isLive { return "Setting up · \(ledger.values.count { $0.state.settled }) of \(total)" }
        return failed == 0 ? "Set up · \(total) of \(total) done" : "Set up · \(total - failed) done, \(failed) failed"
    }

    /// A group's line: each item with its state, done ones ticked ("Homebrew ✓ · Mole ✓ · webp installing · npm").
    func line(_ group: SetupGroup) -> String {
        group.items.compactMap { item in
            guard let state = ledger[item]?.state else { return nil }
            return switch state {
            case .done: "\(item.short) ✓"
            case .waiting: item.short
            default: "\(item.short) \(state.words)"
            }
        }
        .joined(separator: " · ")
    }

    /// A group's settled and done counts, for its bar and count; nil when the run has none of it.
    func share(_ group: SetupGroup) -> (settled: Int, done: Int, total: Int)? {
        let mine = group.items.compactMap { ledger[$0] }
        return mine.isEmpty ? nil : (mine.count { $0.state.settled }, mine.count { $0.state == .done }, mine.count)
    }

    /// Fork's count: "15 changes", or what of them is on this Mac already.
    var forkCount: String {
        let n = everything.count
        let base = "\(n) change\(n == 1 ? "" : "s")"
        return onMac.isEmpty ? base : "\(base) · \(onMac.count) already on this Mac"
    }

    /// Whether the helpers' run needs the Mac's login, because Homebrew is in it.
    var asksForMacLogin: Bool { !onMac.contains(.homebrew) }

    #if DEBUG
    /// A render's state in place of a run: what is on its Mac, what is ticked, the ledger.
    func seed(onMac: Set<SetupItem>, picked: Set<SetupItem> = [], ledger: [SetupItem: Change] = [:], phase: Phase) {
        self.onMac = onMac
        self.picked = picked
        self.ledger = ledger
        self.phase = phase
    }
    #endif
}
