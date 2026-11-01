import Foundation

/// One menu item as the front app's menu bar holds it: its title, whether it can be picked, its shortcut as a key cap and
/// the items of its submenu, then the shortcut as Accessibility gives it, a character and a modifier mask.
public struct MenuItemNode: Equatable, Sendable, Codable {
    public var title: String, enabled: Bool
    public var children: [MenuItemNode]
    /// The shortcut's virtual key, which names a key with no character (Delete, the arrows, Return, F-keys).
    public var char: String?, modifiers: Int?, virtualKey: Int?
    /// Its check mark ("✓"), read for the top bar's App menus, which draw the menu itself.
    public var mark: String?

    public init(title: String, enabled: Bool, children: [MenuItemNode] = [], char: String? = nil, modifiers: Int? = nil, virtualKey: Int? = nil,
                mark: String? = nil) {
        self.title = title; self.enabled = enabled; self.children = children; self.char = char; self.modifiers = modifiers
        self.virtualKey = virtualKey; self.mark = mark
    }

    /// An untitled item with no submenu: the menu's separator line.
    public var isSeparator: Bool { title.trimmingCharacters(in: .whitespaces).isEmpty && children.isEmpty }

    /// The shortcut as a key cap, "⇧⌘S".
    public var key: String? { MenuItemSearch.key(char: char, modifiers: modifiers, virtualKey: virtualKey) }
}

/// The front app's menu items found by typing at the menu's root (card agent-bo-95423046; Raycast's and SuperCmd's
/// Search Menu Items, ideas only). The panel reads the menu bar through Accessibility as the menu opens; each row is the
/// drive route action that presses its item by title path (DriveRoute.menu), so Return is an AXPress, never a keystroke
/// (ADR 0001) and Cmd+K binds it as any drive route.
public enum MenuItemSearch {
    /// What one element answers: its attributes and the items inside it (a submenu's items, already out of its AXMenu).
    public struct Raw<Element> {
        public var title: String?, enabled: Bool, char: String?, modifiers: Int?
        public var children: [Element]
        public var virtualKey: Int?
        public var mark: String?
        public init(title: String?, enabled: Bool, char: String?, modifiers: Int?, children: [Element], virtualKey: Int? = nil, mark: String? = nil) {
            self.title = title; self.enabled = enabled; self.char = char; self.modifiers = modifiers; self.children = children
            self.virtualKey = virtualKey; self.mark = mark
        }
    }

    /// The menu bar's items four levels deep, less the Apple menu and macOS's Services submenu. An element that does not
    /// answer is left out; the walk ends after `cap` items or once `expired`, keeping what it read, so a hung or huge app
    /// costs the menu a bounded wait.
    public static func walk<Element>(_ bar: [Element], read: (Element) -> Raw<Element>?, cap: Int = 1500,
                                     expired: () -> Bool) -> [MenuItemNode] {
        walk(items: Array(bar.dropFirst()), level: 1, read: read, cap: cap, expired: expired)
    }

    /// One menu's items (File's: New, Open…), three levels deep as the bar's walk reads them; the top bar's App menus
    /// draw the menu from these (AppMenus).
    public static func walk<Element>(menu items: [Element], read: (Element) -> Raw<Element>?, cap: Int = 1500,
                                     expired: () -> Bool) -> [MenuItemNode] {
        walk(items: items, level: 2, read: read, cap: cap, expired: expired)
    }

    private static func walk<Element>(items: [Element], level: Int, read: (Element) -> Raw<Element>?, cap: Int,
                                      expired: () -> Bool) -> [MenuItemNode] {
        let depth = 4
        var count = 0
        func nodes(_ elements: [Element], _ level: Int) -> [MenuItemNode] {
            var out: [MenuItemNode] = []
            for element in elements {
                guard count < cap, !expired() else { break }
                guard let raw = read(element) else { continue }
                count += 1
                let title = raw.title ?? ""
                if title == "Services", !raw.children.isEmpty { continue }
                out.append(MenuItemNode(title: title, enabled: raw.enabled, children: level < depth ? nodes(raw.children, level + 1) : [],
                                        char: raw.char, modifiers: raw.modifiers, virtualKey: raw.virtualKey, mark: raw.mark))
            }
            return out
        }
        return nodes(items, level)
    }

    /// A row per enabled item, titled and under its path ("File › Open Recent"), which search matches too; `except`
    /// holds the drive routes already listed as bound actions, so one is never listed twice. The route keeps each title
    /// as the menu has it, since the press matches titles exactly. Two items on one path (Chrome's two Paste and Match
    /// Style, two History tabs of one title) are one route the press finds first, so one row: SwiftUI's list needs each
    /// row's id once (Build 68 log, 2026-10-18). `app`, the app's name, is searched too, so typing it lists the app's
    /// items as its actions, as the catalogue's commands are (Sven, 1.0.1).
    public static func entries(_ bar: [MenuItemNode], bundle: String, app: String? = nil, except: Set<String> = []) -> [MenuEntry] {
        var listed: Set<String> = []
        func rows(_ nodes: [MenuItemNode], _ path: [String]) -> [MenuEntry] {
            nodes.flatMap { node -> [MenuEntry] in
                let title = node.title
                // A separator is untitled; a title holding the route's separator would not read back as its path.
                guard node.enabled, !title.trimmingCharacters(in: .whitespaces).isEmpty, !title.contains(DriveRoute.pathSeparator) else { return [] }
                if !node.children.isEmpty { return rows(node.children, path + [title]) }
                let id = DriveRoute.menu(bundle: bundle, path: path + [title]).id
                guard !path.isEmpty, !except.contains(id), listed.insert(id).inserted else { return [] }
                return [MenuEntry(title: title.trimmingCharacters(in: .whitespaces), target: .action(id), detail: node.key,
                                  detailIsKey: node.key != nil, keywords: (path + [app].compactMap(\.self)).joined(separator: " "), ownKind: .menuItem, app: bundle,
                                  subtitle: DriveRoute.title(path))]
            }
        }
        return rows(bar, [])
    }

    /// An item's shortcut as a key cap, "⇧⌘S", from Accessibility's command character and modifier mask (0 Command,
    /// then 1 Shift, 2 Option, 4 Control, 8 no Command); a key with no printable character by its virtual key's name,
    /// nil without either.
    public static func key(char: String?, modifiers: Int?, virtualKey: Int? = nil) -> String? {
        let cap: String
        // Apple's private-use glyphs are what Accessibility gives as the character for keys like the arrows.
        if let char, char.count == 1, let scalar = char.unicodeScalars.first, scalar != " ", !CharacterSet.controlCharacters.contains(scalar),
           !(0xE000...0xF8FF).contains(scalar.value) {
            cap = char.uppercased()
        } else if let virtualKey, let name = KeyNames.names[Int64(virtualKey)] {
            cap = name
        } else {
            return nil
        }
        let m = modifiers ?? 0
        return [(4, "⌃"), (2, "⌥"), (1, "⇧")].filter { m & $0.0 != 0 }.map(\.1).joined() + (m & 8 == 0 ? "⌘" : "") + cap
    }
}
