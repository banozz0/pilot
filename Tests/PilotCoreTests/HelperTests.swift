import Foundation
import Testing
@testable import PilotCore

/// General's Helpers (Sven 2026-10-12): each helper is found in the folders Install looks in, never on PATH, and says
/// how it installs. The file system is a fake: a set of paths that are executable.
@Suite("Helpers")
struct HelperTests {
    static let home = NSHomeDirectory()

    @Test("A helper is installed when its command is in one of Install's folders; anywhere else, such as /usr/bin, is not")
    func detection() {
        let fake: Set<String> = ["/opt/homebrew/bin/brew", "\(Self.home)/.cargo/bin/cargo", "/usr/local/bin/mo", "/usr/bin/npm"]
        #expect(Helper.installed { fake.contains($0) } == ["homebrew", "cargo", "mole"])
        #expect(Helper.installed { _ in false }.isEmpty)
        #expect(Helper.installed { _ in true } == Set(Helper.all.map(\.id)))
        #expect(Helper.npm.path { $0 == "\(Self.home)/.local/bin/npm" } == "\(Self.home)/.local/bin/npm")
    }

    @Test("Homebrew runs its own installer, which asks for the password in the terminal; the rest are formulae that need it")
    func routes() {
        #expect(Helper.all.map(\.id) == ["homebrew", "mole", "mas", "npm", "cargo"])
        #expect(Helper.homebrew.package == nil)
        #expect(Helper.homebrew.install.hasPrefix("/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"))
        #expect([Helper.mole, .mas, .npm, .cargo].map(\.install) == ["brew install mole", "brew install mas", "brew install node", "brew install rust"])
        #expect(Helper.homebrew.step(installed: []) == .installer(Helper.homebrew.install))
        #expect(Helper.npm.step(installed: []) == .needsHomebrew, "a formula waits for Homebrew")
        #expect(Helper.npm.step(installed: ["homebrew"]) == .formula(Package(.formula, "node")!))
        #expect(Helper.mole.step(installed: ["mole"]) == .installed && Helper.homebrew.step(installed: ["homebrew"]) == .installed)
        #expect(Helper(key: "helper:npm") == .npm && Helper(key: "npm") == nil && Helper(key: "helper:yarn") == nil)
    }

    @Test("Install's search hint names the first missing helper that adds a source: Homebrew, then npm, then cargo; never Mole or mas")
    func searchHint() {
        #expect(Helper.searchHint(installed: []) == .homebrew)
        #expect(Helper.searchHint(installed: ["homebrew"]) == .npm)
        #expect(Helper.searchHint(installed: ["homebrew", "npm"]) == .cargo)
        #expect(Helper.searchHint(installed: ["homebrew", "npm", "cargo"]) == nil, "Mole and mas add no source")
    }
}
