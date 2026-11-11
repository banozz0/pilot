import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// An extension's detail in the menu's panel (card agent-bo-95423245), measured without a screen: hosted offscreen in a
/// borderless window never ordered in, its drawn size read through a GeometryReader in an overlay (from behind, a
/// ForEach never delivers it), its two scrolls read off the hosting view.
@MainActor
@Suite("Extension detail view")
struct ExtensionDetailViewTests {
    /// A heading, a paragraph with inline code, a list, a fenced block; three facts; two actions.
    static let detail = Extension.Detail(
        markdown: """
            # Fix the tap's stall on a secure field

            The tap stops seeing keys while a password field has focus: `CGEventTap` reports **secure input**, and Pilot
            says so rather than working round it.

            ## Steps

            - Focus a password field in Safari
            - Press `Hyper+Space` and watch the log

            ```bash
            swift test --filter 'Tap|SecureInput' 2>&1 | tee /tmp/pilot-tap-secure-input-run-with-a-long-unbroken-line.log
            ```
            """,
        metadata: [.init(label: "Status", text: "Open"), .init(label: "Author", text: "banozz"),
                   .init(label: "Branch", text: "ghostex/fa8c45f8-secure-input-tap-stall")],
        actions: [.open("https://github.com/example/repo/pull/42"), Extension.Item.Action(kind: .copy("#42"), title: "Copy PR Number")])

    /// AI usage's detail as blocks (pilot-1-1 T5's drawing hD): two sections of meters, its facts beside them.
    static let blocksDetail = Extension.Detail(
        markdown: "",
        metadata: [.init(label: "Pace", text: "8% ahead"), .init(label: "Today", text: "1.2M tokens"), .init(label: "Reset credits", text: "2 left")],
        actions: [Extension.Item.Action(kind: .copy("Session 66% left"), title: "Copy summary")],
        blocks: [.section(title: "Claude", subtitle: nil, asideNote: "Max", blocks: [
                    .meter(.init(label: "Session", percent: 66, note: "66% left · 21:10")),
                    .meter(.init(label: "Week · all models", percent: 39, note: "39% left · Mon 09:00"))]),
                 .section(title: "Codex", subtitle: nil, asideNote: "Plus", blocks: [
                    .meter(.init(label: "5 hours", percent: 80, note: "80% left · 22:40")),
                    .meter(.init(label: "Week", percent: 71, note: "71% left · Tue"))])])

    /// The detail as a live picker's one row, as ExtensionRun.detail makes it.
    static func row(_ detail: Extension.Detail = detail) -> MenuEntry {
        var row = MenuEntry(title: "Pull request", target: .action("ext.github.pr#0"), isAnswer: true)
        row.ownActions = detail.actions.map(\.label)
        row.extensionDetail = detail
        return row
    }

    static func liveNav(_ rows: [MenuEntry]) -> MenuNavigator {
        var nav = MenuNavigator(list: [], title: "GitHub", live: true)
        nav.replaceList(rows)
        return nav
    }

    @Test("The markdown splits into headings, paragraphs joined as CommonMark joins them, list items and fenced code")
    func blocks() {
        #expect(DetailBlock.split(Self.detail.markdown) == [
            .heading(level: 1, text: "Fix the tap's stall on a secure field"),
            .paragraph("The tap stops seeing keys while a password field has focus: `CGEventTap` reports **secure input**, and Pilot says so rather than working round it."),
            .heading(level: 2, text: "Steps"),
            .item(marker: "•", text: "Focus a password field in Safari"),
            .item(marker: "•", text: "Press `Hyper+Space` and watch the log"),
            .code("swift test --filter 'Tap|SecureInput' 2>&1 | tee /tmp/pilot-tap-secure-input-run-with-a-long-unbroken-line.log"),
        ])
        #expect(DetailBlock.split("### Deep ###\n1. one\n   carried on\n2) two\n\n---\nhard  \nbreak\\\nend\n#not a heading") == [
            .heading(level: 3, text: "Deep"), .item(marker: "1.", text: "one carried on"), .item(marker: "2.", text: "two"), .rule,
            .paragraph("hard\nbreak\nend #not a heading"),
        ])
        #expect(DetailBlock.split("").isEmpty)
    }

    /// The drawn size, as the view's own overlay reports it.
    struct Drawn: PreferenceKey {
        static let defaultValue = CGSize.zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
    }

    final class Box { var size = CGSize.zero }

    /// `view` reporting its drawn size into `box`.
    static func measured(_ view: some View, _ box: Box) -> some View {
        view.overlay { GeometryReader { Color.clear.preference(key: Drawn.self, value: $0.size) } }
            .onPreferenceChange(Drawn.self) { size in MainActor.assumeIsolated { box.size = size } }
    }

    @Test("Hosted at Instrument's wide panel's size it draws whole: the words beside the facts, neither spilling sideways")
    func fitsThePanel() throws {
        testApp()
        let panel = MenuPanelSize.instrument(.wide, rows: 0, headings: 0, full: true)
        // The room between the 58 pt search line and the 42 pt foot.
        let room = CGSize(width: panel.width, height: panel.height - MenuPanelSize.s(58) - MenuPanelSize.s(42))
        let box = Box()
        let (window, host) = Self.host(Self.measured(ExtensionDetailView(detail: Self.detail), box), room)
        defer { window.close() }
        AliasesListTests.until { box.size != .zero && SharedLook.MenuScrollTests.scrollViews(in: host).count == 2 }

        #expect(box.size.width > 0 && box.size.height > 0, "drew nothing: \(box.size)")
        #expect(box.size.width <= room.width && box.size.height <= room.height, "\(box.size) in \(room)")

        // The words' scroll and the facts', side by side across the panel, the facts' at their column's width.
        let columns = SharedLook.MenuScrollTests.scrollViews(in: host).map { (frame: $0.convert($0.bounds, to: host), scroll: $0) }
            .sorted { $0.frame.minX < $1.frame.minX }
        try #require(columns.count == 2, "\(columns.map(\.frame))")
        let documents = try columns.map { try #require($0.scroll.documentView) }
        let (words, facts) = (columns[0].frame, columns[1].frame)
        #expect(abs(facts.width - ExtensionDetailView.factsWidth) < 0.5, "facts \(facts)")
        #expect(words.maxX <= facts.minX, "the words \(words) run under the facts \(facts)")
        #expect(words.minX >= 0 && facts.maxX <= room.width + 0.5, "\(words) \(facts) in \(room)")
        for (column, document) in zip(columns, documents) {
            // Nothing wider than its column: a long code line or value wraps instead.
            #expect(document.frame.width <= column.frame.width + 0.5, "spills sideways: \(document.frame) in \(column.frame)")
            #expect(document.frame.height > 40, "laid out nothing: \(document.frame)")
        }
        // Heading, paragraph, two items and a code block run longer than three facts.
        #expect(documents[0].frame.height > documents[1].frame.height, "words \(documents[0].frame), facts \(documents[1].frame)")
    }

    @Test("A detail with only facts gives them the whole width; an empty one draws no scroll", arguments: [true, false])
    func partial(facts: Bool) {
        let detail = Extension.Detail(markdown: facts ? "" : " \n", metadata: facts ? Self.detail.metadata : [], actions: [])
        let (room, box) = (CGSize(width: 620, height: 364), Box())
        let (window, host) = Self.host(Self.measured(ExtensionDetailView(detail: detail), box), room)
        defer { window.close() }
        // Drawn before the scrolls are counted, so an empty detail's none is not a view not laid out yet.
        #expect(AliasesListTests.until { box.size != .zero }, "drew nothing")
        let scrolls = SharedLook.MenuScrollTests.scrollViews(in: host)
        #expect(scrolls.count == (facts ? 1 : 0))
        if let only = scrolls.first { #expect(abs(only.convert(only.bounds, to: host).width - room.width) < 0.5, "\(only.frame)") }
    }

    /// `view` at `size` in a borderless window that is never ordered in, laid out.
    static func host(_ view: some View, _ size: CGSize) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    @Test("The foot names Return after the detail's first action, Cmd+Return its page when it has one, Cmd+K its actions, Escape close or back")
    func footer() {
        func words(_ hints: [KeyHint]) -> [String] { hints.map { "\($0.key) \($0.label)" } }
        let model = MenuModel(nav: Self.liveNav([Self.row()]))
        #expect(model.nav.shownDetail == Self.detail)
        #expect(words(model.footer) == ["Esc close"])
        #expect(words(model.footerCommands) == ["↵ Open", "⌘K Actions"])
        // An extension with a page (Q639): Cmd+Return opens it.
        var paged = Self.row()
        paged.extensionPage = "github"
        #expect(words(MenuModel(nav: Self.liveNav([paged])).footerCommands) == ["↵ Open", "⌘↵ Open page", "⌘K Actions"])
        #expect(model.instrumentSize == MenuPanelSize.instrument(.wide, rows: 0, headings: 0, full: true))

        // Pushed over another view, Escape goes back to it.
        final class Quiet: MenuSource {
            var show: ([MenuEntry]) -> Void = { _ in }
            func search(_ query: String) {}
            func pick(_ row: MenuEntry, action: Int) -> MenuPick { .stay }
            func close() {}
        }
        let pushed = MenuModel(nav: Self.liveNav([MenuEntry(title: "A PR", target: .action("ext.github.list#0"))]))
        pushed.push(Self.liveNav([Self.row()]), over: Quiet())
        #expect(words(pushed.footer) == ["Esc back"])

        // No actions: nothing for Return or Cmd+K to name.
        let bare = MenuModel(nav: Self.liveNav([Self.row(Extension.Detail(markdown: "# Hi", metadata: [], actions: []))]))
        #expect(bare.footerCommands.isEmpty)
        // A live list's rows name their own Return (To-do B); rows with no action name none.
        let list = MenuModel(nav: Self.liveNav([MenuEntry(title: "A PR", target: .action("ext.github.list#0")), MenuEntry(title: "B", target: .action("ext.github.list#1"))]))
        #expect(list.nav.shownDetail == nil)
        #expect(words(list.footer) == ["Esc close"] && list.footerCommands.isEmpty)
    }
}

extension SharedLook {
    /// The detail in the real panel, hidden (alpha 0, no mouse), in Instrument and Toybox, each drawing its own detail: in
    /// place of the list, under Cmd+K's actions.
    @MainActor
    @Suite("Extension detail in the menu", .serialized)
    struct ExtensionDetailMenuTests {
        @Test("The menu draws the detail in place of the list, and Cmd+K's actions over it take the keyboard", .pilotFocus,
              arguments: PilotStyle.allCases)
        func drawsInTheMenu(_ style: PilotStyle) throws {
            testApp()
            let look = Look.shared
            let saved = look.style
            defer { look.style = saved }
            look.style = style

            let model = MenuModel(nav: ExtensionDetailViewTests.liveNav([ExtensionDetailViewTests.row()]))
            let panel = PanelTestSupport.hide(PilotMenu.makePanel(model))
            defer { panel.orderOut(nil) }
            let content = try #require(panel.contentView)
            panel.makeKeyAndOrderFront(nil)
            AliasesListTests.until { SharedLook.MenuScrollTests.scrollViews(in: content).count == 2 }

            // The words and the facts, and no list.
            let scrolls = SharedLook.MenuScrollTests.scrollViews(in: content)
            #expect(scrolls.count == 2, "\(scrolls.map(\.frame))")
            for scroll in scrolls {
                let frame = scroll.convert(scroll.bounds, to: content)
                #expect(content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(frame) outside \(content.bounds)")
            }
            #expect(Self.fields(in: content).count == 1)

            _ = model.nav.handle(.commandK)
            AliasesListTests.until { Self.fields(in: content).count == 2 && panel.firstResponder is NSTextView }
            #expect(model.nav.actions?.visible.count == 2)
            // The actions' filter is drawn over the detail and has the keyboard.
            let fields = Self.fields(in: content)
            #expect(fields.count == 2, "\(fields.map(\.frame))")
            #expect(fields.contains { panel.firstResponder === $0 || panel.firstResponder === $0.currentEditor() })
        }

        static func fields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }

        #if DEBUG
        nonisolated static let env = ProcessInfo.processInfo.environment

        /// The menu with the detail in Instrument and Toybox, dark and light, with Cmd+K's actions over it, drawn through the
        /// menu's panel as Instrument's renders draw it, Panels glass off (glass draws nothing offscreen). Opt-in like the other renders, in a moved home:
        /// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter ExtensionDetailMenuTests`
        @Test("The detail renders in the menu", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
        func render() throws {
            let home = try #require(Self.env["CFFIXED_USER_HOME"])
            try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
            let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("extension-detail")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            testApp()
            let faces = DisplayFaces.directory
            DisplayFaces.directory = LookThemeTests.fonts
            DisplayFaces.register()
            let look = Look.shared
            let saved = (look.style, look.themeID, look.glass)
            defer { (look.style, look.themeID, look.glass) = saved; DisplayFaces.directory = faces }
            look.glass = false
            let shots: [(name: String, style: PilotStyle, theme: String, actions: Bool, blocks: Bool)] = [
                // Instrument's own detail (batch 7, card agent-bo-95423181), in its theme's colours.
                ("instrument-dark", .instrument, "tokyo-night", false, false),
                ("instrument-porcelain", .instrument, "porcelain", false, false),
                ("instrument-lagoon-actions", .instrument, "tokyo-night", true, false),
                // Toybox's own detail (batch 7, card agent-bo-95423182), following the theme.
                ("toybox", .toybox, "toybox", false, false),
                ("toybox-night-actions", .toybox, "toybox-night", true, false),
                // pilot-1-1 T9: a detail's blocks in place of its words, its page a Cmd+Return away.
                ("instrument-blocks", .instrument, "tokyo-night", false, true),
                ("toybox-blocks", .toybox, "toybox", false, true),
            ]
            for shot in shots {
                (look.style, look.themeID) = (shot.style, shot.theme)
                var row = ExtensionDetailViewTests.row(shot.blocks ? ExtensionDetailViewTests.blocksDetail : ExtensionDetailViewTests.detail)
                if shot.blocks { row.extensionPage = "ai-usage" }
                let model = MenuModel(nav: ExtensionDetailViewTests.liveNav([row]))
                if shot.actions { _ = model.nav.handle(.commandK) }
                try InstrumentMenuRenders.render(MenuView(model: model), shot.name, in: dir)
            }
        }
        #endif
    }
}
