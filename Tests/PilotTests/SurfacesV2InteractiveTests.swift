import Foundation
import PilotCore
import Synchronization
import Testing
@testable import Pilot

/// Surfaces v2, P3 in Pilot (SPEC story 165): a view's `refresh` asks again only while its view shows, with its context;
/// the fixture's chat takes a reply typed in its input, its asks answer as `input`, and every run carries Pilot's
/// defaults; a page's push opens its pane.
@MainActor
@Suite("Surfaces v2 interactive")
struct SurfacesV2InteractiveTests {
    @Test("A view asking a refresh is asked again with its context while its keep-fresh task runs, and never once it ends; one asking none is not")
    func keepFresh() async throws {
        let (dir, exts, storage) = try SurfacesV2Tests.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asked = Mutex<[JSONValue?]>([])
        let model = SurfacesV2Tests.popover(exts, storage: storage) { command, context in
            guard command == "chat" else { return .blocks([.markdown("bar")]) }
            asked.withLock { $0.append(context) }
            return .blocks([.markdown("chat")], refresh: 2)
        }
        await model.open()
        #expect(model.top.refresh == nil)
        await model.keepFresh(sleep: { _ in Issue.record("a view asking no refresh slept") })
        let ref: JSONValue = .object(["ref": .string("s1")])
        await model.push("chat", title: "Reply", context: ref)
        #expect(model.top.refresh == 2 && model.pace == .init(depth: 2, command: "chat", every: 2))
        let slept = Mutex<[Duration]>([])
        let loop = Task {
            await model.keepFresh(sleep: { every in
                slept.withLock { $0.append(every) }
                try await Task.sleep(for: .milliseconds(10))
            })
        }
        #expect(try await SystemSamplerTests.wait { asked.withLock { $0.count } >= 4 })
        loop.cancel()
        await loop.value
        let after = asked.withLock { $0.count }
        try await Task.sleep(for: .milliseconds(100))
        #expect(asked.withLock { $0.count } == after, "closed: no more asks")
        #expect(asked.withLock { $0 }.allSatisfy { $0 == ref } && slept.withLock { $0 }.allSatisfy { $0 == .seconds(2) })
    }

    @Test("The fixture end to end: its chat answers a chat, an input and refresh 2; the reply typed goes as input with Pilot's defaults, and the chat shows it")
    func fixtureChat() async throws {
        let (dir, exts, storage) = try SurfacesV2Tests.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try #require(Extension.find(in: exts).extensions.first)
        let inputs = try #require(await ExtensionsModule.inputs(for: ext, storage: storage, hud: { _ in }))
        #expect(inputs.pilot["repos"] == PilotFolders.shared.repos && inputs.pilot["terminal"]?.isEmpty == false
                && inputs.pilot["blocks"] == Extension.Block.kinds.joined(separator: ",")
                && inputs.pilot["icons"]?.split(separator: ",").contains("cloud.sun") == true && inputs.pilot.count == 4)
        let chat = try #require(ext.noView("chat")), ref: JSONValue = .object(["ref": .string("s1")])
        guard case .blocks(let blocks, let every) = await ExtensionRun.blocks(chat, surface: .popover, context: ref, inputs: inputs, timeout: .seconds(10)),
              case .chat(let before) = blocks.first, case .input(let input) = blocks.last else { Issue.record("no chat and input"); return }
        #expect(every == 2 && before.shown.map(\.role) == [.user, .tool, .assistant])
        let send = try #require(input.submit("Ship it", alt: true))
        guard case .run(let name, let context) = send.kind else { Issue.record("not a run"); return }
        let sendCommand = try #require(ext.noView(name))
        let ran = await ExtensionRun.noView(sendCommand, context: context, input: send.input, inputs: inputs, timeout: .seconds(10))
        #expect(ran == .hud("Sent to s1"))
        guard case .blocks(let again, _) = await ExtensionRun.blocks(chat, surface: .popover, context: ref, inputs: inputs, timeout: .seconds(10)),
              case .chat(let after) = again.first else { Issue.record("no chat"); return }
        #expect(after.messages.suffix(2).map(\.text) == ["Ship it", "Got it (interrupting). Repos: \(PilotFolders.shared.repos)"])
    }

    @Test("The fixture's asks: a rename sends the text, a tag the choice's value, a close nothing extra")
    func fixtureAsks() async throws {
        let (dir, exts, storage) = try SurfacesV2Tests.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try #require(Extension.find(in: exts).extensions.first)
        let inputs = try #require(await ExtensionsModule.inputs(for: ext, storage: storage, hud: { _ in }))
        guard case .blocks(let blocks, _) = await ExtensionRun.blocks(try #require(ext.bar).command, surface: .popover, inputs: inputs, timeout: .seconds(10)) else {
            Issue.record("no popover"); return
        }
        guard let rows = blocks.lazy.compactMap({ if case .list(_, let items, _) = $0 { items } else { nil } }).first else { Issue.record("no list"); return }
        let row = try #require(rows.first)
        #expect(row.badges == [.init(text: "idle"), .init(text: "review", tone: .fine)] && row.inline.map(\.icon) == ["bubble", "moon"])
        func ran(_ action: Extension.Item.Action) async throws -> ExtensionRun.Outcome {
            guard case .run(let name, let context) = action.kind else { throw CancellationError() }
            let command = try #require(ext.noView(name))
            return await ExtensionRun.noView(command, context: context, input: action.input, inputs: inputs, timeout: .seconds(10))
        }
        func asking(_ title: String) throws -> Extension.Asking {
            let action = try #require(row.actions.first { $0.title == title })
            return try #require(Extension.Asking(action))
        }
        var rename = try asking("Rename…")
        #expect(rename.text == "Pilot coordinator 2")
        rename.text = "Coordinator"
        let renamed = try #require(rename.save())
        #expect(try await ran(renamed) == .hud("rename s1: Coordinator"))
        let tag = try asking("Tag")
        guard case .choices(let choices) = tag.ask else { Issue.record("no choices"); return }
        #expect(try await ran(tag.pick(choices[1])) == .hud("tag s1: none"))
        let close = try asking("Close…")
        #expect(close.yes == "Close" && close.action.destructive)
        let confirmed = try #require(close.save())
        #expect(try await ran(confirmed) == .hud("close s1: confirmed"))
    }

    @Test("A page follows its answer's refresh over its manifest's pace; a push opens the pane with its context, asked as a page, its actions the page's")
    func pagePane() async throws {
        let (dir, exts, storage) = try SurfacesV2Tests.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = ExtensionPageModel(id: "surfaces-demo", folder: exts, storage: storage, run: { _, _ in .blocks([.markdown("page")], refresh: 30) })
        await page.refresh()
        #expect(page.every == 30 && page.ext?.page?.every == 60)
        // Inside its manifest's pace a refresh asks only the command; Refresh reads the folder again.
        try FileManager.default.removeItem(at: exts.appending(path: "surfaces-demo"))
        await page.refresh()
        #expect(!page.gone && page.blocks == [.markdown("page")])
        await page.refresh(reread: true)
        #expect(page.gone)
        try FileManager.default.copyItem(at: SurfacesV2Tests.fixture, to: exts.appending(path: "surfaces-demo"))
        await page.refresh(reread: true)
        let asked = Mutex<[String]>([])
        var acted: [String] = []
        await page.open("chat", title: "Reply", context: .object(["ref": .string("s2")]), act: { action, _, _ in acted.append(action.label); return nil }) { command, context, _ in
            asked.withLock { $0.append("\(command.name) \(context.map { "\($0)" } ?? "-")") }
            return .blocks([.markdown("chat")], refresh: 2)
        }
        let pane = try #require(page.pane)
        #expect(pane.top.blocks == [.markdown("chat")] && pane.top.title == "Reply" && pane.top.refresh == 2 && !pane.canGoBack)
        #expect(asked.withLock { $0 } == [#"chat object(["ref": PilotCore.JSONValue.string("s2")])"#])
        pane.perform(.copy("x"))
        #expect(acted == ["Copy"])
        pane.perform(Extension.Item.Action(kind: .push(command: "send", context: nil), title: "Deeper"))
        #expect(try await SystemSamplerTests.wait { pane.canGoBack }, "a push in the pane stacks with a back")
        page.pane = nil
    }
}
