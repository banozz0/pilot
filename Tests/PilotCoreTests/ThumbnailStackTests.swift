import CoreGraphics
import Foundation
import Testing
@testable import PilotCore

/// The after-capture thumbnails' place (build 54) and the setting that chooses them.
@Suite("Thumbnail stack")
struct ThumbnailStackTests {
    @Test("Every thumbnail is the same 4:3 card, whatever the capture's shape")
    func size() {
        for capture in [CGSize(width: 1000, height: 500), CGSize(width: 400, height: 800), CGSize(width: 120, height: 80), CGSize(width: 1400, height: 90)] {
            #expect(ThumbnailStack.size(capture) == CGSize(width: 216, height: 162))
        }
    }

    @Test("The newest sits in the bottom-right corner, older ones stacked above it")
    func frames() {
        let screen = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let frames = ThumbnailStack.frames([CGSize(width: 200, height: 100), CGSize(width: 150, height: 140)], in: screen)
        #expect(frames[1] == CGRect(x: 1440 - 16 - 150, y: 56, width: 150, height: 140), "the newest, lowest")
        #expect(frames[0] == CGRect(x: 1440 - 16 - 200, y: 56 + 140 + 10, width: 200, height: 100))
    }

    @Test("Thumbnail place: each corner stacks away from its edge, newest nearest it; the middle centres the stack")
    func places() {
        let screen = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let sizes = [CGSize(width: 200, height: 100), CGSize(width: 150, height: 140)]
        func frames(_ place: CaptureSettings.ThumbnailPlace) -> [CGRect] { ThumbnailStack.frames(sizes, in: screen, place: place) }
        #expect(frames(.bottomRight) == ThumbnailStack.frames(sizes, in: screen), "the default")
        #expect(frames(.bottomLeft) == [CGRect(x: 16, y: 56 + 140 + 10, width: 200, height: 100), CGRect(x: 16, y: 56, width: 150, height: 140)])
        let top = 40 + 860 - 16.0
        #expect(frames(.topRight) == [CGRect(x: 1440 - 16 - 200, y: top - 140 - 10 - 100, width: 200, height: 100),
                                      CGRect(x: 1440 - 16 - 150, y: top - 140, width: 150, height: 140)], "the newest at the top")
        #expect(frames(.topLeft).map(\.minX) == [16, 16] && frames(.topLeft).map(\.minY) == frames(.topRight).map(\.minY))
        let middle = frames(.middle)
        #expect(middle.map(\.midX) == [720, 720])
        #expect(middle[1].minY == (40 + 430 - 125) && middle[0].maxY == 40 + 430 + 125, "250 tall, centred, the newest at the foot")
        #expect(CaptureSettings().thumbnailPlace == .bottomRight)
        let saved = try? JSONDecoder().decode(CaptureSettings.self, from: JSONEncoder().encode(CaptureSettings(thumbnailPlace: .topLeft)))
        #expect(saved?.thumbnailPlace == .topLeft)
        let old = try? JSONDecoder().decode(CaptureSettings.self, from: Data(#"{"engine":"pilot"}"#.utf8))
        #expect(old?.thumbnailPlace == .bottomRight, "settings from before read the default")
    }

    @Test("After capture is a thumbnail by default; settings from before carry over: editor off keeps copying only")
    func setting() throws {
        #expect(CaptureSettings().afterCapture == .thumbnail)
        let off = try JSONDecoder().decode(CaptureSettings.self, from: Data(#"{"engine":"pilot","openEditor":false}"#.utf8))
        let on = try JSONDecoder().decode(CaptureSettings.self, from: Data(#"{"engine":"pilot","openEditor":true}"#.utf8))
        #expect(off.afterCapture == .copy && on.afterCapture == .thumbnail)
        let saved = try JSONDecoder().decode(CaptureSettings.self, from: JSONEncoder().encode(CaptureSettings(afterCapture: .editor, delay: 5)))
        #expect(saved.afterCapture == .editor && saved.delay == 5)
    }
}
