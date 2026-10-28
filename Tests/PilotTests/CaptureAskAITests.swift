import AppKit
import Foundation
import PilotCore
import Synchronization
import SwiftUI
import Testing
@testable import Pilot

/// Ask AI about a capture (story 191): the picture sized and encoded to send, the chat opened on a new conversation
/// with it waiting, sent through the chat route and never the agent's, and the starters. No real AI runs here.
@MainActor
@Suite("Capture Ask AI", .serialized)
struct CaptureAskAITests {
    /// A stand-in capture: an error line on a light ground, `width` by `height` pixels.
    static func capture(_ width: Int = 720, _ height: Int = 200) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("✕  Error: ENOENT, no such file or directory 'config.json'" as NSString)
            .draw(at: CGPoint(x: 24, y: CGFloat(height) / 2 - 14), withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: NSColor.systemRed])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    static func settled(_ model: AIChatModel) async {
        for _ in 0..<200 where model.running { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("A capture is sent at its own pixels, or shrunk to 1568 on its longer side, keeping its shape")
    func size() {
        #expect(CaptureAskAI.size(800, 400) == CGSize(width: 800, height: 400))
        #expect(CaptureAskAI.size(3456, 2234) == CGSize(width: 1568, height: 1014))
        #expect(CaptureAskAI.size(1200, 20_000) == CGSize(width: 94, height: 1568))
    }

    @Test("The picture is a PNG of the sized capture")
    func picture() throws {
        let picture = try #require(CaptureAskAI.picture(Self.capture(3136, 400)))
        #expect(picture.mediaType == "image/png")
        let read = try #require(NSBitmapImageRep(data: picture.data))
        #expect(read.pixelsWide == 1568 && read.pixelsHigh == 200)
    }

    @Test("Ask AI starts a new chat with the capture waiting; its message goes through the chat route, not the agent's", .pilotFocus)
    func asks() async throws {
        let panel = AIChatPanel(drops: BarDropPanelTests.drops(), page: { false })
        let sent = AIChatPanelTests.Sent(), agent = Mutex(0)
        panel.route = { _ in agent.withLock { $0 += 1 }; return .success(AIChatModel.turn(AIChatPanelTests.runner(sent))) }
        panel.pictureRoute = { .success(AIChatModel.turn(AIChatPanelTests.runner(sent))) }
        panel.routeName = { "Claude Code · Haiku" }
        defer { panel.hide(); panel.model.clear() }
        panel.model.send("an earlier chat", through: .success(AIChatPanelTests.runner(sent)))
        await Self.settled(panel.model)

        let picture = try #require(CaptureAskAI.picture(Self.capture()))
        panel.ask(about: picture)
        #expect(panel.isShown && panel.model.turns.isEmpty && panel.model.attachment == picture)
        panel.model.draft = AIChat.Starter.capture(language: "English")[0].prompt
        panel.send()
        #expect(panel.model.attachment == nil, "the picture goes with the message")
        await Self.settled(panel.model)
        let request = try #require(sent.requests.withLock { $0.last })
        #expect(request.image == picture && request.history.isEmpty && request.session == nil)
        #expect(agent.withLock { $0 } == 0)
        #expect(panel.model.turns.first?.image == picture)

        panel.send("and how do I fix it?")
        await Self.settled(panel.model)
        #expect(agent.withLock { $0 } == 1, "a follow-up goes the usual way, resuming the session")
        #expect(sent.requests.withLock { $0.last?.image } == nil)
    }

    @Test("A capture not sent leaves with the drop: Esc, a click outside or the key never leave it on the AI page's chat", .pilotFocus)
    func cancelled() async throws {
        let drops = BarDropPanelTests.drops()
        let panel = AIChatPanel(drops: drops, page: { false })
        let sent = AIChatPanelTests.Sent()
        panel.pictureRoute = { .success(AIChatModel.turn(AIChatPanelTests.runner(sent))) }
        panel.routeName = { "Claude Code · Haiku" }
        defer { panel.hide(); panel.model.clear() }
        let picture = try #require(CaptureAskAI.picture(Self.capture()))
        panel.ask(about: picture)
        #expect(panel.isShown && panel.model.attachment == picture)
        #expect(drops.key(in: .askAI, 53, [], nil, at: 10), "Escape closes the drop")
        #expect(!panel.isShown && panel.model.attachment == nil, "the AI page shows this same chat")
        panel.show()
        #expect(panel.model.attachment == nil)
        panel.ask(about: picture)
        panel.hide()
        #expect(panel.model.attachment == nil, "the drop's key or a click outside closes it the same way")

        panel.ask(about: picture)
        panel.send("what is this?")
        await Self.settled(panel.model)
        panel.hide()
        #expect(panel.model.turns.first?.image == picture, "a sent capture stays in its turn")
    }
}

#if DEBUG
extension SharedLook {
/// The editor's top bar, Ask AI and Redact sensitive text in it, fits the editor at its narrowest in every style.
@MainActor
@Suite("Capture editor bar width")
struct CaptureEditorBarWidth {
    @Test("Every top-bar cap fits EditorLayout.minWidth")
    func fits() {
        testApp()
        let look = Look.shared
        let saved = look.style
        defer { look.style = saved }
        let model = EditorModel(image: CaptureAskAITests.capture(), scale: 2, accent: 0x3CD2DB, dark: true)
        for style in PilotStyle.allCases {
            look.style = style
            let width = NSHostingView(rootView: EditorTopBar(model: model).fixedSize().styled(.hud, look: look)).fittingSize.width
            #expect(width <= EditorLayout.minWidth, "\(style.rawValue): \(width)")
        }
    }
}

/// The chat with a capture waiting and once asked, and the thumbnail's hover with Ask AI, in Instrument and Toybox.
/// Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter CaptureAskAIRenders`
@MainActor
@Suite("Capture Ask AI renders")
struct CaptureAskAIRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The chat with a capture waiting and once asked, and the thumbnail's hover with Ask AI", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let dir = try ClockRenders.dir("capture-ask-ai")
        testApp()
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        let picture = try #require(CaptureAskAI.picture(CaptureAskAITests.capture()))
        for (style, theme) in [(PilotStyle.instrument, "lagoon"), (.toybox, "toybox")] {
            (look.style, look.themeID) = (style, theme)
            let waiting = AIChatModel()
            waiting.route = "Claude Code · Haiku"
            waiting.attachment = picture
            let asked = AIChatModel()
            asked.route = "Claude Code · Haiku"
            asked.attachment = picture
            asked.send(AIChat.Starter.capture(language: "English")[0].prompt, through: .success(AIChatPanelRenders.answers(
                "Node could not find `config.json` in the folder it ran from (ENOENT). Run it from the project's folder, or pass the path:\n\n```bash\nnode app.js --config ./config.json\n```")))
            await CaptureAskAITests.settled(asked)
            for (name, model) in [("1-waiting", waiting), ("2-asked", asked)] {
                let rep = try #require(try await snapshot(rendering: AIChatPanel.content(model, look: look)))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(style.rawValue)-\(theme)-chat-\(name).png"))
            }
            let thumb = ThumbnailModel(image: CaptureAskAITests.capture(640, 400), scale: 2, file: nil)
            thumb.stopClock()
            thumb.hovered = true
            thumb.stopClock()
            let view = ThumbnailView(model: thumb).frame(width: ThumbnailStack.size(thumb.size).width, height: ThumbnailStack.size(thumb.size).height)
                .styled(.hud, look: look).pilotTheme(look: look)
            let rep = try #require(try await snapshot(rendering: view))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(style.rawValue)-\(theme)-thumbnail-hover.png"))
        }
    }
}
}
#endif
