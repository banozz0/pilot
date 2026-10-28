import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Other apps' menu bar items fold behind a chevron in the top bar (card agent-bo-95423018, design JJPiA9o30SA, the drawer
/// shot): folded by default, a click unfolds them, and they fold again 5 s after the pointer leaves; an app with a template
/// glyph draws it in the bar's glyph colour, any other its app icon in full colour (Sven, 2026-10-10). On a fake Accessibility tree and a fake
/// clock; with PILOT_RENDER_DIR set the bars are also written there as PNGs. It reads the shared look's theme, so it runs
/// inside SharedLook.
extension SharedLook {
@MainActor
@Suite("Other apps drawer", .serialized)
struct OtherAppsDrawerTests {
    /// Shottr and Finder with one item each, Control Centre with two: Control Centre has a template glyph, Finder none.
    /// "Shottr" carries TextEdit's bundle, on every Mac: an app not on disk draws its name, wider, and the clicks miss.
    static func extras() -> MenuAppsTests.FakeExtras {
        let fake = MenuAppsTests.FakeExtras()
        fake.apps = [
            MenuExtrasApp(pid: 10, name: "Shottr", bundleId: "com.apple.TextEdit"),
            MenuExtrasApp(pid: 11, name: "Finder", bundleId: "com.apple.finder"),
            MenuExtrasApp(pid: 12, name: "Control Centre", bundleId: "com.apple.controlcenter"),
        ]
        fake.trees = [
            10: [MenuExtrasRaw(title: nil, description: "Shottr", help: nil, handle: MenuItemHandle("shottr" as NSString))],
            11: [MenuExtrasRaw(title: nil, description: "Finder", help: nil, handle: MenuItemHandle("finder" as NSString))],
            12: [MenuExtrasRaw(title: nil, description: "Wi-Fi", help: nil, handle: MenuItemHandle("wifi" as NSString)),
                 MenuExtrasRaw(title: nil, description: "Battery", help: nil, handle: MenuItemHandle("battery" as NSString))],
        ]
        return fake
    }

    /// Sven's bar with the fake apps read, Other apps on or off.
    static func bar(otherApps: Bool) async throws -> (store: BarItemsStore, sources: BarSources, timer: ExtensionTimer) {
        let apps = MenuAppsTests.make(Self.extras())
        await apps.refresh()
        let bar = try StripStyleTests.svensBar(menuApps: apps)
        bar.store.settings.set(.otherApps, on: otherApps)
        return bar
    }

    /// The right side's extent as drawn: from its first item's left edge to its last's right edge.
    static func rightSide(_ store: BarItemsStore, _ frames: StripStyleTests.Frames) -> CGFloat {
        let names = (store.settings.preview(.topBar).top?[.right] ?? []).map { $0.isGroup ? "Group" : $0.kind.title }
        let placed = names.compactMap { frames.placed[$0] }.filter { $0.width > 0 && $0.minX >= 0 }
        return (placed.map(\.maxX).max() ?? 0) - (placed.map(\.minX).min() ?? 0)
    }

    @Test("Folded, the right side is as wide as it is without Other apps plus the chevron's slot and one spacing (card agent-bo-95423018, AC 1)")
    func foldedWidth() async throws {
        var widths: [Bool: CGFloat] = [:]
        var chevron: CGRect = .zero, gap: CGFloat = .infinity
        for on in [false, true] {
            let (store, sources, timer) = try await Self.bar(otherApps: on)
            defer { timer.stop() }
            let frames = StripStyleTests.Frames()
            let rep = try rendered(StripStyleTests.strip(store, sources, width: 1440, frames: frames), wait: 0.5)
            if on {
                try StripStyleTests.write(rep, "drawer/strip-folded")
                chevron = try #require(frames.placed["Other apps"])
                // The bar's own room between the chevron and the item beside it, whatever the style's spacing.
                gap = frames.placed.values.filter { $0.width > 0 && $0 != chevron }
                    .map { $0.minX >= chevron.maxX ? $0.minX - chevron.maxX : chevron.minX - $0.maxX }.filter { $0 >= 0 }.min() ?? .infinity
            }
            widths[on] = Self.rightSide(store, frames)
        }
        #expect(chevron.width > 10 && chevron.width < 34, "the folded drawer is \(chevron.width) wide: more than a chevron")
        let grown = widths[true]! - widths[false]!
        #expect(abs(grown - (chevron.width + gap)) < 0.5,
                "folded, the right side grew \(grown), the chevron's slot is \(chevron.width) plus the bar's \(gap)")
    }

    /// The unfolded items' middles: the chevron's target is 27 pt (11 and an 8 pt inset each side), each app's 31.
    static let shottr = CGPoint(x: 27 + 15, y: 15), finder = CGPoint(x: 27 + 31 + 15, y: 15)

    @Test("A click on the chevron unfolds the drawer; each unfolded item then calls MenuApps' press once per click (card agent-bo-95423018, AC 2)")
    func clickUnfoldsAndPresses() async throws {
        let fake = Self.extras(), apps = MenuAppsTests.make(fake)
        await apps.refresh()
        let drawer = apps.drawer
        let panel = PanelTestSupport.bar(TopBarMenuApps(apps: apps).environment(\.inTopBar, true).font(BarMetrics.font)
            .frame(width: 200, height: 30, alignment: .leading).pilotTheme().background(Theme.background), size: CGSize(width: 200, height: 30))
        defer { panel.close() }
        #expect(!drawer.isOpen)
        // Folded, a click where Shottr's item will be presses nothing.
        PanelTestSupport.click(panel, at: Self.shottr)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.pressed.isEmpty, "folded, an item took a click")

        // The chevron is the drawer's first target, at its leading edge.
        PanelTestSupport.click(panel, at: CGPoint(x: 12, y: 15))
        PanelTestSupport.pump(0.5)
        try #require(drawer.isOpen, "a click on the chevron did not unfold the drawer")

        PanelTestSupport.click(panel, at: Self.shottr)
        #expect(try await SystemSamplerTests.wait { fake.pressed.count == 1 })
        PanelTestSupport.click(panel, at: Self.finder)
        #expect(try await SystemSamplerTests.wait { fake.pressed.count == 2 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.pressed == [MenuItemHandle("shottr" as NSString), MenuItemHandle("finder" as NSString)])
    }

    @Test("On a fake clock the drawer folds 5 s after the pointer leaves and not before; back inside first, it stays (card agent-bo-95423018, AC 3)")
    func foldsAfterFiveSeconds() async throws {
        let sleep = StripStyleTests.FakeSleep()
        let drawer = MenuAppsDrawer { await sleep.sleep($0) }
        drawer.toggle()
        #expect(drawer.isOpen)
        drawer.pointer(inside: true)
        drawer.pointer(inside: false)
        #expect(try await SystemSamplerTests.wait { sleep.asked == [.seconds(5)] })
        for _ in 0..<50 { await Task.yield() }
        #expect(drawer.isOpen, "folded before its 5 s ran out")
        sleep.advance()
        #expect(try await SystemSamplerTests.wait { !drawer.isOpen })

        // Back inside before the 5 s run out: it stays open.
        drawer.toggle()
        drawer.pointer(inside: false)
        #expect(try await SystemSamplerTests.wait { sleep.asked.count == 2 })
        drawer.pointer(inside: true)
        sleep.advance()
        for _ in 0..<50 { await Task.yield() }
        #expect(drawer.isOpen, "folded with the pointer back inside")

        // A click folds it at once, and a fold already waiting does nothing more.
        drawer.pointer(inside: false)
        #expect(try await SystemSamplerTests.wait { sleep.asked.count == 3 })
        drawer.toggle()
        #expect(!drawer.isOpen)
        drawer.toggle()
        sleep.advance()
        for _ in 0..<50 { await Task.yield() }
        #expect(drawer.isOpen, "a fold left over from before the click folded the drawer")
    }

    @Test("A template item draws in the bar's glyph colour and nothing else; an app with no picture draws its icon at full strength (card agent-bo-95423018, AC 4; Sven, 2026-10-10)")
    func glyphs() async throws {
        let ground = StripStyleTests.ground()
        let ink = StripStyleTests.bytes(BarMetrics.glyphInk(StyleTokens.of(.instrument, theme: Look.shared.theme)))
        let apps = Self.extras().apps, finder = apps[1], controlCentre = apps[2]
        #expect(MenuAppGlyph.of(controlCentre).isTemplate)

        // The template: every pixel lies between the ground and the glyph colour, and some are the glyph colour.
        let template = try StripStyleTests.alone(MenuAppIcon(app: controlCentre))
        try StripStyleTests.write(template, "drawer/strip-template")
        var full = 0, off = 0
        for y in 0..<template.pixelsHigh {
            for x in 0..<template.pixelsWide {
                let p = StripStyleTests.pixel(template, x, y)
                if StripStyleTests.near(p, ink, 6) { full += 1 }
                if Self.offBlend(p, ground, ink) > 8 { off += 1 }
            }
        }
        #expect(full > 20, "\(full) pixels in the glyph colour")
        #expect(off == 0, "\(off) pixels off the line from the ground to the glyph colour: not drawn as a template")

        // The app icon: drawn alone and in the drawer, each strong channel of the drawer's is all the way from the ground
        // to the whole icon's, never dimmed (the median share is what is checked: blending is not quite linear in bytes).
        let icon = try #require(AppsModule.icon(bundle: "com.apple.finder"))
        let drawn = try StripStyleTests.alone(MenuAppIcon(glyph: .icon(icon), name: finder.name))
        let whole = try StripStyleTests.alone(MenuAppIcon.iconImage(icon))
        try StripStyleTests.write(drawn, "drawer/strip-icon")
        var coloured = 0
        for y in 0..<drawn.pixelsHigh {
            for x in 0..<drawn.pixelsWide where Self.offBlend(StripStyleTests.pixel(drawn, x, y), ground, ink) > 30 { coloured += 1 }
        }
        let (median, channels) = StripStyleTests.strength(drawn, of: whole)
        #expect(coloured > 40, "\(coloured) coloured pixels: not the app's icon")
        #expect(channels > 100 && abs(median - 1) < 0.04, "drawn at \(median) of the icon's strength over \(channels) channels, not full")
    }

    /// An app bundle in a fresh folder named `name`, with `files` (path under Resources, image) written as PNGs. Removed
    /// by the caller.
    static func fixtureBundle(_ name: String, files: [(String, NSImage)]) throws -> (folder: URL, app: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-template-\(UUID().uuidString)")
        let app = folder.appendingPathComponent("\(name).app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "dev.banozz.pilot.fixture-\(UUID().uuidString)", "CFBundleName": name, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        for (path, image) in files {
            let url = resources.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        }
        return (folder, app)
    }

    /// A ring `points` square in `colour` on clear (at 2x when `retina`, as a @2x file's pixels are), or in two colours.
    static func ring(_ points: CGFloat, _ colour: NSColor = .black, second: NSColor? = nil, retina: Bool = false) -> NSImage {
        let side = retina ? points * 2 : points
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            colour.setStroke()
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            path.lineWidth = 3
            path.stroke()
            if let second { second.setFill(); NSRect(x: rect.midX - 2, y: rect.midY - 2, width: 4, height: 4).fill() }
            return true
        }
    }

    @Test("The status item's picture is the bundle's best-named menu-bar-sized one-colour image: an Electron tray icon over a menu's template, never another platform's, a coloured one or a toolbar's (Sven, 2026-10-10)")
    func picksTheStatusPicture() throws {
        let (folder, app) = try Self.fixtureBundle("Wispr Fixture", files: [
            ("assets/tray/TrayIconMac@2x.png", Self.ring(16, .white, retina: true)),
            ("assets/tray/TrayIconWindows.png", Self.ring(16)),
            ("assets/tray/MenuEyeTemplate.png", Self.ring(16)),
            ("StatusBarIconColour.png", Self.ring(18, .red, second: .blue)),
            ("TrayIconBig.png", Self.ring(64)),
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try #require(MenuAppGlyph.template(at: app, app: "Wispr Fixture"), "no picture found")
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 16, height: 16), "picked a \(image.size) image: not the @2x tray icon at 16 pt")
        #expect(MenuAppGlyph.isOneColour(Self.ring(16, .white)) && !MenuAppGlyph.isOneColour(Self.ring(16, .red, second: .blue)))
        // Names: status words first, then the app's own words; another state's lower, another platform's never.
        #expect(MenuAppGlyph.score("StatusBarIcon", words: ["tailscale"]) > MenuAppGlyph.score("StatusBarIconDimmed", words: ["tailscale"]))
        #expect(MenuAppGlyph.score("icon-reminder-1", words: MenuAppGlyph.words("Reminders MenuBar")) > 0
                && MenuAppGlyph.score("icon-note-1", words: MenuAppGlyph.words("Reminders MenuBar")) == 0)
        #expect(MenuAppGlyph.score("shottr-22", words: ["shottr"]) > MenuAppGlyph.score("shottr-22-animated-1", words: ["shottr"]))
        #expect(MenuAppGlyph.score("TrayIconWindows", words: MenuAppGlyph.words("Wispr Flow")) == 0)
    }

    @Test("The user's installed menu bar apps draw their own status picture from the bundle's asset catalog, where installed (Sven, 2026-10-10)")
    func svensApps() throws {
        for (path, app, picked) in [("/Applications/Shottr.app", "Shottr", "shottr"), ("/Applications/Tailscale.app", "Tailscale", "statusbar"),
                                    ("/Applications/Reminders MenuBar.app", "Reminders MenuBar", "reminder")] {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            #expect(MenuAppGlyph.catalogNames(try #require(Bundle(url: url))).contains { $0.lowercased().contains(picked) }, "\(app): its catalog was not read")
            let image = try #require(MenuAppGlyph.template(at: url, app: app), "\(app): no picture")
            #expect(image.isTemplate && MenuAppGlyph.menuBarHeights.contains(image.size.height), "\(app): \(image.size)")
        }
    }

    /// An app bundle whose Resources hold only `StatusTemplate.png`, a black ring on clear: what a status item's
    /// template image looks like. Removed by the caller.
    static func fixtureBundle() throws -> (folder: URL, app: URL) {
        try fixtureBundle("Fixture", files: [("StatusTemplate.png", ring(18))])
    }

    @Test("An app's own template image, read from its bundle, draws in the bar's glyph colour and nothing else (card agent-bo-95423018, AC 4, Moody REJECT sbQO9aJoKjU)")
    func bundleTemplate() throws {
        let (folder, app) = try Self.fixtureBundle()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try #require(MenuAppGlyph.template(at: app, app: "Fixture"), "the bundle's StatusTemplate.png was not found")
        #expect(image.isTemplate)
        let rep = try StripStyleTests.alone(MenuAppIcon(glyph: .template(image), name: "Fixture"))
        try StripStyleTests.write(rep, "drawer/strip-bundle-template")
        let ground = StripStyleTests.ground(), ink = StripStyleTests.bytes(BarMetrics.glyphInk(StyleTokens.of(.instrument, theme: Look.shared.theme)))
        var full = 0, off = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let p = StripStyleTests.pixel(rep, x, y)
                if StripStyleTests.near(p, ink, 6) { full += 1 }
                if Self.offBlend(p, ground, ink) > 8 { off += 1 }
            }
        }
        #expect(full > 40, "\(full) pixels in the glyph colour: the ring is not drawn in it")
        #expect(off == 0, "\(off) pixels off the line from the ground to the glyph colour: drawn black, not as a template")
    }

    /// How far `p` is from the line between `a` and `b` in RGB: 0 for a blend of the two.
    static func offBlend(_ p: [UInt8], _ a: [UInt8], _ b: [UInt8]) -> Double {
        let d = (0..<3).map { Double(b[$0]) - Double(a[$0]) }, v = (0..<3).map { Double(p[$0]) - Double(a[$0]) }
        let len = d.reduce(0) { $0 + $1 * $1 }
        let t = len == 0 ? 0 : min(max(zip(v, d).reduce(0) { $0 + $1.0 * $1.1 } / len, 0), 1)
        return sqrt((0..<3).reduce(0) { $0 + pow(v[$1] - t * d[$1], 2) })
    }

    @Test("The open drawer in the user's bar: the chevron on its raised pill, then each app's glyph or icon (card agent-bo-95423018, renders)")
    func openRender() async throws {
        let (store, sources, timer) = try await Self.bar(otherApps: true)
        defer { timer.stop() }
        let kinds = Set(store.settings.preview(.topBar).top!.values.joined().flatMap(\.kinds)).subtracting([.otherApps])
        kinds.forEach(sources.readings.hold)
        defer { kinds.forEach(sources.readings.release) }
        #expect(try await SystemSamplerTests.wait { sources.sampler.history.count >= 3 })
        sources.readings.menuApps.drawer.toggle()
        let frames = StripStyleTests.Frames()
        let rep = try rendered(StripStyleTests.strip(store, sources, width: 1440, frames: frames), wait: 0.8)
        try StripStyleTests.write(rep, "drawer/strip-open")
        let open = try #require(frames.placed["Other apps"])
        #expect(open.width > 80, "open, the drawer is \(open.width) wide: the items did not slide out")
        #expect(StripStyleTests.resting(rep, bands: []).seeThrough == 0)
    }

    @Test("One button's menu is native: each app a section header over its items, a pick runs once the menu has closed")
    func oneButtonMenu() async throws {
        var pressed: [String] = []
        let owner = BarMenu()
        let menu = owner.menu(sections: [("Shottr", [("Shottr", { pressed.append("Shottr") })]),
                                         ("Control Centre", ["Wi-Fi", "Battery"].map { title in (title, { pressed.append(title) }) })])
        #expect(menu.items.map(\.title) == ["Shottr", "Shottr", "Control Centre", "Wi-Fi", "Battery"])
        #expect(menu.items.map(\.isSectionHeader) == [true, false, true, false, false])
        let battery = menu.items[4]
        testApp()
        #expect(NSApp.sendAction(try #require(battery.action), to: owner, from: battery))
        #expect(try await SystemSamplerTests.wait(seconds: 5) { pressed == ["Battery"] })
    }
}
}
