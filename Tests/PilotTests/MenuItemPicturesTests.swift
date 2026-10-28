import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The drawer's exact menu bar items (ADR 0012) and its opener, on fakes: nothing captures the screen, asks Screen
/// Recording, touches the real menu bar or presses a real app's item.
@MainActor
@Suite("Menu item pictures")
struct MenuItemPicturesTests {
    /// Counts every call, so a test proves none ran before the toggle was on.
    final class FakeCapture: MenuBarCapturing, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        var granted = true
        var bars: [CapturedBar] = []
        private func note(_ call: String) { lock.withLock { _calls.append(call) } }
        func allowed() -> Bool { note("allowed"); return granted }
        func ask() { note("ask") }
        func capture(over frames: [CGRect], ownPid: pid_t) async throws -> [CapturedBar] { note("capture"); return bars }
    }

    /// The opener's sleep in a test: each settle step passes at once, but the room's 60 s keep lasts until it is cancelled,
    /// so it never runs out between the press and the test's look (a yield there put the room back first under load).
    static let sleep: @Sendable (Duration) async -> Void = { duration in
        guard duration == MenuItemOpener.keep else { return await Task.yield() }
        try? await Task.sleep(for: .seconds(3600))
    }

    final class FakeSpacer: MenuBarSpacing {
        var lengths: [CGFloat] = []
        var shown = false
        func show(length: CGFloat) { lengths.append(length); shown = true }
        func hide() { shown = false }
    }

    /// A fake menu bar 200 × 30 points at 2×, transparent but for a 4 × 4 point mark at each of `marks`' x.
    static func bar(marks: [CGFloat], at origin: CGPoint = CGPoint(x: 1000, y: 0), fill: Bool = false) -> CapturedBar {
        let scale = 2, w = 200 * scale, h = 30 * scale
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        if fill { context.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        for x in marks { context.fill(CGRect(x: Int(x) * scale, y: 13 * scale, width: 4 * scale, height: 4 * scale)) }
        return CapturedBar(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 30)), image: context.makeImage()!)
    }

    /// Two apps' items at x 1010 and 1050, 24 wide, read from a fake tree.
    static func extras() -> MenuAppsTests.FakeExtras {
        let fake = MenuAppsTests.FakeExtras()
        fake.apps = [MenuExtrasApp(pid: 10, name: "Shottr", bundleId: "cc.ffitch.shottr"),
                     MenuExtrasApp(pid: 12, name: "Control Centre", bundleId: "com.apple.controlcenter")]
        fake.trees = [
            10: [MenuExtrasRaw(title: nil, description: "Shottr", help: nil, handle: MenuItemHandle("shottr" as NSString),
                               frame: CGRect(x: 1010, y: 0, width: 24, height: 30))],
            12: [MenuExtrasRaw(title: nil, description: "Wi-Fi", help: nil, handle: MenuItemHandle("wifi" as NSString),
                               frame: CGRect(x: 1050, y: 0, width: 24, height: 30))],
        ]
        return fake
    }

    @Test("With Show exact menu bar items off, no scan, launch, hover or drawer open asks Screen Recording, its state or the screen")
    func noCaptureBeforeOptIn() async throws {
        let capture = FakeCapture()
        var on = false
        let pictures = MenuItemPictures(capturer: capture, ownPid: 13, isOn: { on })
        let launch = LaunchHook()
        let apps = MenuApps(reader: Self.extras(), ownPid: 13, pictures: pictures, watchLaunches: launch.watch)
        apps.drawer.toggle()
        apps.start()
        #expect(try await SystemSamplerTests.wait { apps.list.count == 2 })
        launch.fire()
        apps.opened()
        apps.hovered()
        await apps.refresh()
        pictures.toggled()
        _ = pictures.lacksPermission
        #expect(capture.calls.isEmpty, "with the toggle off Pilot called \(capture.calls)")
        #expect(pictures.pictures.isEmpty)

        on = true
        await apps.refresh()
        #expect(capture.calls == ["allowed", "capture"])
    }

    @Test("Show exact menu bar items is off in saved settings that never had it, and kept once on")
    func settingSaved() throws {
        var settings = BarSettings.defaults
        #expect(!settings.exactMenuItems)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json["exactMenuItems"] = nil
        #expect(try !JSONDecoder().decode(BarSettings.self, from: JSONSerialization.data(withJSONObject: json)).exactMenuItems)
        settings.exactMenuItems = true
        #expect(try JSONDecoder().decode(BarSettings.self, from: JSONEncoder().encode(settings)).exactMenuItems)
    }

    @Test("Turned on without the grant, Pilot asks once and captures nothing; granted, it captures")
    func asksOnTurningOn() async {
        let capture = FakeCapture()
        capture.granted = false
        let pictures = MenuItemPictures(capturer: capture, ownPid: 13, isOn: { true })
        pictures.toggled()
        #expect(capture.calls == ["allowed", "ask"])
        let apps = MenuApps(reader: Self.extras(), ownPid: 13, pictures: pictures)
        apps.drawer.toggle()
        await apps.refresh()
        #expect(!capture.calls.contains("capture"))
        #expect(pictures.pictures.isEmpty)
        capture.granted = true
        pictures.toggled()
        #expect(capture.calls.filter { $0 == "ask" }.count == 1, "asked again with the grant in hand")
    }

    @Test("The drawer opening pictures the items, and so does each scan while it is open (an app launching or quitting); a hover within the gap, a scan with the drawer shut and a hidden module do not")
    func refreshTriggers() async throws {
        let capture = FakeCapture()
        capture.bars = [Self.bar(marks: [20, 60])]
        let pictures = MenuItemPictures(capturer: capture, ownPid: 13, isOn: { true })
        let launch = LaunchHook()
        // A pinned clock: the hover gap never runs out because the main actor stalled (a full run's did, 2026-10-11).
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let reader = Self.extras()
        let apps = MenuApps(reader: reader, ownPid: 13, pictures: pictures, now: { clock }, watchLaunches: launch.watch)
        let captures = { capture.calls.filter { $0 == "capture" }.count }
        apps.start()
        // A scan checks the drawer in the same main-actor turn it sets the list, so a list seen is a scan done with it.
        #expect(try await SystemSamplerTests.wait { apps.list.count == 2 })
        #expect(captures() == 0, "the shut drawer was pictured")
        apps.drawer.toggle()
        apps.opened()
        #expect(try await SystemSamplerTests.wait { captures() == 1 })
        launch.fire()
        #expect(try await SystemSamplerTests.wait { captures() == 2 })
        apps.hovered()
        try await Task.sleep(for: .milliseconds(200))
        #expect(captures() == 2, "a hover inside the gap captured")
        apps.drawer.toggle()
        // An app quits: the scan lists one. Waited for, not slept on: a starved scan ran after the next toggle opened the
        // drawer and pictured it (full runs, 2026-10-11).
        reader.apps = [reader.apps[0]]
        launch.fire()
        #expect(try await SystemSamplerTests.wait { apps.list.count == 1 })
        #expect(captures() == 2, "a scan with the drawer shut captured")
        apps.drawer.toggle()
        apps.stop()
        launch.fire()
        apps.opened()
        try await Task.sleep(for: .milliseconds(200))
        #expect(captures() == 2, "captured while the module was hidden")
    }

    @Test("Each item is cropped at its own frame and cut to its marks, one grey drawn as a template; an empty crop keeps its last picture")
    func crops() async throws {
        let capture = FakeCapture()
        capture.bars = [Self.bar(marks: [20, 60])]
        let pictures = MenuItemPictures(capturer: capture, ownPid: 13, isOn: { true })
        let apps = MenuApps(reader: Self.extras(), ownPid: 13, pictures: pictures)
        apps.drawer.toggle()
        await apps.refresh()
        let shottr = try #require(apps.list.first { $0.app.pid == 10 }?.items.first)
        let picture = try #require(pictures.picture(shottr))
        // The 4 × 4 point mark alone: macOS's room round it goes (Sven on build 82).
        #expect(picture.image.size == NSSize(width: 4, height: 4))
        #expect(picture.image.isTemplate)
        #expect(pictures.picture(apps.list[1].items[0]) != nil)

        // The bar drew nothing this time (hidden): the last pictures stay.
        capture.bars = [Self.bar(marks: [])]
        await apps.refresh()
        #expect(pictures.picture(shottr) == picture)
    }

    /// One item as macOS might draw it, 24 × 30 points at 2×: each fill a colour and a rect in pixels.
    static func item(_ fills: [(CGColor, CGRect)]) -> CGImage {
        let context = CGContext(data: nil, width: 48, height: 60, bitsPerComponent: 8, bytesPerRow: 48 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (colour, rect) in fills {
            context.setFillColor(colour)
            context.fill(rect)
        }
        return context.makeImage()!
    }

    /// The template's alpha at pixel (x, y), counted from the top.
    static func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 { StripStyleTests.pixel(NSBitmapImageRep(cgImage: image), x, y)[3] }

    static let glyph = CGRect(x: 8, y: 16, width: 32, height: 28), hole = CGRect(x: 20, y: 26, width: 8, height: 8)

    @Test("A grey item takes the bar's ink, whatever grey and tint macOS drew it in; a badge keeps its hole; a coloured one stays as it is (Sven, 2026-10-11)")
    func greyItemsTakeTheInk() throws {
        // Black on a light menu bar, with the wallpaper's red in it and a reading in a lighter grey: full ink, the reading less.
        let tinted = try #require(MenuItemPictures.ink(Self.item([(CGColor(red: 0.18, green: 0.04, blue: 0.04, alpha: 1), Self.glyph),
                                                                 (CGColor(gray: 0.45, alpha: 1), CGRect(x: 0, y: 0, width: 48, height: 10))])))
        #expect(Self.alpha(tinted, 24, 30) == 255)
        #expect((80...200).contains(Self.alpha(tinted, 24, 55)))
        #expect(Self.alpha(tinted, 2, 30) == 0)
        // White on a dark menu bar.
        let white = try #require(MenuItemPictures.ink(Self.item([(CGColor(gray: 1, alpha: 1), Self.glyph)])))
        #expect(Self.alpha(white, 24, 20) == 255)
        // A dark tile with a light mark in it: the mark stays a hole.
        let badge = try #require(MenuItemPictures.ink(Self.item([(CGColor(gray: 0.05, alpha: 1), Self.glyph), (CGColor(gray: 0.95, alpha: 1), Self.hole)])))
        #expect(Self.alpha(badge, 12, 20) == 255)
        #expect(Self.alpha(badge, 24, 30) < 20)
        // An app's coloured logo.
        #expect(MenuItemPictures.ink(Self.item([(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1), Self.glyph)])) == nil)
    }

    @Test("A crop skips a window that fills the item (a backdrop) and one that does not cover it")
    func cropPicksTheDrawingWindow() throws {
        let item = CGRect(x: 1010, y: 0, width: 24, height: 30)
        let backdrop = Self.bar(marks: [], fill: true), elsewhere = Self.bar(marks: [20], at: CGPoint(x: 2000, y: 0))
        #expect(MenuItemPictures.crop(item, from: [backdrop, elsewhere]) == nil)
        let cropped = try #require(MenuItemPictures.crop(item, from: [backdrop, elsewhere, Self.bar(marks: [20])]))
        #expect(cropped.width == 48 && cropped.height == 60)
    }

    @Test("The open drawer with pictures draws one target per item, and a click presses that item")
    func drawerShowsPictures() async throws {
        let fake = Self.extras(), capture = FakeCapture()
        capture.bars = [Self.bar(marks: [20, 60])]
        let apps = MenuApps(reader: fake, ownPid: 13, pictures: MenuItemPictures(capturer: capture, ownPid: 13, isOn: { true }),
                            opener: MenuItemOpener(reader: fake, spacer: FakeSpacer(), sleep: { _ in }))
        apps.drawer.toggle()
        await apps.refresh()
        let panel = PanelTestSupport.bar(TopBarMenuApps(apps: apps).environment(\.inTopBar, true).font(BarMetrics.font)
            .frame(width: 200, height: 30, alignment: .leading).pilotTheme().background(Theme.background), size: CGSize(width: 200, height: 30))
        defer { panel.close() }
        PanelTestSupport.pump(0.5)
        // The chevron's 27, then each 4-wide picture with the bar's 8 pt inset each side.
        PanelTestSupport.click(panel, at: CGPoint(x: 27 + 20 + 10, y: 15))
        #expect(try await SystemSamplerTests.wait { fake.pressed == [MenuItemHandle("wifi" as NSString)] })
    }

    @Test("The opener widens Pilot's room by how far the item must move, presses it once it lands, and puts it back at the next click outside its app")
    func opensUnderTheDrawer() async throws {
        let fake = MovingExtras(), spacer = FakeSpacer()
        let opener = MenuItemOpener(reader: fake, spacer: spacer, sleep: Self.sleep)
        let item = MenuApps.Item(label: "Shottr", handle: MenuItemHandle("shottr" as NSString), frame: CGRect(x: 3000, y: 0, width: 24, height: 30))
        fake.moved = { spacer.lengths.last.map { CGRect(x: 3000 - $0, y: 0, width: 24, height: 30) } }
        #expect(await opener.open(item, of: 10, under: 1800).value)
        #expect(spacer.lengths == [1200] && spacer.shown)
        #expect(fake.pressed == [item.handle])
        #expect(opener.isMoved)
        opener.clicked(ownerPid: 10)
        #expect(spacer.shown, "a click in the app's own menu took the room away")
        opener.clicked(ownerPid: 99)
        #expect(!spacer.shown && !opener.isMoved)
    }

    @Test("An item that does not move (macOS's own, right of Pilot's room) is pressed where it sits and the room goes at once; one left of the drawer is never moved")
    func pressesInPlace() async throws {
        let fake = MovingExtras(), spacer = FakeSpacer()
        let opener = MenuItemOpener(reader: fake, spacer: spacer, sleep: Self.sleep)
        let item = MenuApps.Item(label: "Clock", handle: MenuItemHandle("clock" as NSString), frame: CGRect(x: 3300, y: 0, width: 60, height: 30))
        fake.moved = { item.frame }
        #expect(await opener.open(item, of: 12, under: 1800).value)
        #expect(spacer.lengths == [1500] && !spacer.shown && !opener.isMoved)
        #expect(fake.pressed == [item.handle])

        let left = MenuApps.Item(label: "Left", handle: MenuItemHandle("left" as NSString), frame: CGRect(x: 1000, y: 0, width: 24, height: 30))
        // The fake reads one frame for every item: now Left's.
        fake.moved = { left.frame }
        #expect(await opener.open(left, of: 12, under: 1800).value)
        #expect(spacer.lengths == [1500], "an item left of the drawer was moved")
    }

    @Test("A drawer item whose menu reads closed opens as Pilot's own menu under the drawer's item, Pilot's room never made; a pick presses its path inside that item")
    func drawsTheItemsMenu() async throws {
        let fake = MovingExtras(), spacer = FakeSpacer()
        let shottr = MenuApps.Item(label: "Shottr", handle: MenuItemHandle("shottr" as NSString), frame: CGRect(x: 3180, y: 0, width: 24, height: 30))
        fake.menus = [shottr.handle: [MenuItemNode(title: "Capture Screen", enabled: true),
                                     MenuItemNode(title: "more", enabled: true, children: [MenuItemNode(title: "Pin Screenshot", enabled: true)])]]
        var shown: [([MenuItemNode], NSView)] = [], pick: (([String]) -> Void)?
        let apps = MenuApps(reader: fake, ownPid: 13, opener: MenuItemOpener(reader: fake, spacer: spacer, sleep: Self.sleep),
                            showMenu: { nodes, view, picked in shown.append((nodes, view)); pick = picked })
        let window = NSWindow(contentRect: CGRect(x: 2490, y: 1410, width: 30, height: 30), styleMask: .borderless, backing: .buffered, defer: true)
        let button = NSView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        window.contentView = button
        #expect(await apps.press(shottr, under: (pid: 10, view: button)).value)
        #expect(shown.count == 1 && shown.first?.0.map(\.title) == ["Capture Screen", "more"] && shown.first?.1 === button)
        #expect(spacer.lengths.isEmpty && fake.pressed.isEmpty, "the item itself was pressed or moved")
        pick?(["more", "Pin Screenshot"])
        #expect(try await SystemSamplerTests.wait { fake.picked == [["more", "Pin Screenshot"]] && fake.pickedIn == [shottr.handle] })

        // An item with no menu to read (a popover) goes to the opener, its frame read afresh: the scan's is stale.
        let popover = MenuApps.Item(label: "Popover", handle: MenuItemHandle("popover" as NSString), frame: CGRect(x: 3000, y: 0, width: 24, height: 30))
        fake.moved = { CGRect(x: 3100 - (spacer.shown ? spacer.lengths.last ?? 0 : 0), y: 0, width: 24, height: 30) }
        #expect(await apps.press(popover, under: (pid: 11, view: button)).value)
        #expect(shown.count == 1 && spacer.lengths == [610] && fake.pressed == [popover.handle])
        apps.opener.putBack()
    }

    /// A fake tree whose item's frame follows Pilot's room.
    final class MovingExtras: MenuExtrasReading, @unchecked Sendable {
        var moved: @MainActor () -> CGRect? = { nil }
        var pressed: [MenuItemHandle] = []
        var menus: [MenuItemHandle: [MenuItemNode]] = [:]
        private let lock = NSLock()
        private var _picked: [([String], MenuItemHandle)] = []
        var picked: [[String]] { lock.withLock { _picked.map(\.0) } }
        var pickedIn: [MenuItemHandle] { lock.withLock { _picked.map(\.1) } }
        func menu(of handle: MenuItemHandle) -> [MenuItemNode] { menus[handle] ?? [] }
        func press(_ path: [String], in handle: MenuItemHandle) -> Bool { lock.withLock { _picked.append((path, handle)) }; return true }
        func running() -> [MenuExtrasApp] { [] }
        func items(of pid: pid_t) throws -> [MenuExtrasRaw]? { nil }
        func press(_ handle: MenuItemHandle) -> Bool { pressed.append(handle); return true }
        func frame(of handle: MenuItemHandle) -> CGRect? { DispatchQueue.main.sync { MainActor.assumeIsolated { moved() } } }
    }

    /// Stands in for NSWorkspace's launches: `fire` is an app launching or quitting, heard while the token is kept.
    final class LaunchHook: @unchecked Sendable {
        final class Token { let changed: @Sendable () -> Void; init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed } }
        private weak var token: Token?
        func watch(_ changed: @escaping @Sendable () -> Void) -> AnyObject { let token = Token(changed); self.token = token; return token }
        func fire() { token?.changed() }
    }
}
