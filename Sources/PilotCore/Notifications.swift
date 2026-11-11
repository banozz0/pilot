import Foundation

/// One element of Notification Center's Accessibility tree, as the notification keys read it; the app wraps an
/// AXUIElement, tests a fake.
public protocol NotificationElement {
    /// The raw AX action names; a custom one arrives as "Name:Close\nTarget:0x0\nSelector:(null)".
    var actionNames: [String] { get }
    var children: [any NotificationElement] { get }
    /// Performs the action under its raw name.
    func perform(_ action: String) -> Bool
    /// AXRole and AXSubrole, what the banner reader tells a banner from its host by.
    var role: String? { get }
    var subrole: String? { get }
    /// AXIdentifier: a banner's stays the same for as long as it is up.
    var identifier: String? { get }
    /// AXValue, a line of text's words.
    var value: String? { get }
    /// AXAttributedDescription's words: "App, Title, Body" on a banner.
    var attributedDescription: String? { get }
    /// The application element's windows; the reader walks these, never the app's menu bar. Nil when the list couldn't be
    /// read (a timeout), so a failed read is told from one that answered with none.
    var windows: [any NotificationElement]? { get }
    /// AXExpanded on the application element: Notification Center's own panel is open, its rows sharing banners' subroles.
    var isExpanded: Bool { get }
    /// AXPosition, in screen points from the top left.
    var position: CGPoint? { get }
    /// Moves the element; only Notification Center's host window can move.
    func setPosition(_ point: CGPoint) -> Bool
}

public extension NotificationElement {
    var role: String? { nil }
    var subrole: String? { nil }
    var identifier: String? { nil }
    var value: String? { nil }
    var attributedDescription: String? { nil }
    var windows: [any NotificationElement]? { children }
    var isExpanded: Bool { false }
    var position: CGPoint? { nil }
    func setPosition(_ point: CGPoint) -> Bool { false }
}

/// Omarchy's Super+comma family on the Mac (card agent-bo-95422949, story 124): clear the latest notification, clear
/// them all, open the latest, by pressing Notification Center's own Close, Clear All and AXPress through Accessibility.
/// A notification is an element offering Close, a stack one offering Clear All; the first in tree order is the top one
/// on screen. Apple renames these now and then, so a macOS update can break the keys.
public enum Notifications {
    public static let noneTip = "No notification on screen"
    /// Clear all's cap, so a tree that never empties cannot keep a walk going.
    public static let maxPresses = 20
    static let maxDepth = 12
    static let maxNodes = 300

    /// The Name part of an AX action name ("Close" from "Name:Close\nTarget:…"); a plain name is itself.
    public static func name(_ raw: String) -> String {
        guard raw.hasPrefix("Name:") else { return raw }
        return String(raw.dropFirst(5).prefix { $0 != "\n" })
    }

    /// Closes the top notification; false when none is on screen or the press failed.
    public static func clearLatest(_ root: (any NotificationElement)?) -> Bool { pressTop(root, "Close") }

    /// Opens the top notification in its app.
    public static func openLatest(_ root: (any NotificationElement)?) -> Bool { pressTop(root, "AXPress") }

    /// Clear All on each stack and Close on each loose notification, the tree read afresh after every press, at most
    /// `maxPresses`; the number of presses made.
    public static func clearAll(_ root: () -> (any NotificationElement)?) -> Int {
        var presses = 0
        while presses < maxPresses, let n = first(in: root(), offering: ["Clear All", "Close"]),
              let press = action(n, "Clear All") ?? action(n, "Close"), n.perform(press) {
            presses += 1
        }
        return presses
    }

    private static func pressTop(_ root: (any NotificationElement)?, _ wanted: String) -> Bool {
        guard let n = first(in: root, offering: ["Close"]), let raw = action(n, wanted) else { return false }
        return n.perform(raw)
    }

    /// The first element in tree order offering one of `names`, depth first, at most `maxNodes` visited: with the panel
    /// open a miss walks its widgets too, and every visit is a call into Notification Center.
    static func first(in root: (any NotificationElement)?, offering names: Set<String>) -> (any NotificationElement)? {
        var budget = maxNodes
        func walk(_ element: any NotificationElement, _ depth: Int) -> (any NotificationElement)? {
            guard depth <= maxDepth, budget > 0 else { return nil }
            budget -= 1
            if element.actionNames.contains(where: { names.contains(name($0)) }) { return element }
            for child in element.children {
                if let found = walk(child, depth + 1) { return found }
            }
            return nil
        }
        return root.flatMap { walk($0, 0) }
    }

    private static func action(_ element: any NotificationElement, _ wanted: String) -> String? {
        element.actionNames.first { name($0) == wanted }
    }
}
