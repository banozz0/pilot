import Foundation
import Synchronization

/// The macOS menu bar's automatic hiding, System Events' `autohide menu bar` of `dock preferences` (top bar spike,
/// vault note Projects/Pilot/Top bar spike.md); a protocol so tests never touch the real one.
public protocol MenuBarAutohide: Sendable {
    func isHidden() async throws -> Bool
    func setHidden(_ hidden: Bool) async throws
}

/// The real one: osascript in a child process (AGENTS.md: never NSAppleScript on the main thread), the timeout long
/// enough for macOS's one Automation prompt to be answered.
public struct SystemEventsAutohide: MenuBarAutohide {
    public init() {}

    static let readScript = #"tell application "System Events" to get autohide menu bar of dock preferences"#
    static func writeScript(_ hidden: Bool) -> String {
        #"tell application "System Events" to set autohide menu bar of dock preferences to "# + (hidden ? "true" : "false")
    }
    static func parse(_ output: String) -> Bool? {
        ["true": true, "false": false][output.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    public func isHidden() async throws -> Bool {
        let out = try await Self.run(Self.readScript)
        guard let hidden = Self.parse(out) else { throw ChildProcess.Failure(tool: "osascript", status: 0, message: "autohide read \(out)") }
        return hidden
    }

    public func setHidden(_ hidden: Bool) async throws { _ = try await Self.run(Self.writeScript(hidden)) }

    private static func run(_ script: String) async throws -> String {
        try await ChildProcess.run("/usr/bin/osascript", ["-e", script], timeout: .seconds(120))
    }
}

public enum TopBarError: Error, CustomStringConvertible {
    case autohide(any Error)
    case block(any Error)

    public var description: String {
        switch self {
        case .autohide(let e): "The menu bar's hiding was not changed (System Events: \(e)); allow Pilot under Privacy & Security › Automation"
        case .block(let e): "The tiler's room for the bar was not set: \(e)"
        }
    }
}

/// The top bar's switch (card agent-bo-95422850): on saves the menu bar's autohide, makes room for the bars in Pilot's
/// block, then hides the menu bar; off writes the block without bars, then puts the saved autohide back. Each step
/// that fails undoes the one before it, so the switch is either fully on or as it was.
public struct TopBarSwitch: Codable, Equatable, Sendable {
    public var isOn: Bool
    /// System Events' autohide as switching on found it, put back by switching off.
    public var savedAutohide: Bool?

    public init(isOn: Bool, savedAutohide: Bool?) { self.isOn = isOn; self.savedAutohide = savedAutohide }

    public static let off = TopBarSwitch(isOn: false, savedAutohide: nil)

    public typealias WriteBars = @Sendable ([PilotBlock.BarInset]) async throws -> Void

    public func switchedOn(_ bars: [PilotBlock.BarInset], autohide: any MenuBarAutohide,
                           writeBars: WriteBars) async throws(TopBarError) -> TopBarSwitch {
        guard !isOn else { return self }
        let found: Bool
        do { found = try await autohide.isHidden() } catch { throw .autohide(error) }
        do { try await writeBars(bars) } catch { throw .block(error) }
        do { try await autohide.setHidden(true) } catch {
            try? await writeBars([])
            throw .autohide(error)
        }
        return TopBarSwitch(isOn: true, savedAutohide: found)
    }

    /// `bars` are the ones on now, written back when the menu bar refuses to come back.
    public func switchedOff(bars: [PilotBlock.BarInset], autohide: any MenuBarAutohide,
                            writeBars: WriteBars) async throws(TopBarError) -> TopBarSwitch {
        guard isOn else { return self }
        do { try await writeBars([]) } catch { throw .block(error) }
        do { try await autohide.setHidden(savedAutohide ?? false) } catch {
            try? await writeBars(bars)
            throw .autohide(error)
        }
        return .off
    }
}

/// Where the bars sit and how tall they are, from each screen's menu bar strip.
public enum TopBarGeometry {
    /// A screen by the tiler's monitor name (NSScreen's localizedName) and its bar height.
    public struct Screen: Equatable, Sendable {
        public let name: String
        public let strip: Double
        public let displayUUID: String?
        public init(name: String, strip: Double, displayUUID: String? = nil) {
            self.name = name; self.strip = strip; self.displayUUID = displayUUID
        }
    }

    /// The menu bar's strip: the frame's top less the visible frame's; when autohide leaves that 0, the height
    /// remembered while it showed, else `fallback` (NSStatusBar's thickness, which reads 22 where the strip is 30).
    public static func strip(frameMaxY: Double, visibleMaxY: Double, remembered: Double?, fallback: Double) -> Double {
        let measured = frameMaxY - visibleMaxY
        return measured > 0 ? measured : remembered ?? fallback
    }

    /// A bar's frame (AppKit's, bottom-left origin): its screen's top `strip`, the whole width.
    public static func frame(screen: CGRect, strip: Double) -> CGRect {
        CGRect(x: screen.minX, y: screen.maxY - strip, width: screen.width, height: strip)
    }

    /// A screen's visible frame less its bar, both in AX coordinates (y down): the bar is a hard edge, so a window Pilot
    /// places (a snap, a cascade, a move to another display) starts under it. No bar, or a visible frame already clear
    /// of it, leaves the frame as it is.
    public static func belowBar(_ visible: CGRect, screen: CGRect, bar: Double?) -> CGRect {
        guard let bar, bar > 0 else { return visible }
        let edge = max(visible.minY, screen.minY + CGFloat(inset(bar)))
        return CGRect(x: visible.minX, y: edge, width: visible.width, height: max(0, visible.maxY - edge))
    }

    /// The tiler's gaps are whole points: rounded up, so no tile slips under the bar.
    public static func inset(_ strip: Double) -> Int { Int(strip.rounded(.up)) }

    /// The room each screen's bar takes in Pilot's block.
    public static func bars(_ screens: [Screen]) -> [PilotBlock.BarInset] {
        screens.map { PilotBlock.BarInset(monitor: $0.name, height: inset($0.strip)) }
    }
}

/// The top bar's own settings before card agent-bo-95422910, read only to carry them into the bar items (BarSettings.migrated).
public enum TopBarModule: String, Decodable, Sendable {
    case workspaces, clock, focusedApp, inputSource, volume, pomodoro, battery, menuApps
    case cpu, gpu, ram, disk, temperature, network, bluetooth
}

public enum TopBarStyle: String, Decodable, Sendable {
    case compact, text, graph
}

/// One saved module and its look.
public struct TopBarItem: Decodable, Equatable, Sendable {
    public let module: TopBarModule
    public let style: TopBarStyle?

    public init(_ module: TopBarModule, style: TopBarStyle? = nil) { self.module = module; self.style = style }
    private enum CodingKeys: CodingKey { case module, style }

    /// A style this Pilot lacks is forgotten; a module it lacks fails, and the side skips it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(TopBarModule.self, forKey: .module), style: (try? c.decodeIfPresent(TopBarStyle.self, forKey: .style)) ?? nil)
    }
}

/// A side of the top bar.
public enum TopBarSide: String, Codable, CaseIterable, Sendable {
    case left, centre, right
}

public struct TopBarLayout: Decodable, Equatable, Sendable {
    public var left: [TopBarItem], centre: [TopBarItem], right: [TopBarItem]
    public init(left: [TopBarItem], centre: [TopBarItem], right: [TopBarItem]) {
        self.left = left; self.centre = centre; self.right = right
    }
    private enum CodingKeys: CodingKey { case left, centre, right }

    /// The old default: workspaces on the left, the clock on the right.
    public static let standard = TopBarLayout(left: [TopBarItem(.workspaces)], centre: [], right: [TopBarItem(.clock)])

    public subscript(side: TopBarSide) -> [TopBarItem] {
        switch side {
        case .left: left
        case .centre: centre
        case .right: right
        }
    }

    /// A module a later Pilot saved and this one lacks is skipped, never a crash.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func side(_ key: CodingKeys) throws -> [TopBarItem] {
            try c.decode([Lossy<TopBarItem>].self, forKey: key).compactMap(\.value)
        }
        self.init(left: try side(.left), centre: try side(.centre), right: try side(.right))
    }
}

/// One element of a saved list that a later Pilot may have written: one this Pilot cannot read is nil, never a failure.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

/// The clock's look: a date pattern (Unicode TR35, as DateFormatter takes it), one of the presets or Sven's own.
public struct TopBarClockFormat: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let time24 = Self(rawValue: "HH:mm"), time12 = Self(rawValue: "h:mm a"), seconds24 = Self(rawValue: "HH:mm:ss")
    /// The clock's date, its own hit target in the date + time style.
    public static let date = Self(rawValue: "EEE d MMM")
    /// The old top bar clock's default, carried as the time style's pattern.
    public static let dateTime24 = Self(rawValue: date.rawValue + "  HH:mm")
    /// The time patterns to pick; the date + time style adds the date.
    public static let presets: [(title: String, format: Self)] = [("24 h", time24), ("12 h", time12), ("24 h with seconds", seconds24)]

    public func formatter(timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = rawValue
        return f
    }

    public func text(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        Self.formatters.withLock { made in
            let key = Formatting(pattern: rawValue, timeZone: timeZone, locale: locale)
            if let f = made[key] { return f.string(from: date) }
            let f = formatter(timeZone: timeZone, locale: locale)
            made[key] = f
            return f.string(from: date)
        }
    }

    /// Every bar redraws its clock every few seconds, each slot asking again: one formatter per pattern, zone and locale.
    private struct Formatting: Hashable { let pattern: String, timeZone: TimeZone, locale: Locale }
    private static let formatters = Mutex<[Formatting: DateFormatter]>([:])

    /// Whether the text changes every second (an s outside quoted text), so the bar redraws that often only then.
    public var showsSeconds: Bool { unquoted.contains("s") }

    /// Its hours and minutes, without seconds: an event's start and end in the clock's own hours (h or K outside quoted
    /// text is a 12-hour clock).
    public var hoursAndMinutes: Self { unquoted.contains(where: { $0 == "h" || $0 == "K" }) ? .time12 : .time24 }

    /// The pattern outside quoted text.
    private var unquoted: String {
        rawValue.split(separator: "'", omittingEmptySubsequences: false).enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element).joined()
    }
}

/// The top bar's settings before card agent-bo-95422910 (topBar.settings): the standard layout and the clock's format,
/// read only to carry them into the bar items; a screen's own layout is not carried.
public struct TopBarSettings: Decodable, Equatable, Sendable {
    public var standard = TopBarLayout.standard
    public var clock = TopBarClockFormat.dateTime24

    public init() {}
}

/// The workspaces module: the tiler's occupied workspaces plus the one this screen shows, in the tiler's order.
public enum TopBarWorkspaces {
    public struct Item: Equatable, Sendable {
        public let name: String
        /// The workspace this bar's screen shows.
        public let isShownHere: Bool
        public let isFocused: Bool
    }

    public static func items(occupied: [String], focused: String?, visibleHere: String?) -> [Item] {
        Set(occupied + [focused, visibleHere].compactMap { $0 }).sorted(by: OccupiedWorkspace.ordered)
            .map { Item(name: $0, isShownHere: $0 == visibleHere, isFocused: $0 == focused) }
    }

    /// A workspace's apps as the icons style draws them (card agent-bo-95423019): each once in the tiler's order, at most
    /// `limit`, the rest counted as +N.
    public struct Icons: Equatable, Sendable {
        public let apps: [String]
        public let more: Int

        public init(apps: [String], more: Int) { self.apps = apps; self.more = more }
        public init(_ all: [String], limit: Int = 3) { self.init(apps: Array(all.prefix(limit)), more: max(0, all.count - limit)) }

        public var moreLabel: String? { more > 0 ? "+\(more)" : nil }
    }
}

/// What the modules of card agent-bo-95422852 say, from their readings.
public enum TopBarText {
    /// The output's volume; Muted while muted; a dash for a device with no volume (an HDMI screen).
    public static func volume(_ level: Float?, muted: Bool?) -> String {
        muted == true ? "Muted" : level.map { "\(Int(($0 * 100).rounded())) %" } ?? "–"
    }

    /// The layout's name, or its first two letters in capitals as a code.
    public static func inputSource(_ name: String?, style: BarStyle?) -> String {
        guard let name else { return "–" }
        return style == .code ? String(name.filter(\.isLetter).prefix(2)).uppercased() : name
    }

    /// The frontmost app's name; nil hides the module (no app in front, or one with no name).
    public static func focusedApp(_ name: String?) -> String? { name.flatMap { $0.isEmpty ? nil : $0 } }

    /// The SF Symbol for the battery's level, to the nearest quarter.
    public static func batterySymbol(_ battery: SystemStats.Battery) -> String {
        "battery.\(Int((Double(battery.percent) / 25).rounded()) * 25)"
    }
}

extension KeyboardLayouts {
    /// The layout after the current one in `choices`, wrapping round; nil when there is no other.
    nonisolated public static func next(in choices: [InputSource]) -> InputSource? {
        guard choices.count > 1 else { return nil }
        return choices[((choices.firstIndex(where: \.isCurrent) ?? -1) + 1) % choices.count]
    }
}
