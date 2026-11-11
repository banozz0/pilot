#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Menu bar in the whole window at 1440, 1000 and 760 in every style in Tokyo Night (card agent-bo-95423001), opt-in like
/// the other renders: nothing runs past the window's right edge; with PILOT_RENDER_OCR=1 too, every line whole, so Vision
/// reads no ellipsis anywhere, and the strip short of room drops Finder before Pilot's items. In a moved home, with Stats'
/// readings and the mockup's menu bar:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-3001 PILOT_RENDER_DIR=/tmp/pilot-renders-3001 PILOT_RENDER_OCR=1 swift test --filter MenuBarRenders`
extension SharedLook {
@MainActor
@Suite("Menu bar renders")
struct MenuBarRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// The lines Vision reads in `rep` right of `left` points, a band of 240 points every 120: on the whole page it reads
    /// next to nothing.
    static func lines(in rep: NSBitmapImageRep, from left: CGFloat = 0) throws -> [String] {
        let image = try #require(rep.cgImage), band = 240 * rep.pixelsHigh / Int(rep.size.height)
        let x = Int(left) * rep.pixelsWide / Int(rep.size.width)
        return try stride(from: 0, to: image.height, by: band / 2).flatMap { y in
            let crop = try #require(image.cropping(to: CGRect(x: x, y: y, width: image.width - x, height: min(band, image.height - y))))
            return try recognisedText(in: NSBitmapImageRep(cgImage: crop)).map(\.text)
        }
    }

    /// Whether the page's right gutter, the last 6 to 14 points under the window's bar, is one colour: nothing on the page
    /// runs past its padding to the window's edge. From 100 down, under every style's frame (Toybox's page panel starts
    /// at 80).
    static func gutterClear(_ rep: NSBitmapImageRep) -> Bool {
        let scale = rep.pixelsWide / Int(rep.size.width), width = Int(rep.size.width)
        let ground = rep.colorAt(x: (width - 10) * scale, y: 100 * scale)
        return stride(from: 100 * scale, to: rep.pixelsHigh, by: scale).allSatisfy { y in
            stride(from: (width - 14) * scale, to: (width - 6) * scale, by: scale).allSatisfy { x in rep.colorAt(x: x, y: y) == ground }
        }
    }

    /// Where the page starts in a window `width` wide: right of the frame's rail and, but under 900 pt, the area's page
    /// list (RailLayout), each with its rule (Instrument 1 pt, Toybox 2), so the page's checks leave the frame's own words
    /// to the frame's renders.
    static func pageLeft(_ style: PilotStyle, width: CGFloat) -> CGFloat {
        let (rail, rule): (CGFloat, CGFloat) = style == .instrument ? (72, 1) : (76, 2)
        return rail + rule + (RailLayout.narrow(width) ? 0 : RailLayout.listWidth(width) + rule)
    }

    @Test("Menu bar shows every line whole at 1440, 1000 and 760 in every style", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("menubar")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let engine = Engine()
        StatsRenders.seed(SystemSampler.shared)
        StatsRenders.pickMockup(BarItemsStore.shared)
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.menubar")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        Look.shared.themeID = "tokyo-night"
        let picked = Look.shared.style
        defer { Look.shared.themeID = PilotTheme.defaultID; Look.shared.style = picked }
        model.go(AppPlace(.menuBar))
        // Every style (ADR 0008), each in its own window frame; Instrument light too, since its Menu bar page is restyled
        // (card agent-bo-95423181).
        for (style, dark) in [(PilotStyle.instrument, true), (.instrument, false), (.toybox, false)] {
            Look.shared.style = style
            for width in [1440, 1000, 760] {
                window.setContentSize(NSSize(width: CGFloat(width), height: 2600))
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                frame.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(frame, scale: 2))
                let name = "window-\(style.rawValue)\(style == .instrument && !dark ? "-light" : "")-\(width)"
                // The page's end, read right of the frame: the rail and the list keep their foot at the window's.
                try RestyledRenders.writeTrimmed(rep, from: Int(Self.pageLeft(style, width: CGFloat(width))), to: dir.appendingPathComponent("\(name).png"))
                #expect(Self.gutterClear(rep), "\(name): the page runs past the window's right edge")
                // Vision reads only on request (card agent-bo-95422962): it stalls the main thread and fails on a loaded Mac.
                guard Self.env["PILOT_RENDER_OCR"] != nil else { continue }
                let read = try Self.lines(in: rep, from: Self.pageLeft(style, width: CGFloat(width)))
                let cut = read.filter { $0.contains("…") || $0.contains("...") }
                #expect(cut.isEmpty, "\(name): cut lines \(cut)")
                // Every item tile's name reads whole on one line: none broken mid-word, as "Workspac" over "es" was
                // beside Instrument's sidebar at 760.
                let broken = BarKind.allCases.filter { $0.group != .readings }.map(\.title).filter { title in !read.contains { $0.contains(title) } }
                #expect(broken.isEmpty, "\(name): names not read whole \(broken)")
                // Short of room, the strip's Finder goes before any of Pilot's items: the leftmost, CPU, outlasts it.
                if read.contains(where: { $0.contains("Finder") }) { #expect(read.contains { $0.contains("CPU") }, "\(name): Finder kept, CPU dropped") }
            }
        }
    }

    /// Each item's frame in the strip, by side and place, as the strip lays them out.
    typealias Frames = StripStyleTests.Frames

    /// The top bar's preview in a host, drawn as the page draws it (30 high, its 12 pt type), every item recording its frame
    /// in the strip under its side, place and name.
    static func strip(_ sides: [TopBarSide: [BarSlot]], engine: Engine, into frames: Frames) -> NSHostingView<some View> {
        let strip = TopBarStrip(sides: sides) { slot in
            let side = TopBarSide.allCases.first { sides[$0]?.contains(slot) == true }!
            let name = "\(side.rawValue) \(sides[side]!.firstIndex(of: slot)!) \(slot.isGroup ? "group" : slot.kinds[0].title)"
            TopBarSlotView(slot: slot, screen: "", sources: engine.barSources, store: BarItemsStore.shared)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("strip")) } action: { frames.placed[name] = $0 }
        }
        return NSHostingView(rootView: strip.coordinateSpace(.named("strip")).frame(height: 30).font(.system(size: 12, weight: .medium))
            .environment(engine).pilotTheme())
    }

    @Test("The top bar's row centres the clock, moves it to the middle of the clear gap when crowded, then drops whole items: right side's innermost first, then the left's, never the clock")
    func topBarRowOrder() {
        let row = TopBarRow(spacing: 6, gap: 12)
        let widths: [TopBarSide: [CGFloat]] = [.left: [30, 20], .centre: [100], .right: [0, 200, 40]]
        // Room for all: the clock centred, the right side against the edge, the empty item taking no room.
        var plan = row.arrange(widths, room: 1000)
        #expect(plan.x[.centre] == [450] && plan.x[.left] == [0, 36] && plan.x[.right] == [754, 754, 960])
        // 56 + 12 + 100 + 12 + 246 = 426: no room to spare, the clock between the sides, nothing goes.
        plan = row.arrange(widths, room: 426)
        #expect(plan.x[.centre] == [68] && plan.x[.right]?.contains(nil) == false && plan.x[.left]?.contains(nil) == false)
        // At 600 the centred clock (250 to 350) would run into the right side (from 354, less the gap): it sits mid-gap, at 155.
        #expect(row.arrange(widths, room: 600).x[.centre] == [155])
        // A point short: the right side's innermost item that draws goes, the outer one stays.
        plan = row.arrange(widths, room: 425)
        #expect(plan.x[.right] == [nil, nil, 385] && plan.x[.left] == [0, 36] && plan.x[.centre] == [162.5])
        // Short of room for the right side at all: then the left's innermost; the clock stays even when nothing else fits.
        plan = row.arrange(widths, room: 150)
        #expect(plan.x[.right] == [nil, nil, nil] && plan.x[.left] == [0, nil] && plan.x[.centre] == [46])
        plan = row.arrange(widths, room: 90)
        #expect(plan.x[.left] == [nil, nil] && plan.x[.centre] == [0])
    }

    @Test("Short of room the row first shrinks the item that folds toward its least, then drops whole items, the right side's innermost first; the folding item never goes below its least (card agent-bo-95423016, AC 2)")
    func foldBeforeDropping() {
        let row = TopBarRow(spacing: 4, gap: 10)
        // Left: Pilot 30, workspaces 80, the app's menus 400 that fold to 90. Right: three readings 100 and the clock 140.
        let widths: [TopBarSide: [CGFloat]] = [.left: [30, 80, 400], .right: [100, 100, 100, 140]]
        let least: [TopBarSide: [CGFloat]] = [.left: [30, 80, 90], .right: [100, 100, 100, 140]]
        // 518 + 10 + 452 = 980: room for all, nothing shrinks.
        var plan = row.arrange(widths, least: least, room: 980)
        #expect(plan.width[.left] == [30, 80, 400] && plan.x[.right] == [528, 632, 736, 840])
        // 200 short: the menus give 200 and every status item stays.
        plan = row.arrange(widths, least: least, room: 780)
        #expect(plan.width[.left] == [30, 80, 200] && plan.x[.right]?.contains(nil) == false && plan.x[.right]?.first == 328)
        // 310 short is all the menus can give: still nothing goes.
        plan = row.arrange(widths, least: least, room: 670)
        #expect(plan.width[.left] == [30, 80, 90] && plan.x[.right]?.contains(nil) == false)
        // A point more: the right side's innermost goes, and the menus take back the room it left.
        plan = row.arrange(widths, least: least, room: 669)
        #expect(plan.x[.right]?.first == .some(nil) && plan.x[.right]?.dropFirst().contains(nil) == false)
        #expect(plan.width[.left] == [30, 80, 193])
        // With no least given every item is rigid, as before.
        #expect(row.arrange(widths, room: 780).x[.right]?.first == .some(nil))
    }

    @Test("What goes for room folds into the overflow item, first on the right side; none while everything fits, and the item's own width can send one more (Sven on build 52: no limit on what the bar holds)")
    func overflowItem() {
        let row = TopBarRow(spacing: 6, gap: 12)
        let widths: [TopBarSide: [CGFloat]] = [.left: [30, 20], .centre: [100], .right: [0, 200, 40]]
        // Room for all: no overflow, the row as without one.
        var plan = row.arrange(widths, room: 1000, more: 20)
        #expect(plan.more == nil && plan.x[.right] == [754, 754, 960])
        // The 200 goes: the overflow item sits first on the right side, 6 before the 40 that stays.
        plan = row.arrange(widths, room: 425, more: 20)
        #expect(plan.x[.right] == [nil, nil, 385] && plan.more == 359 && plan.x[.centre] == [162.5])
        // At 230 the 40 alone would fit, but not beside the overflow item: it goes too, and the overflow holds both.
        #expect(row.arrange(widths, room: 230).x[.right] == [nil, nil, 190])
        plan = row.arrange(widths, room: 230, more: 20)
        #expect(plan.x[.right] == [nil, nil, nil] && plan.more == 210 && plan.x[.left] == [0, 36])
        // Only an item drawing nothing going shows no overflow item.
        plan = row.arrange([.right: [0, 40]], room: 30, more: 20)
        #expect(plan.x[.right] == [nil, nil] && plan.more == 10)
        #expect(row.arrange([.right: [0, 40]], room: 1000, more: 20).more == nil)
    }

    /// Every item's frame in `host`'s strip resized to `width`.
    static func placed(_ host: NSView, _ frames: Frames, width: CGFloat) -> [String: CGRect] {
        frames.placed = [:]
        host.frame = CGRect(x: 0, y: 0, width: width, height: 30)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        return frames.placed
    }

    /// The Top bar and Both tabs' preview strip (card agent-bo-95423006): at every width the page gives it, 400 to 1440,
    /// no two items overlap and none crosses the strip's edge; an item that goes lies wholly outside it, and the
    /// clock stays. On main 3af0e90 the centre clock ran into the right side at window width 1000.
    @Test("Top bar preview: items never overlap or cross the strip's edge, and the clock stays", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func topBarStrip() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        testApp()
        let engine = Engine()
        StatsRenders.seed(SystemSampler.shared)
        StatsRenders.pickMockup(BarItemsStore.shared)
        Look.shared.themeID = "tokyo-night"
        // Liquid Glass draws nothing off screen: Calm's capsules on the flat fill, so the renders show them.
        let glass = Look.shared.glass
        Look.shared.glass = false
        defer { Look.shared.themeID = PilotTheme.defaultID; Look.shared.glass = glass }
        for placement in [BarPlacement.topBar, .both] {
            let sides = try #require(BarItemsStore.shared.settings.preview(placement).top)
            try #require(sides[.centre]?.isEmpty == false, "the mockup has no clock in the centre")
            let frames = Frames(), host = Self.strip(sides, engine: engine, into: frames)
            // Each item's own width, from a strip with room for all.
            let whole = Self.placed(host, frames, width: 2400)
            for width in stride(from: 400, through: 1440, by: 20).map(CGFloat.init) {
                let name = "\(placement.title) \(Int(width))"
                let strip = CGRect(x: 0, y: 0, width: width, height: 30)
                // An item drawing nothing (Other apps with none) takes no room.
                let shown = Self.placed(host, frames, width: width).filter { $0.value.intersects(strip) && $0.value.width > 0 }
                for (item, frame) in shown {
                    #expect(strip.contains(frame.insetBy(dx: 0.5, dy: 0.5)), "\(name): \(item) crosses the strip's edge at \(frame)")
                    #expect(frame.width >= (whole[item]?.width ?? 0) - 0.5, "\(name): \(item) squeezed to \(frame.width) from \(whole[item]?.width ?? 0)")
                }
                let sorted = shown.sorted { $0.key < $1.key }
                for (i, a) in sorted.enumerated() {
                    for b in sorted[(i + 1)...] where a.value.insetBy(dx: 0.5, dy: 0.5).intersects(b.value) {
                        Issue.record("\(name): \(a.key) at \(a.value) overlaps \(b.key) at \(b.value)")
                    }
                }
                #expect(shown.keys.contains { $0.hasPrefix("centre ") }, "\(name): the clock went")
            }
        }
        // The page on that tab at the window's widths, the page as wide as the window leaves it beside the picked style's
        // sidebar (pageLeft), for the eye: written to PILOT_RENDER_DIR/menubar, nothing past the page's right edge.
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("menubar")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for placement in [BarPlacement.topBar, .both] {
            let window = AppWindowController.makeWindow(content: NSHostingView(rootView: MenuBarPage(onScreen: true, placement: placement).environment(engine).pilotTheme()))
            defer { window.close() }
            window.minSize = .zero
            for width in [1440, 1000, 760] {
                window.setContentSize(NSSize(width: CGFloat(width) - Self.pageLeft(Look.shared.style, width: CGFloat(width)), height: 2600))
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                let frame = try #require(window.contentView?.superview)
                frame.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(frame, scale: 2))
                let name = "page-\(placement == .topBar ? "topbar" : "both")-\(width)"
                try RestyledRenders.writeTrimmed(rep, from: 0, to: dir.appendingPathComponent("\(name).png"))
                #expect(Self.gutterClear(rep), "\(name): the page runs past the window's right edge")
            }
        }
    }
}
}
#endif
