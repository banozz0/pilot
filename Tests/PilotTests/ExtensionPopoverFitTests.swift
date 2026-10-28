import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The extension popover's fixes after build 20 (Sven 2026-10-10, SPEC story 165): a row's ⋯ is a native menu of its
/// actions, and a long chat keeps the popover inside the room under its item, its reply box and buttons on screen.
@MainActor
@Suite("Extension popover fit")
struct ExtensionPopoverFitTests {
    @Test("A row's ⋯ menu (BarMenu's plain one) lists every action by its label; a pick runs it once the menu has closed")
    func actionsMenu() async throws {
        var acted: [String] = []
        // The owner is the items' (weak) target, so it lives as long as the menu shows.
        let owner = BarMenu()
        let menu = owner.menu(["lazygit", "Copy"].map { title in (title, { acted.append(title) }) })
        #expect(menu.items.map(\.title) == ["lazygit", "Copy"])
        let item = menu.items[1]
        #expect(item.target === owner && item.action != nil)
        testApp()
        let sent = NSApp.sendAction(try #require(item.action), to: owner, from: item)
        #expect(sent)
        #expect(acted.isEmpty, "a pick waits for the menu's tracking to end")
        #expect(try await SystemSamplerTests.wait(seconds: 5) { acted == ["Copy"] })
    }

    /// A Ghostex chat as Sven had it: ten of his questions, ten long answers, then its reply box and buttons.
    static let chat: [Extension.Block] = {
        var messages: [Extension.Block.Chat.Message] = []
        for n in 0..<10 {
            messages.append(.init(role: .user, text: "Question \(n): what is left?", at: Date(timeIntervalSince1970: 1_791_638_000 + Double(n) * 60)))
            messages.append(.init(role: .tool, text: "ran 3 tools"))
            messages.append(.init(role: .assistant, text: String(repeating: "Answer \(n), a long line that wraps across the popover. ", count: 4)))
        }
        let ref: JSONValue = .object(["ref": .string("s1")])
        return [.chat(.init(messages: messages, working: true)),
                .input(.init(placeholder: "Reply to Dobby…", action: .init(kind: .run(command: "send", context: ref), title: "Queue"),
                             alt: .init(kind: .run(command: "send", context: ref), title: "Interrupt and send"))),
                .buttons([.init(kind: .run(command: "focus", context: ref), title: "Open in Ghostex"),
                          .init(kind: .run(command: "sleep", context: ref), title: "Sleep")])]
    }()

    /// The popover on `blocks` in a window never shown, refitted to its content as BarPanel's panel is, until it settles.
    static func fitted(_ blocks: [Extension.Block], room: CGFloat?, look: Look? = nil) async throws -> (NSWindow, CGSize) {
        let (dir, exts, storage) = try SurfacesV2Tests.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SurfacesV2Tests.popover(exts, storage: storage) { _, _ in .blocks(blocks) }
        await model.open()
        let item = ExtensionBar.Item(id: "surfaces-demo", title: "Ghostex", icon: "👻", hasPage: false, answer: nil, problem: nil)
        let popover = ExtensionPopoverView(item: item, model: model).environment(\.barPopoverRoom, room)
        let view: AnyView = if let look { AnyView(popover.styled(.barPopovers, look: look).pilotTheme(look: look).fixedSize()) }
                            else { AnyView(popover.fixedSize()) }
        testApp()
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<8 {
            PanelTestSupport.pump(0.1)
            window.setContentSize(host.fittingSize)
        }
        return (window, host.fittingSize)
    }

    @Test("A long chat's popover is 460 wide and keeps inside its room, the chat scrolling; without a room it runs on past it")
    func longChatFits() async throws {
        let (capped, size) = try await Self.fitted(Self.chat, room: 520)
        defer { capped.close() }
        #expect(size.width == ExtensionPopoverView.chatWidth)
        #expect(size.height <= 520 && size.height > 400, "fills its room, no more: \(size.height)")
        let (free, tall) = try await Self.fitted(Self.chat, room: nil)
        defer { free.close() }
        #expect(tall.height > 1000, "the same chat uncapped: \(tall.height)")
        let (short, list) = try await Self.fitted([.markdown("Nothing waits.")], room: 520)
        defer { short.close() }
        #expect(list.width == ExtensionPopoverView.width && list.height < 200, "a short answer keeps its own size")
    }
}

#if DEBUG
/// Opt-in, on the shared look:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter ExtensionPopoverFitRenders`
extension SharedLook {
@MainActor
@Suite("Extension popover fit renders")
struct ExtensionPopoverFitRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The long chat's popover in a 560 pt room renders in every style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let out = try SharedLook.SurfacesV2Renders.out()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        look.glass = false
        defer { (look.themeID, look.style, look.glass) = saved }
        for (style, theme) in SharedLook.SurfacesV2Renders.styles {
            (look.themeID, look.style) = (theme, style)
            let (window, _) = try await ExtensionPopoverFitTests.fitted(ExtensionPopoverFitTests.chat, room: 560, look: look)
            defer { window.close() }
            let host = try #require(window.contentView)
            host.layoutSubtreeIfNeeded()
            try #require(snapshot(host, scale: 2)?.representation(using: .png, properties: [:]))
                .write(to: out.appendingPathComponent("popover-long-chat-\(style.rawValue).png"))
        }
    }
}
}
#endif
