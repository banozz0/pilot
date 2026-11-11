#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Onboarding 1.1 (T54, variant C, Q841-Q843): a sandbox run of Set up with a recording system in place of the Mac, so
/// nothing installs and no default, key or setting of this Mac changes; then each screen drawn from that run, Instrument
/// and Toybox. The run's record goes to `sandbox-run.txt` beside the images. Opt-in like the other renders, in a moved
/// home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter OnboardingRenders`
extension SharedLook {
@MainActor
@Suite("Onboarding renders")
struct OnboardingRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Set up everything and its undo, on a recording Mac, then every screen", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("onboarding")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let engine = try SharedLook.HomeRenders.engine()
        let look = Look.shared
        look.themeID = Self.env["PILOT_RENDER_THEME"] ?? "tokyo-night"
        defer { look.themeID = PilotTheme.defaultID; look.style = .instrument }

        // A fresh Mac: nothing on it; Notes already opens Obsidian, .txt TextEdit, .md nothing.
        let suite = "pilot-onboarding-renders-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mac = RecordingMac(defaults: defaults)
        mac.picks.set(.notes, "md.obsidian")
        mac.log.removeAll()
        let setup = OnboardingSetup(system: mac, defaults: defaults)
        setup.load()
        #expect(setup.everything.count == 15 && setup.noAppBefore == [.md])
        let grants = RecordingGrants()
        let model = OnboardingModel(setup: setup, walk: GrantWalk(system: grants))

        // Hyper, Access and the fork, as a fresh Mac shows them.
        for (step, name) in [(OnboardingModel.Step.welcome, "1-hyper"), (.permissions, "2-access"), (.extras, "3a-fork")] {
            model.step = step
            try instrument(model, engine, name, dir)
        }
        try toybox(model, engine, "3a-fork", dir)

        // Pick by hand: mole ticked ticks Homebrew; the .md row.
        setup.phase = .pick
        setup.set(.mole, true)
        setup.set(.md, true)
        #expect(setup.picked == [.homebrew, .mole, .md])
        try instrument(model, engine, "3b-pick", dir)
        setup.set(.homebrew, false)
        #expect(setup.picked == [.md])
        setup.phase = .fork

        // Set up everything.
        setup.start(setup.everything)
        for _ in 0..<100 where setup.ledger[.md]?.state != .done { try await Task.sleep(for: .milliseconds(20)) }
        #expect(mac.picks.picks[.files] == AppRolePicks.pilot && mac.picks.picks[.notes] == AppRolePicks.pilot)
        let ran = mac.log + ["keys: files → \(mac.picks.picks[.files] ?? "Automatic"), notes → \(mac.picks.picks[.notes] ?? "Automatic")"]
        #expect(ran.contains("default public.plain-text → dev.banozz.pilot") && ran.contains("default net.daringfireball.markdown → dev.banozz.pilot"))
        #expect(ran.contains("downloads dictation true, voices true") && ran.contains("launch at login on") && ran.contains("pilot command link"))
        let script = try #require(mac.scripts.first)
        let order = script.split(separator: "\n").filter { $0.hasPrefix("step ") }.map { $0.split(separator: " ")[1] }
        #expect(order == ["'homebrew'", "'mole'", "'mas'", "'ffmpeg'", "'webp'", "'npm'", "'cargo'"])
        #expect(setup.ledger[.notesKey]?.before == "md.obsidian" && setup.ledger[.txt]?.before == "com.apple.TextEdit")

        // Mid-run: the Terminal's status file and the downloads part way.
        mac.status = "homebrew installing\nhomebrew done\nmole installing\nmole done\nmas done\nffmpeg done\nwebp installing\n"
        mac.downloads = [.dictation: .downloading(0.42), .voices: .ready]
        setup.refresh()
        #expect(setup.title == "Setting up · 11 of 15")
        model.step = .extras
        try instrument(model, engine, "3c-run", dir)
        try toybox(model, engine, "3c-run", dir)

        // The end: npm failed, the window closed before cargo.
        mac.status! += "webp done\nnpm installing\nnpm failed exit 1\ncargo installing\nclosed\n"
        mac.installed = [.homebrew, .mole, .mas, .ffmpeg, .webp]
        mac.downloads[.dictation] = .ready
        setup.refresh()
        let retry = "; install it from \(AppPlace(.helpers).path)"
        #expect(setup.ledger[.npm]?.state == .failed("stopped with exit 1; the Terminal window says why" + retry))
        #expect(setup.ledger[.cargo]?.state == .failed("the Terminal window closed before it finished" + retry))
        #expect(setup.title == "Set up · 13 done, 2 failed" && !setup.isLive)
        try instrument(model, engine, "3d-run-done", dir)

        // Try it (T58): no What changed card; Allow the rest reads nothing until it starts, then walks each grant: one
        // already allowed passes without an ask, one allowed in Settings moves on by itself, Skip and Stop leave the rest
        // for Settings › Permissions, and Screen Recording is asked before it is ever read (ADR 0012).
        model.startTryIt()
        try instrument(model, engine, "4a-try-it", dir)
        try toybox(model, engine, "4a-try-it", dir)
        #expect(grants.log.isEmpty && model.walk.phase == .ready)
        // The walk on a model of its own, drawn without a window's appear and disappear: a closed render window's late
        // onDisappear stops its model's walk, as closing Welcome does.
        let walking = OnboardingModel(setup: setup, walk: GrantWalk(system: grants))
        walking.startTryIt()
        grants.granted = [.systemEvents]
        walking.walk.start()
        for _ in 0..<50 where walking.walk.phase != .asking(.fullDiskAccess) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(grants.log == ["read systemEvents", "read fullDiskAccess", "ask fullDiskAccess"])
        try instrument(walking, engine, "4b-allow-the-rest", dir)
        grants.granted.insert(.fullDiskAccess)
        walking.walk.tick()
        for _ in 0..<50 where walking.walk.phase != .asking(.microphone) { try await Task.sleep(for: .milliseconds(20)) }
        walking.walk.skip()
        for _ in 0..<50 where walking.walk.phase != .asking(.screenRecording) { try await Task.sleep(for: .milliseconds(20)) }
        grants.granted.insert(.screenRecording)
        walking.walk.tick()
        for _ in 0..<50 where walking.walk.phase != .asking(.inputMonitoring) { try await Task.sleep(for: .milliseconds(20)) }
        walking.walk.stop()
        let asked = grants.log.firstIndex(of: "ask screenRecording"), read = grants.log.firstIndex(of: "read screenRecording")
        #expect(asked != nil && read != nil && asked! < read!)
        #expect(walking.walk.phase == .finished && walking.walk.done == "Done: 3 of 6")
        #expect(walking.walk.skipped == [.microphone, .inputMonitoring, .notifications] && grants.log.last == "close helper inputMonitoring")
        // Allowed, Screen Recording's helper stays for its Quit & Reopen; the next steps close only their own.
        #expect(!grants.log.contains("close helper screenRecording") && grants.log.contains("close helper fullDiskAccess"))
        try instrument(walking, engine, "4c-allow-the-rest-done", dir)
        try toybox(walking, engine, "4c-allow-the-rest-done", dir)
        let walked = grants.log

        // A Stop during an awaited read, or a Skip during a tick's read, ends that turn (reviewer, T58): nothing is asked,
        // read or opened for it again, and an ask still waiting on its own read is told it is no longer wanted.
        let slow = RecordingGrants()
        slow.delay = .milliseconds(150)
        let halted = GrantWalk(system: slow)
        halted.start()
        try await Task.sleep(for: .milliseconds(30))
        halted.stop()
        try await Task.sleep(for: .milliseconds(400))
        #expect(slow.log == ["read systemEvents", "close helper systemEvents"] && halted.phase == .finished)
        let racing = RecordingGrants()
        let skipping = GrantWalk(system: racing)
        skipping.start()
        for _ in 0..<50 where racing.log.last != "ask systemEvents" { try await Task.sleep(for: .milliseconds(20)) }
        racing.delay = .milliseconds(150)
        racing.granted = [.systemEvents]
        skipping.tick()
        skipping.skip()
        for _ in 0..<50 where racing.log.last != "ask fullDiskAccess" { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(skipping.phase == .asking(.fullDiskAccess) && skipping.skipped == [.systemEvents] && skipping.allowedRows.isEmpty)
        #expect(racing.stills.first?() == false && racing.stills.last?() == true)

        // Undo everything, group by group: Homebrew's own uninstaller (the view asks first), each key and kind back.
        mac.log.removeAll()
        for group in SetupGroup.allCases { setup.undo(setup.undoable(group)) }
        // The kinds go back in turn, .md after .txt.
        for _ in 0..<100 where setup.ledger[.md]?.state == .done { try await Task.sleep(for: .milliseconds(20)) }
        mac.installed = []
        setup.refresh()
        #expect(mac.picks.picks[.notes] == "md.obsidian" && mac.picks.picks[.files] == nil)
        #expect(mac.log.contains("default public.plain-text → com.apple.TextEdit"))
        #expect(mac.log.contains { $0.hasPrefix("terminal Remove Homebrew: /bin/bash -c ") })
        #expect(setup.ledger[.md]?.state == .undoFailed("this Mac had no app for Markdown files before; pick one in Open with"))
        #expect(SetupItem.allCases.filter { setup.ledger[$0]?.state == .undone }.count == 12)
        let undone = mac.log + ["keys: files → \(mac.picks.picks[.files] ?? "Automatic"), notes → \(mac.picks.picks[.notes] ?? "Automatic")"]

        // A Mac with Homebrew, Mole and the voices: they are never part of the run, so no undo removes them.
        let second = RecordingMac(defaults: defaults)
        second.installed = [.homebrew, .mole]
        second.downloads = [.voices: .ready]
        defaults.removeObject(forKey: OnboardingSetup.ledgerKey)
        let kept = OnboardingSetup(system: second, defaults: defaults)
        kept.load()
        #expect(kept.everything.count == 12 && !kept.asksForMacLogin)
        let other = OnboardingModel(setup: kept)
        other.step = .extras
        try instrument(other, engine, "3e-fork-homebrew-on-mac", dir)
        kept.start([.homebrew, .mole, .mas, .voices])
        #expect(kept.ledger.keys.sorted { $0.rawValue < $1.rawValue } == [.mas])
        #expect(second.scripts.count == 1 && !second.scripts[0].contains("'homebrew'"))
        second.status = "mas installing\nmas done\nend\n"
        kept.refresh()
        kept.undo(kept.undoable(.helpers))
        #expect(second.log.contains { $0.hasPrefix("terminal Remove Pilot's helpers: brew uninstall mas") })

        // The quiet limit's marks are looked at again (reviewer, T54): a helper that installed after 30 quiet minutes
        // shows done with its Undo, and an undo that went through after them shows undone.
        typealias Change = OnboardingSetup.Change
        let quiet = OnboardingSetup.State.failed(OnboardingSetup.quietReason)
        // Only a final reading replaces a quiet mark: "installing" leaves it quiet, and Run setup again still reaches the fork.
        kept.seed(onMac: [.homebrew, .mole], ledger: [.mas: Change(state: quiet)], phase: .run)
        second.status = "mas installing\n"
        kept.refresh()
        #expect(kept.ledger[.mas]?.state == quiet && !kept.isLive)
        kept.again()
        #expect(kept.phase == .fork && kept.ledger[.mas]?.state == quiet && !kept.everything.contains(.mas))
        second.installed.insert(.mas)
        kept.seed(onMac: [.homebrew, .mole], ledger: [.mas: Change(state: quiet)], phase: .run)
        second.status = "mas installing\nmas done\nend\n"
        kept.refresh()
        #expect(kept.ledger[.mas]?.state == .done && kept.undoable(.helpers) == [.mas])
        kept.seed(onMac: [.homebrew, .mole], ledger: [.mas: Change(state: .undoFailed(OnboardingSetup.stillReason))], phase: .run)
        second.installed = [.homebrew, .mole]
        kept.refresh()
        #expect(kept.ledger[.mas]?.state == .undone)

        // Ctrl-C has its own words.
        let stopped = SetupScript.read("homebrew installing\nstopped\n", ids: ["homebrew", "mole"])
        #expect(stopped.finished && stopped.outcomes["mole"] == .failed("Ctrl-C stopped the run before it finished"))

        // A download under way counts as on this Mac. Run setup again (Q847, Q848) keeps the record of what is still in
        // place, with its before-state and Undo, drops what was undone, undoes nothing, and opens on the fork, also at the
        // next launch, until a run starts.
        second.downloads[.dictation] = .downloading(0.3)
        kept.load()
        #expect(kept.onMac.contains(.dictation))
        second.installed.insert(.mas)
        kept.seed(onMac: [.homebrew, .mole], ledger: [.mas: Change(state: .done), .cargo: Change(state: .undone)], phase: .run)
        let logged = second.log.count
        kept.again()
        #expect(kept.ledger == [.mas: Change(state: .done)] && kept.phase == .fork && second.log.count == logged)
        #expect(kept.undoable(.helpers) == [.mas])
        let relaunched = OnboardingSetup(system: second, defaults: defaults)
        #expect(relaunched.phase == .fork && relaunched.ledger[.mas]?.state == .done)
        relaunched.load()
        relaunched.start([.ffmpeg])
        #expect(!defaults.bool(forKey: OnboardingSetup.againKey) && relaunched.ledger[.mas]?.state == .done)
        kept.seed(onMac: [], ledger: [.npm: Change(state: .running("installing"))], phase: .fork)
        second.status = "npm installing\n"
        kept.again()
        #expect(kept.phase == .run && kept.ledger[.npm]?.state == .running("installing"))

        let record = (["Allow the rest:"] + walked + ["", "Set up everything:"] + ran + ["", "Its script:", script, "", "Undo:"] + undone + ["", "Homebrew on the Mac:"] + second.log)
        try record.joined(separator: "\n").write(to: dir.appendingPathComponent("sandbox-run.txt"), atomically: true, encoding: .utf8)
        print(record.joined(separator: "\n"))
    }

    private func instrument(_ model: OnboardingModel, _ engine: Engine, _ name: String, _ dir: URL) throws {
        Look.shared.style = .instrument
        try SharedLook.InstrumentPanelsRenders.renderWindow(InstrumentOnboarding(model: model, confirming: .constant(nil), finish: {})
            .environment(engine).styled(.onboarding).pilotTheme(), name: "\(name)-instrument", in: dir)
    }

    /// Toybox's steps through OnboardingView, in its own titled window as PilotApp opens it.
    private func toybox(_ model: OnboardingModel, _ engine: Engine, _ name: String, _ dir: URL) throws {
        Look.shared.style = .toybox
        defer { Look.shared.style = .instrument }
        let host = NSHostingView(rootView: OnboardingView(model: model).environment(engine))
        host.frame.size = host.fittingSize
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to Pilot"
        w.isReleasedWhenClosed = false
        w.contentView = host
        defer { w.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let chrome = try #require(w.contentView?.superview)
        chrome.layoutSubtreeIfNeeded()
        try #require(snapshot(chrome, scale: 2)?.representation(using: .png, properties: [:]))
            .write(to: dir.appendingPathComponent("\(name)-toybox.png"))
        w.close()
        // The window's onDisappear (the model's stop) lands now, not in the middle of what the test does next.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
}
}

/// A Mac in memory for Set up: what is on it, and every change asked for, in words. Never a real install, default, key or
/// setting.
@MainActor
final class RecordingMac: SetupSystem {
    var log: [String] = []
    var scripts: [String] = []
    var installed: Set<SetupItem> = []
    var downloads: [SetupItem: SpeechModel.State] = [:]
    var status: String?
    var loginOn = false, linked = false, speech: String?
    let picks: AppRolePicks
    private let mac = SandboxDefaults()
    var defaultApps: DefaultAppsSystem { mac }

    init(defaults: UserDefaults) {
        picks = AppRolePicks(defaults: defaults, installed: { _ in true }, found: { _ in true })
        mac.record = { [weak self] in self?.log.append($0) }
    }

    func installed(_ item: SetupItem) -> Bool { installed.contains(item) }
    func download(_ item: SetupItem) -> SpeechModel.State { downloads[item] ?? .absent }
    var speechPick: String? { speech }
    var hasSpeechModel: Bool { downloads[.dictation] == .ready }
    func startDownloads(dictation: Bool, voices: Bool) {
        log.append("downloads dictation \(dictation), voices \(voices)")
        if dictation { downloads[.dictation] = .downloading(0) }
        if voices { downloads[.voices] = .downloading(0) }
    }
    func removeDownload(_ item: SetupItem, pick: String?) {
        log.append("remove download \(item.rawValue), dictation pick back to \(pick ?? "none")")
        downloads[item] = .absent
    }
    var launchesAtLogin: Bool { loginOn }
    func launchAtLogin(_ on: Bool) -> String? { log.append("launch at login \(on ? "on" : "off")"); loginOn = on; return nil }
    var commandLinked: Bool { linked }
    func linkCommand(_ on: Bool) -> String? { log.append("pilot command \(on ? "link" : "unlink")"); linked = on; return nil }
    var statusPath: String { "/sandbox/setup-run.txt" }
    func readStatus() -> String? { status }
    func runScript(_ script: String, title: String) -> String? {
        log.append("terminal \(title): script with \(script.split(separator: "\n").count { $0.hasPrefix("step ") }) steps")
        scripts.append(script)
        status = ""
        return nil
    }
    func runInTerminal(_ command: String, title: String, onSuccess: String) { log.append("terminal \(title): \(command)") }
}

/// Default apps in memory: Pilot listed for both kinds, .txt on TextEdit, .md on nothing.
@MainActor
final class SandboxDefaults: DefaultAppsSystem {
    var defaults: [DefaultHandler: String] = [.contentType("public.plain-text"): "com.apple.TextEdit"]
    var record: (String) -> Void = { _ in }

    func current(_ handler: DefaultHandler) -> String? { defaults[handler] }
    func choices(_ handlers: [DefaultHandler]) -> [(name: String, bundle: String)] {
        [("TextEdit", "com.apple.TextEdit"), ("Pilot", AppRolePicks.pilot)]
    }
    func name(_ bundle: String) -> String { bundle }
    func setDefault(_ bundle: String, for handler: DefaultHandler) async throws {
        if case .contentType(let id) = handler { record("default \(id) → \(bundle)") }
        defaults[handler] = bundle
    }
}
/// The Mac's grants in memory for Allow the rest: what reads allowed, and every read and ask, in words. Never a real
/// prompt, pane or read.
@MainActor
final class RecordingGrants: GrantSystem {
    var granted: Set<Onboarding.Row> = []
    var log: [String] = []

    /// How long each read takes: a slow read lets a test Stop or Skip while it is awaited.
    var delay: Duration?
    func allowed(_ row: Onboarding.Row) async -> Bool {
        log.append("read \(row)")
        if let delay { try? await Task.sleep(for: delay) }
        return granted.contains(row)
    }
    func ask(_ row: Onboarding.Row, still: @escaping @MainActor () -> Bool) { log.append("ask \(row)"); stills.append(still) }
    /// Each ask's still-on-it check, so a test sees one go false after Skip.
    var stills: [@MainActor () -> Bool] = []
    func closeHelper(_ row: Onboarding.Row) { log.append("close helper \(row)") }
}
#endif
