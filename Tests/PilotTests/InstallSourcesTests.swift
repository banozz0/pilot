import Foundation
import Testing
@testable import PilotCore
@testable import Pilot

/// Cards agent-bo-95422998 and agent-bo-95422989: a search row from the App Store, PyPI or npm, and an npm tool in
/// Remove, reach the same confirm step with the exact command, and nothing runs before Sven's yes. Confirm and the
/// terminal are fakes; nothing installs or uninstalls here.
@MainActor
@Suite("Install and remove from more sources")
struct InstallSourcesTests {
    @MainActor final class Record {
        var asked: [(title: String, command: String)] = [], ran: [(command: String, onSuccess: String)] = []
        var yes: (@MainActor () -> Void)?
        func confirm(_ title: String, _ command: String, _ yes: @escaping @MainActor () -> Void) { asked.append((title, command)); self.yes = yes }
        func run(_ command: String, _ title: String, _ onSuccess: String) { ran.append((command, onSuccess)) }
    }

    @Test("Return on an App Store, PyPI or npm row asks with its install command, titled with the row's name",
          arguments: [("mas:497799835", "Install Xcode", "mas get 497799835"), ("uv:httpie", "Install httpie", "uv tool install httpie"),
                      ("npm:@scope/cow", "Install @scope/cow", "npm install -g @scope/cow")])
    func install(key: String, title: String, command: String) {
        InstallSearch.titles.withLock { $0[key] = String(title.dropFirst("Install ".count)) }
        let record = Record()
        InstallModule.pick(key, confirm: record.confirm, run: record.run)
        #expect(record.asked.map(\.title) == [title])
        #expect(record.asked.map(\.command) == [command])
        #expect(record.ran.isEmpty, "nothing runs before the yes")
        record.yes?()
        #expect(record.ran.map(\.command) == [command])
        #expect(record.ran.map(\.onSuccess) == ["open -g 'pilot://installed?package=\(key)'"])
    }

    @Test("A helper's Install: a formula asks titled with the helper and records it; Homebrew waits for Return; none runs unasked", .pilotFocus)
    func helpers() {
        let record = Record()
        InstallModule.install(.npm, confirm: record.confirm, run: record.run, installed: ["homebrew"])
        #expect(record.asked.map(\.title) == ["Install npm"] && record.asked.map(\.command) == ["brew install node"])
        #expect(record.ran.isEmpty)
        record.yes?()
        #expect(record.ran.map(\.onSuccess) == ["open -g 'pilot://installed?package=formula:node'"])

        InstallModule.install(.homebrew, confirm: record.confirm, run: record.run, installed: [])
        #expect(record.asked.last?.title == "Install Homebrew" && record.asked.last?.command == Helper.homebrew.install)
        record.yes?()
        #expect(record.ran.last?.command == Helper.homebrew.install && record.ran.last?.onSuccess == VisibleRun.waitForReturn)

        // Installed, or a formula with no Homebrew: nothing is asked.
        InstallModule.install(.mole, confirm: record.confirm, run: record.run, installed: ["homebrew", "mole"])
        InstallModule.install(.cargo, confirm: record.confirm, run: record.run, installed: [])
        #expect(record.asked.count == 2 && record.ran.count == 2)
    }

    @Test("Return on a pipx, cargo or Go row asks with that tool's own command (N9)",
          arguments: [("pipx:httpie", "pipx install httpie"), ("cargo:ripgrep", "cargo install ripgrep"),
                      ("go:github.com/jesseduffield/lazygit", "go install github.com/jesseduffield/lazygit@latest")])
    func installTool(key: String, command: String) {
        let record = Record()
        InstallModule.pick(key, confirm: record.confirm, run: record.run)
        #expect(record.asked.map(\.command) == [command])
        #expect(record.ran.isEmpty)
    }

    @Test("A search's page opens with nothing asked or run; a GitHub release asks with its download and runs it only on yes (N9)")
    func pagesAndDownloads() {
        let record = Record()
        var opened: [URL] = []
        let store = URL(string: "macappstore://apps.apple.com/app/id6504484102")!
        InstallModule.pick("page:\(store.absoluteString)", confirm: record.confirm, run: record.run) { opened.append($0) }
        #expect(opened == [store])
        #expect(record.asked.isEmpty && record.ran.isEmpty)

        let asset = "https://github.com/rxhanson/Rectangle/releases/download/v2.0.3/Rectangle2.0.3.dmg"
        InstallSearch.titles.withLock { $0["asset:\(asset)"] = "Rectangle" }
        InstallModule.pick("asset:\(asset)", confirm: record.confirm, run: record.run) { opened.append($0) }
        let command = "curl -fL --progress-bar -o ~/Downloads/Rectangle2.0.3.dmg '\(asset)' && open ~/Downloads/Rectangle2.0.3.dmg"
        #expect(record.asked.map(\.title) == ["Install Rectangle"])
        #expect(record.asked.map(\.command) == [command])
        #expect(record.ran.isEmpty, "nothing runs before the yes")
        record.yes?()
        #expect(record.ran.map(\.command) == [command])

        // A page off the hosts Install opens is not a page: nothing opens.
        InstallModule.pick("page:https://evil.example/", confirm: record.confirm, run: record.run) { opened.append($0) }
        #expect(opened == [store])
    }

    @Test("Return on an npm tool asks with that tree's own npm, and uninstalls only on yes")
    func removeNPM() {
        let record = Record()
        InstallModule.remove(RemoveRow(source: .npm("sideshow", prefix: "/Users/s/.local"), name: "sideshow"),
                             confirm: record.confirm, run: record.run)
        let command = "'/Users/s/.local/bin/npm' uninstall -g --prefix '/Users/s/.local' sideshow"
        #expect(record.asked.map(\.title) == ["Remove sideshow"])
        #expect(record.asked.map(\.command) == [command])
        #expect(record.ran.isEmpty, "nothing runs before the yes")
        record.yes?()
        #expect(record.ran.map(\.command) == [command])
        #expect(record.ran.map(\.onSuccess) == ["open -g 'pilot://removed?package=npm:sideshow'"])
    }
}
