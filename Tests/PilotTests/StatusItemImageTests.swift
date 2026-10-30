import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The menu-bar item as one small picture (cards agent-bo-95422837 and 911): macOS redraws a status item once per menu bar
/// every time it changes, and a SwiftUI view there cost a full layout and render each time; a template image costs a draw.
@MainActor
@Suite("Status item image")
struct StatusItemImageTests {
    static func cpu(_ value: String) -> [[BarPart]] { [[.reading(.cpu), .value(value, widest: "100%")], [.reading(.ram), .value("58%", widest: "100%")]] }

    @Test("The picture keeps one width as the numbers change, is a template for the menu bar's colours, and fits its height")
    func width() throws {
        let narrow = try #require(StatusItemImage.image(Self.cpu("5%")))
        let wide = try #require(StatusItemImage.image(Self.cpu("100%")))
        #expect(narrow.size.width == wide.size.width && narrow.size.width > 50)
        #expect(narrow.isTemplate && narrow.size.height == StatusItemImage.height)
    }

    @Test("Every part has room: graphs, meters, symbols, the mark, rings, badges, workspaces, dots and Wi-Fi bars")
    func parts() throws {
        let all: [BarPart] = [.graph([0, 0.5, 1]), .bar(0.4), .symbol("timer"), .mark, .ring(0.75), .badge("BR"),
                              .workspaces(["1", "2", "3"], current: "2", app: "Zen"), .dots(count: 4, current: 1), .strength(3), .space(14), .divider]
        for part in all { #expect(StatusItemImage.width(part) > 0, "\(part)") }
        #expect(try #require(StatusItemImage.image([all])).size.width > 150)
    }

    @Test("With nothing to draw there is no picture; an app's icon is the button's own, never part of the template")
    func nothing() {
        #expect(StatusItemImage.image([]) == nil)
        #expect(StatusItemImage.image([[.app(name: "Finder", showsName: true)]]) == nil)
    }

    /// What one tick costs in the menu bar: macOS snapshots the item once per menu bar (two on Sven's Mac). Opt-in.
    @Test("A tick's two snapshots: the SwiftUI view against the picture", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func cost() {
        func cpuMS() -> Double {
            var u = rusage(); getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1000 + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1000
        }
        let host = NSHostingView(rootView: BarPartsView(items: Self.cpu("0%")))
        var a = cpuMS()
        for tick in 0..<100 {
            host.rootView = BarPartsView(items: Self.cpu("\(tick)%"))
            for _ in 0..<2 {
                host.frame.size = host.fittingSize
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
            }
        }
        let swiftUI = (cpuMS() - a) / 100
        a = cpuMS()
        for tick in 0..<100 {
            let image = StatusItemImage.image(Self.cpu("\(tick)%"))
            for _ in 0..<2 {
                guard let image, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
                                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(origin: .zero, size: image.size))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        let picture = (cpuMS() - a) / 100
        print("live: a tick's two snapshots, SwiftUI \(String(format: "%.2f", swiftUI)) ms, picture \(String(format: "%.2f", picture)) ms")
        #expect(picture < swiftUI)
    }
}
