import Foundation
import Testing
@testable import PilotCore

/// Drive another app (card agent-bo-95422444, stories 45 and 47): a bind runs another app's URL, one of its menu items
/// by title path, a keystroke into the focused app, a Shortcuts shortcut or a shell command, named by its action id.
@Suite("Drive routes")
struct DriveRouteTests {
    @Test("Each id reads back to its route and writes the same id")
    func roundTrip() {
        let cases: [(String, DriveRoute)] = [
            ("drive.url:shottr://grab/window", .url("shottr://grab/window")),
            ("drive.menu:com.apple.finder:File > New Finder Window", .menu(bundle: "com.apple.finder", path: ["File", "New Finder Window"])),
            ("drive.key:shift+cmd+T", .keystroke(Key("t", [.shift, .cmd], hyper: false))),
            ("drive.shortcut:Morning routine", .shortcut("Morning routine")),
            ("drive.shell:touch /tmp/pilot-drive-probe", .shell("touch /tmp/pilot-drive-probe")),
        ]
        for (id, route) in cases {
            #expect(DriveRoute(id: id) == route)
            #expect(route.id == id)
        }
    }

    @Test("A keystroke reads any case and spelling of its keys; an unknown key or modifier is no route")
    func keystroke() {
        #expect(DriveRoute(id: "drive.key:cmd+shift+t") == .keystroke(Key("t", [.cmd, .shift], hyper: false)))
        #expect(DriveRoute(id: "drive.key:Ctrl+Left") == .keystroke(Key("←", .ctrl, hyper: false)))
        #expect(DriveRoute(id: "drive.key:leftAlt+h") == .keystroke(Key("h", .leftAlt, hyper: false)))
        #expect(DriveRoute(id: "drive.key:hyper+t") == nil)
        #expect(DriveRoute(id: "drive.key:cmd+nokey") == nil)
        #expect(DriveRoute(id: "drive.key:") == nil)
    }

    @Test("A route with nothing to run is no route, and other actions are not drive routes; macOS's own menus are never pressed")
    func refused() {
        for id in ["drive.url:", "drive.shell:", "drive.shortcut:", "drive.menu:com.apple.finder", "drive.menu::File > New",
                   "drive.menu:com.apple.finder:File >  ", "drive.copy", "windows.close", "apps.open:com.apple.finder"] {
            #expect(DriveRoute(id: id) == nil, "\(id)")
        }
        // Control Centre, the menu extras and the login window can switch radios or end the session (T52 review).
        for bundle in ["com.apple.controlcenter", "com.apple.ControlCenter", "com.apple.systemuiserver", "com.apple.MenuBarAgent", "com.apple.loginwindow",
                       "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.TextInputMenuAgent"] {
            #expect(!DriveRoute.pressesMenus(of: bundle, regular: true), "\(bundle)")
        }
        // Any other com.apple. agent is refused by its activation policy; another maker's accessory app is not.
        #expect(!DriveRoute.pressesMenus(of: "com.apple.Siri", regular: false) && !DriveRoute.pressesMenus(of: "com.apple.WindowManager", regular: false))
        #expect(DriveRoute.pressesMenus(of: "com.apple.finder", regular: true) && DriveRoute.pressesMenus(of: "com.mitchellh.ghostty", regular: false))
    }

    @Test("Shell commands run in a child login shell, Shortcuts through shortcuts run; the others run no child")
    func command() {
        #expect(DriveRoute.shell("echo hi > f").command(loginShell: "/bin/zsh") == .init(path: "/bin/zsh", arguments: ["-l", "-c", "echo hi > f"]))
        #expect(DriveRoute.shortcut("Morning").command(loginShell: "/bin/zsh") == .init(path: "/usr/bin/shortcuts", arguments: ["run", "Morning"]))
        #expect(DriveRoute.url("shottr://ocr").command(loginShell: "/bin/zsh") == nil)
    }

    @Test("The Binds screen names a route in plain words")
    func label() {
        #expect(DriveRoute.menu(bundle: "com.apple.finder", path: ["File", "New Finder Window"]).label(appName: "Finder") == "Finder: File › New Finder Window")
        #expect(DriveRoute.keystroke(Key("t", [.cmd, .shift], hyper: false)).label(appName: nil) == "Keystroke Shift+Cmd+T")
        #expect(DriveRoute.url("shottr://ocr").label(appName: nil) == "Open shottr://ocr")
        #expect(DriveRoute.shortcut("Morning").label(appName: nil) == "Shortcut: Morning")
        #expect(DriveRoute.shell("touch f").label(appName: nil) == "Shell: touch f")
    }

    @Test("A drive bind the user set survives the bind file's round trip")
    func storeKeepsIt() throws {
        let id = DriveRoute.shell("touch /tmp/x").id
        var store = BindStore(defaults: [:])
        try store.set(id, to: Key("y", .shift))
        let read = try BindStore(json: store.json(), defaults: [:])
        #expect(read.action(for: Key("y", .shift)) == id)
    }
}

/// Picker actions (card agent-bo-95422698, story 48): a bind runs a command, shows its lines as a list, and runs a
/// second command with the pick.
@Suite("Picker routes")
struct PickerRouteTests {
    let route = DriveRoute.picker(title: "Audio output", list: "printf 'a\\nb\\n'", run: #"printf %s "$1" > /tmp/pick"#)

    @Test("A picker's id reads back to its title and both commands, whatever they quote")
    func roundTrip() {
        #expect(DriveRoute(id: route.id) == route)
        #expect(route.id.hasPrefix("drive.pick:"))
        #expect(DriveRoute(id: #"drive.pick:{"list":"ls","run":""}"#) == nil)
        #expect(DriveRoute(id: "drive.pick:ls") == nil)
        #expect(DriveRoute.picker(title: " ", list: "ls", run: "x").checked == .picker(title: nil, list: "ls", run: "x"))
        #expect(DriveRoute(id: #"drive.pick:{"list":"ls","run":"open \"$1\""}"#) == .picker(title: nil, list: "ls", run: #"open "$1""#))
    }

    @Test("The list command runs in a login shell; each non-empty line is a row, once")
    func rows() {
        #expect(route.command(loginShell: "/bin/zsh") == .init(path: "/bin/zsh", arguments: ["-l", "-c", "printf 'a\\nb\\n'"]))
        #expect(DriveRoute.rows("a\n\n b \na\r\nc") == ["a", "b", "c"])
    }

    @Test("The pick reaches the second command as $1, never pasted into its text")
    func pickCommand() {
        #expect(route.pickCommand(loginShell: "/bin/zsh", pick: "b; rm -rf ~") ==
                .init(path: "/bin/zsh", arguments: ["-l", "-c", #"printf %s "$1" > /tmp/pick"#, "pilot-pick", "b; rm -rf ~"]))
        #expect(DriveRoute.shell("x").pickCommand(loginShell: "/bin/zsh", pick: "b") == nil)
    }

    @Test("The Binds screen names a picker by its title, else its list command")
    func label() {
        #expect(route.label(appName: nil) == "Pick: Audio output")
        #expect(DriveRoute.picker(title: nil, list: "ls ~/code", run: "x").label(appName: nil) == "Pick from: ls ~/code")
    }
}
