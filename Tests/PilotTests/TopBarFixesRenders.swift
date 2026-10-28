#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// The top bar fixes of build 21 drawn in Instrument: TextEdit's menus in the centre, other apps' items as
/// template glyphs in the bar's text colour (installed apps' own icons with the tile keyed out), and the spacer stretched
/// to 160 points, plain and in edit mode with its grip. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-tbf PILOT_RENDER_DIR=/tmp/pilot-renders-tbf swift test --filter TopBarFixesRenders`
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
        readings.hold(.appMenus)
        defer { readings.release(.appMenus) }
        await menus.reading?.value

        let width: CGFloat = 1440
        look.style = .instrument
        let bar = TopBarView(screen: Self.screen, sources: sources, store: store, frames: BarFrames()).frame(width: width, height: 30)
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
}
}
#endif
