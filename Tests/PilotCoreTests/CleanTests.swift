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

    /// Cut from `mo clean --dry-run < /dev/null` on Sven's Mac, Mole 1.72.0, 2026-11-17: items are marked `○`, not `→`,
    /// and the total is "size · N items" (whitelist line left out, the home folder as ~).
    static let dryRun172 = """
    ◎ System caches need sudo, run sudo -v && mo clean --dry-run for full preview

    ⚙ Apple Silicon | Free space: 83.87GB

    ➤ User essentials
      ○ User app cache · 9 items, 1.39GB dry
      ○ User app logs · 12KB dry

    ➤ Browsers
      ○ Chrome Service Worker, would clean 230.6MB, 0 protected

    ➤ Cloud & Office
      ✓ Nothing to clean

    ➤ Developer tools
      ○ npm cache · would clean
      ⊙ Rust toolchains · 3 · 1.95.0 and 1.99.1 besides stable · ~/.rustup/toolchains
      ◎ Project caches · skipped 1 slow/incomplete root scan
      ○ Zig cache · 6 items, 291.1MB dry
      ◎ Simulator caches · skipped (process state unknown)

    ➤ Large files
      ⊙ Gradle caches · 5.29GB · ~/.gradle/caches


    ======================================================================
    Dry run complete - no changes made
    Potential space: 2.09GB · 212 items
    Detailed file list: ~/.config/mole/clean-list.txt
    ======================================================================
    """

    @Test("Mole 1.72's ○ items read like 1.54's →, review and skipped lines still left out, and the total is the size alone")
    func parse172() {
        let preview = CleanPreview.parse(Self.dryRun172)
        #expect(preview.items.map(\.title) == ["User app cache", "User app logs", "Chrome Service Worker", "npm cache", "Zig cache"])
        #expect(preview.items.map(\.detail) == ["9 items, 1.39GB", "12KB", "would clean 230.6MB, 0 protected", "would clean",
                                                "6 items, 291.1MB"])
        #expect(preview.items.map(\.section) == ["User essentials", "User essentials", "Browsers", "Developer tools", "Developer tools"])
        #expect(preview.total == "2.09GB")
        #expect(preview.systemSkipped)
        var progress = CleanProgress()
        Self.dryRun172.split(whereSeparator: \.isNewline).forEach { progress.read(String($0)) }
        #expect(progress == CleanProgress(section: "Large files", items: 5))
        // Its file list (W89): each path under its part with Mole's decimal size; one counted under another, the Trash's
        // items and a pattern are left out.
        let list = CleanList.parse("""
        # Mole Cleanup Preview - 2026-11-21 10:00:00
        #   /Users/*/Library/Caches/com.example.app

        === User essentials ===
        /Users/me/Library/Caches/Foo  # 57.9MB, 12 items
        /Users/me/Library/Caches/Foo/Sub  # 1.0MB, counted under /Users/me/Library/Caches/Foo
        /Users/me/.Trash/old.zip  # 4KB
        /Users/me/Library/Logs/*.log  # 1KB

        === Developer tools ===
        /Users/me/Library/Developer/Xcode/DerivedData/App-x  # 1.02GB
        /Users/me/Library/Caches/Bar  # size unknown
        """, home: "/Users/me")
        #expect(list.parts.map(\.name) == ["User essentials", "Developer tools"])
        #expect(list.rows.map(\.path) == ["/Users/me/Library/Caches/Foo", "/Users/me/Library/Developer/Xcode/DerivedData/App-x", "/Users/me/Library/Caches/Bar"])
        #expect(list.rows.map(\.bytes) == [57_900_000, 1_020_000_000, nil] && list.rows[0].count == 12)
        #expect(list.parts[1].bytes == 1_020_000_000 && list.rows[2].size == "size unknown")
        #expect(list.rows[0].id == CleanList.id("/Users/me/Library/Caches/Foo") && list.rows[0].id.count == 10)
        #expect(list.rows([list.rows[1].id, "0000000000"]) == [list.rows[1]])
        #expect(list.without([list.rows[0].id]).parts.map(\.name) == ["Developer tools"])
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
        // Each part opens to Mole's lines for it (Mole records a path's section, never its line), then its paths (W89).
        #expect(rows.first { $0.title == "User app cache" }?.detail == "41 items, 13.53GB")
        #expect(rows.first { $0.title == "User app cache" }?.home == CleanMenu.part("User essentials"))
        #expect(rows.filter { $0.home == .clean }.compactMap { if case .branch(let b) = $0.target { b.title } else { nil } }
                == ["User essentials", "Browsers", "Developer tools"])
        #expect(rows.first { $0.target == .branch(CleanMenu.part("Browsers")) }?.detail == "Chrome cache, Chrome Service Worker · not listed one by one")
        #expect(rows.contains { $0.target == .clean(.unlisted("Browsers")) })
        #expect(rows.contains { $0.target == .clean(.note(7)) && $0.title.contains("System caches") })
        // The target is the row's id in the list, so no two rows share one, Mole's repeated titles included.
        #expect(Set(rows.map(\.id)).count == rows.count)
        let repeated = CleanPreview.parse("➤ Developer tools\n  → Obsolete VS Code extension · 235.3MB dry\n  → Obsolete VS Code extension · 4.7MB dry\n")
        let twice = CleanMenu.entries(repeated, mole: true)
        #expect(Set(twice.map(\.id)).count == twice.count)
        #expect(rows.suffix(2).map(\.title) == ["Disk usage", "Reports"])
        #expect(rows.suffix(2).map(\.target) == [.clean(.analyze), .clean(.reports)])
        #expect(rows.allSatisfy { $0.home?.browsed == .clean && !$0.inSearch })
        // With its file list: each part's paths biggest first with a tick; an untick shows on the part and splits Clean in two.
        var listed = CleanPreview.parse(Self.dryRun)
        listed.list = CleanList.parse("=== User essentials ===\n/Users/me/Library/Caches/A  # 1.0MB\n/Users/me/Library/Caches/B  # 3.0MB, 4 items\n",
                                      home: "/Users/me")
        let b = CleanList.id("/Users/me/Library/Caches/B")
        let all = CleanMenu.entries(listed, mole: true, home: "/Users/me")
        #expect(all.filter { $0.home == CleanMenu.part("User essentials") }.map(\.title)
                == ["User app cache", "User app logs", "Trash", "~/Library/Caches/B", "~/Library/Caches/A"])
        #expect(all.first { $0.target == .clean(.path(b)) }?.detail == "4 items · 3 MB")
        let off = CleanMenu.entries(listed, mole: true, unticked: [b], home: "/Users/me")
        #expect(off.prefix(2).map(\.target) == [.clean(.ticked), .clean(.run)])
        #expect(off.prefix(2).map(\.title) == ["Clean ticked 1 MB", "Clean all 28.75GB"])
        #expect(off.first { $0.target == .branch(CleanMenu.part("User essentials")) }?.detail
                == "User app cache, User app logs, Trash · 1 of 2 ticked, 1 MB")
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
        // A tick unticked in the menu holds until the kept preview goes; then every path is ticked again.
        previewer.toggle("0000000001")
        #expect(previewer.unticked == ["0000000001"])
        previewer.drop()
        #expect(previewer.ready == nil && previewer.unticked.isEmpty)
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
