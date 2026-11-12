#if DEBUG
import AppKit
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// The top bar fixes of build 21 drawn in Instrument: TextEdit's menus in the centre, other apps' items as
/// template glyphs in the bar's text colour (installed apps' own icons with the tile keyed out), and the spacer stretched
/// to 160 points, plain and in edit mode with its grip. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-tbf PILOT_RENDER_DIR=/tmp/pilot-renders-tbf swift test --filter TopBarFixesRenders`
/// With `PILOT_LIVE=1` too, `live` draws the bar from this Mac's own menu bar items: Accessibility reads only, no press.
@MainActor
@Suite("Top bar fixes renders")
struct TopBarFixesRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let screen = "Studio"
    /// Menu bar apps on this Mac, as Sven's bar lists them.
    static let apps: [(String, String)] = [("Ghostex", "com.madda.ghostex.gpui"), ("Ghostty", "com.mitchellh.ghostty"), ("FluidVoice", "com.FluidApp.app"), ("Shottr", "cc.ffitch.shottr"), ("Stats", "eu.exelban.Stats"),
                                           ("Tailscale", "io.tailscale.ipn.macsys"), ("CodexBar", "com.steipete.codexbar"),
                                           ("NordVPN", "com.nordvpn.NordVPN"), ("Control Centre", "com.apple.controlcenter")]

    @Test("Centred app menus, other apps' glyphs and a stretched spacer, in Instrument", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let dir = try ClockRenders.dir("topbar-fixes")
        testApp()
        let look = Look.shared
        let (style, glass) = (look.style, look.glass)
        look.glass = false
        defer { (look.style, look.glass) = (style, glass) }

        let extras = MenuAppsTests.FakeExtras()
        extras.apps = Self.apps.enumerated().map { MenuExtrasApp(pid: pid_t(100 + $0.offset), name: $0.element.0, bundleId: $0.element.1) }
        extras.trees = Dictionary(uniqueKeysWithValues: extras.apps.map { app in
            (app.pid, [MenuExtrasRaw(title: nil, description: app.name, help: nil, handle: MenuItemHandle(app.name as NSString))])
        })
        let menuApps = MenuApps(reader: extras, ownPid: 13)
        await menuApps.refresh()
        menuApps.drawer.toggle()
        let width: CGFloat = 1440
        look.style = .instrument
        let bar = try await Self.bar(menuApps).frame(width: width, height: 30)
        try writeRender(bar, to: dir.appendingPathComponent("bar-instrument.png"), wait: 0.8)
        // Each app's glyph alone, larger, beside its app icon: what the mark keyed off.
        let row = HStack(spacing: 18) {
            ForEach(Self.apps, id: \.1) { name, bundle in
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        if let icon = AppsModule.icon(bundle: bundle) { Image(nsImage: icon).resizable().frame(width: 32, height: 32) }
                        MenuAppIcon(app: MenuExtrasApp(pid: 1, name: name, bundleId: bundle)).scaleEffect(2).frame(width: 40, height: 36)
                    }
                    Text(name).font(.caption)
                }
            }
        }
        .padding(16).environment(\.inTopBar, true).styled(.topBar).pilotTheme()
        .background(Color(StyleTokens.of(.instrument, theme: look.theme).colors.canvas))
        try writeRender(row, to: dir.appendingPathComponent("glyphs-instrument.png"), wait: 0.5)
    }

    /// macOS 27.2 gives no app an AXExtrasMenuBar; the items are read off MenuBarAgent's bar (Sven on 1.0.2 build 3:
    /// Other apps gone from the top bar). Pictures stay off, so nothing asks Screen Recording.
    @Test("This Mac's other apps in the top bar's open drawer", .enabled(if: env["PILOT_LIVE"] != nil && env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func live() async throws {
        let dir = try ClockRenders.dir("topbar-fixes")
        testApp()
        let look = Look.shared
        let (style, glass) = (look.style, look.glass)
        look.glass = false
        defer { (look.style, look.glass) = (style, glass) }
        try #require(AXIsProcessTrusted(), "the test's process needs Accessibility to read the menu bar")
        let menuApps = MenuApps(pictures: MenuItemPictures(isOn: { false }))
        await menuApps.refresh()
        print("other apps live: \(menuApps.list.map { "\($0.app.name) [\($0.items.map(\.label).joined(separator: ", "))]" })")
        #expect(!menuApps.list.isEmpty)
        menuApps.drawer.toggle()
        look.style = .instrument
        let bar = try await Self.bar(menuApps).frame(width: 1440, height: 30)
        try writeRender(bar, to: dir.appendingPathComponent("bar-live-instrument.png"), wait: 0.8)
    }

    /// The bar: TextEdit's menus in the centre, other apps on the right, a 160-point spacer and the clock.
    /// Notifications in each placement (Sven, 2026-11-12): the top bar's bell item with three new, a card and the list
    /// that drop under it; and floating, the cards above the bell bottom right. Above and Below apps draw alike offscreen
    /// (only the window level differs), so one floating picture serves both. Layout and words only: glass is off.
    @Test("Notifications in the top bar and floating", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func notifications() async throws {
        let dir = try ClockRenders.dir("notifications-placement")
        testApp()
        let look = Look.shared, settings = NotificationSettings.shared, model = NotificationCardsModel.shared
        let (glass, saved) = (look.glass, (settings.enabled, settings.showIn, settings.topBarOn))
        look.glass = false
        defer {
            look.glass = glass
            (settings.enabled, settings.showIn, settings.topBarOn) = saved
            (model.cards, model.drawer, model.unread) = ([], [], 0)
        }
        settings.topBarOn = { true }
        settings.enabled = true
        settings.showIn = .topBar
        let now = Date()
        let entries = [("Messages", "Maya", "Dinner at eight? I booked the place by the harbour."), ("Calendar", "Standup", "In 5 minutes, Room 2")]
            .enumerated().map { i, words in
                NotificationEntry(NotificationRead(id: "r\(i)", kind: .banner, app: words.0, title: words.1, subtitle: "", body: words.2, actions: [], opensReply: false),
                                  at: now.addingTimeInterval(Double(-90 * i)))
            }
        (model.cards, model.drawer, model.unread) = ([entries[0]], entries, 3)
        let width: CGFloat = 1440, ground = Color(white: 0.2)

        let bar = try await Self.bar(MenuApps(reader: MenuAppsTests.FakeExtras(), ownPid: 13), notifications: true).frame(width: width, height: 30)
        let dropped = HStack(alignment: .top, spacing: 16) {
            NotificationCardStack(model: model)
            NotificationBarDrawer(model: model)
        }
        .padding(.trailing, 16).styled(.barPopovers).pilotTheme()
        let topBar = VStack(alignment: .trailing, spacing: 8) { bar; dropped }.padding(.bottom, 16).frame(width: width).background(ground)
        try writeRender(topBar, to: dir.appendingPathComponent("top-bar.png"), wait: 0.8)

        settings.showIn = .floating
        (model.cards, model.unread) = (entries, 3)
        let floating = VStack(alignment: .trailing, spacing: NotificationPlacement.gap) {
            NotificationCardStack(model: model)
            NotificationBell(model: model) { _ in }
        }
        .padding(NotificationPlacement.margin).frame(width: width, height: 520, alignment: .bottomTrailing).background(ground)
        .styled(.barPopovers).pilotTheme()
        try writeRender(floating, to: dir.appendingPathComponent("floating.png"), wait: 0.8)
    }

    static func bar(_ menuApps: MenuApps, notifications: Bool = false) async throws -> TopBarView {
        let menus = AppMenus(reader: AppMenusTests.fake(), front: { AppMenusTests.textEdit }, center: NotificationCenter())
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: SetupKeepAwakeTests.FakeSources()),
                                   menuApps: menuApps, appMenus: menus, readBattery: { nil }, readWiFi: { nil }, clock: { ClockRenders.now },
                                   watchStats: { _ in Task {} })
        let sources = BarSources(readings: readings, observers: EngineObservers(), sampler: SystemSampler.shared,
                                 keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()), timer: ExtensionTimer(), pilotTitle: { "2" })
        let defaults = try #require(UserDefaults(suiteName: "pilot.renders.topbar-fixes"))
        defaults.removePersistentDomain(forName: "pilot.renders.topbar-fixes")
        let store = BarItemsStore(defaults: defaults) { [:] }
        store.settings.set(.group, on: false)
        store.settings.set(.timer, on: false)
        for kind in [BarKind.appMenus, .otherApps, .volume, .spacer, .clock] { store.settings.set(kind, on: true) }
        store.settings.set(.clock, style: .time)
        store.settings.place(.spacer, on: .left, at: 2)
        store.settings.place(.appMenus, on: .centre, at: 0)
        store.settings.place(.clock, on: .right, at: .max)
        store.settings.setSpacer(width: 160)
        if notifications { store.settings.set(.notifications, on: true) }
        readings.hold(.appMenus)
        defer { readings.release(.appMenus) }
        await menus.reading?.value
        return TopBarView(screen: screen, sources: sources, store: store, frames: BarFrames())
    }
}
}
#endif
