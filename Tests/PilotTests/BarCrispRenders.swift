#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The centre island at 1x, as Sven's 3440 by 1440 screen draws it (2026-11-14: "TERMINAL" and "ASK AI" soft): the real
/// strip in a real TopBarIslandClip, cropped to the island the row reports, at the window's whole-pixel width. Writes the
/// PNG and prints the island's row rect and the clip's offset, so a half-point offset shows in numbers. Opt-in like the
/// other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pch PILOT_RENDER_DIR=/tmp/pcr swift test --filter BarCrispRenders`
extension SharedLook {
@MainActor
@Suite("Bar crisp renders")
struct BarCrispRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The centre island at 1x on a 3440 pt screen, Three islands Attached",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let dir = try ClockRenders.dir("bar-crisp")
        testApp()
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        (look.style, look.themeID, look.glass) = (.instrument, "tokyo-night", false)
        defer { (look.style, look.themeID, look.glass) = saved }
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: SetupKeepAwakeTests.FakeSources()),
                                   readBattery: { nil }, readWiFi: { nil }, watchStats: { _ in Task {} })
        let sources = BarSources(readings: readings, observers: EngineObservers(), sampler: SystemSamplerTests.sampler(SystemSamplerTests.Counter()),
                                 keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()), timer: ExtensionTimer(), pilotTitle: { "2" })

        var config = BarPreset.threeIslands.configuration
        config.attached = true
        let canvas = BarPresetGeometry.frame(config, screen: CGRect(x: 0, y: 0, width: 3440, height: 1440), strip: 32)
        var settings = BarSettings.defaults
        let drops: [BarSlot] = [BarKind.terminal, .askAI].map { kind in settings.set(kind, style: .iconName); return .item(settings.entry(kind)) }
        // Two drops alone, with the clock as Sven's centre has it, and with the clock and Ask AI as an icon; each of them
        // came out an even width, centred on a whole point. "odd" is the drops and clock one point wider, Sven's island's
        // parity (473 wide on a 3416 canvas: x 1471.5).
        settings.set(.askAI, style: .icon)
        let narrow: [BarSlot] = [.item(settings.entry(.terminal)), .item(settings.entry(.askAI))]
        let variants: [(String, [BarSlot])] = [("drops", drops), ("drops-clock", drops + [.item(settings.entry(.clock))]),
                                               ("narrow-clock", narrow + [.item(settings.entry(.clock))]),
                                               ("odd", drops + [.item(settings.entry(.clock))]),
                                               ("right-half", drops)]
        for (name, items) in variants {
            let odd = name == "odd", right = name == "right-half"
            var reported: CGRect?
            // "right-half": the drops on the right side asked half a point wider (SwiftUI sizes it on whole pixels at 1x), its
            // window kept inside the canvas: arrange() rounds x down, so the group never passes the row's end.
            var rightGroup: CGRect?
            let strip = TopBarStrip(sides: right ? [.right: items] : [.centre: items], configuration: config, reportIsland: { side, rect in
                if side == (right ? .right : .centre) { reported = rect }
                if side == .right { rightGroup = rect }
            }) {
                TopBarSlot(slot: $0, screen: "Studio", sources: sources, store: .shared, lights: BarDropLights(open: []))
                    .padding(.trailing, odd && $0 == items.last ? 1 : right && $0 == items.last ? 0.5 : 0)
            }
            let host = NSHostingView(rootView: strip.styled(.topBar, look: look).pilotTheme(look: look))
            host.sizingOptions = []
            let clip = TopBarIslandClip(host)
            clip.frame = CGRect(origin: .zero, size: canvas.size)
            clip.canvas = canvas
            let window = NSWindow(contentRect: clip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = clip
            defer { window.close() }
            clip.layoutSubtreeIfNeeded()
            PanelTestSupport.pump(0.6)
            if right {
                let grown = rightGroup.map { $0.insetBy(dx: -BarIslandShape.flare(config), dy: 0) }
                print("bar-crisp right-half: right group \(String(describing: rightGroup)) window frame \(String(describing: BarPresetGeometry.islandFrame(grown, in: canvas)))")
                #expect(BarPresetGeometry.islandFrame(grown, in: canvas) != nil, "the right island's window would go")
            }
            let rect = try #require(reported)
            // As TopBarWindows.placeIsland crops it; the window takes AppKit's whole-pixel size.
            let grown = rect.insetBy(dx: -BarIslandShape.flare(config), dy: 0)
            clip.crop = grown
            let frame = try #require(BarPresetGeometry.islandFrame(grown, in: canvas))
            clip.setFrameSize(CGSize(width: frame.width.rounded(), height: frame.height.rounded()))
            PanelTestSupport.pump(0.3)
            print("bar-crisp \(name): canvas \(canvas) island \(rect) window frame \(frame) content x \(host.frame.minX)")
            let rep = try #require(snapshot(clip, scale: 1))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name)-1x.png"))
        }
    }
}
}
#endif
