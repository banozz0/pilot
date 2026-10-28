import Foundation

/// My binds (SPEC.md, Interim layout; card agent-bo-95422700): Sven's keys as Hammerspoon had them on 2026-10-04. The
/// registered actions carry their own default keys; these are the binds only an app link can make. Zen by bundle id,
/// as Hammerspoon opened it, since Pilot's browser role follows the macOS default.
public enum MyBinds {
    public static let zen = "app.zen-browser.zen"

    public static let extras: [String: Key] = [
        AppLink.open(bundle: "com.madda.ghostex.gpui").id: Key("g"),
        AppLink.open(bundle: zen).id: Key("b"),
        // Hyper+T drops the terminal (spec Bar drops, Q105).
        AppLink.open(bundle: "com.tdesktop.Telegram").id: Key("t", .alt),
        AppLink.open(bundle: "dev.empryo.desktop").id: Key("z"),
        AppLink.url(bundle: zen, url: "https://claude.ai").id: Key("i"),
        AppLink.url(bundle: zen, url: "https://youtube.com").id: Key("y"),
        AppLink.url(bundle: zen, url: "https://open.spotify.com").id: Key("m"),
        AppLink.privateWindow(bundle: zen).id: Key("b", .shift),
        AppLink.open(bundle: "net.whatsapp.WhatsApp").id: Key("w", .shift),
        AppLink.open(bundle: "dev.vencord.vesktop").id: Key("v", .shift),
        AppLink.open(bundle: "com.openai.codex").id: Key("i", .shift),
        AppLink.url(bundle: zen, url: "https://mail.google.com").id: Key("e", .shift),
        AppLink.url(bundle: zen, url: "https://x.com").id: Key("x", .shift),
    ]

    /// The registry's default keys plus these. A registry default on one of their keys is a clash the store refuses
    /// and logs, so none is hidden: Hyper+B is Zen itself, and the browser role has no key here.
    public static func preset(registry: [String: Key]) -> [String: Key] {
        registry.merging(extras) { _, extra in extra }
    }
}
