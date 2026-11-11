#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
import WebKit
@testable import Pilot

/// Apps › Repos and General's Developer switch (Pilot 1.0.2, Q715, Q716), opt-in like the other renders: fixture repos made
/// in the moved home (one real repo with a commit, a worktree, `_tools` and `oss`, which the list leaves out), the list,
/// the tree with a Swift file and with the README's source, and the filter, in Toybox and Instrument; then the window on
/// Repos and on General, the switch on, at Glass on and off; then the README rendered (MarkdownPreview, through WebKit's
/// own snapshot, as a page render draws no web view): a header in HTML as Pilot's README has, a table, a local image and
/// a remote one as its alt text. Nothing under the real ~/code is read.
/// `CFFIXED_USER_HOME=/tmp/<fresh> PILOT_RENDER_DIR=/tmp/<fresh> PILOT_RESOURCES=Packaging swift test --filter ReposPageRenders`
extension SharedLook {
@MainActor
@Suite("Repos page renders")
struct ReposPageRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Repos and the Developer switch render in both styles", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to read ~/code")
        // The seed replaces <home>/code: only ever under /tmp, never a real home.
        try #require(home.hasPrefix("/tmp/"), "CFFIXED_USER_HOME must be a fresh folder under /tmp")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("repos")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let homeURL = URL(fileURLWithPath: home)
        try Self.seed(homeURL)
        let toml = homeURL.appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml.path) { FileManager.default.createFile(atPath: toml.path, contents: Data()) }

        let engine = try SharedLook.HomeRenders.engine()
        engine.settings.developer = true
        let look = Look.shared
        look.themeID = Self.env["PILOT_RENDER_THEME"] ?? "tokyo-night"
        defer { look.themeID = PilotTheme.defaultID; look.style = .instrument; look.glass = true }

        func page(_ name: String, _ start: ReposPage.Start, height: CGFloat = 860) throws {
            for (suffix, style) in [("toybox", PilotStyle.toybox), ("instrument", .instrument)] {
                look.style = style
                let host = NSHostingView(rootView: Ground { ReposPage(start: start) }.styled(.page(.repos)).pilotTheme().environment(engine))
                host.frame.size = NSSize(width: 1160, height: height)
                RunLoop.main.run(until: Date().addingTimeInterval(1.2))
                host.layoutSubtreeIfNeeded()
                try #require(snapshot(host, scale: 2)?.representation(using: .png, properties: [:]))
                    .write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
        // The subjects as `git log -1 --format=%s` gave them for the fixture; beta has no commit.
        let subjects = ["alpha": "app: greet by name"]
        let alpha = ReposPage.Start(home: homeURL, repo: "alpha", open: ["Sources", "Sources/App"], subjects: subjects)
        try page("list", .init(home: homeURL, subjects: subjects), height: 480)
        try page("tree-text", { var s = alpha; s.file = "Sources/App/main.swift"; return s }())
        try page("tree-markdown-source", { var s = alpha; s.file = "README.md"; s.source = true; return s }())
        try page("filter", { var s = alpha; s.query = "swift"; s.file = "Package.swift"; return s }())

        // The window: Repos listed under Apps with the switch on, and General's Data block with the switch, Glass on and off.
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        for (place, name, height) in [(AppPlace(.repos), "window-repos", 900), (AppPlace(.general), "window-general", 1300)] {
            for (suffix, style, glass) in [("toybox", PilotStyle.toybox, true), ("instrument-glass", .instrument, true), ("instrument-solid", .instrument, false)] {
                look.style = style
                look.glass = glass
                window.setContentSize(NSSize(width: 1440, height: height))
                model.go(place)
                RunLoop.main.run(until: Date().addingTimeInterval(1.0))
                frame.layoutSubtreeIfNeeded()
                try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:]))
                    .write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
    }

    @Test("The README renders as GitHub shows it, in both styles", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func readme() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home && home.hasPrefix("/tmp/"), "CFFIXED_USER_HOME must be a fresh folder under /tmp")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("repos")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let homeURL = URL(fileURLWithPath: home)
        try Self.seed(homeURL)
        let repo = homeURL.appendingPathComponent("code/alpha"), readme = repo.appendingPathComponent("README.md")
        let skill = homeURL.appendingPathComponent(".claude/skills/review/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nname: review\ndescription: A strict PASS or REJECT on finished work\n---\n\n# Review\n\n1. Read the diff.\n2. Say **PASS** or **REJECT**.\n".utf8).write(to: skill)
        // A look of its own: this test awaits the page, and Look.shared's style moved meanwhile would redraw other suites'.
        let (look, _) = LookPageTests().look()
        for (name, file, root, height) in [("readme", readme, repo, 1500.0), ("skill", skill, skill.deletingLastPathComponent(), 360)] {
            for (suffix, style) in [("toybox", PilotStyle.toybox), ("instrument", .instrument)] {
                look.style = style
                let text = try String(contentsOf: file, encoding: .utf8)
                let host = NSHostingView(rootView: Ground { MarkdownPreview(text: text, file: file, root: root, showsSource: .constant(false)) { EmptyView() } }.styled(.page(.repos), look: look).pilotTheme(look: look))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                func web(_ view: NSView) -> WKWebView? { view as? WKWebView ?? view.subviews.lazy.compactMap(web).first }
                let page = try #require(web(host), "no web view in the preview")
                for _ in 0..<100 where page.isLoading || page.url == nil { try await Task.sleep(for: .milliseconds(50)) }
                try await Task.sleep(for: .milliseconds(400))
                let config = WKSnapshotConfiguration()
                config.rect = page.bounds
                let image = try await page.takeSnapshot(configuration: config)
                // The page draws no ground of its own (the pane shows through it): the snapshot goes on the style's.
                let ground = NSColor(Ink(style: StyleTokens.of(look.style, theme: look.theme)).background)
                let laid = NSImage(size: image.size, flipped: false) { rect in ground.setFill(); rect.fill(); image.draw(in: rect); return true }
                let rep = try #require(laid.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name)-rendered-\(suffix).png"))
            }
        }
    }

    /// ~/code in the moved home: alpha, a repo with one commit, Sources, a README, an image, a binary and a node_modules the
    /// tree hides; beta, a repo with no commit; a worktree whose .git is a file; and `_tools` and `oss`, never listed.
    static func seed(_ home: URL) throws {
        let code = home.appendingPathComponent("code"), fm = FileManager.default
        if fm.fileExists(atPath: code.path) { try fm.removeItem(at: code) }
        func write(_ path: String, _ text: String) throws {
            let url = code.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        // A header in HTML and a table, as Pilot's own README has (Sven, build 8: it showed as raw HTML and pipes).
        try write("alpha/README.md", """
            <h1 align="center">Alpha</h1>

            <p align="center"><img src="site/logo.png" width="72" alt="Alpha's logo"></p>

            <p align="center"><b>A small fixture repo for the Repos page.</b></p>

            <p align="center">
            <a href="https://example.com/alpha.dmg"><b>Download Alpha.dmg</b></a>
            &nbsp;·&nbsp; <a href="https://example.com">Website</a> &nbsp;·&nbsp; macOS 27+<br>
            <sub>Free, MIT</sub> <img src="https://img.shields.io/badge/build-passing-green.svg" alt="build passing">
            </p>

            ## What it holds

            | | Part | What it is | Key |
            |---|---|---|---|
            | ⌨️ | [Entry point](Sources/App/main.swift) | `Sources/App/main.swift`, which **greets** whoever runs it. | `swift run` |
            | 🧪 | Tests | One suite, *empty* for now. | |

            - [x] A picture and a binary
            - [ ] A release

            > [!NOTE]
            > Pilot never writes into a repo.

            ```sh
            swift run alpha
            ```

            <details>
            <summary>Building from source</summary>

            Run `swift build`, then `swift run alpha Sven`.

            </details>

            <script>document.body.innerHTML = "scripts never run"</script>
            """)
        try write("alpha/Package.swift", "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"alpha\", targets: [.executableTarget(name: \"App\", path: \"Sources/App\")])\n")
        try write("alpha/Sources/App/main.swift", (["import Foundation", "", "/// Greets whoever runs it.", "struct Greeter {",
                                                     "    let name: String", "", "    func line() -> String { \"Hello, \\(name)!\" }", "}", "",
                                                     "let greeter = Greeter(name: CommandLine.arguments.dropFirst().first ?? \"world\")",
                                                     "print(greeter.line())"] + (1...30).map { "// line \($0) of the fixture's padding" })
            .joined(separator: "\n") + "\n")
        try write("alpha/Sources/App/Util.swift", "extension String {\n    var shouted: String { uppercased() + \"!\" }\n}\n")
        try write("alpha/.gitignore", ".build/\nnode_modules\n*.log\n")
        try write("alpha/node_modules/left-pad/index.js", "module.exports = s => s\n")
        try write("alpha/Tests/AppTests/GreeterTests.swift", "import Testing\n")
        try Data([0, 1, 2, 3, 0, 255]).write(to: code.appendingPathComponent("alpha/data.bin"))
        try logo(code.appendingPathComponent("alpha/site/logo.png"))
        try write("beta/notes.txt", "Nothing committed yet.\n")
        try write("_tools/zig/README", "not a repo\n")
        try write("oss/ghostty/README.md", "upstream\n")
        try fm.createDirectory(at: code.appendingPathComponent("oss/ghostty/.git"), withIntermediateDirectories: true)
        try write("alpha-wt/.git", "gitdir: ../alpha/.git/worktrees/alpha-wt\n")
        try git(["init", "-q", "-b", "main"], in: code.appendingPathComponent("alpha"), home: home)
        try git(["add", "-A"], in: code.appendingPathComponent("alpha"), home: home)
        try git(["commit", "-q", "-m", "app: greet by name"], in: code.appendingPathComponent("alpha"), home: home)
        try git(["init", "-q", "-b", "draft"], in: code.appendingPathComponent("beta"), home: home)
    }

    /// A 144 pt rounded square in the accent's blue with an A, the README's local image.
    static func logo(_ url: URL) throws {
        let image = NSImage(size: NSSize(width: 144, height: 144), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 32, yRadius: 32).fill()
            let words = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: 88, weight: .bold), .foregroundColor: NSColor.white])
            words.draw(at: NSPoint(x: (rect.width - words.size().width) / 2, y: (rect.height - words.size().height) / 2))
            return true
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// git on the fixture alone: the moved home, no global or system config (so none of Sven's hooks or settings).
    static func git(_ arguments: [String], in folder: URL, home: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", folder.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "core.hooksPath=/dev/null",
                       "-c", "commit.gpgsign=false"] + arguments
        p.environment = ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0, "git \(arguments.joined(separator: " ")) exited \(p.terminationStatus)")
    }
}
}

/// The page on the window's ground, as the window draws it.
private struct Ground<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.styleLayout().background(ink.background) }
}
#endif
