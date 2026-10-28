/// One app's lifecycle as seen in a change to the running apps (card agent-bo-95422739). NSWorkspace's launch and
/// terminate notifications never arrive for menu-bar-only apps such as the old tiler (seen live 2026-10-04, card
/// agent-bo-95422738) and Hammerspoon without its Dock icon, so Pilot watches runningApplications instead.
public enum AppLifecycle {
    /// Whether one change ended and launched `bundleId`, given the bundle ids added and removed. A caller runs ended
    /// first, so a quit and relaunch in one change leaves the app launched.
    public static func change(for bundleId: String, added: [String?]?, removed: [String?]?) -> (ended: Bool, launched: Bool) {
        (removed?.contains(bundleId) == true, added?.contains(bundleId) == true)
    }
}
