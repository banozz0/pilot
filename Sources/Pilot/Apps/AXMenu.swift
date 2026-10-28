import ApplicationServices
import PilotCore

/// An app's menu bar through the Accessibility API: press the item behind a Command shortcut without posting keys. Not
/// tied to the main thread: a walk of a big menu bar (History, Bookmarks) runs off it, so the key tap never waits on it.
enum AXMenu {
    /// Presses the first enabled menu item whose shortcut is Command plus `cmdChar` (e.g. "N" for New Window).
    @discardableResult
    static func press(pid: pid_t, cmdChar: String) -> Bool {
        press(pid: pid, titles: [], orShortcut: cmdChar, modifiers: 0)
    }

    /// Presses the first enabled item titled one of `titles`, else the first whose shortcut is `char` (or, for a key with
    /// no character, `virtualKey`) with Accessibility's modifier mask `modifiers` (1 Shift, 2 Option, 4 Control, 8 no
    /// Command): an item every app names its own way. The walk gives up after `seconds`.
    @discardableResult
    static func press(pid: pid_t, titles: Set<String>, orShortcut char: String?, virtualKey: Int? = nil, modifiers: Int,
                      within seconds: TimeInterval = 1) -> Bool {
        let char = char?.uppercased()
        return press(pid: pid, titles: titles, within: seconds) { shortcut($0, char, virtualKey, modifiers) } == .pressed
    }

    /// What a press by title or shortcut found: an item greyed out (Actual Size at actual size) is told from none.
    enum Found { case pressed, disabled, missing }

    /// Presses the first enabled item titled one of `titles`, else the first enabled one `onShortcut` takes, in one walk:
    /// a title ends it, the first item on the shortcut is kept in case none does.
    static func press(pid: pid_t, titles: Set<String>, within seconds: TimeInterval = 1, orShortcut onShortcut: (AXUIElement) -> Bool) -> Found {
        guard let bar = menuBar(pid) else { return .missing }
        var byShortcut: AXUIElement?, disabled = false
        let item = find(in: bar, until: Date.now + seconds, where: { e in
            let titled = string(e, kAXTitleAttribute).map(titles.contains) == true
            guard titled || (byShortcut == nil && onShortcut(e)) else { return false }
            guard bool(e, kAXEnabledAttribute) else { disabled = true; return false }
            if titled { return true }
            byShortcut = e
            return titles.isEmpty
        }) ?? byShortcut
        guard let item else { return disabled ? .disabled : .missing }
        return press(item) ? .pressed : .missing
    }

    /// An item on one of these shortcuts: its character, upper-cased as Accessibility may give it, and its modifier mask.
    static func on(_ e: AXUIElement, _ keys: [(char: String, modifiers: Int)]) -> Bool {
        guard let char = string(e, kAXMenuItemCmdCharAttribute)?.uppercased(), let modifiers = integer(e, kAXMenuItemCmdModifiersAttribute)
        else { return false }
        return keys.contains { $0.char.uppercased() == char && $0.modifiers == modifiers }
    }

    /// Another item in the same menu as `e` that `match` takes.
    static func beside(_ e: AXUIElement, where match: (AXUIElement) -> Bool) -> Bool {
        var parent: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parent) == .success, let parent else { return false }
        return children(of: parent as! AXUIElement).contains { !CFEqual($0, e) && match($0) }
    }

    static func press(_ item: AXUIElement) -> Bool {
        AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// Presses the enabled menu item at a title path, ["File", "New Finder Window"], from the menu bar down.
    @discardableResult
    static func press(pid: pid_t, path: [String]) -> Bool { item(pid: pid, path: path).map(press) ?? false }

    /// Presses the enabled item at a title path under `root`: an app's menu bar, or one menu bar item, whose menu holds
    /// the path's first title (another app's status item in the top bar's Other apps).
    static func press(_ path: [String], under root: AXUIElement) -> Bool { item(path, under: root).map(press) ?? false }

    /// The enabled item at a title path, nil until it is there; `pid`'s menu bar.
    static func item(pid: pid_t, path: [String]) -> AXUIElement? { menuBar(pid).flatMap { item(path, under: $0) } }

    /// A path's title matches case aside, and may list the spellings the app's languages give it, "Empty Bin… | Empty
    /// Trash…" (P38: Sven's Apple apps run in English (UK), whose Finder says Bin and whose Chrome says "New tab").
    static func item(_ path: [String], under root: AXUIElement) -> AXUIElement? {
        var element = root
        for title in path {
            // A menu bar item and a submenu item hold their items inside one AXMenu child.
            let items = children(of: element).flatMap { string($0, kAXRoleAttribute) == kAXMenuRole ? children(of: $0) : [$0] }
            let spellings = title.components(separatedBy: " | ")
            guard let item = items.first(where: { e in
                string(e, kAXTitleAttribute).map { shown in spellings.contains { $0.caseInsensitiveCompare(shown) == .orderedSame } } == true
            }) else { return nil }
            element = item
        }
        return bool(element, kAXEnabledAttribute) ? element : nil
    }

    /// A hung app answers no faster than this, so a press never waits AX's default 6 s. Never Pilot's own: Accessibility
    /// into its own process runs AppKit's NSMenu on the asking thread, off the main one, and crashed Pilot (build 23).
    private static func menuBar(_ pid: pid_t) -> AXUIElement? {
        guard pid != getpid() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var bar: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return nil }
        return (bar as! AXUIElement)
    }

    private static func find(in element: AXUIElement, depth: Int = 0, until deadline: Date, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth < 5 else { return nil }
        for child in children(of: element) {
            guard Date.now < deadline else { return nil }
            if match(child) { return child }
            if let found = find(in: child, depth: depth + 1, until: deadline, where: match) { return found }
        }
        return nil
    }

    /// An item on that shortcut, enabled or not: its character, or its virtual key where the shortcut has no character.
    private static func shortcut(_ e: AXUIElement, _ char: String?, _ virtualKey: Int?, _ modifiers: Int) -> Bool {
        if let char { return on(e, [(char, modifiers)]) }
        return virtualKey != nil && integer(e, kAXMenuItemCmdVirtualKeyAttribute) == virtualKey && integer(e, kAXMenuItemCmdModifiersAttribute) == modifiers
    }

    private static func children(of e: AXUIElement) -> [AXUIElement] {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }
    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v as? String : nil
    }
    private static func integer(_ e: AXUIElement, _ attr: String) -> Int? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? (v as? NSNumber)?.intValue : nil
    }
    private static func bool(_ e: AXUIElement, _ attr: String) -> Bool {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? ((v as? NSNumber)?.boolValue ?? true) : true
    }
}

/// The front app's whole menu bar for the menu's search (MenuItemSearch, card agent-bo-95423046), or one of its menus for
/// the top bar's App menus, read off the main thread: one ask per item for all its attributes and one per submenu for its items, each element waiting at most
/// 0.5 s, the whole read 1.5 s.
enum AXMenuItems {
    private static var attributes: CFArray {
        [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXChildrenAttribute,
         kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemMarkCharAttribute] as CFArray
    }

    static func read(pid: pid_t, budget: TimeInterval = 1.5) -> [MenuItemNode] {
        // Never Pilot's own, as AXMenu.menuBar.
        guard pid != getpid() else { return [] }
        let app = AXUIElementCreateApplication(pid), deadline = Date(timeIntervalSinceNow: budget)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var bar: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return [] }
        return MenuItemSearch.walk(children(bar as! AXUIElement), read: raw, expired: { Date() > deadline })
    }

    /// One menu bar item's menu (the top bar's App menus), read off the main thread within `budget`.
    static func read(menu element: AXUIElement, budget: TimeInterval = 1) -> [MenuItemNode] {
        let deadline = Date(timeIntervalSinceNow: budget)
        guard let menu = raw(element) else { return [] }
        return MenuItemSearch.walk(menu: menu.children, read: raw, expired: { Date() > deadline })
    }

    /// A menu bar item's or a submenu item's one child is the AXMenu that holds its items.
    private static func raw(_ element: AXUIElement) -> MenuItemSearch.Raw<AXUIElement>? {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
              let v = values as? [AnyObject], v.count == 7 else { return nil }
        // In the order `attributes` names them.
        let (title, enabled, char, modifiers, menus, virtualKey, mark) = (v[0], v[1], v[2], v[3], v[4], v[5], v[6])
        return MenuItemSearch.Raw(title: title as? String, enabled: (enabled as? NSNumber)?.boolValue ?? true, char: char as? String,
                                  modifiers: (modifiers as? NSNumber)?.intValue,
                                  children: ((menus as? [AXUIElement]) ?? []).flatMap(children), virtualKey: (virtualKey as? NSNumber)?.intValue,
                                  mark: (mark as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(e, 0.5)
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success ? v as? [AXUIElement] ?? [] : []
    }
}
