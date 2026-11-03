import AppKit
import PilotCore

/// A bar item's right-click menu as a native NSMenu (card agent-bo-95423010, design JJPiA9o30SA version 1), hung under
/// the item in either bar: a check on the current style and side, a section header over the styles, each hint greyed at
/// the right. An extension row's ⋯ in a bar popover pops one at the pointer: a SwiftUI Menu there did nothing (a
/// non-activating panel of an app not in front; Sven on build 20), as do the row's right-click and the clock's second
/// zone; Other apps' one button hangs one under itself. The top bar's App menus draw the front app's menus here too, under the clicked title.
@MainActor
final class BarMenu: NSObject {
    /// Each item's pick, by its tag.
    private var picks: [() -> Void] = []

    /// Shows the menu under `view` and returns once it closes; a pick runs after that.
    static func show(_ rows: [BarMenuRow], under view: NSView, perform: @escaping (BarAction) -> Void) {
        let owner = BarMenu()
        owner.pop(owner.menu(rows, perform: perform), under: view, gap: 4)
    }

    /// Shows `items` under `view` and returns once the menu closes; a pick runs after that.
    static func show(_ items: [(title: String, run: () -> Void)], under view: NSView) {
        let owner = BarMenu()
        owner.pop(owner.menu(items), under: view)
    }

    /// Shows `sections` under `view`, each its title as a header over its items, and returns once the menu closes; a pick
    /// runs after that.
    static func show(sections: [(title: String, items: [(title: String, run: () -> Void)])], under view: NSView) {
        let owner = BarMenu()
        owner.pop(owner.menu(sections: sections), under: view)
    }

    /// Shows `items` at the pointer, a check on the one titled `checked`, and returns once the menu closes; a pick runs
    /// after that.
    static func pop(_ items: [(title: String, run: () -> Void)], checked: String? = nil) {
        let owner = BarMenu(), menu = owner.menu(items)
        menu.items.first { $0.title == checked }?.state = .on
        owner.pop(menu, at: NSEvent.mouseLocation, in: nil)
    }

    /// Shows `sections` at the pointer, each its title over its picks, a check on each pick titled in `checked`; a pick
    /// runs after the menu closes.
    static func pop(sections: [(title: String, items: [(title: String, run: () -> Void)])], checked: Set<String> = []) {
        let owner = BarMenu(), menu = owner.menu(sections: sections)
        for item in menu.items where checked.contains(item.title) { item.state = .on }
        owner.pop(menu, at: NSEvent.mouseLocation, in: nil)
    }

    /// One row of a native menu: a pick, checked or not, its hint greyed at the right; a submenu; a section header; a
    /// separator. A bar item's rows (BarMenuRow) become these, and the desktop's Hyper + right-click builds them.
    enum Row {
        case pick(String, checked: Bool = false, hint: String? = nil, run: () -> Void)
        case submenu(String, [Row])
        case header(String)
        case separator
    }

    /// Shows `rows` at `point`, in AppKit's screen coordinates, and returns once the menu closes; a pick runs after that.
    static func pop(_ rows: [Row], at point: NSPoint) {
        let owner = BarMenu()
        owner.pop(owner.menu(rows: rows), at: point, in: nil)
    }

    /// The front app's menu (the top bar's App menus), its items as `nodes` hold them, under `view`, the clicked title,
    /// as the menu bar hangs a menu: a pick hands back its title path inside the menu.
    static func show(appMenu nodes: [MenuItemNode], under view: NSView, pick: @escaping ([String]) -> Void) {
        let owner = BarMenu()
        owner.pop(owner.menu(nodes, path: [], pick: pick), under: view)
    }

    /// The menus folded behind the App menus' chevron, each a submenu of its items, its pick handed its path inside it.
    static func show(appMenus menus: [(title: String, nodes: [MenuItemNode], pick: ([String]) -> Void)], under view: NSView) {
        let owner = BarMenu(), menu = owner.menu([])
        for (title, nodes, pick) in menus {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = owner.menu(nodes, path: [], pick: pick)
            menu.addItem(item)
        }
        owner.pop(menu, under: view)
    }

    /// An app's menu items as a native menu: a separator for each run of untitled ones, a submenu's items inside it, the
    /// check mark and the greyed shortcut as the app's own menu shows them; nothing here takes a key equivalent.
    private func menu(_ nodes: [MenuItemNode], path: [String], pick: @escaping ([String]) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let font = NSFont.menuFont(ofSize: 0)
        let widest = nodes.filter { !$0.isSeparator }.map { NSAttributedString(string: $0.title, attributes: [.font: font]).size().width }.max() ?? 0
        for node in nodes {
            if node.isSeparator {
                if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
                continue
            }
            let item: NSMenuItem
            if node.children.isEmpty {
                item = self.item(node.title) { pick(path + [node.title]) }
                if let key = node.key { item.attributedTitle = Self.title(node.title, hint: key, font: font, at: widest + 32) }
            } else {
                item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
                item.submenu = self.menu(node.children, path: path + [node.title], pick: pick)
            }
            item.isEnabled = node.enabled
            item.state = node.mark == nil ? .off : .on
            menu.addItem(item)
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }

    /// Hangs `menu` `gap` under `view`.
    private func pop(_ menu: NSMenu, under view: NSView, gap: CGFloat = 0) {
        pop(menu, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + gap : -gap), in: view)
    }

    private func pop(_ menu: NSMenu, at point: NSPoint, in view: NSView?) {
        // NSMenuItem's target is weak: the owner lives until the menu's tracking ends.
        withExtendedLifetime(self) { _ = menu.popUp(positioning: nil, at: point, in: view) }
    }

    /// A plain menu of `items`, a pick each.
    func menu(_ items: [(title: String, run: () -> Void)]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items { menu.addItem(self.item(item.title, pick: item.run)) }
        return menu
    }

    /// A menu of `rows`, a submenu's rows inside it; the hints line up right of the widest pick.
    private func menu(rows: [Row]) -> NSMenu {
        let menu = self.menu([])
        let font = NSFont.menuFont(ofSize: 0)
        let titles = rows.compactMap { if case .pick(let title, _, _, _) = $0 { title } else { nil } }
        let widest = titles.map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }.max() ?? 0
        for row in rows {
            switch row {
            case .pick(let title, let checked, let hint, let run):
                let item = self.item(title, pick: run)
                item.state = checked ? .on : .off
                if let hint { item.attributedTitle = Self.title(title, hint: hint, font: font, at: widest + 48) }
                menu.addItem(item)
            case .submenu(let title, let rows):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = self.menu(rows: rows)
                menu.addItem(item)
            case .header(let title): menu.addItem(.sectionHeader(title: title))
            case .separator: menu.addItem(.separator())
            }
        }
        return menu
    }

    /// A menu of `sections`, each its title as a header over its picks.
    func menu(sections: [(title: String, items: [(title: String, run: () -> Void)])]) -> NSMenu {
        let menu = self.menu([])
        for section in sections {
            menu.addItem(.sectionHeader(title: section.title))
            for item in section.items { menu.addItem(self.item(item.title, pick: item.run)) }
        }
        return menu
    }

    private func item(_ title: String, pick: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
        item.target = self
        item.tag = picks.count
        picks.append(pick)
        return item
    }

    private func menu(_ rows: [BarMenuRow], perform: @escaping (BarAction) -> Void) -> NSMenu {
        menu(rows: rows.map { Self.row($0, perform: perform) })
    }

    private static func row(_ row: BarMenuRow, perform: @escaping (BarAction) -> Void) -> Row {
        switch row {
        case .separator: .separator
        case .header(let title): .header(title)
        case .submenu(let title, let rows): .submenu(title, rows.map { Self.row($0, perform: perform) })
        case .action(let title, let action, let checked, let hint): .pick(title, checked: checked, hint: hint) { perform(action) }
        }
    }

    /// The title, then its hint right-aligned at `at` in the secondary colour.
    private static func title(_ title: String, hint: String, font: NSFont, at: CGFloat) -> NSAttributedString {
        let hintWidth = NSAttributedString(string: hint, attributes: [.font: font]).size().width
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: at + hintWidth)]
        let text = NSMutableAttributedString(string: title + "\t", attributes: [.font: font, .paragraphStyle: style])
        text.append(NSAttributedString(string: hint, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
        return text
    }

    @objc private func picked(_ item: NSMenuItem) {
        // After the menu's tracking ends, so a popover it opens (or a push in the one it sits in) is not dismissed with it.
        DispatchQueue.main.async(execute: picks[item.tag])
    }
}
