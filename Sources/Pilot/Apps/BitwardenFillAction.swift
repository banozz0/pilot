import AppKit
import ApplicationServices
import PilotCore
import WebApps

/// Bitwarden: fill login (card agent-bo-95422814): the logins for the page in front, typed into its focused field.
/// The session key lives only in the vault's memory (Sven's option 1, 2026-10-05); a login only in BitwardenFill's Login
/// while it is typed. Nothing here says, logs or copies a password, a username or the session key.
@MainActor
enum BitwardenFillAction {
    /// The bw CLI, holding the session key in memory only, gone when Pilot quits or is told to forget it.
    private static let vault = BitwardenCLIVault(unlocker: unlock)
    /// The app in front when the bind was pressed: the address is read from it, and typing happens only if it is still
    /// in front once a login is chosen. Set only while no fill runs.
    private static var target: NSRunningApplication?

    private static let filler = BitwardenFill.Filler(
        vault: vault,
        frontURL: { target.flatMap(FrontPage.url) },
        pick: pick,
        type: { username, password in
            guard let target, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                return HUD.tip("The app in front changed; nothing was typed")
            }
            Post.text(username)
            Post.key(KeyCode.tab, [])
            Post.text(password)
        },
        say: { HUD.tip($0) },
        log: { alog.notice("bitwarden \($0, privacy: .public)") })

    static func run() {
        guard !filler.isRunning else { return }
        target = NSWorkspace.shared.frontmostApplication
        Task { await filler.run() }
    }

    /// Bitwarden: forget the fill session: bw locks it, and Pilot lets the key go.
    static func forget() {
        Task {
            await vault.lock()
            HUD.tip("Bitwarden fill session forgotten")
            alog.notice("bitwarden fill: session dropped")
        }
    }

    /// A visible terminal runs bw unlock; Sven types his master password into bw there, with Pilot's key tap off so not
    /// one of those keys reaches Pilot. bw's --raw output, the session key alone, comes back through a private pipe,
    /// never the terminal or a file.
    private static func unlock() async -> String? {
        guard let bw = Homebrew.cli("bw") else { HUD.tip("Bitwarden's bw is not installed"); return nil }
        let pipe: SessionPipe
        do { pipe = try SessionPipe() } catch { alog.error("bitwarden fill: pipe not made"); return nil }
        // No tip: its Escape watch sees keys typed in other apps. The tap goes off until the pipe is done.
        HUD.dismissTip()
        let key = await BitwardenUnlock.run(
            pauseKeys: { Engine.shared?.pauseKeyboard() }, resumeKeys: { Engine.shared?.resumeKeyboard() },
            openTerminal: { VisibleTerminal.run(BitwardenUnlock.command(bw: bw, pipe: pipe.path.path), title: "Bitwarden unlock", onSuccess: "true") },
            read: { await pipe.read(timeout: BitwardenUnlock.readWait) })
        guard let key else {
            alog.notice("bitwarden fill: unlock gave no session")
            return nil
        }
        alog.notice("bitwarden fill: session held in memory")
        try? await Task.sleep(for: .milliseconds(600))  // the terminal closes and the app in front gets its window back
        return key
    }

    /// Names and usernames in Pilot's picker; the picker logs only that a row was picked.
    private static func pick(_ choices: [BitwardenFill.Choice]) async -> String? {
        await withCheckedContinuation { done in
            let rows = choices.map { MenuEntry(title: $0.name, target: .action($0.id), detail: $0.username) }
            PilotMenu.shared.pick(rows, title: "Bitwarden", logTitles: false, cancelled: { done.resume(returning: nil) }) { row in
                guard case .action(let id) = row.target else { return done.resume(returning: nil) }
                done.resume(returning: id)
            }
        }
    }
}

/// The address of the page in an app's front window, read through Accessibility: the web area's AXURL, which Safari,
/// Chrome and Pilot's web apps expose. Found from the focused field up first (a few steps), then through the window;
/// a Pilot web app falls back to its own site.
@MainActor
enum FrontPage {
    static func url(_ app: NSRunningApplication) -> URL? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var node: AXUIElement? = attribute(element, kAXFocusedUIElementAttribute)
        for _ in 0..<40 {
            guard let current = node else { break }
            if let url = webAreaURL(current) { return url }
            node = attribute(current, kAXParentAttribute)
        }
        if let window: AXUIElement = attribute(element, kAXFocusedWindowAttribute), let url = search(window) { return url }
        guard app.bundleIdentifier?.hasPrefix(WebAppSpec.bundleIDPrefix) == true, let bundle = app.bundleURL else { return nil }
        return WebAppDirectory.read(bundle)?.url
    }

    private static func webAreaURL(_ element: AXUIElement) -> URL? {
        guard (attribute(element, kAXRoleAttribute) as String?) == "AXWebArea" else { return nil }
        return attribute(element, "AXURL")
    }

    /// Breadth first through at most 300 elements, so a huge page never stalls the bind.
    private static func search(_ root: AXUIElement) -> URL? {
        var queue = [root], next = 0
        while next < queue.count, next < 300 {
            let element = queue[next]
            next += 1
            if let url = webAreaURL(element) { return url }
            queue += (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        }
        return nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
