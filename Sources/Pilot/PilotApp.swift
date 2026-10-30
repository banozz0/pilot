import PilotCore
import SwiftUI

@main
struct PilotApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var engine = Engine()
    /// Decided once at launch: onboarding opens by itself only while Accessibility is missing or a run is unfinished.
    private let needsOnboarding: Bool

    init() {
        MallocMode.forgetForChildren()
        needsOnboarding = OnboardingWindow.opensAtLaunch()
    }

    var body: some Scene {
        Window("Welcome to Pilot", id: "onboarding") {
            OnboardingView().environment(engine)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(needsOnboarding ? .presented : .suppressed)
        // Without this, SwiftUI opens the first scene for every pilot:// URL nothing claims: the Welcome window.
        .handlesExternalEvents(matching: [])

        // While the app window is open Pilot has its own menu bar: Cmd+, opens the window from there too.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Open Pilot…") { AppWindowController.shared.open() }.keyboardShortcut(",")
            }
        }
    }
}

/// Info.plist's LSEnvironment starts Pilot in libmalloc's space-efficient mode (story 142): memory Pilot frees goes back
/// to macOS instead of staying in its footprint. Measured in a test process on 2026-10-11: 158 against 69 MB after every
/// page of the app window was shown and the window freed, 79 against 19 MB after a Vision read, the same CPU.
enum MallocMode {
    static let variable = "MallocSpaceEfficient"

    /// libmalloc reads it once, as the process starts; off the environment then, so the shells and tools Pilot starts
    /// keep the Mac's default.
    static func forgetForChildren() { unsetenv(variable) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigterm: DispatchSourceSignal?
    private let services = PilotServices()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXIsProcessTrusted() { NSApp.activate() }
        AXTimeout.applyEverywhere()
        // The themes' display faces, for Pilot only; then Reduce transparency, Increase contrast and the wallpaper's
        // brightness, followed live (card agent-bo-95422890).
        DisplayFaces.registerInBackground()
        Look.shared.followSystem()
        Engine.shared?.launch()
        // Sparkle's daily check, in a release bundle only (SH6); it asks the user first, on the second launch.
        PilotUpdates.shared.start()
        // The bar items in the macOS menu bar, as the store places them (cards agent-bo-95422833, 910 and 911).
        if let engine = Engine.shared { MenuBarStatusItems.shared.start(engine.barSources) }
        // Setup's Extras downloads a quit cut off start again, and show on Pilot's item as they run (Sven, 2026-10-29).
        ExtrasDownloads.shared.resume()
        // A speech model or Kokoro download pressed in Settings, cut off the same way, goes on too.
        SpeechModels.shared.resume()
        KokoroModel.shared.resume()
        // Nothing about this Mac is read while the screen is locked or asleep (card agent-bo-95422839).
        // The sampler, the bars' timed readings, the secure-input check and the clipboard's poll all wait for an unlock.
        let engine: [any ScreenPausing] = Engine.shared.map { [$0.barSources.readings, $0.secureInput] } ?? []
        ScreenEvents.shared.start(pausing: [SystemSampler.shared, ClipboardHistory.shared, WallpaperSettings.shared] + engine)
        // Look › Wallpaper's Change on its own (story 160): a timer only while an interval is set.
        WallpaperSettings.shared.schedule()
        // Defaults › Folders' GIFs folder, handed to Stickers before the menu first lists it.
        _ = PilotFolders.shared
        // Stats' 1 hour and Today (card agent-bo-95422992): a reading a minute all day, paused with the rest while locked.
        SystemSampler.shared.loadMinutes()
        // Each screen's brightness route and level, read off the main thread (story 144).
        ScreenBrightness.start()
        // Display membership only observes launch/wake/reconfiguration; it never changes a desktop automatically.
        DisplayConnections.shared.startObserving()
        // A screen's rotation, put back when macOS applies another set of screens' layout (Sven 2026-10-24).
        SetupDisplays.shared.followRotations()
        // A mouse plugged in gets the pointer speed, once Pilot has set one (System › Mouse, Q442).
        PointerSpeed.start()
        Task { await SystemSampler.shared.watch(every: SystemSampler.historyInterval, needs: .history) }
        // Low-battery alerts (Q394): the Bluetooth batteries with the slow readings while the setting is on.
        LowBatteryAlerts.shared.follow()
        // A kill or a logout sends SIGTERM; route it through terminate so the Caps Lock remap is undone.
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApp.terminate(nil) }
        sigterm?.resume()
        // Finder's Convert with Pilot… (Info.plist NSServices, card agent-bo-95423211).
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        // The pilot command's socket (ADR 0013).
        ControlSocket.serve()
    }

    /// pilot://press?layer=capslock|lctl|rctl|lopt|ropt|lcmd|rcmd|chord|plain&key=k[&tap=1][&shift=1][&ctrl=1][&alt=1|left|right][&cmd=…][&app=Finder]&token=… posts the keys itself (the manual test
    /// protocol; with app, only once that app is frontmost; the token always, LinkToken); pilot://run?action=windows.close[&app=Finder] runs an action by id
    /// (a command, keystroke or non-web URL with the link token, LinkToken);
    /// pilot://observers prints the observers to the log; pilot://reload-binds reads the bind store's file again;
    /// pilot://bind?action=…&key=…[&shift=1][&ctrl=1][&alt=1] or &unbind=1 or &reset=1 changes one bind (Engine.bind);
    /// pilot://alert?text=… shows a tip, the alert Hammerspoon's hammerspoon://fence showed for scripts;
    /// pilot://open[?page=tiling] opens the app window, on that page (Setup also takes &section=wifi and the like); pilot://install?package=formula:hello asks to install a
    /// package (confirm first) and pilot://installed?package=… and pilot://removed?package=… are the
    /// visible terminal's success hooks (InstallModule);
    /// pilot://import?pack=…|file=… opens Export and import with that file's binds to preview (story 58);
    /// pilot://bar?move=cpu&side=left&index=2, ?add=… or ?remove=… edits the top bar as the Menu bar page's strip does,
    /// ?edit=1 opens that page; no link token needed: it only changes bar.items (BarRoute, card agent-bo-95423017).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host {
            // `&tab=page` with `extension=<id>` opens that extension's page (story 161).
            case "open" where url.queryValue("tab") == "page" && url.queryValue("extension") != nil:
                AppWindowController.shared.openExtensionPage(url.queryValue("extension")!)
            case "open": AppWindowController.shared.open(AppPlace.linked(url), setup: SetupSection.linked(url), extension: url.queryValue("extension"))
            case "import":
                BindImport.shared.open(url)
                AppWindowController.shared.open(.exportImport)
            case "press": Engine.shared?.testPress(url)
            case "run": Engine.shared?.runAction(url)
            case "observers": Engine.shared?.printObservers()
            case "reload-binds": Engine.shared?.binds.load()
            case "bind": Engine.shared?.bind(url)
            case "install": InstallModule.install(url)
            case "installed": InstallModule.recordInstalled(url)
            case "removed": InstallModule.recordRemoved(url)
            case "bar": BarItemsStore.shared.route(url)
            case "alert":
                let text = url.queryValue("text") ?? ""
                log.notice("alert: \(text, privacy: .public)")
                if !text.isEmpty { HUD.tip(text) }
            default: log.error("unknown url \(LinkToken.redact(url.absoluteString), privacy: .public)")
            }
        }
    }

    /// Pilot lives in the menu bar: the last window going (a HUD panel hidden at launch, Cmd+W on the app window) never
    /// quits it. SwiftUI said no here only while a MenuBarExtra scene existed; without it its default quit Pilot the
    /// moment its first panel went, about 150 ms after launch (lane 1's P1 after card agent-bo-95422912).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening Pilot.app while it runs (a double-click, Spotlight, `open -a Pilot`) opens its window; while Welcome is
    /// open it brings Welcome forward instead, as the app window waits until onboarding is done (first run, 2026-10-28).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if OnboardingWindow.bringForward() { return false }
        AppWindowController.shared.open()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A recording running or closing is finished first, so quitting never loses it (story 192); at most 10 s.
        let recorder = Recorder.shared
        if recorder.isActive || recorder.closing != nil {
            var replied = false
            let reply = { @MainActor in
                guard !replied else { return }
                replied = true
                Engine.shared?.quit()
                SystemSampler.shared.saveMinutes()
                sender.reply(toApplicationShouldTerminate: true)
            }
            recorder.stop(then: reply)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { MainActor.assumeIsolated { reply() } }
            return .terminateLater
        }
        Engine.shared?.quit()
        SystemSampler.shared.saveMinutes()
        return .terminateNow
    }
}
