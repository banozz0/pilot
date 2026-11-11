import AppKit
import Foundation
@testable import Pilot
import PilotCore
import SwiftUI

/// The sandbox's Notification Center (a harness, not a test): `tree.json` in a throwaway folder stands in for the
/// Accessibility tree, `pid` for its process, and what the watcher does is appended to `events.jsonl`. Rewriting the tree
/// and bumping `generation` is a banner arriving.
@MainActor
enum NotificationFixture {
    static func install(_ folder: String) {
        let source = NotificationFixtureSource(URL(filePath: folder))
        PilotNotifications.shared.useSandbox(source: source, presenter: NotificationRecordingPresenter(source: source))
        source.pollCommands()
    }
}

final class NotificationFixtureSource: NotificationSource, @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var host: CGPoint?
    @MainActor private var watch: Task<Void, Never>?

    nonisolated init(_ folder: URL) { self.folder = folder }

    func file(_ name: String) -> URL { folder.appending(path: name) }
    func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name).path(percentEncoded: false)) }
    func text(_ name: String) -> String? { (try? String(contentsOf: file(name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }

    func record(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: .sortedKeys) else { return }
        lock.withLock {
            let handle = (try? FileHandle(forWritingTo: file("events.jsonl"))) ?? {
                FileManager.default.createFile(atPath: file("events.jsonl").path(percentEncoded: false), contents: nil)
                return try? FileHandle(forWritingTo: file("events.jsonl"))
            }()
            _ = try? handle?.seekToEnd()
            try? handle?.write(contentsOf: data + Data("\n".utf8))
            try? handle?.close()
        }
    }

    var hostPosition: CGPoint? {
        get { lock.withLock { host } }
        set { lock.withLock { host = newValue } }
    }

    func currentPID() -> pid_t { pid_t(text("pid") ?? "") ?? 0 }
    func stillRunning(_ pid: pid_t) -> Bool { pid > 0 && currentPID() == pid }

    @MainActor func attach(changed: @escaping @MainActor () -> Void) -> Bool {
        detach()
        let pid = currentPID()
        guard pid > 0 else { record(["event": "attach-refused"]); return false }
        record(["event": "attach", "pid": Int(pid)])
        watch = Task { [weak self] in
            var seen = self?.text("generation")
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                let now = self.text("generation")
                if now != seen { seen = now; changed() }
            }
        }
        return true
    }

    @MainActor func detach() {
        if watch != nil { record(["event": "detach"]) }
        watch?.cancel()
        watch = nil
    }

    /// Runs for the host's life: a tap on the bell works with the setting off too.
    @MainActor func pollCommands() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                self?.runCommands()
            }
        }
    }

    /// Two displays for the bell: the Mac mini's 3440x1440 (`main`) and a 1920x1080 to its right (`side`), top bar and
    /// Dock taken off the first.
    static let displays = ["main": CGRect(x: 0, y: 70, width: 3440, height: 1340), "side": CGRect(x: 3440, y: 0, width: 1920, height: 1050)]
    /// One store for the run: a test run's `UserDefaults.pilot()` is a new throwaway suite each call.
    @MainActor private var bellStore: NotificationBellPlaces?
    @MainActor var bellPlaces: NotificationBellPlaces {
        if let bellStore { return bellStore }
        let made = NotificationBellPlaces(defaults: UserDefaults.pilot())
        bellStore = made
        return made
    }

    /// The bell let go at `x`,`y` (screen points) at `side` on a display, through the store and placement the app's bell uses.
    @MainActor private func bellDrop(display: String, x: Double, y: Double, side: Double) {
        guard let visible = Self.displays[display] else { return record(["event": "bad-command"]) }
        bellPlaces.save(CGRect(x: x, y: y, width: side, height: side), on: display, visible: visible)
        bellPlace(display: display)
        if has("render") { NotificationFixtureRender.bell(side: side).map { try? $0.write(to: file("bell.png")) } }
    }

    /// Where the bell is on a display, and the drawer it would open beside it.
    @MainActor private func bellPlace(display: String) {
        guard let visible = Self.displays[display] else { return record(["event": "bad-command"]) }
        let bell = bellPlaces.frame(on: display, visible: visible)
        let drawer = bellPlaces.drawer(nextTo: bell, in: visible)
        // A one-card stack on the main display, placed as the app places it against this bell.
        let cards = NotificationPlacement.cards(in: Self.displays["main"]!, size: CGSize(width: NotificationPlacement.cardWidth, height: 92), bell: bell)
        record(["event": "bell-place", "display": display, "last": bellPlaces.lastDisplay ?? "",
                "bell": [bell.minX, bell.minY, bell.width, bell.height], "drawer": [drawer.minX, drawer.minY, drawer.width, drawer.height],
                "cards": [cards.minX, cards.minY, cards.width, cards.height]])
    }

    /// `commands`, a line each: `open <id>`, `close <id>` or `button <name> <id>`, the taps a card would make;
    /// `bell-drop <display> <x> <y> <side>` and `bell <display>`, the bell's drag and where it is; `drawer-closed <w> <h>`,
    /// the drawer closing at a pulled size.
    @MainActor private func runCommands() {
        guard has("commands"), let text = text("commands"), !text.isEmpty else { return }
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            switch (words.first, words.count) {
            case ("drawer"?, 1): PilotNotifications.shared.toggleDrawer()
            case ("remove"?, 2): PilotNotifications.shared.removeFromDrawer(words[1])
            case ("clear"?, 1): PilotNotifications.shared.clearDrawer()
            case ("open"?, 2): PilotNotifications.shared.press(.open, id: words[1])
            case ("close"?, 2): PilotNotifications.shared.press(.close, id: words[1])
            case ("button"?, 3): PilotNotifications.shared.press(.button(words[1]), id: words[2])
            case ("bell-drop"?, 5): bellDrop(display: words[1], x: Double(words[2]) ?? 0, y: Double(words[3]) ?? 0, side: Double(words[4]) ?? 0)
            case ("bell"?, 2): bellPlace(display: words[1])
            case ("drawer-closed"?, 3): bellPlaces.keepDrawerSize(CGSize(width: Double(words[1]) ?? 0, height: Double(words[2]) ?? 0))
            default: record(["event": "bad-command"])
            }
        }
        try? FileManager.default.removeItem(at: file("commands"))
    }

    func root() -> (any NotificationElement)? {
        guard let data = try? Data(contentsOf: file("tree.json")),
              let tree = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        record(["event": "read"])
        if has("host-back") {
            hostPosition = nil
            try? FileManager.default.removeItem(at: file("host-back"))
        }
        return NotificationFixtureNode(tree, source: self)
    }

    func vocabulary() -> NotificationVocabulary { .english }
}

/// One node of `tree.json`, keyed as the real tree's attributes.
final class NotificationFixtureNode: NotificationElement {
    let node: [String: Any]
    let source: NotificationFixtureSource

    init(_ node: [String: Any], source: NotificationFixtureSource) { (self.node, self.source) = (node, source) }

    private func nodes(_ key: String) -> [any NotificationElement] {
        (node[key] as? [[String: Any]] ?? []).map { NotificationFixtureNode($0, source: source) }
    }

    var actionNames: [String] { node["actions"] as? [String] ?? [] }
    var children: [any NotificationElement] { nodes("children") }
    /// A tree without the key is a read that failed; `"windows": []` is Notification Center with nothing up.
    var windows: [any NotificationElement]? { node["windows"] == nil ? nil : nodes("windows") }
    var role: String? { node["role"] as? String }
    var subrole: String? { node["subrole"] as? String }
    var identifier: String? { node["identifier"] as? String }
    var value: String? { node["value"] as? String }
    var attributedDescription: String? { node["description"] as? String }
    var isExpanded: Bool { node["expanded"] as? Bool ?? false }

    var position: CGPoint? {
        if subrole == NotificationReader.hostSubrole, let moved = source.hostPosition { return moved }
        guard let xy = node["position"] as? [Double], xy.count == 2 else { return nil }
        return CGPoint(x: xy[0], y: xy[1])
    }

    func setPosition(_ point: CGPoint) -> Bool {
        source.record(["event": "move", "x": point.x, "y": point.y, "subrole": subrole ?? ""])
        guard !source.has("refuse-move") else { return false }
        source.hostPosition = point
        return true
    }

    func perform(_ action: String) -> Bool {
        source.record(["event": "press", "id": identifier ?? "", "action": Notifications.name(action)])
        return !source.has("refuse-press")
    }
}

/// Records what would be drawn, in the sandbox's fixture words only.
@MainActor
final class NotificationRecordingPresenter: NotificationPresenting {
    let source: NotificationFixtureSource

    init(source: NotificationFixtureSource) { self.source = source }

    /// The screen frame a Mac mini on a 3440x1440 display gives the panels: the top bar and Dock taken off.
    static let visible = CGRect(x: 0, y: 70, width: 3440, height: 1340)

    func update(cards: [NotificationEntry], drawer: [NotificationEntry], unread: Int) {
        let size = CGSize(width: NotificationPlacement.cardWidth, height: 92 * Double(min(cards.count, NotificationFeed.cardLimit)))
        // As the app's panels place them: against the bell where it is now (review round 2, B2 wiring).
        let bell = source.bellPlaces.frame(on: "main", visible: Self.visible)
        let frame = NotificationPlacement.cards(in: Self.visible, size: size, bell: bell)
        source.record(["event": "cards", "cards": cards.map(Self.describe), "drawer": drawer.map(Self.describe), "unread": unread,
                       "frame": [frame.minX, frame.minY, frame.width, frame.height], "bell": [bell.minX, bell.minY]])
        if !cards.isEmpty, source.has("render"), let png = NotificationFixtureRender.cards(cards) { try? png.write(to: source.file("cards.png")) }
    }

    func begin() { source.record(["event": "begin"]) }
    func toggleDrawer() {
        source.record(["event": "drawer"])
        if source.has("render"), let png = NotificationFixtureRender.drawer(PilotNotifications.shared.feed.drawer) { try? png.write(to: source.file("drawer.png")) }
    }
    func openApp(named name: String) { source.record(["event": "open-app", "app": name]) }
    func end() { source.record(["event": "end"]) }
    func say(_ text: String) { source.record(["event": "tip", "text": text]) }

    private static func describe(_ entry: NotificationEntry) -> [String: Any] {
        ["id": entry.id, "kind": entry.kind.rawValue, "app": entry.app ?? "", "title": entry.title, "subtitle": entry.subtitle, "body": entry.body,
         "actions": entry.actions, "live": entry.live, "left": entry.leftToMacOS]
    }
}

/// One offscreen picture of the cards, on the sandbox's flat ground: layout and words only, glass doesn't draw offscreen.
@MainActor
enum NotificationFixtureRender {
    static func cards(_ cards: [NotificationEntry]) -> Data? {
        let model = NotificationCardsModel()
        model.cards = Array(cards.prefix(NotificationFeed.cardLimit).reversed())
        let host = NSHostingView(rootView: NotificationCardStack(model: model).padding(16).background(Color(white: 0.2)).styled(.barPopovers).pilotTheme().fixedSize())
        host.frame.size = host.fittingSize
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    static func bell(side: Double) -> Data? {
        let model = NotificationCardsModel()
        model.unread = 3
        model.bellSide = side
        let host = NSHostingView(rootView: NotificationBell(model: model) { _ in }.padding(16).background(Color(white: 0.2)).styled(.barPopovers).pilotTheme().fixedSize())
        host.frame.size = host.fittingSize
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    static func drawer(_ entries: [NotificationEntry]) -> Data? {
        let model = NotificationCardsModel()
        model.drawer = entries
        model.unread = 2
        let view = HStack(alignment: .bottom, spacing: 16) {
            NotificationDrawer(model: model).frame(width: NotificationPlacement.drawerWidth, height: 440)
            NotificationBell(model: model) { _ in }
        }
        let host = NSHostingView(rootView: view.padding(16).background(Color(white: 0.2)).styled(.barPopovers).pilotTheme().fixedSize())
        host.frame.size = host.fittingSize
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
