#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// GitHub checks, the CI widget (P79), opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-ci PILOT_RENDER_DIR=/tmp/pilot-renders-ci swift test --filter WidgetCIRenders`
/// - gh's answers parsed (passing, failing, running, none), the repos picked from the GitHub extension's setting and
///   ~/code's origins, then passing, failing and running rows at three sizes in each style, solid and glass, then a long
///   list that scrolls over its hidden count, all repos without runs, no repos and the preview before a read:
///   `widgets/ci.png`. No gh runs.
@MainActor
@Suite("Widget CI renders")
struct WidgetCIRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static func answer(_ status: String, _ conclusion: String, workflow: String = "CI", branch: String = "main") -> Data {
        Data(#"[{"status":"\#(status)","conclusion":"\#(conclusion)","workflowName":"\#(workflow)","headBranch":"\#(branch)","url":"https://github.com/o/r/actions/runs/1"}]"#.utf8)
    }

    @Test("The CI widget: gh's answers, the repos it picks, passing, failing and running rows, each style, solid and glass",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func ci() async throws {
        let dir = try WidgetRenders.dir()
        testApp()

        let passing = WidgetCI.run("example/pilot", answer: Self.answer("completed", "success"))
        let failing = WidgetCI.run("example/macroslip", answer: Self.answer("completed", "failure", workflow: "Build and test", branch: "feature/onboarding"))
        let running = WidgetCI.run("example/socialtools", answer: Self.answer("in_progress", "", workflow: "Deploy"))
        #expect(passing.state == .passing && passing.workflow == "CI" && passing.branch == "main")
        #expect(failing.state == .failing && running.state == .running)
        #expect(WidgetCI.run("example/x", answer: Data("[]".utf8)).problem == WidgetCI.noRuns)
        #expect(WidgetCI.run("example/x", answer: Data("nope".utf8)).problem != nil)

        #expect(WidgetCI.origin(config: "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:example/pilot.git\n") == "example/pilot")
        #expect(WidgetCI.origin(config: "[remote \"origin\"]\n\turl = https://github.com/maddada/gpui-component\n") == "maddada/gpui-component")
        #expect(WidgetCI.origin(config: "[remote \"origin\"]\n\turl = https://gitlab.com/a/b.git\n") == nil)
        let local = ["example/pilot", "example/agents", "someone/fork"]
        #expect(WidgetCI.pick(only: "", local: local) == ["example/agents", "example/pilot", "someone/fork"])
        #expect(WidgetCI.pick(only: "example, maddada/gpui-component", local: local) == ["example/agents", "example/pilot", "maddada/gpui-component"])

        // Repos with no Actions runs are left out, counted on a line under the list (T43); with none left, a line says so.
        let none = (1...20).map { WidgetCI.Run(repo: "example/quiet\($0)", problem: WidgetCI.noRuns) }
        let runs = [passing, none[0], failing, running, none[1], WidgetCI.Run(repo: "example/agents", problem: "gh signed out")]
        let rows = WidgetCI.blocks(runs)
        guard case .list(_, let items, _)? = rows.first else { Issue.record("no list: \(rows)"); return }
        guard case .note(let hidden)? = rows.last, rows.count == 2 else { Issue.record("no count line: \(rows)"); return }
        #expect(hidden.text == "2 repos with no Actions runs hidden")
        guard case .note(let empty)? = WidgetCI.blocks(Array(none.prefix(3))).first else { Issue.record("no empty line"); return }
        #expect(empty.text == "No GitHub Actions runs in your 3 repos")
        #expect(WidgetCI.blocks([passing]).count == 1)
        #expect(items.map(\.title) == ["macroslip · Build and test · feature/onboarding", "socialtools · Deploy · main", "agents", "pilot · CI · main"])
        #expect(items.map(\.icon) == ["🔴", "🟡", "⚪", "🟢"])
        #expect(items.map(\.subtitle) == ["failing", "running", "gh signed out", "passing"])

        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        look.themeID = "tokyo-night"
        let widget = try #require(ReadyWidgets.widget(ReadyWidgets.ci))
        #expect(widget.data == .ci && widget.draw == .blocks && widget.title == "GitHub checks")
        // A long list at the widget's own size: it scrolls, its foot fading, over the count line.
        let long = WidgetCI.blocks(runs + none + (1...12).map { WidgetCI.run("example/app\($0)", answer: Self.answer("completed", "success")) })
        let sizes = [Widget.Size(width: 240, height: 150), widget.size, Widget.Size(width: 360, height: 280)]
        var sheet: [NSBitmapImageRep] = []
        for style in PilotStyle.allCases {
            for glass in [false, true] {
                look.style = style; look.glass = glass
                let shown: [([Extension.Block], Widget.Size)] = sizes.map { (rows, $0) }
                    + [(long, widget.size), (WidgetCI.blocks(none), Widget.Size(width: 240, height: 150)),
                       (WidgetCI.blocks([]), Widget.Size(width: 240, height: 150)), (WidgetCI.preview(), Widget.Size(width: 240, height: 150))]
                let tiles = shown.map { blocks, size in
                    let model = WidgetTileModel()
                    model.title = widget.title; model.icon = widget.icon; model.blocks = blocks
                    return WidgetTile(model: model, look: look).frame(width: size.width, height: size.height)
                }
                let row = VStack(alignment: .leading, spacing: 10) {
                    Text("\(style.title) · \(glass ? "Glass" : "Solid")").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    HStack(alignment: .top, spacing: 24) { ForEach(tiles.indices, id: \.self) { tiles[$0] } }
                }
                .padding(24)
                .background(WidgetPreview.ground(look.theme))
                .styled(.hud).pilotTheme(look: look)
                sheet.append(try rendered(row))
            }
        }
        try WidgetRenders.stacked(sheet).write(to: dir.appending(path: "ci.png"))
    }
}
}
#endif
