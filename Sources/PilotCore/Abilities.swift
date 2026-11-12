import Foundation

/// Every ability Pilot has, findable in one list (story 155, task C7; Sven 2026-10-09: he did not know Quick AI, Next
/// wallpaper or file search existed): each registered action with one line of what it does and its key, and what the
/// Hyper+Space menu answers when typed, which no action names. Launcher › Abilities draws it (page map, Sven 2026-10-17:
/// the Menu page is Launcher).
public enum Abilities {
    public struct Ability: Identifiable, Equatable, Sendable {
        /// The action's id, or `typed.<name>` for what the menu answers.
        public var id: String
        public var name: String
        /// One line of what it does.
        public var what: String
        /// The key that runs it now, "Hyper+Ctrl+Space"; a typed ability's is the menu's key. Nil: no key yet.
        public var key: String?
        /// What Try types into the menu (empty: nothing) for a typed ability; nil for an action, which Set key binds.
        public var typing: String?
        /// Try runs it from the app window: not for one that acts on the window in front (Pilot's own then), types into
        /// it, powers the Mac off, cuts the network or rewrites another app's settings.
        public var canTry = true

        /// The action Set key binds; nil for a typed ability, which has none.
        public var action: String? { typing == nil ? id : nil }
    }

    public struct Group: Identifiable, Equatable, Sendable {
        /// The actions' module, nil for what the menu answers when typed.
        public var module: String?
        public var abilities: [Ability]
        public var id: String { module ?? "typed" }
        public var title: String { module.map(Abilities.title) ?? "Type in the menu" }
    }

    /// What the menu answers when typed at its root, which no action names (the calculator, file search, Ask AI);
    /// `groups` gives each the menu's key.
    public static let typed: [Ability] = [
        typed("calculator", "Calculator", "Type a sum or a unit, 12*7 or 10 km in mi; Return copies the answer.", "12*7"),
        typed("world", "Money, time zones and dates", "40 eur in usd, time in tokyo, today + 30 days; Return copies it.", "time in tokyo"),
        typed("ask", "Ask AI", "Type ask and a question; the AI chat opens under the top bar with it sent, answered by the AI picked on the AI page, on your own plan or key.", "ask "),
        typed("translate", "Translate", "Type tr and the words; Return copies the translation.", "tr hola"),
        typed("define", "Define", "Type def and a word; its meanings, synonyms and Spanish fill the menu, Return pastes the one picked.",
              "def serendipity"),
        typed("reminder", "Reminders", "Type a time and words, 20m stretch; Pilot reminds you then.", "20m stretch"),
        typed("event", "Calendar events", "Type event, the words and a day or time, event lunch with Ana tomorrow 1pm; Return adds it to your calendar without opening Calendar.",
              "event "),
        typed("files", "File search", "Type part of a file's name; Cmd+K on a file opens, reveals or converts it."),
        typed("windows", "Windows", "Type a window's title to bring it forward, on any workspace."),
        typed("menuItems", "Menu items of the app you were in", "Type a menu item's name to click it without the mouse."),
        // P38: the drive catalogue's commands of the apps on this Mac.
        typed("appCommands", "App commands", "Type an app's name or what it does, music or new event; Return runs that app's own command.",
              "new event"),
        typed("emoji", "Emoji", "Type a word, fire or heart; Return types the emoji where you were.", "fire"),
        typed("quicklinks", "Quicklinks", "Type a quicklink's keyword and words to open a search; make them on Launcher › More › Quicklinks."),
        // Its GIFs folder and GIPHY key sit under this row on Launcher › Abilities (page map, Sven 2026-10-17).
        typed("stickers", "Stickers and GIFs", "Open Actions › Stickers and GIFs: emoji as pictures, your GIFs folder and GIPHY's; Return pastes one.",
              "stickers"),
        typed("snippets", "Snippets", "Type a snippet's keyword in any app, or here, to paste its text; write them on the Snippets page."),
    ]

    private static func typed(_ id: String, _ name: String, _ what: String, _ typing: String = "") -> Ability {
        Ability(id: "typed.\(id)", name: name, what: what, typing: typing)
    }

    /// The groups the list shows, typed first (what nothing else names), then by module; each by name. `actions` are the
    /// Binds screen's (BindsPage.actions), so every action Binds lists is here; a typed ability wears the key of `menu`,
    /// the Hyper+Space menu's action. Modules come in the keyboard legend's order (BindsKeyboard.module).
    public static func groups(actions: [BindsPage.ActionInfo], store: BindStore, menu: String, search: String = "") -> [Group] {
        let menuKey = store.trigger(for: menu)?.label
        let byModule = Dictionary(grouping: actions, by: \.module)
        let modules = byModule.keys.sorted { (BindsKeyboard.module($0), $0) < (BindsKeyboard.module($1), $1) }
        let all = [Group(module: nil, abilities: typed.map { var a = $0; a.key = menuKey; return a })] + modules.map { module in
            let rows = (byModule[module] ?? []).map { a in
                Ability(id: a.id, name: a.label, what: what(a.id, label: a.label), key: store.trigger(for: a.id)?.label, canTry: canTry(a.id))
            }
            return Group(module: module, abilities: rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        let filter = FuzzyRanker.Filter(search)
        guard !filter.typed.isEmpty else { return all }
        let keywords = Dictionary(actions.map { ($0.id, $0.keywords ?? "") }, uniquingKeysWith: { a, _ in a })
        func found(_ test: ([String]) -> Bool) -> [Group] {
            all.compactMap { group in
                let hits = group.abilities.filter { a in test([a.name, a.what, group.title, a.key ?? "", keywords[a.id] ?? ""]) }
                return hits.isEmpty ? nil : Group(module: group.module, abilities: hits)
            }
        }
        return filter.search(found)
    }

    /// Abilities ship minimal (Sven 2026-10-10): these drive one app or one setup, so a new Mac lists none of them until
    /// the app is here and they are added from Launcher › Abilities › More abilities. One that holds a key is always listed,
    /// so a bind never hides. The app links a preset makes (`apps.open:`, `apps.url:`) need no entry: one that holds a key is listed (Pilot default's Ghostex, Codex…).
    /// Each needs what Install's catalogue checks for: an app by bundle id, a file, or a command.
    public static let optional: [String: CatalogueEntry.Check] = [
        "apps.bitwardenFill": .bundle(Bitwarden.bundle), "apps.bitwardenForget": .bundle(Bitwarden.bundle),
        "apps.bitwardenLock": .bundle(Bitwarden.bundle), "apps.bitwardenGenerator": .bundle(Bitwarden.bundle),
        "apps.bitwardenSearch": .bundle(Bitwarden.bundle), "apps.generatePassword": .bundle(Bitwarden.bundle),
        "apps.lazygit": .command("lazygit"),
        "look.ghosttyApply": .bundle("com.mitchellh.ghostty"), "look.ghosttyRemove": .bundle("com.mitchellh.ghostty"),
    ]

    /// Pilot's own actions that work one app, by its bundle id, so typing the app's name lists them under it (T41): the
    /// optional ones that need an app (Bitwarden's Generate a password) and these, which are always listed.
    static let appActions: [String: String] = [
        "system.newEvent": "com.apple.iCal", "system.openFullDiskAccess": "com.apple.systempreferences",
    ]

    /// The app one of Pilot's own actions works, nil for an action of no one app.
    public static func app(of id: String) -> String? {
        if case .bundle(let bundle)? = optional[id] { return bundle }
        return appActions[id]
    }

    /// Whether the Binds screen, the menu and Abilities list an action: a shipped one always, an optional one while it
    /// holds a key, or once added with what it needs here.
    public static func isListed(_ id: String, bound: Bool, added: Set<String>, has: (CatalogueEntry.Check) -> Bool) -> Bool {
        guard let need = optional[id] else { return true }
        return bound || (added.contains(id) && has(need))
    }

    /// More abilities: the optional ones not listed whose app is here, by name, for Add; `actions` is every action,
    /// the unlisted included.
    public static func addable(actions: [BindsPage.ActionInfo], listed: (String) -> Bool, has: (CatalogueEntry.Check) -> Bool,
                               search: String = "") -> [Ability] {
        let rows = actions.compactMap { a -> (row: Ability, fields: [String])? in
            guard let need = optional[a.id], !listed(a.id), has(need) else { return nil }
            let row = Ability(id: a.id, name: a.label, what: what(a.id, label: a.label), canTry: false)
            return (row, [row.name, row.what, title(a.module), a.keywords ?? ""])
        }
        return FuzzyRanker.Filter(search).filter(rows, \.fields).map(\.row)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func title(_ module: String) -> String { module == "engine" ? "Pilot" : module.prefix(1).uppercased() + module.dropFirst() }

    /// What an action does in one line; one Pilot makes per app, site or script names what it opens or runs.
    public static func what(_ id: String, label: String) -> String {
        if let line = lines[id] { return line }
        for (prefix, line) in prefixed where id.hasPrefix(prefix) {
            return line.replacingOccurrences(of: "%", with: String(id.dropFirst(prefix.count)))
                .replacingOccurrences(of: "@", with: label)
        }
        return "Runs \(label)."
    }

    /// Try is offered unless running it from the app window would act on Pilot's own window, type into it, power the Mac
    /// off, cut the network, wipe notifications, run a script, or rewrite another app's settings.
    public static func canTry(_ id: String) -> Bool {
        if noTry.contains(id) { return false }
        return !noTryPrefixes.contains { id.hasPrefix($0) }
    }

    static let noTryPrefixes = ["windows.", "drive.", "workspaces.move:", "workspaces.moveFollow:", "scripts.run:", "ext."]
    static let noTry: Set<String> = [
        "workspaces.saveSnapshot", "workspaces.restoreSnapshot", "workspaces.openLayout", "workspaces.rescue", "workspaces.toggleGaps", "workspaces.cycleLayout",
        "system.lock", "system.sleep", "system.restart", "system.shutDown", "system.logOut", "system.wifi", "system.bluetooth", "system.ejectAll",
        "system.clearAllNotifications", "system.clearNotification", "system.idleLock",
        "engine.hyper", "engine.tilingOff", "engine.openWindow", "bar.peekMenuBar",
        "apps.pastePlain", "apps.bitwardenFill", "apps.bitwardenLock", "apps.bitwardenForget", "ai.fix", "ai.selection", "ai.selectionTools", "speech.readAloud",
        "look.ghosttyApply", "look.ghosttyRemove",
        "dictation.toggle", "dictation.hold", "cursor.spotlight",
    ]

    /// Actions made per app, site, script or setting, by id prefix: % is the rest of the id, @ the action's label.
    static let prefixed: [(String, String)] = [
        ("workspaces.go:", "Shows workspace % and its windows."),
        ("rings.open:", "Held, opens this ring of actions at the pointer: flick toward one and let go to run it."),
        ("workspaces.move:", "Sends the window in front to workspace %."),
        ("workspaces.moveFollow:", "Sends the window in front to workspace % and goes there with it."),
        ("apps.open:", "Opens @, or brings it forward."),
        ("apps.web:", "Opens the web app @."),
        ("apps.url:", "Opens @ in your browser."),
        ("apps.private:", "Opens @ in a private window."),
        ("links.open:", "Opens the quicklink @."),
        ("configs.edit:", "Opens @ in your editor."),
        ("scripts.run:", "Runs your script @."),
        ("ext.", "Runs the extension command @."),
        ("drive.shell:", "Runs a shell command: @."),
        ("drive.url:", "Opens @."),
        ("drive.menu:", "Clicks @ in the app's menu."),
        ("drive.key:", "Presses @ in the app in front."),
        ("drive.shortcut:", "Runs the Shortcut @."),
        ("drive.", "Drives the app in front: @."),
        ("system.output:", "Sends the Mac's sound to @."),
    ]

    static let lines: [String: String] = [
        // Pilot
        "engine.sheet": "Opens every bind in the menu's Learn › Keybindings; Return runs one.",
        "engine.openWindow": "Opens this window.",
        "engine.hyper": "Turns the Hyper key off and on again, for a game or someone else at the keyboard.",
        "engine.topBar": "Shows or hides Pilot's top bar.",
        "engine.reportBug": "Opens a new GitHub issue with what a fix needs already filled in.",
        "engine.suggestIdea": "Opens a new GitHub issue for an idea.",
        "engine.restartTiler": "Starts Pilot's tiler again when it stopped answering, as Home's Restart does.",
        "engine.grantAccessibility": "Asks for Accessibility and opens its pane in System Settings, with Pilot's icon beside it to drag into the list.",
        "system.openFullDiskAccess": "Opens Full Disk Access in System Settings, where Pilot's switch lives.",
        "engine.tilingOn": "Turns tiling back on after the dropdown's Tiling switch turned it off.",
        "engine.tilingOff": "Stops tiling and brings every workspace's windows onto the screen, as the dropdown's Tiling switch does.",
        "engine.support": "Opens Pilot's GitHub Sponsors page.",
        // Apps
        "ai.ask": "Opens the AI chat under the top bar; the AI picked on the AI page answers, and the chat keeps going.",
        "ai.chat": "Opens or closes the AI chat under the top bar, the conversation as you left it.",
        "terminal.drop": "Opens or closes a terminal under the top bar; the shell keeps running while it is hidden, Escape twice closes it.",
        "ai.fix": "Fixes the spelling and grammar of the text you selected, in place, with the AI picked on the AI page.",
        "ai.selection": "Opens a chat bubble beside the text you selected: ask about it, or pick a rewrite and Cmd+Return replaces it.",
        "ai.selectionTools": "Shows Ask AI, Read aloud, Copy and Translate (and Summarise, with that extension) at the pointer for the text you selected; Hyper+drag over text shows them too.",
        "speech.readAloud": "Reads the text you selected aloud in the best voice for its language; press it again to stop.",
        "apps.activityMonitor": "Opens Activity Monitor.",
        "apps.agent": "Opens a coding agent, Claude Code or Codex, in a new terminal window (Open with › Apps for keys).",
        "apps.ai": "Opens your AI app or site (Open with › Apps for keys).",
        "apps.appsMenu": "Opens the menu on Apps.",
        "apps.nextApp": "Brings forward the app you were in before, as a Command-Tab tap; again goes back.",
        "apps.previousApp": "Brings forward the app you used longest ago, as a Command-Shift-Tab tap; again walks back through them all.",
        "apps.reports": "Shows every Update and Clean run kept: what ran, how it ended, its output.",
        "apps.update": "Opens Update in Hyper+Space: what can be updated, run only after you confirm.",
        "apps.install": "Opens Install, the apps Pilot recommends, each installed through Homebrew after you confirm.",
        "apps.clean": "Opens Clean in Hyper+Space: what Mole would clear, run only after you confirm.",
        "apps.bitwardenFill": "Fills the login for the site in front from Bitwarden.",
        "apps.bitwardenForget": "Forgets the unlocked Bitwarden session, so the next fill asks again.",
        "apps.bitwardenGenerator": "Opens Bitwarden's password generator.",
        "apps.bitwardenLock": "Locks every Bitwarden vault.",
        "apps.bitwardenSearch": "Searches your Bitwarden vault.",
        "apps.browser": "Opens your browser.",
        "apps.calendar": "Opens Calendar.",
        "apps.clipboard": "Opens clipboard history: search, pin and paste what you copied.",
        "apps.clipboardOptionV": "Opens clipboard history on Option+V, as ClipBook did.",
        "apps.editor": "Opens your main editor (Open with › Editor).",
        "apps.emoji": "Opens the emoji grid; Return types the emoji where you were, ⌘Return copies it.",
        "apps.files": "Opens a Finder window.",
        "apps.generatePassword": "Makes a strong password with Bitwarden.",
        "apps.launcher": "Opens the Hyper+Space menu: apps, windows, files, actions and answers.",
        "apps.lazygit": "Picks a repo under ~/code and opens lazygit on it in Ghostty.",
        "apps.mail": "Opens your mail app or site.",
        "apps.messages": "Opens your chat app or site.",
        "apps.music": "Opens your music app or site.",
        "apps.notes": "Opens Apple Notes.",
        "apps.passwords": "Opens Passwords.",
        "apps.pilotFiles": "Opens Pilot Files, a window to browse your folders, find a file by name, and rename, copy, move or trash files, each undone with Cmd+Z.",
        "apps.pastePlain": "Pastes what you copied as plain text, without its formatting.",
        "apps.terminal": "Opens a terminal.",
        "apps.webApp": "Makes a site into a Mac app of its own, in Install › Web apps.",
        "notes.toggle": "Opens the quick notes panel, on the note you left when you were on it a moment ago; notes are Markdown files in your notes folder.",
        "notes.pin": "Pins the quick notes panel on screen, or unpins it: pinned, it floats over other windows and stays open on a click outside.",
        // Captures
        "captures.activeWindow": "Captures a window you click, without its shadow.",
        "captures.area": "Freezes the screen and captures an area you drag.",
        "captures.fullscreen": "Captures the whole screen the pointer is on.",
        "captures.menu": "Opens the menu on Capture.",
        "captures.ocr": "Reads the text in an area you drag and copies it.",
        "captures.makeQR": "Makes a QR code of the text you copied, or what you type; copy it as a picture or save it with your captures.",
        "captures.readQR": "Reads a QR code in an area you drag on the screen; copy its text, or open its link.",
        "captures.readQRScreen": "Reads a QR code in an area you drag on the screen; copy its text, or open its link.",
        "captures.pauseRecording": "Pauses the screen recording, or resumes it.",
        "captures.editLast": "Opens your last capture in the editor: the newest thumbnail (a recording's in the video editor), or the newest file in your captures folder.",
        "captures.editVideo": "Opens a recording you pick in the video editor: trim, crop, speed, zooms that follow your clicks, a backdrop, then MP4 or GIF.",
        "captures.pinLast": "Pins your last capture over every window; scroll zooms it, Esc closes it.",
        "captures.repeatArea": "Captures the area you last dragged again, on the same screen.",
        "captures.scrollingUp": "A scrolling capture that goes up, for a chat read from the bottom.",
        "captures.toggleDesktopIcons": "Leaves the desktop icons out of captures and recordings, or puts them back in; the desktop never changes.",
        "captures.restoreThumbnail": "Shows the last capture thumbnail you closed again.",
        "captures.delayed": "Counts down, then freezes the screen for you to drag an area, so a menu you opened is in it.",
        "captures.smartElement": "Freezes the screen and captures the button, list or panel under the pointer; scroll for a bigger one.",
        "captures.subject": "Captures an area with its background removed, on your Mac: a person, a product, a logo.",
        "captures.markup": "Freezes the screen so you draw arrows, boxes and text on an area, then saves it.",
        "captures.pickColour": "Freezes the screen under a pixel magnifier; a click copies the colour's hex, Shift-click its RGB.",
        "captures.screenRecording": "Records a screen, an app or an area you pick; the key again stops it.",
        "captures.scrolling": "Captures a page taller than the screen; Pilot scrolls it for you, or you do.",
        // Drive
        "drive.copy": "Copy in the app in front.",
        "drive.cut": "Cut in the app in front.",
        "drive.nextTab": "Next tab in the app in front.",
        "drive.paste": "Paste in the app in front.",
        "drive.previousTab": "Previous tab in the app in front.",
        "drive.moveTabLeft": "Moves the tab in front one place left with the app's own Move Tab Left menu item; an app without one says so.",
        "drive.moveTabRight": "Moves the tab in front one place right with the app's own Move Tab Right menu item; an app without one says so.",
        "drive.zoomIn": "Zooms in the app in front with its own Zoom In menu item, as Command-plus does.",
        "drive.zoomOut": "Zooms out the app in front with its own Zoom Out menu item, as Command-minus does.",
        "drive.actualSize": "Puts the app in front back to actual size with its own menu item, as Command-0 does.",
        "drive.quitApp": "Quits the app in front.",
        "drive.redo": "Redo in the app in front.",
        "drive.selectAll": "Select all in the app in front.",
        "drive.undo": "Undo in the app in front.",
        "extensions.catalogue": "Lists the extensions in Pilot's catalogue, such as Pomodoro; Return installs or updates one.",
        "extensions.openFolder": "Opens the folder your extensions live in.",
        "scripts.openFolder": "Opens the folder your scripts live in; each shows in the menu.",
        // Media
        "media.mute": "Mutes or unmutes the sound.",
        "media.next": "Skips to the next track.",
        "media.playPause": "Plays or pauses what is playing.",
        "media.previous": "Goes back a track.",
        "media.volumeDown": "Turns the volume down.",
        "media.volumeUp": "Turns the volume up.",
        // System
        "bar.peekMenuBar": "Shows the macOS menu bar while the key is held.",
        "look.ghosttyApply": "Gives Ghostty Pilot's theme and font.",
        "look.ghosttyRemove": "Takes Pilot's look out of Ghostty's config.",
        "system.bluetooth": "Turns Bluetooth on or off; asks first when Bluetooth keyboards and mice are the only input.",
        "system.bluetoothSettings": "Opens System on Bluetooth.",
        "system.brightnessDown": "Dims the screen the window in front is on.",
        "system.brightnessDownAll": "Dims every screen.",
        "system.brightnessUp": "Brightens the screen the window in front is on.",
        "system.brightnessUpAll": "Brightens every screen.",
        "system.clearAllNotifications": "Clears every notification.",
        "system.clearNotification": "Clears the latest notification.",
        "system.darkMode": "Switches macOS between dark and light.",
        "system.desktopIcons": "Hides Finder's icons on the desktop, or shows them again; Finder restarts once so it takes the change.",
        "system.displaySettings": "Opens System on Displays.",
        "system.rotateDisplay": "Turns a screen to 0, 90, 180 or 270 degrees; it stays unless you press Revert within 15 s.",
        "system.focusSettings": "Opens Focus in System Settings.",
        "system.idleLock": "Locks the Mac after it sits idle, or stops it locking.",
        "cursor.spotlight": "Dims the screen around the pointer while the key is held, with Spotlight on in Look › Cursor.",
        "system.infoHUD": "Flashes the time, the date, the battery and the weather on the screen in front.",
        "system.keepAwake": "Keeps the Mac awake, or lets it sleep again.",
        "system.newEvent": "Opens the menu with event typed: add the words and a day or time, and Return adds it to your calendar.",
        "dictation.toggle": "Starts or stops dictation: Pilot's own or the app picked under Voice › Dictation.",
        "dictation.hold": "Dictates while the key is held: Pilot's own or the app picked under Voice › Dictation.",
        "system.ejectAll": "Ejects every external drive, SD card and disk image; a disk that stays says what holds it.",
        "system.killProcess": "Picks a running process in the menu and stops it.",
        "system.lock": "Locks the screen.",
        "system.lockKeyboard": "Stops every key so you can wipe the keyboard; hold Esc 3 s, click Unlock, or wait 2 minutes to end it.",
        "system.logOut": "Logs out.",
        "system.menu": "Opens the menu on System: power, sound, Wi-Fi, display, Focus.",
        "system.activityMenu": "Opens the menu on Activity: what runs, busiest first, to quit or force quit.",
        "system.statsMenu": "Opens the menu on Stats: CPU, memory, storage, network, heat and the busiest apps.",
        "system.missionControl": "Opens Mission Control.",
        "system.pointerSpeedCycle": "Steps the pointer speed through Slow, Normal and Fast, as System › Mouse saves them.",
        "system.pointerSpeedSlow": "Moves the pointer at the Slow speed System › Mouse saves.",
        "system.pointerSpeedNormal": "Moves the pointer at the Normal speed System › Mouse saves.",
        "system.pointerSpeedFast": "Moves the pointer at the Fast speed System › Mouse saves.",
        "system.screenZoom": "Turns macOS screen zoom on or off. Needs Use keyboard shortcuts to zoom on in System Settings › Accessibility › Zoom; until it is, a press says so.",
        "system.screenZoomIn": "Zooms the whole screen in; a held key keeps zooming. Needs Use keyboard shortcuts to zoom on in System Settings › Accessibility › Zoom.",
        "system.screenZoomOut": "Zooms the whole screen out; a held key keeps zooming. Needs Use keyboard shortcuts to zoom on in System Settings › Accessibility › Zoom.",
        "system.nextWallpaper": "Puts the next wallpaper on; Look › Wallpaper picks the images, the order and the screens.",
        "system.nextWallpaperAll": "Puts the next wallpaper on every screen at once, each from its own folders.",
        "system.nightShift": "Turns Night Shift on or off.",
        "system.pill": "Drops the pill's views from the top bar, or with the top bar off from the top of the screen; arrows and Tab switch views, Return acts on the lit row.",
        "system.nextPillView": "Shows the pill's next view on the top bar without opening it.",
        "system.themeCarousel": "Browses the theme packs your style takes in the Carousel, each drawn as a desktop with your apps; Return applies one after its Allow.",
        "system.wallpaperCarousel": "Browses the current theme's wallpapers, or the folders that cycle, in the Carousel; Return sets one, F keeps it as a favourite.",
        "system.openNotification": "Opens the latest notification.",
        "system.notificationDrawer": "Opens the list of notifications Pilot has shown.",
        "system.previousWallpaper": "Goes back to the wallpaper before.",
        "system.previousWallpaperAll": "Goes back to the wallpaper before on every screen at once.",
        "system.restart": "Restarts the Mac.",
        "system.shutDown": "Shuts the Mac down.",
        "system.sleep": "Puts the Mac to sleep.",
        "system.soundSettings": "Opens System on Sound.",
        "system.speedTest": "Measures your internet speed with macOS's own test.",
        "system.translationLanguages": "Opens where macOS downloads languages for Translate.",
        "system.wifi": "Turns Wi-Fi on or off.",
        "system.wifiSettings": "Opens System on Wi-Fi.",
        // Windows
        "windows.balance": "Gives every tiled window on the workspace the same size.",
        "windows.centre": "Floats the window in front and centres it.",
        "windows.centreColumn": "Scrolls the strip to put the column in front in the middle.",
        "windows.leaveStack": "Takes the window in front out of its stack into a column of its own on a scrolling strip.",
        "windows.maximiseColumn": "Makes the column in front full width on a scrolling strip, or gives it its width back.",
        "windows.close": "Closes the window in front.",
        "windows.closeAll": "Closes every window of the app in front.",
        "windows.closeOthers": "Closes every window on the workspace but the one in front.",
        "windows.cycle": "Brings forward the app's next window.",
        "windows.cycleBack": "Brings forward the app's previous window, back the way Next window of the app went.",
        "windows.cycleColumnWidth": "Steps the column in front to its next width on a scrolling strip.",
        "windows.cycleColumnWidthBack": "Steps the column in front back to its previous width on a scrolling strip.",
        "windows.defocus": "Blurs and dims everything but the window in front.",
        "windows.firstThird": "Puts the window in front on the screen's first third.",
        "windows.firstThreeQuarters": "Puts the window in front on the screen's first three quarters.",
        "windows.firstTwoThirds": "Puts the window in front on the screen's first two thirds.",
        "windows.flipSplit": "Turns the split the window is in from side by side to stacked, or back.",
        "windows.focusDisplayLeft": "Moves focus to the screen on the left.",
        "windows.focusDisplayRight": "Moves focus to the screen on the right.",
        "windows.focusDown": "Moves focus to the window below.",
        "windows.focusLeft": "Moves focus to the window on the left.",
        "windows.focusNext": "Moves focus to the next window on the workspace.",
        "windows.focusPrevious": "Moves focus to the window before.",
        "windows.focusRight": "Moves focus to the window on the right.",
        "windows.focusUp": "Moves focus to the window above.",
        "windows.fullscreen": "Makes the window in front fill the screen, or not.",
        "windows.grow": "Makes the window in front bigger.",
        "windows.growHeight": "Makes the window in front taller.",
        "windows.growWidth": "Makes the window in front wider.",
        "windows.joinDown": "Groups the window in front with the one below.",
        "windows.joinLeft": "Groups the window in front with the one on the left.",
        "windows.joinRight": "Groups the window in front with the one on the right.",
        "windows.joinUp": "Groups the window in front with the one above.",
        "windows.lastQuarter": "Puts the window in front on the screen's last quarter.",
        "windows.lastThird": "Puts the window in front on the screen's last third.",
        "windows.lastTwoThirds": "Puts the window in front on the screen's last two thirds.",
        "windows.maximise": "Floats the window in front and fills the screen with it.",
        "windows.middleThird": "Puts the window in front on the screen's middle third.",
        "windows.minimise": "Minimises the window in front.",
        "windows.popOut": "Floats the window in front out of the tiles, centred.",
        "windows.resetLayout": "Puts the workspace's tiles back in their plain layout.",
        "windows.sendToDisplayLeft": "Moves the window in front to the screen on the left.",
        "windows.sendToDisplayRight": "Moves the window in front to the screen on the right.",
        "windows.sendToNextWorkspace": "Moves the window in front to the next workspace; you stay where you are.",
        "windows.sendToPreviousWorkspace": "Moves the window in front to the workspace before; you stay where you are.",
        "windows.shrink": "Makes the window in front smaller.",
        "windows.shrinkHeight": "Makes the window in front shorter.",
        "windows.shrinkWidth": "Makes the window in front narrower.",
        "windows.snapLeft": "Floats the window in front onto the screen's left half.",
        "windows.snapRight": "Floats the window in front onto the screen's right half.",
        "windows.snapTop": "Floats the window in front onto the screen's top half.",
        "windows.snapBottom": "Floats the window in front onto the screen's bottom half.",
        "windows.swapDown": "Swaps the window in front with the one below.",
        "windows.swapLeft": "Swaps the window in front with the one on the left.",
        "windows.swapRight": "Swaps the window in front with the one on the right.",
        "windows.swapUp": "Swaps the window in front with the one above.",
        "windows.showDesktop": "Moves every window on the workspace out of the way, and puts them back as they were.",
        "windows.toggleScrolling": "Lays the workspace's windows out as columns on a strip that scrolls, or tiles them again.",
        "windows.toggleFloat": "Floats the window in front, or tiles it again.",
        "windows.toggleFloatWorkspace": "Floats every window on the workspace, or tiles them again.",
        "windows.vimFocusDown": "Moves focus down; a second action, so a second key can do it too.",
        "windows.vimFocusLeft": "Moves focus left; a second action, so a second key can do it too.",
        "windows.vimFocusRight": "Moves focus right; a second action, so a second key can do it too.",
        "windows.vimFocusUp": "Moves focus up; a second action, so a second key can do it too.",
        "windows.vimSwapDown": "Swaps with the window below; a second action, so a second key can do it too.",
        "windows.vimSwapLeft": "Swaps with the window on the left; a second action, so a second key can do it too.",
        "windows.vimSwapRight": "Swaps with the window on the right; a second action, so a second key can do it too.",
        "windows.vimSwapUp": "Swaps with the window above; a second action, so a second key can do it too.",
        // Workspaces
        "workspaces.cycleLayout": "Turns the workspace's tiles to the next layout.",
        "workspaces.former": "Goes back to the workspace you were on.",
        "workspaces.next": "Shows the next workspace.",
        "workspaces.openLayout": "Opens the apps the workspace's Opens here lists that are missing and puts each in its spot.",
        "workspaces.previous": "Shows the workspace before.",
        "workspaces.rescue": "Brings back windows stranded off screen or on a lost workspace.",
        "workspaces.restoreSnapshot": "Reopens and places the workspace's saved windows.",
        "workspaces.saveSnapshot": "Saves which windows the workspace holds and where.",
        "workspaces.toggleGaps": "Takes the gaps between tiles out, or puts them back.",
    ]
}
