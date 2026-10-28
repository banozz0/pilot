#if DEBUG
import AppKit
import Clipboard
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Auto-redact and Blur's Text only (story 195) on the editor's billing page: OCR is faked from the page's own runs, each
/// word measured in the face it is drawn in, as pilot-text would box it.
extension SharedLook {
@MainActor
@Suite("Capture redact")
struct CaptureRedactTests {
    /// What pilot-text would read off CaptureFixture's page: a line a run, each word boxed.
    static var read: [ReadLine] {
        let size = CaptureFixture.size
        func unit(_ r: CGRect) -> CGRect { CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height) }
        return CaptureFixture.runs.map { run in
            let words = ReadLine.wordRanges(run.text).map { range -> CGRect in
                let before = (String(run.text[..<range.lowerBound]) as NSString).size(withAttributes: [.font: run.font]).width
                let word = (String(run.text[range]) as NSString).size(withAttributes: [.font: run.font])
                return unit(CGRect(x: run.at.x + before, y: run.at.y, width: word.width, height: word.height))
            }
            return ReadLine(text: run.text, box: unit(run.rect), words: words)
        }
    }

    static func model(_ capture: CGImage, accent: UInt32 = 0x3A7BF2, dark: Bool = true) -> EditorModel {
        let model = EditorModel(image: capture, scale: 2, accent: accent, dark: dark)
        model.readCapture = { Self.read }
        return model
    }

    /// Waits for the model's read to come back, on the main run loop.
    static func settle(_ model: EditorModel) async {
        for _ in 0..<200 where model.finding { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(5))
    }

    static func boxes(_ model: EditorModel) -> [CGRect] {
        model.document.marks.compactMap { if case .box(let r, _) = $0.kind { r } else { nil } }
    }

    @Test("Redact covers the page's email and live key, a mark each in one undo step, and a second press adds none")
    func redact() async throws {
        let model = Self.model(try #require(CaptureFixture.image()))
        model.redactSensitive()
        await Self.settle(model)
        let covers = Self.boxes(model)
        #expect(covers.count == 2)
        #expect(covers.contains { $0.contains(CaptureFixture.run("maya.lind@northwind.studio").rect.insetBy(dx: 1, dy: 1)) })
        #expect(covers.contains { $0.contains(CaptureFixture.run("nw_live_7f3a9c2e81d4b6a0f5e2c9d7").rect.insetBy(dx: 1, dy: 1)) })
        #expect(model.tool == .select)
        #expect(model.hint == "Covered 1 email, 1 key")

        model.redactSensitive()
        await Self.settle(model)
        #expect(Self.boxes(model).count == 2)
        #expect(model.hint == "All covered already")

        // One away with a click and ⌫; the rest stay. Undo brings it back, a second undo takes both.
        let email = CaptureFixture.run("maya.lind@northwind.studio").rect
        model.begin(CGPoint(x: email.midX, y: email.midY)); model.end(CGPoint(x: email.midX, y: email.midY))
        #expect(model.key(.delete))
        #expect(Self.boxes(model).count == 1)
        model.undo()
        #expect(Self.boxes(model).count == 2)
        model.undo()
        #expect(Self.boxes(model).isEmpty)
    }

    @Test("Text only blurs the lines inside the drag and nothing else; an area without text adds nothing")
    func textOnly() async throws {
        let model = Self.model(try #require(CaptureFixture.image()))
        model.pick(.blur)
        model.setTextOnly(true)
        let card = CaptureFixture.planCard
        model.begin(CGPoint(x: card.minX, y: card.minY)); model.end(CGPoint(x: card.maxX, y: card.maxY))
        await Self.settle(model)
        let mark = try #require(model.document.marks.first)
        guard case .blurText(let area, let boxes, false) = mark.kind else { Issue.record("not a text blur: \(mark.kind)"); return }
        #expect(area == card)
        // PRO PLAN, $12 / month, the renewal line and the two buttons' words: five lines, every box inside the card.
        #expect(boxes.count == 5)
        #expect(boxes.allSatisfy { card.insetBy(dx: -3, dy: -3).contains($0) })

        model.begin(CGPoint(x: 300, y: 411)); model.end(CGPoint(x: 500, y: 428))
        await Self.settle(model)
        #expect(model.document.marks.count == 1)
        #expect(model.hint == "No text in that area")
    }

    @Test("The editor with auto-redact's covers and a Text only blur renders in Instrument and Toybox",
          .enabled(if: CaptureEditorRenders.env["PILOT_RENDER_DIR"] != nil && CaptureEditorRenders.env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(CaptureEditorRenders.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        let out = URL(fileURLWithPath: try #require(CaptureEditorRenders.env["PILOT_RENDER_DIR"])).appendingPathComponent("capture-redact")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let capture = try #require(CaptureFixture.image())
        for pass in [CaptureEditorRenders.passes[0], CaptureEditorRenders.passes[3]] {
            look.style = pass.style
            look.themeID = pass.theme
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            let redacted = Self.model(capture, accent: tokens.colors.accent.rgb, dark: tokens.dark)
            redacted.redactSensitive()
            await Self.settle(redacted)
            let blurred = Self.model(capture, accent: tokens.colors.accent.rgb, dark: tokens.dark)
            blurred.pick(.blur)
            blurred.setTextOnly(true)
            let card = CaptureFixture.planCard
            blurred.begin(CGPoint(x: card.minX, y: card.minY)); blurred.end(CGPoint(x: card.maxX, y: card.maxY))
            await Self.settle(blurred)
            blurred.deselect()
            // A narrow capture: the editor at its least width, with the blur footer's Text only.
            let narrow = EditorModel(image: try #require(capture.cropping(to: CGRect(x: 480, y: 252, width: 800, height: 600))), scale: 2,
                                     accent: tokens.colors.accent.rgb, dark: tokens.dark)
            narrow.pick(.blur)
            narrow.setTextOnly(true)
            for (name, model) in [("1-redacted", redacted), ("2-text-blur", blurred), ("3-narrow", narrow)] {
                let size = EditorLayout.window(model.size, fit: 1, tokens: tokens)
                let rep = try CaptureEditorRenders.draw(CaptureEditorView(model: model), tokens: tokens, size: size, scale: 2)
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("R-\(name)-\(pass.tag).png"))
            }
        }
    }
}
}
#endif
