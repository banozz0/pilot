import AppKit
import ApplicationServices
import OSLog
import PilotCore

/// Finder's files through Accessibility, read only and off the main thread (a slow Finder answers no slower than the
/// timeout): what is selected (P43's folder designs) and what lies under a point (Hyper + right-click, story 199). An
/// item names its file by AXURL, on itself or a child (a list row's cell). Never Pilot's own process.
enum FinderItems {
    /// Every element read waits at most this long.
    nonisolated static let timeout: Float = 0.5

    /// The items selected in Finder's front window (or on the desktop): the focused list's, else the first list found
    /// under the focused window, breadth first.
    nonisolated static func selection() -> [URL] {
        guard let app = finder() else { return [] }
        var items = value(app, kAXFocusedUIElementAttribute).map { selected($0 as! AXUIElement) } ?? []
        if items.isEmpty, let window = value(app, kAXFocusedWindowAttribute) {
            var queue = [window as! AXUIElement], seen = 0
            while items.isEmpty, !queue.isEmpty, seen < 400 {
                let e = queue.removeFirst()
                seen += 1
                items = selected(e)
                queue += elements(e, kAXChildrenAttribute)
            }
        }
        return items.compactMap { url($0) }
    }

    /// The file under `point` (global, top-left origin, as a CGEvent's location) in a Finder window or on the desktop, or
    /// every selected file when it is one of them; none over a list's blank space, a toolbar or anything else. Walks up
    /// from the deepest element there to the item, never past the list that holds it, so a blank spot never names a
    /// file the list holds. The item names its file by AXURL, else by AXFilename or the name it shows, inside the
    /// folder the window shows (AXDocument); a press never names that folder itself, which is the view, not an item in
    /// it (Build 76: a file's press opened its folder's actions). Each lookup logs the roles it walked and how it named
    /// the file, so a view whose items name nothing shows in Pilot's log.
    nonisolated static func at(_ point: CGPoint) -> [URL] {
        guard let app = finder() else { return [] }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var e = hit else {
            finderLog.notice("finder: no element under the pointer")
            return []
        }
        // The elements from the hit up to the list that holds them.
        var walked: [(element: AXUIElement, role: String)] = [], container = "none"
        for _ in 0..<8 {
            let role = value(e, kAXRoleAttribute) as? String ?? "?"
            if containers.contains(role) { container = role; break }
            walked.append((e, role))
            guard let up = parent(e) else { break }
            e = up
        }
        let shown = windowFolder(above: e), folder = shown?.url
        let chain = walked.map(\.role).joined(separator: ">") + " in " + container + (shown?.desktop == true ? " on the desktop" : "")
        for (element, role) in walked {
            guard let (file, how) = named(element, role: role, in: folder) else { continue }
            if let folder, file.standardizedFileURL.path == folder.standardizedFileURL.path {
                finderLog.notice("finder: \(chain, privacy: .public) named the window's own folder by \(how, privacy: .public): no file")
                return []
            }
            finderLog.notice("finder: \(chain, privacy: .public): \(file.lastPathComponent, privacy: .public) by \(how, privacy: .public) on \(role, privacy: .public)")
            return isSelected(element) ? selectionHolding(element, file) : [file]
        }
        finderLog.notice("finder: \(chain, privacy: .public): no file named\(folder == nil ? ", the window shows no folder" : "", privacy: .public)")
        return []
    }

    /// The file `element` names and how: its AXURL; else its AXFilename, or the name it shows, in `folder`. A row or a
    /// cell names it on a child too; any other element only on itself.
    private nonisolated static func named(_ element: AXUIElement, role: String, in folder: URL?) -> (URL, String)? {
        let rowLike = role == kAXRowRole || role == kAXCellRole, below = rowLike ? 3 : 0
        if let url = url(element, below: below) { return (url, "AXURL") }
        guard let folder else { return nil }
        if let name = first(element, below: below, { value($0, "AXFilename") as? String }), !name.isEmpty,
           FileManager.default.fileExists(atPath: folder.appending(path: name).path) {
            return (folder.appending(path: name), "AXFilename")
        }
        // A desktop icon is taken as an AXImage that shows its name as its title; unverified until the live check.
        guard rowLike || role == kAXTextFieldRole || role == kAXStaticTextRole || role == kAXImageRole else { return nil }
        let shown = first(element, below: rowLike ? 2 : 0) { e in
            [kAXValueAttribute, kAXTitleAttribute].lazy.compactMap { value(e, $0) as? String }.first { !$0.isEmpty }
        }
        return shown.flatMap { file(shown: $0, in: folder) }.map { ($0, "its name") }
    }

    /// The item in `folder` Finder shows as `name`: that file, or the one whose display name it is (an extension hidden).
    private nonisolated static func file(shown name: String, in folder: URL) -> URL? {
        let fm = FileManager.default, direct = folder.appending(path: name)
        if fm.fileExists(atPath: direct.path) { return direct }
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.first { fm.displayName(atPath: $0.path) == name }
    }

    /// The folder the window above `e` shows, by its AXDocument; on the desktop (a window with no subrole, or none above
    /// its scroll area) the Desktop folder, whose icons may name no AXURL; nil when a window names none.
    private nonisolated static func windowFolder(above e: AXUIElement) -> (url: URL, desktop: Bool)? {
        var e = e, role = value(e, kAXRoleAttribute) as? String
        for _ in 0..<8 {
            if role == kAXWindowRole {
                let document = value(e, kAXDocumentAttribute)
                if let url = ((document as? URL) ?? (document as? String).flatMap(URL.init(string:))), url.isFileURL { return (url, false) }
                return value(e, kAXSubroleAttribute) == nil ? desktop() : nil
            }
            guard let up = parent(e) else { return nil }
            let below = role
            e = up
            role = value(e, kAXRoleAttribute) as? String
            if role == kAXApplicationRole { return below == kAXScrollAreaRole ? desktop() : nil }
        }
        return nil
    }

    private nonisolated static func desktop() -> (url: URL, desktop: Bool)? {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first.map { ($0, true) }
    }

    /// Roles that hold items: the walk up stops here, the point on none of them.
    private nonisolated static let containers: Set<String> = [kAXListRole, kAXOutlineRole, kAXTableRole, kAXBrowserRole,
                                                             kAXScrollAreaRole, kAXWindowRole, kAXApplicationRole, kAXSheetRole]

    /// The item, or the row or cell over it, is selected.
    private nonisolated static func isSelected(_ e: AXUIElement) -> Bool {
        var e = e
        for _ in 0..<3 {
            if value(e, kAXSelectedAttribute) as? Bool == true { return true }
            guard let up = parent(e) else { return false }
            e = up
            if containers.contains(value(e, kAXRoleAttribute) as? String ?? "") { return false }
        }
        return false
    }

    /// The selection of the list holding `e`, `file` among it; just `file` when that list is not found.
    private nonisolated static func selectionHolding(_ e: AXUIElement, _ file: URL) -> [URL] {
        var e = e
        for _ in 0..<6 {
            guard let up = parent(e) else { break }
            e = up
            let items = selected(e)
            guard !items.isEmpty else { continue }
            let urls = items.compactMap { url($0) }
            return urls.contains(file) ? urls : [file]
        }
        return [file]
    }

    private nonisolated static func finder() -> AXUIElement? {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: DesktopIcons.finder).first else { return nil }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    private nonisolated static func value(_ e: AXUIElement, _ name: String) -> AnyObject? {
        // Every element, not only the app's: a hung Finder answers no slower than this.
        AXUIElementSetMessagingTimeout(e, timeout)
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private nonisolated static func parent(_ e: AXUIElement) -> AXUIElement? { value(e, kAXParentAttribute).map { $0 as! AXUIElement } }

    private nonisolated static func elements(_ e: AXUIElement, _ name: String) -> [AXUIElement] { (value(e, name) as? [AXUIElement]) ?? [] }

    private nonisolated static func selected(_ e: AXUIElement) -> [AXUIElement] {
        let rows = elements(e, kAXSelectedRowsAttribute)
        return rows.isEmpty ? elements(e, kAXSelectedChildrenAttribute) : rows
    }

    /// The file `e` names by AXURL, on itself or a child up to `below` levels down.
    private nonisolated static func url(_ e: AXUIElement, below: Int = 3) -> URL? {
        first(e, below: below) { e in
            let named = value(e, kAXURLAttribute)
            return ((named as? URL) ?? (named as? String).flatMap(URL.init(string:))).flatMap { $0.isFileURL ? $0 : nil }
        }
    }

    /// What `read` finds on `e`, else on a child up to `below` levels down, depth first.
    private nonisolated static func first<T>(_ e: AXUIElement, below: Int, _ read: (AXUIElement) -> T?) -> T? {
        if let found = read(e) { return found }
        guard below > 0 else { return nil }
        for child in elements(e, kAXChildrenAttribute) {
            if let found = first(child, below: below - 1, read) { return found }
        }
        return nil
    }
}

private let finderLog = Logger(subsystem: "dev.banozz.pilot", category: "files")
