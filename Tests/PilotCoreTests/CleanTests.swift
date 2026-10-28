import Foundation
import Testing
@testable import PilotCore

/// Clean (story 117, card agent-bo-95422881): Mole's own dry run read into rows, the one command a clean runs, and the
/// preview kept for 15 minutes. Nothing here runs Mole: the runner is a fake.
@Suite("Clean")
struct CleanTests {
    /// Cut from `NO_COLOR=1 mo clean --dry-run < /dev/null` on Sven's Mac, Mole 1.54.0, 2026-10-06 (whitelist lines left out).
    static let dryRun = """

    Clean Your Mac

    Dry Run Mode, Preview only, no deletions

    ◎ System caches need sudo, run sudo -v && mo clean --dry-run for full preview

    ⚙ Apple Silicon | Free space: 36.32GB
    ✓ Whitelist: 19 core patterns active

    ➤ User essentials
      → User app cache · 41 items, 13.53GB dry
      → User app logs · 17 items, 3.9MB dry
      → Trash · would empty, 3 items

    ➤ Browsers
      → Chrome cache · 1.73GB dry
      → Chrome Service Worker, would clean 270.4MB, 0 protected

    ➤ Cloud & Office
      ✓ Nothing to clean

    ➤ Developer tools
      → npm cache · would clean
      ⊙ Rust toolchains · 2 found (rustup toolchain list)
      ◎ Project caches · skipped 1 slow/incomplete root scan
      → Xcode Simulator system cache · would remove 1 entries (3.26GB)

    ➤ Large files
      ⊙ Simulator data · 4.78GB · ~/Library/Developer/CoreSimulator/Devices


    ======================================================================
    Dry run complete - no changes made
    Potential space: 28.75GB | Items: 834 | Categories: 6
    Detailed file list: /Users/ada/.config/mole/clean-list.txt
    Use mo clean --whitelist to add protection rules
    ======================================================================
    """

    @Test("A dry run reads into Mole's own items, each under its section with Mole's words for it, and the total")
    func parse() {
        let preview = CleanPreview.parse(Self.dryRun)
        #expect(preview.items.map(\.title) == ["User app cache", "User app logs", "Trash", "Chrome cache", "Chrome Service Worker",
                                               "npm cache", "Xcode Simulator system cache"])
        #expect(preview.items.map(\.detail) == ["41 items, 13.53GB", "17 items, 3.9MB", "would empty, 3 items", "1.73GB",
                                                "would clean 270.4MB, 0 protected", "would clean", "would remove 1 entries (3.26GB)"])
        #expect(preview.items.map(\.section) == ["User essentials", "User essentials", "User essentials", "Browsers", "Browsers",
                                                 "Developer tools", "Developer tools"])
        #expect(preview.total == "28.75GB")
        #expect(preview.systemSkipped)
    }

    @Test("A run with admin access cached includes system caches; a run that never summed has no total")
    func partial() {
        let preview = CleanPreview.parse("➤ User essentials\n  → User app cache · 2 items, 1.0GB dry\n")
        #expect(preview.total == nil)
        #expect(!preview.systemSkipped)
        #expect(preview.items.count == 1)
    }

    @Test("Clean's rows: the run row asks with exactly mo clean and shows the total, then each item, the skipped system caches, Disk usage")
    func entries() {
        let rows = CleanMenu.entries(CleanPreview.parse(Self.dryRun), mole: true)
        #expect(rows.first?.title == "Clean 28.75GB")
        #expect(rows.first?.detail == "mo clean")
        #expect(rows.first?.target == .clean(.run))
        #expect(rows.map(\.title).contains("User app cache"))
        #expect(rows.first { $0.title == "User app cache" }?.detail == "User essentials · 41 items, 13.53GB")
        #expect(rows.contains { $0.target == .clean(.note(7)) && $0.title.contains("System caches") })
        // The target is the row's id in the list, so no two rows share one, Mole's repeated titles included.
        #expect(Set(rows.map(\.id)).count == rows.count)
        let repeated = CleanPreview.parse("➤ Developer tools\n  → Obsolete VS Code extension · 235.3MB dry\n  → Obsolete VS Code extension · 4.7MB dry\n")
        let twice = CleanMenu.entries(repeated, mole: true)
        #expect(Set(twice.map(\.id)).count == twice.count)
        #expect(rows.suffix(2).map(\.title) == ["Disk usage", "Reports"])
        #expect(rows.suffix(2).map(\.target) == [.clean(.analyze), .clean(.reports)])
        #expect(rows.allSatisfy { $0.home == .clean && !$0.inSearch })
    }

    @Test("With Mole missing Clean's first row installs it through Install's confirm step, then Reports (story 153)")
    func missing() {
        let rows = CleanMenu.entries(nil, mole: false)
        #expect(rows.map(\.target) == [.clean(.install), .clean(.reports)])
        #expect(Helper.mole.package?.key == "formula:mole")
        #expect(rows.first?.detail == "brew install mole")
    }

    @Test("While the preview runs Clean lists nothing, so the menu says it is previewing")
    func previewing() {
        #expect(CleanMenu.entries(nil, mole: true).isEmpty)
    }

    @Test("Pilot runs only Mole's preview, its clean and its disk explorer; never its whitelist, purge, optimize or uninstall")
    func commands() {
        #expect(Mole.preview == ["clean", "--dry-run"])
        #expect(Mole.clean == "mo clean")
        #expect(Mole.analyze == "mo analyze")
        for command in Mole.preview + [Mole.clean, Mole.analyze] {
            for never in ["whitelist", "purge", "optimize", "uninstall", "remove", "--permanent"] { #expect(!command.contains(never)) }
        }
    }

    @Test("Clean is a top branch (its place: MenuBranchesTests.branches)")
    func branch() {
        #expect(MenuBranch.clean.parent == nil)
        #expect(MenuBranch.clean.title == "Clean")
    }

    @MainActor @Test("A preview under 15 minutes old is reused; an older one, or one dropped after a clean, runs Mole again")
    func reuse() async {
        var now = Date(timeIntervalSince1970: 0)
        var runs = 0
        let previewer = CleanPreviewer(now: { now }) { _ in
            runs += 1
            return CleanTests.dryRun
        }
        #expect(await previewer.preview()?.total == "28.75GB")
        #expect(runs == 1)
        now += 14 * 60
        _ = await previewer.preview()
        #expect(runs == 1)
        #expect(previewer.ready != nil)
        now += 2 * 60
        #expect(previewer.ready == nil)
        _ = await previewer.preview()
        #expect(runs == 2)
        previewer.drop()
        #expect(previewer.ready == nil)
        _ = await previewer.preview()
        #expect(runs == 3)
    }

    @MainActor @Test("Two opens while Mole is still previewing share the one run; a failed run is not kept")
    func shared() async {
        var runs = 0
        var output: String? = nil
        let previewer = CleanPreviewer(now: { .now }) { _ in
            runs += 1
            try? await Task.sleep(for: .milliseconds(50))
            return output
        }
        async let a = previewer.preview()
        async let b = previewer.preview()
        let (first, second) = await (a, b)
        #expect(first == nil && second == nil)
        #expect(runs == 1)
        output = CleanTests.dryRun
        #expect(await previewer.preview()?.items.count == 7)
        #expect(runs == 2)
    }

    @MainActor @Test("A clean confirmed while Mole is still previewing stops that preview, and it is not kept")
    func dropWhileRunning() async {
        var cancelled = false
        let previewer = CleanPreviewer(now: { .now }) { _ in
            try? await Task.sleep(for: .seconds(5))
            cancelled = Task.isCancelled
            return CleanTests.dryRun
        }
        let first = Task { await previewer.preview() }
        try? await Task.sleep(for: .milliseconds(50))
        previewer.drop()
        _ = await first.value
        #expect(cancelled)
        #expect(previewer.ready == nil)
    }

    /// Card agent-bo-95423002: Sven saw only "Mole is previewing…" and took it for stuck, though the run finished behind
    /// the closed menu (102 s on 2026-10-07).
    @MainActor @Test("While Mole previews, the menu names the section it is on and the items found so far")
    func progress() async throws {
        let gate = Gate()
        let previewer = CleanPreviewer(now: { .now }) { report in
            report("➤ User essentials")
            report("  → Trash · would empty, 3 items")
            report("➤ Browsers")
            report("  → Chrome cache · 1.73GB dry")
            report("  ⊙ Simulator data · 4.78GB · ~/Library/Developer/CoreSimulator/Devices")
            await gate.wait()
            return CleanTests.dryRun
        }
        #expect(previewer.progress == nil)
        #expect(CleanMenu.waiting(nil) == "Mole is starting its preview, which takes a minute or two; it keeps going if you close the menu.")
        let menu = Task { await previewer.preview() }
        try await Self.until { previewer.progress?.items == 2 }
        #expect(previewer.progress == CleanProgress(section: "Browsers", items: 2))
        #expect(CleanMenu.waiting(previewer.progress)
                == "Mole is checking Browsers, 2 items so far; it keeps going if you close the menu.")
        await gate.open()
        _ = await menu.value
        #expect(previewer.progress == nil, "a finished run has no progress")
    }

    @MainActor @Test("Closing the menu mid-run leaves Mole going: the run ends, is reported once and kept, and the next open reuses it")
    func survivesClose() async throws {
        let gate = Gate()
        var runs = 0
        var reports: [CleanPreview?] = []
        let previewer = CleanPreviewer(now: { .now }) { _ in
            runs += 1
            await gate.wait()
            return CleanTests.dryRun
        }
        previewer.onFinish = { reports.append($0) }
        let menu = Task { await previewer.preview() }
        let second = Task { await previewer.preview() }
        try await Self.until { previewer.progress != nil }
        menu.cancel()
        second.cancel()
        await gate.open()
        try await Self.until { previewer.ready != nil }
        #expect(reports.map { $0?.total } == ["28.75GB"], "one report for one run, with two menus having waited")
        #expect(await previewer.preview()?.total == "28.75GB")
        #expect(runs == 1)
    }

    @MainActor @Test("A failed run is reported too; a run dropped for a clean is not")
    func reportFailures() async throws {
        var reports: [CleanPreview?] = []
        let failing = CleanPreviewer(now: { .now }) { _ in nil }
        failing.onFinish = { reports.append($0) }
        #expect(await failing.preview() == nil)
        #expect(reports.count == 1 && reports[0] == nil)
        let gate = Gate()
        let dropped = CleanPreviewer(now: { .now }) { _ in
            await gate.wait()
            return CleanTests.dryRun
        }
        dropped.onFinish = { reports.append($0) }
        let menu = Task { await dropped.preview() }
        try await Self.until { dropped.progress != nil }
        dropped.drop()
        await gate.open()
        _ = await menu.value
        #expect(reports.count == 1)
        #expect(dropped.progress == nil && dropped.ready == nil)
    }

    @Test("When the preview ends with Clean not on screen, a tip says so; with Clean showing, the rows do")
    func tip() {
        let preview = CleanPreview.parse(CleanTests.dryRun)
        #expect(CleanMenu.tip(preview, showing: false) == "Mole's preview is ready: Clean 28.75GB in Pilot's menu")
        #expect(CleanMenu.tip(CleanPreview(items: [], total: nil, systemSkipped: false), showing: false)
                == "Mole's preview is ready: nothing to clean")
        #expect(CleanMenu.tip(nil, showing: false) == "Mole's preview did not finish; open Clean to try again")
        #expect(CleanMenu.tip(preview, showing: true) == nil)
        #expect(CleanMenu.tip(nil, showing: true) == nil, "the menu says it failed itself")
    }

    /// Holds a run until opened.
    @MainActor final class Gate {
        private var isOpen = false
        private var held: [CheckedContinuation<Void, Never>] = []
        func wait() async { if !isOpen { await withCheckedContinuation { held.append($0) } } }
        func open() async { isOpen = true; held.forEach { $0.resume() }; held = [] }
    }

    @MainActor static func until(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
