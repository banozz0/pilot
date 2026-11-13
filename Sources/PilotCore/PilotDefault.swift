import Foundation

/// Pilot default (SPEC story 149): the preset a new install starts on. Since 1.0 it is Sven's own layout, his Arrows 2
/// preset's keys as they were on 2026-10-28 (Sven, Q531: "Your binds exactly as they are"): My binds' table with the
/// keys he set by hand, frozen here so a registry default that moves later never changes what a stranger gets. Keys
/// that open an app the Mac lacks stay bound and do nothing but log "not installed".
public enum PilotDefault {
    public static let binds: [String: Key] = {
        var b: [String: Key] = [
        "ai.chat": Key("q"),
        "apps.browser": Key("b"),
        "apps.clipboard": Key("v"),
        "apps.clipboardOptionV": Key("v", .alt, hyper: false),
        "apps.emoji": Key("e"),
        "apps.files": Key("f"),
        "apps.generatePassword": Key("p", .shift),
        "apps.launcher": Key("space"),
        "apps.lazygit": Key("l", .shift),
        "apps.open:com.madda.ghostex.gpui": Key("g"),
        "apps.open:com.openai.codex": Key("o"),
        "apps.open:dev.vencord.vesktop": Key("d"),
        "apps.open:net.whatsapp.WhatsApp": Key("w", .shift),
        "apps.open:rocks.spotifast.Spotifast": Key("m"),
        "apps.passwords": Key("p"),
        "apps.terminal": Key("return"),
        // Sven's own GitHub web app is his alone: a new install opens the site (Q542).
        "apps.web:https://github.com": Key("g", .shift),
        "apps.web:https://www.youtube.com": Key("y"),
        "apps.web:https://x.com": Key("x"),
        "captures.area": Key("s"),
        "captures.editLast": Key("e", .shift),
        "captures.fullscreen": Key("a"),
        "captures.ocr": Key("x", .shift),
        "captures.screenRecording": Key("r"),
        "captures.scrolling": Key("z"),
        "drive.moveTabLeft": Key("left", [.ctrl, .alt]),
        "drive.moveTabRight": Key("right", [.ctrl, .alt]),
        "drive.nextTab": Key("right", .alt),
        #"drive.pick:{"list":"ls ~/code","run":"open \"$HOME/code/$1\"","title":"Open a code folder"}"#: Key(";"),
        "drive.previousTab": Key("left", .alt),
        "drive.zoomIn": Key("="),
        "drive.zoomOut": Key("-"),
        "media.mute": Key("F10"),
        "media.next": Key("F9"),
        "media.playPause": Key("F8"),
        "media.previous": Key("F7"),
        "media.volumeDown": Key("F11"),
        "media.volumeUp": Key("F12"),
        "notes.toggle": Key("n"),
        "system.brightnessDown": Key("F1"),
        "system.brightnessDownAll": Key("F1", .shift),
        "system.brightnessUp": Key("F2"),
        "system.brightnessUpAll": Key("F2", .shift),
        "system.infoHUD": Key("t", [.ctrl, .alt]),
        "system.lock": Key("escape"),
        "system.missionControl": Key("up", .leftAlt, hyper: false),
        "system.nextWallpaper": Key("space", .shift),
        "system.previousWallpaper": Key("space", .ctrl),
        "terminal.drop": Key("t"),
        "windows.centre": Key("c"),
        "windows.close": Key("w"),
        "windows.cycle": Key("down", [.ctrl, .alt]),
        "windows.cycleBack": Key("up", [.ctrl, .alt]),
        "windows.defocus": Key("d", .shift),
        "windows.firstThird": Key("left", [.shift, .cmd]),
        "windows.firstThreeQuarters": Key("["),
        // Q195 (Sven, 2026-11-13): Hyper+Ctrl+arrows nudge; the display keys took their registry defaults.
        "windows.focusDisplayLeft": Key(","),
        "windows.focusDisplayRight": Key("."),
        "windows.focusDown": Key("down"),
        "windows.focusLeft": Key("left"),
        "windows.focusNext": Key("tab"),
        "windows.focusRight": Key("right"),
        "windows.focusUp": Key("up"),
        "windows.fullscreen": Key("f", .shift),
        "windows.grow": Key("=", .shift),
        "windows.joinDown": Key("down", [.shift, .alt]),
        "windows.joinLeft": Key("left", [.shift, .alt]),
        "windows.joinRight": Key("right", [.shift, .alt]),
        "windows.joinUp": Key("up", [.shift, .alt]),
        "windows.lastQuarter": Key("]"),
        "windows.lastThird": Key("right", [.shift, .cmd]),
        "windows.maximise": Key("up", .cmd),
        "windows.middleThird": Key("up", [.shift, .cmd]),
        "windows.minimise": Key("h"),
        "windows.nudgeDown": Key("down", .ctrl),
        "windows.nudgeLeft": Key("left", .ctrl),
        "windows.nudgeRight": Key("right", .ctrl),
        "windows.nudgeUp": Key("up", .ctrl),
        "windows.sendToDisplayLeft": Key(",", .shift),
        "windows.sendToDisplayRight": Key(".", .shift),
        "windows.showDesktop": Key("down", .leftAlt, hyper: false),
        "windows.shrink": Key("-", .shift),
        "windows.snapBottom": Key("down", [.alt, .cmd]),
        "windows.snapLeft": Key("left", .cmd),
        "windows.snapRight": Key("right", .cmd),
        "windows.snapTop": Key("up", [.alt, .cmd]),
        "windows.swapDown": Key("down", .shift),
        "windows.swapLeft": Key("left", .shift),
        "windows.swapRight": Key("right", .shift),
        "windows.swapUp": Key("up", .shift),
        "windows.toggleFloat": Key("t", .shift),
        "workspaces.former": Key("`"),
        "workspaces.rescue": Key("escape", .shift),
        "workspaces.toggleGaps": Key("delete", .shift),
        ]
        for name in Workspaces.all {
            b["workspaces.go:\(name)"] = Key(name)
            b["workspaces.move:\(name)"] = Key(name, .shift)
        }
        // Moving a window and following it, Hyper+Alt+5 to 9 (1 to 4 left free).
        for name in Workspaces.all.dropFirst(4) { b["workspaces.moveFollow:\(name)"] = Key(name, .alt) }
        return b
    }()

    /// Sven's mouse buttons, trigger → action, which a new install's bind file starts with (Binds' first load): each one
    /// whose action is on that Mac, so Mouse 4 stays Back where his Now Playing extension is not.
    public static let mouse: [Key: String] = [
        Key("Mouse 3", hyper: false): "apps.terminal",
        Key("Mouse 3"): "drive.actualSize",
        Key("Mouse 4", hyper: false): "ext.now-playing.playpause",
        Key("Mouse 4"): "drive.zoomOut",
        Key("Mouse 5", hyper: false): "drive.key:Escape",
        Key("Mouse 5"): "drive.zoomIn",
        Key("Mouse Scroll Up"): "media.volumeUp",
        Key("Mouse Scroll Down"): "media.volumeDown",
    ]

    /// Start from scratch: empty but the Pilot menu, so a new preset never locks its maker out.
    public static let scratch: [String: Key] = ["apps.launcher": Key("space")]
}
