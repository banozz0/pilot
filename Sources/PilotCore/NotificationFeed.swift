import Foundation

/// A banner's style, from its AXSubrole. Since macOS 26 every one is a view in Notification Center's one full-screen host
/// window, and a new one only shows as AXLayoutChanged.
public enum NotificationKind: String, Sendable, Codable {
    case banner = "AXNotificationCenterBanner"
    case alert = "AXNotificationCenterAlert"
    case bannerStack = "AXNotificationCenterBannerStack"
    case alertStack = "AXNotificationCenterAlertStack"
    /// One of macOS's own banners drawn by Control Center rather than Notification Center (a screen-capture privacy hint,
    /// 2026-11-14): no AX subrole marks it, so this one is Pilot's name.
    case system = "PilotControlCenterBanner"
}

/// The action names Notification Center translates, every language's, from its own strings; the reader tells the app's
/// buttons from its own with them.
public struct NotificationVocabulary: Sendable, Equatable {
    public var close: Set<String>
    public var clearAll: Set<String>
    public var builtIn: Set<String>

    /// The words apps use for a button that opens a text field.
    public static let reply: Set<String> = ["Reply", "Respond", "Responder", "Répondre", "Antworten", "Rispondi", "Antwoorden"]
    public static let english = from(loctable: [:])

    /// `Localizable.loctable`, language to strings: each key's translations plus the key; empty gives the English names.
    public static func from(loctable: [String: Any]) -> NotificationVocabulary {
        func names(_ key: String) -> Set<String> {
            var found: Set<String> = [key]
            for case let strings as [String: Any] in loctable.values {
                if let name = strings[key] as? String, !name.isEmpty { found.insert(name) }
            }
            return found
        }
        let close = names("Close"), clearAll = names("Clear All")
        let others = ["Show", "Show Details", "Hide Details", "Clear", "Options"].reduce(into: Set<String>()) { $0.formUnion(names($1)) }
        return NotificationVocabulary(close: close, clearAll: clearAll, builtIn: others.union(close).union(clearAll))
    }
}

/// One notification as Accessibility shows it. Its words are never logged or sent anywhere; the drawer's copy is saved
/// on the Mac only (`NotificationStore`).
public struct NotificationRead: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: NotificationKind
    public let app: String?
    public let title: String
    public let subtitle: String
    public let body: String
    /// The app's own buttons, in Notification Center's order.
    public let actions: [String]
    /// A button that opens a text field: the notification stays in macOS's banner.
    public let opensReply: Bool
    public var isSystem: Bool { kind == .system }
}

/// What one walk of Notification Center found.
public struct NotificationReading: Sendable, Equatable {
    /// Notification Center answered with its window list. Since macOS 27.2 the host window exists only while a banner is up,
    /// so an answered list without it means nothing is up; an unanswered one (a timeout, a locked screen) says nothing.
    public var answered = false
    public var panelOpen = false
    public var hostFound = false
    /// Where the host window is, read once a walk.
    public var hostPosition: CGPoint?
    public var banners: [NotificationRead] = []
    /// The host window was up with the panel closed, yet no banner read in it: since 27.2 that window exists only while
    /// one is up, so this is a misread. Its make-up, counted and never a word, for the log.
    public var emptyHost: String?
    public init(answered: Bool = false, panelOpen: Bool = false, hostFound: Bool = false, hostPosition: CGPoint? = nil, banners: [NotificationRead] = [],
                emptyHost: String? = nil) {
        (self.answered, self.panelOpen, self.hostFound, self.hostPosition, self.banners, self.emptyHost) = (answered, panelOpen, hostFound, hostPosition, banners, emptyHost)
    }
}

/// Reads banners out of Notification Center's tree (shape and name parsing after NotificationNanny, MIT, notice in
/// Packaging): its AXSystemDialog host window only, so the menu bar, the open panel's
/// list and the desktop's widgets (windows of their own) are never walked.
public enum NotificationReader {
    public static let hostSubrole = "AXSystemDialog"
    static let panelListIdentifier = "AXNotificationListItems"
    /// A lone banner sits 5 deep; two or more pinned alerts (Login Item Added, App Background Activity) were missed at 7
    /// on 2026-11-16. The keys' walk's depth (`Notifications.maxDepth`); `maxNodes` bounds the walk.
    static let maxDepth = Notifications.maxDepth
    static let maxNodes = 300

    public static func host(in app: any NotificationElement) -> (any NotificationElement)? {
        app.windows?.first { $0.subrole == hostSubrole }
    }

    /// The banners on screen, newest first as Notification Center lists them; none while its panel is open.
    public static func read(_ app: any NotificationElement, vocabulary: NotificationVocabulary) -> NotificationReading {
        guard let windows = app.windows else { return NotificationReading() }
        let host = windows.first { $0.subrole == hostSubrole }
        guard !app.isExpanded else { return NotificationReading(answered: true, panelOpen: true, hostFound: host != nil, hostPosition: host?.position) }
        guard let host else { return NotificationReading(answered: true) }
        let banners = elements(in: host, panelOpen: false).compactMap { read(banner: $0, vocabulary: vocabulary) }
        return NotificationReading(answered: true, hostFound: true, hostPosition: host.position, banners: banners,
                                   emptyHost: banners.isEmpty ? shape(of: host) : nil)
    }

    /// The banner element with `id`, read afresh for a press; nil once it has gone.
    public static func element(id: String, in app: any NotificationElement) -> (any NotificationElement)? {
        guard let host = host(in: app) else { return nil }
        return elements(in: host, panelOpen: app.isExpanded).first { key(of: $0) == id }
    }

    /// The list Notification Center keeps its rows in is the open panel's history, never walked then. With the panel
    /// closed the host holds no history (the 27 capture), so a list there holds what is on screen: two or more pinned
    /// alerts (modelled 2026-11-16, not yet captured).
    static func elements(in host: any NotificationElement, panelOpen: Bool) -> [any NotificationElement] {
        var budget = maxNodes, found: [any NotificationElement] = []
        func walk(_ element: any NotificationElement, _ depth: Int) {
            guard depth <= maxDepth, budget > 0, !(panelOpen && element.identifier == panelListIdentifier) else { return }
            budget -= 1
            if let subrole = element.subrole, NotificationKind(rawValue: subrole) != nil { found.append(element); return }
            element.children.forEach { walk($0, depth + 1) }
        }
        walk(host, 0)
        return found
    }

    /// A host window with no banner read: its make-up for the log, walked only then, within the reader's own limits. How
    /// deep and how many nodes the walk reached (`maxNodes` reached is a miss), roles and subroles and the AX-named
    /// identifiers counted. Never a word.
    static func shape(of host: any NotificationElement) -> String {
        var roles: [String: Int] = [:], ids: [String: Int] = [:], nodes = 0, deepest = 0
        func walk(_ element: any NotificationElement, _ depth: Int) {
            guard depth <= maxDepth, nodes < maxNodes else { return }
            nodes += 1
            deepest = max(deepest, depth)
            roles[[element.role ?? "?", element.subrole ?? ""].filter { !$0.isEmpty }.joined(separator: "/"), default: 0] += 1
            if let id = element.identifier, id.hasPrefix("AX") { ids[id, default: 0] += 1 }
            element.children.forEach { walk($0, depth + 1) }
        }
        walk(host, 0)
        return "depth=\(deepest) nodes=\(nodes) roles=\(counted(roles)) ids=\(counted(ids))"
    }

    /// Counts for a log line, as `key:n`, sorted.
    static func counted(_ counts: [String: Int]) -> String {
        counts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
    }

    /// AXIdentifier, or the kind and words for one without, hashed so the key shows none of them.
    static func key(of banner: any NotificationElement) -> String {
        if let id = banner.identifier, !id.isEmpty { return id }
        return "anon-\(banner.subrole ?? "")-\(banner.attributedDescription ?? "")".hashed
    }

    static func read(banner: any NotificationElement, vocabulary: NotificationVocabulary) -> NotificationRead? {
        guard let subrole = banner.subrole, let kind = NotificationKind(rawValue: subrole) else { return nil }
        var lines: [String: String] = [:]
        for child in banner.children where child.role == "AXStaticText" {
            guard let id = child.identifier, let value = child.value else { continue }
            let text = clean(value)
            if !text.isEmpty { lines[id] = text }
        }
        let description = banner.attributedDescription.map(clean) ?? ""
        let title = lines["title"] ?? fallbackTitle(description)
        let actions = banner.actionNames.filter { $0.hasPrefix("Name:") }.map(Notifications.name).filter { !vocabulary.builtIn.contains($0) }
        return NotificationRead(id: key(of: banner), kind: kind, app: app(description: description, title: lines["title"]), title: title,
                                subtitle: lines["subtitle"] ?? "", body: lines["body"] ?? "", actions: actions,
                                opensReply: actions.contains { NotificationVocabulary.reply.contains($0) })
    }

    /// The app, from "App, Title, Body" or, on a Persistent banner on macOS 27, "App Title, Body".
    static func app(description: String, title: String?) -> String? {
        if let title, !title.isEmpty {
            let padded = description + ", "
            for marker in [", \(title), ", " \(title), "] {
                guard let range = padded.range(of: marker) else { continue }
                let app = String(padded[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !app.isEmpty, !app.contains(", ") { return app }
            }
        }
        let first = description.components(separatedBy: ", ").first.map(clean) ?? ""
        return first.isEmpty ? nil : first
    }

    /// The part after the app, for a layout with no labelled lines.
    private static func fallbackTitle(_ description: String) -> String {
        let parts = description.components(separatedBy: ", ")
        return parts.count > 1 ? parts[1] : description
    }

    /// Drops invisible marks (WhatsApp's U+200E) and the spaces round the words.
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint })).trimmingCharacters(in: .whitespaces)
    }
}

/// macOS's own banners that Control Center draws instead of Notification Center: a screen-capture privacy hint ("“App”
/// Is Accessing Your Screen", 2026-11-14), shown in its SystemBannerWindow. The same window also carries the volume and
/// brightness sliders, battery, charging and listening-mode banners, and its menu extras open module windows, so a
/// window is a card only by positive signs: two lines of text or more, and nothing a person sets (no slider, switch,
/// field, list or menu).
public extension NotificationReader {
    static let systemApp = "macOS"
    static let systemPrefix = "cc-"
    /// Roles that mark a control surface, never a banner.
    static let systemControls: Set<String> = [
        "AXSlider", "AXCheckBox", "AXSwitch", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTextField",
        "AXTextArea", "AXScrollArea", "AXTable", "AXOutline", "AXList", "AXMenu", "AXMenuItem", "AXLevelIndicator",
        "AXValueIndicator", "AXProgressIndicator", "AXIncrementor", "AXDisclosureTriangle", "AXTabGroup",
    ]
    static let systemDepth = 8
    static let systemNodes = 120

    /// One Control Center window's shape: its roles and lines of text, counted, never a word.
    struct SystemShape: Sendable, Equatable {
        public var role: String, subrole: String, texts: Int, roles: [String: Int], controls: Bool
        public var isBanner: Bool { texts >= 2 && !controls }
        /// For the log: shape only.
        public var line: String {
            "\(role)/\(subrole) texts=\(texts) controls=\(controls) roles=" + NotificationReader.counted(roles)
        }
    }

    /// One Control Center window as a walk found it: the banner it holds, if it is one, and its shape.
    struct SystemWindow {
        public let window: any NotificationElement
        public let read: NotificationRead?
        public let shape: SystemShape
    }

    /// Every Control Center window, each walked once; nil reads are not banners.
    static func systemWindows(_ app: any NotificationElement) -> [SystemWindow] {
        (app.windows ?? []).map(systemWindow)
    }

    /// The window holding the banner with `id`, read afresh.
    static func systemWindow(id: String, in app: any NotificationElement) -> (any NotificationElement)? {
        systemWindows(app).first { $0.read?.id == id }?.window
    }

    static func isSystem(id: String) -> Bool { id.hasPrefix(systemPrefix) }

    /// Calls `body` on each element under `root`, depth first, at most `systemDepth` deep and `systemNodes` in all.
    private static func visit(_ root: any NotificationElement, _ body: (any NotificationElement) -> Void) {
        var budget = systemNodes
        func walk(_ element: any NotificationElement, _ depth: Int) {
            guard depth <= systemDepth, budget > 0 else { return }
            budget -= 1
            body(element)
            element.children.forEach { walk($0, depth + 1) }
        }
        walk(root, 0)
    }

    private static func systemWindow(_ window: any NotificationElement) -> SystemWindow {
        var texts: [String] = [], roles: [String: Int] = [:], controls = false
        visit(window) { element in
            let role = element.role ?? "?"
            roles[role, default: 0] += 1
            if systemControls.contains(role) { controls = true }
            if role == "AXStaticText", let words = (element.value ?? element.attributedDescription).map(clean), !words.isEmpty { texts.append(words) }
        }
        let shape = SystemShape(role: window.role ?? "?", subrole: window.subrole ?? "-", texts: texts.count, roles: roles, controls: controls)
        guard shape.isBanner else { return SystemWindow(window: window, read: nil, shape: shape) }
        let title = texts[0], body = texts.dropFirst().joined(separator: " ")
        let read = NotificationRead(id: systemPrefix + (title + "\n" + body).hashed, kind: .system, app: systemApp, title: title,
                                    subtitle: "", body: body, actions: [], opensReply: false)
        return SystemWindow(window: window, read: read, shape: shape)
    }

    /// A card's press on a Control Center banner: Close presses its own dismiss button, Open the banner itself.
    static func pressSystem(_ action: NotificationPress, id: String, in app: any NotificationElement, vocabulary: NotificationVocabulary) -> NotificationPressResult {
        guard let window = systemWindow(id: id, in: app) else { return .gone }
        var buttons: [any NotificationElement] = [], pressable: [any NotificationElement] = []
        visit(window) { element in
            if element.role == "AXButton" { buttons.append(element) } else if element.actionNames.contains("AXPress") { pressable.append(element) }
        }
        let closing = vocabulary.close.union(["Dismiss"])
        let target: (any NotificationElement)?, raw: String
        switch action {
        case .close:
            let named = buttons.first { b in [b.identifier, b.attributedDescription].contains { $0.map { closing.contains($0) } ?? false } }
                ?? buttons.first { $0.actionNames.contains { closing.contains(Notifications.name($0)) } }
            target = named ?? (buttons.count == 1 ? buttons[0] : nil)
            raw = target?.actionNames.first { closing.contains(Notifications.name($0)) } ?? "AXPress"
        case .open:
            target = pressable.first
            raw = "AXPress"
        case .button:
            return .refused
        }
        guard let target else { return .refused }
        return target.perform(raw) ? .done : .refused
    }
}

extension String {
    /// A short stable digest of the words, so a key built from them shows none of them.
    var hashed: String { "h" + String(utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 16) }
}

/// What a card's click, close or button asks of the native notification.
public enum NotificationPress: Sendable, Equatable {
    case open, close
    case button(String)

    public var kind: String {
        switch self {
        case .open: "open"
        case .close: "close"
        case .button: "button"
        }
    }
}

public enum NotificationPressResult: String, Sendable {
    case done, gone, refused
}

public extension NotificationReader {
    /// Presses the notification with `id`, read afresh: its own Close or Clear All, AXPress to open it, or one of the app's
    /// buttons by name; `.gone` once it has left Notification Center.
    static func press(_ action: NotificationPress, id: String, in app: any NotificationElement, vocabulary: NotificationVocabulary) -> NotificationPressResult {
        guard let banner = element(id: id, in: app) else { return .gone }
        let names = banner.actionNames
        let raw: String? = switch action {
        case .open: names.first { $0 == "AXPress" }
        case .close: names.first { vocabulary.close.contains(Notifications.name($0)) } ?? names.first { vocabulary.clearAll.contains(Notifications.name($0)) }
        case .button(let name): names.first { Notifications.name($0) == name }
        }
        guard let raw else { return .refused }
        return banner.perform(raw) ? .done : .refused
    }

    /// A text field showed up under the notification: a button that turned out to be a reply.
    static func hasField(id: String, in app: any NotificationElement) -> Bool {
        guard let banner = element(id: id, in: app) else { return false }
        func walk(_ element: any NotificationElement, _ depth: Int) -> Bool {
            if depth > 6 { return false }
            if element.role == "AXTextField" || element.role == "AXTextArea" { return true }
            return element.children.contains { walk($0, depth + 1) }
        }
        return walk(banner, 0)
    }
}

/// One notification as Pilot keeps it; the drawer's are saved across a relaunch (`NotificationFeed.Saved`).
public struct NotificationEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public var kind: NotificationKind
    public var app: String?
    public var title: String
    public var subtitle: String
    public var body: String
    public var actions: [String]
    public var arrived: Date
    /// macOS's banner for it is still up, so Close and the buttons can still reach it.
    public var live = true
    /// Listed in the drawer; a row taken out while its banner is up stays until the banner goes.
    public var inDrawer = true
    /// Pilot draws no card for it: macOS's own banner stays visible instead.
    public var leftToMacOS: Bool
    /// Walks in a row that didn't find it; one is often a timeout, so only a second lets a drawerless record go.
    var missed = 0
    /// When its pop-up's countdown began: it first showed as a card, or the pointer last left the cards. Nil for a saved
    /// row until a walk finds its banner up, so a relaunch never counts from when it arrived.
    var popupSince: Date?
    /// Its pop-up hid itself after its time (Sven, 2026-11-22): no card while its banner stays up, even after one walk that
    /// missed it; still live, still in the drawer.
    public internal(set) var popupDone = false

    init(_ read: NotificationRead, at date: Date) {
        id = read.id; kind = read.kind; app = read.app; title = read.title; subtitle = read.subtitle; body = read.body
        actions = read.actions; arrived = date; leftToMacOS = read.opensReply; popupSince = date
    }

    /// A saved row, read back after a relaunch: its banner's state is unknown until the first walk finds it again.
    init(saved: NotificationFeed.SavedEntry) {
        id = saved.id; kind = saved.kind; app = saved.app; title = saved.title
        subtitle = saved.subtitle; body = saved.body; actions = []; arrived = saved.arrived; live = false; inDrawer = true
        leftToMacOS = false
    }

    public var isSystem: Bool { kind == .system }
    /// A card whose pop-up hasn't hidden itself yet.
    var showsPopup: Bool { live && !leftToMacOS && !popupDone }

    func differs(from read: NotificationRead) -> Bool {
        title != read.title || subtitle != read.subtitle || body != read.body || actions != read.actions
    }

    mutating func take(_ read: NotificationRead) {
        kind = read.kind; app = read.app ?? app; title = read.title; subtitle = read.subtitle; body = read.body; actions = read.actions
        if read.opensReply { leftToMacOS = true }
    }
}

/// What to do with macOS's host window.
public enum NotificationParking: Sendable, Equatable {
    case park
    /// Back on screen, but after a short hold: a burst shouldn't bring it back between two banners.
    case restoreAfterHold
    case restore
}

/// What arrived and went since the last walk, and the drawer's memory: a value, with no clock or Accessibility in it.
public struct NotificationFeed: Sendable {
    public static let drawerLimit = 100
    /// Most cards shown at once; the rest are only in the drawer.
    public static let cardLimit = 4
    static let seenLimit = 500

    /// Newest first: what's up now and what the drawer lists, one record for each notification.
    private var entries: [NotificationEntry] = []
    public private(set) var unread = 0
    private var seen: [String] = []

    public init() {}

    /// What a relaunch keeps: the drawer's rows, at most `drawerLimit`, with only what a row shows (no buttons, no
    /// Accessibility ids beyond the key), and the unread count.
    public struct Saved: Codable, Sendable, Equatable {
        public var entries: [SavedEntry]
        public var unread: Int
        public init(entries: [SavedEntry] = [], unread: Int = 0) { (self.entries, self.unread) = (entries, unread) }
    }

    public struct SavedEntry: Codable, Sendable, Equatable {
        public var id: String, kind: NotificationKind, app: String?, title: String, subtitle: String, body: String, arrived: Date
    }

    public var saved: Saved {
        Saved(entries: drawer.prefix(Self.drawerLimit).map {
            SavedEntry(id: $0.id, kind: $0.kind, app: $0.app, title: $0.title, subtitle: $0.subtitle, body: $0.body, arrived: $0.arrived)
        }, unread: unread)
    }

    /// The drawer as a relaunch left it: every row not live until a walk finds its banner still up, which then comes back
    /// as its card with no second row.
    public init(restoring saved: Saved) {
        entries = saved.entries.prefix(Self.drawerLimit).map(NotificationEntry.init(saved:))
        unread = min(max(saved.unread, 0), entries.count)
        remember(entries.map(\.id))
    }

    public var live: [NotificationEntry] { entries.filter(\.live) }
    /// Newest first, at most `drawerLimit`; kept across a relaunch, gone when the setting goes off.
    public var drawer: [NotificationEntry] { entries.filter(\.inDrawer) }
    /// The cards to draw: up now and not left to macOS.
    public var cards: [NotificationEntry] { live.filter { !$0.leftToMacOS } }
    /// The cards whose pop-up still shows: each hides itself after its time (Sven, 2026-11-22). One hidden is still a card
    /// for parking, so macOS's banner stays off screen too.
    public var popups: [NotificationEntry] { entries.filter(\.showsPopup) }

    /// Hides each pop-up whose countdown reached `seconds` by `now`; true when one hid.
    public mutating func expirePopups(at now: Date, after seconds: TimeInterval) -> Bool {
        var hid = false
        for index in entries.indices where entries[index].showsPopup {
            guard let since = entries[index].popupSince, now.timeIntervalSince(since) >= seconds else { continue }
            entries[index].popupDone = true
            hid = true
        }
        return hid
    }

    /// When the next pop-up hides; nil while none shows, so nothing need wait.
    public func nextPopupEnd(after seconds: TimeInterval) -> Date? {
        entries.filter(\.showsPopup).compactMap(\.popupSince).min().map { $0.addingTimeInterval(seconds) }
    }

    /// The pointer left the cards: each one showing counts down afresh from `now`.
    public mutating func restartPopups(at now: Date) {
        for index in entries.indices where entries[index].showsPopup { entries[index].popupSince = now }
    }

    public struct Change: Sendable, Equatable {
        public var arrived: [NotificationEntry] = []
        public var gone: [String] = []
        public var changed = false
        public var isEmpty: Bool { arrived.isEmpty && gone.isEmpty && !changed }
    }

    /// Takes one walk. An open panel's walk, or one Notification Center didn't answer (a timeout, a locked screen), says
    /// nothing about banners, so it changes nothing; an answered one without the host window means none is up.
    @discardableResult
    public mutating func update(_ reading: NotificationReading, at date: Date) -> Change {
        var change = Change()
        guard !reading.panelOpen, reading.answered else { return change }
        let ids = Set(reading.banners.map(\.id))
        for index in entries.indices where !ids.contains(entries[index].id) {
            entries[index].missed += 1
            guard entries[index].live else { continue }
            entries[index].live = false
            change.gone.append(entries[index].id)
        }
        dropGone()
        for read in reading.banners.reversed() {
            if let index = entries.firstIndex(where: { $0.id == read.id }) {
                // Live again after a walk that missed it (a timeout reads as nothing there): the banner never left.
                // After two or more, it did: a repeat with the same words, whose id is their digest, pops up afresh.
                let returned = entries[index].missed >= 2
                entries[index].missed = 0
                guard !entries[index].live || entries[index].differs(from: read) else { continue }
                if !entries[index].live, returned || entries[index].popupSince == nil {
                    entries[index].popupSince = date
                    entries[index].popupDone = false
                }
                entries[index].live = true
                entries[index].take(read)
                change.changed = true
            } else if !seen.contains(read.id) {
                let entry = NotificationEntry(read, at: date)
                entries.insert(entry, at: 0)
                unread += 1
                change.arrived.append(entry)
                remember([read.id])
            }
        }
        trimDrawer()
        return change
    }

    /// Control Center's banners with a card now: their windows go off screen while the switch is on.
    public var systemCards: [NotificationEntry] { cards.filter(\.isSystem) }

    /// macOS's host window may go off screen: every banner in it has a card, and all of them fit.
    public var canPark: Bool {
        let up = live.filter { !$0.isSystem }
        return !up.isEmpty && up.count <= Self.cardLimit && up.allSatisfy { !$0.leftToMacOS }
    }

    /// Where macOS's host window should be. `allowed`: the switch is on and its own panel, which shares the window, is closed.
    public func parking(allowed: Bool) -> NotificationParking {
        guard allowed else { return .restore }
        if canPark { return .park }
        return live.isEmpty ? .restoreAfterHold : .restore
    }

    /// A press Pilot couldn't finish, or a reply that opened: macOS's banner takes over for this one.
    public mutating func leaveToMacOS(_ id: String) {
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].leftToMacOS = true }
    }

    public mutating func markRead() { unread = 0 }

    public mutating func remove(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].inDrawer = false
        if !entries[index].live { forget(entries.remove(at: index).id) }
    }

    public mutating func clearDrawer() {
        for index in entries.indices { entries[index].inDrawer = false }
        for entry in entries where !entry.live { forget(entry.id) }
        entries.removeAll { !$0.live }
        unread = 0
    }

    private mutating func trimDrawer() {
        var listed = 0
        for index in entries.indices where entries[index].inDrawer {
            listed += 1
            if listed > Self.drawerLimit { entries[index].inDrawer = false }
        }
        dropGone()
    }

    private mutating func dropGone() {
        for entry in entries where !entry.live && !entry.inDrawer && entry.missed >= 2 { forget(entry.id) }
        entries.removeAll { !$0.live && !$0.inDrawer && $0.missed >= 2 }
    }

    /// A dropped record leaves no block: a banner still up after a misread arrives again as a card.
    private mutating func forget(_ id: String) { seen.removeAll { $0 == id } }

    private mutating func remember(_ ids: [String]) {
        seen.append(contentsOf: ids.filter { !seen.contains($0) })
        if seen.count > Self.seenLimit { seen.removeFirst(seen.count - Self.seenLimit) }
    }
}
