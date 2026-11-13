import Foundation

/// The dock's round 5 widgets (Sven's Lumabar picks, Q217, 2026-11-13): quick toggles, recent files, clocks with world
/// time and the sun, the scratch note, a stopwatch, the busiest apps and battery looks. Their choices are
/// DockWidgetOptions'; their faces are made here, pure, so `pilot dock widgets` and the renders go through what the dock
/// draws.

/// System stats' busiest app, by what it uses most of.
public enum DockTopApp: String, CaseIterable, Codable, Sendable {
    case cpu, memory

    public var title: String { self == .cpu ? "Busiest app by CPU" : "Busiest app by memory" }
}

/// How Battery draws its level.
public enum DockBatteryLook: String, CaseIterable, Codable, Sendable {
    case text, ring, gauge, dots

    public var title: String { rawValue.capitalized }
}

/// How Clocks draws the time here.
public enum DockClockLook: String, CaseIterable, Codable, Sendable {
    case digital, flip, analog

    public var title: String { rawValue.capitalized }
}

/// Quick toggles' buttons.
public enum DockToggle: String, CaseIterable, Codable, Sendable {
    case wifi, bluetooth, dnd, mic, output

    public var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .bluetooth: "Bluetooth"
        case .dnd: "Do Not Disturb"
        case .mic: "Microphone"
        case .output: "Sound output"
        }
    }
}

/// Recent files' stacks.
public enum DockStack: String, CaseIterable, Codable, Sendable {
    case downloads, captures, recent

    public var title: String {
        switch self {
        case .downloads: "Downloads"
        case .captures: "Captures"
        case .recent: "Recent files"
        }
    }

    public var symbol: String {
        switch self {
        case .downloads: "arrow.down.circle"
        case .captures: "camera.viewfinder"
        case .recent: "clock.arrow.circlepath"
        }
    }
}

/// One file in a stack: newest first.
public struct DockFile: Equatable, Sendable {
    public let url: URL
    public let date: Date
    public init(url: URL, date: Date) { self.url = url; self.date = date }
    public var name: String { url.lastPathComponent }

    /// The newest `limit` regular files straight in `folder` (no hidden ones, no folders), by when they last changed.
    public static func newest(in folder: URL, limit: Int = 12, fileManager: FileManager = .default) -> [DockFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let found = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return found.compactMap { url -> DockFile? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return DockFile(url: url, date: values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }
}

/// What Quick toggles reads: nil where a state cannot be read (no Wi-Fi, Bluetooth not allowed, no Focus file).
public struct DockToggleStates: Equatable, Sendable {
    public var wifi: Bool?, bluetooth: Bool?, dnd: Bool?, micMuted: Bool?
    public var output: String?
    public init(wifi: Bool? = nil, bluetooth: Bool? = nil, dnd: Bool? = nil, micMuted: Bool? = nil, output: String? = nil) {
        self.wifi = wifi; self.bluetooth = bluetooth; self.dnd = dnd; self.micMuted = micMuted; self.output = output
    }
}

/// The stopwatch: time gathered while paused, and when it last started while it runs. Saved, so a relaunch keeps it.
public struct DockStopwatch: Codable, Equatable, Sendable {
    public var gathered: TimeInterval = 0
    public var started: Date?
    public init(gathered: TimeInterval = 0, started: Date? = nil) { self.gathered = gathered; self.started = started }

    public var running: Bool { started != nil }
    public func elapsed(_ now: Date) -> TimeInterval { gathered + (started.map { max(0, now.timeIntervalSince($0)) } ?? 0) }

    public mutating func start(_ now: Date) { if started == nil { started = now } }

    public mutating func pause(_ now: Date) {
        guard let started else { return }
        gathered += max(0, now.timeIntervalSince(started))
        self.started = nil
    }

    /// Start, or pause where it runs.
    public mutating func toggle(_ now: Date) { running ? pause(now) : start(now) }

    public mutating func reset() { self = DockStopwatch() }

}

/// Where a time zone's main city stands, from macOS's own `zone.tab` (ISO 6709 coordinates), for the sun's times without
/// Location: no permission, no network.
public enum DockZones {
    public static let table = URL(filePath: "/usr/share/zoneinfo/zone.tab")

    /// The coordinates `zone` names in `text` (zone.tab's lines), as degrees north and east.
    public static func place(_ zone: String, in text: String) -> (latitude: Double, longitude: Double)? {
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, fields[2] == zone else { continue }
            return coordinates(String(fields[1]))
        }
        return nil
    }

    /// "+3554+01431" or "+353916-1394441": latitude then longitude, each a sign, degrees, minutes and maybe seconds.
    static func coordinates(_ text: String) -> (latitude: Double, longitude: Double)? {
        guard let split = text.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        guard let latitude = angle(String(text[..<split]), degrees: 2), let longitude = angle(String(text[split...]), degrees: 3) else { return nil }
        return (latitude, longitude)
    }

    private static func angle(_ text: String, degrees width: Int) -> Double? {
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = Array(text.dropFirst())
        guard digits.count == width + 2 || digits.count == width + 4, digits.allSatisfy(\.isNumber) else { return nil }
        let part = { (from: Int, count: Int) in Double(String(digits[from..<from + count]))! }
        let value = part(0, width) + part(width, 2) / 60 + (digits.count == width + 4 ? part(width + 2, 2) / 3600 : 0)
        return sign == "-" ? -value : value
    }
}

/// Sunrise and sunset by the sunrise equation (NOAA's simplified form, a minute or two from the published times).
public enum DockSun {
    /// The sun's rise and set on the day holding `date` in `calendar`'s time zone at a place; nil for each on a day it
    /// never rises or never sets.
    public static func times(on date: Date, latitude: Double, longitude: Double, calendar: Calendar = .autoupdatingCurrent) -> (rise: Date?, set: Date?) {
        let noon = calendar.startOfDay(for: date).addingTimeInterval(12 * 3600)
        let julian = noon.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let n = (julian - 2_451_545.0 + 0.0008).rounded()
        let mean = n - longitude / 360
        let rad = Double.pi / 180
        let m = (357.5291 + 0.98560028 * mean).truncatingRemainder(dividingBy: 360)
        let c = 1.9148 * sin(m * rad) + 0.0200 * sin(2 * m * rad) + 0.0003 * sin(3 * m * rad)
        let lambda = (m + c + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let transit = 2_451_545.0 + mean + 0.0053 * sin(m * rad) - 0.0069 * sin(2 * lambda * rad)
        let declination = asin(sin(lambda * rad) * sin(23.4397 * rad))
        let cosHour = (sin(-0.833 * rad) - sin(latitude * rad) * sin(declination)) / (cos(latitude * rad) * cos(declination))
        guard abs(cosHour) <= 1 else { return (nil, nil) }
        let hour = acos(cosHour) / rad / 360
        let day = { (j: Double) in Date(timeIntervalSince1970: (j - 2_440_587.5) * 86_400) }
        return (day(transit - hour), day(transit + hour))
    }
}

extension DockFaces {
    /// Quick toggles: a round button per toggle picked, lit while on; the output's names its device.
    public static func toggles(_ picked: [DockToggle], _ states: DockToggleStates) -> [DockFace] {
        picked.map { toggle in
            let word = { (on: Bool?) in on.map { $0 ? "On" : "Off" } ?? "Can't read" }
            switch toggle {
            case .wifi:
                return DockFace(glyph: .symbol(states.wifi == false ? "wifi.slash" : "wifi"), label: toggle.title, value: word(states.wifi),
                                kind: .toggle(on: states.wifi), action: .toggle(.wifi))
            case .bluetooth:
                return DockFace(glyph: .symbol("dot.radiowaves.left.and.right"), label: toggle.title, value: word(states.bluetooth),
                                kind: .toggle(on: states.bluetooth), action: .toggle(.bluetooth))
            case .dnd:
                return DockFace(glyph: .symbol("moon.fill"), label: toggle.title, value: states.dnd.map { $0 ? "On" : "Off" } ?? "Focus",
                                kind: .toggle(on: states.dnd ?? false), action: .toggle(.dnd))
            case .mic:
                let on = states.micMuted.map { !$0 }
                return DockFace(glyph: .symbol(on == false ? "mic.slash.fill" : "mic.fill"), label: toggle.title,
                                value: on.map { $0 ? "On" : "Muted" } ?? "Can't read", kind: .toggle(on: on), action: .toggle(.mic))
            case .output:
                let device = states.output ?? "–"
                let symbol = device.lowercased().contains("airpods") || device.lowercased().contains("headphone") ? "headphones" : "speaker.wave.2.fill"
                return DockFace(glyph: .symbol(symbol), label: toggle.title, value: device, kind: .toggle(on: false), action: .toggle(.output))
            }
        }
    }

    /// Recent files: a face per stack picked, its newest file's name under the stack's name.
    public static func stacks(_ picked: [DockStack], _ files: [DockStack: [DockFile]]) -> [DockFace] {
        picked.map { stack in
            let newest = files[stack]?.first
            return DockFace(glyph: .symbol(stack.symbol), label: stack.title, value: newest.map { short($0.name) } ?? "Empty", action: .stack(stack))
        }
    }

    /// A file name held to 22 characters, its extension kept.
    static func short(_ name: String) -> String {
        guard name.count > 20 else { return name }
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        let keep = max(4, 19 - ext.count - 1)
        return String(stem.prefix(keep)) + "…" + (ext.isEmpty ? "" : "." + ext)
    }

    /// Clocks: the time here in its look over today's date, each world clock (its city and how far ahead or behind), and
    /// the sun's next rise or set here when `sun` is on and the zone's place is known.
    public static func clocks(_ now: Date, look: DockClockLook, zones: [String], sun: Bool, place: (latitude: Double, longitude: Double)?,
                              calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> [DockFace] {
        func time(_ date: Date, _ zone: TimeZone) -> String {
            date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: zone).hour(.twoDigits(amPM: .omitted)).minute())
        }
        let here = calendar.timeZone
        let day = now.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: here).weekday(.abbreviated).day())
        func analog(_ zone: TimeZone) -> DockFace.Glyph {
            let parts = calendar.dateComponents(in: zone, from: now)
            return .analog(hour: Double((parts.hour ?? 0) % 12) + Double(parts.minute ?? 0) / 60, minute: Double(parts.minute ?? 0))
        }
        var faces: [DockFace] = switch look {
        case .digital: [DockFace(glyph: .symbol("clock"), label: day, value: time(now, here))]
        case .flip: [DockFace(glyph: .symbol("clock"), label: day, value: time(now, here), kind: .flip)]
        case .analog: [DockFace(glyph: analog(here), label: day, value: time(now, here))]
        }
        for id in zones.prefix(DockWidgetOptions.mostZones) {
            guard let zone = TimeZone(identifier: id) else { continue }
            let ahead = Double(zone.secondsFromGMT(for: now) - here.secondsFromGMT(for: now)) / 3600
            let offset = ahead == 0 ? "" : " " + (ahead > 0 ? "+" : "−") + (ahead.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(abs(ahead)))" : String(format: "%.1f", abs(ahead)))
            let glyph: DockFace.Glyph = look == .analog ? analog(zone) : .symbol("globe")
            faces.append(DockFace(glyph: glyph, label: BarParts.city(zone) + offset, value: time(now, zone)))
        }
        if sun, let place {
            let today = DockSun.times(on: now, latitude: place.latitude, longitude: place.longitude, calendar: calendar)
            let next: (String, Date?, String) = if let rise = today.rise, now < rise { ("Sunrise", rise, "sunrise.fill") }
                else if let set = today.set, now < set { ("Sunset", set, "sunset.fill") }
                else { ("Sunrise", DockSun.times(on: now.addingTimeInterval(86_400), latitude: place.latitude, longitude: place.longitude, calendar: calendar).rise, "sunrise.fill") }
            if let at = next.1 { faces.append(DockFace(glyph: .symbol(next.2, multicolor: true), label: next.0, value: time(at, here))) }
        }
        return faces
    }

    /// The scratch note: its first line of text (a heading only when it holds nothing else), its marks gone.
    public static func note(_ text: String?) -> DockFace {
        let lines = (text ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let line = (lines.first { !$0.hasPrefix("#") } ?? lines.first)?.trimmingCharacters(in: CharacterSet(charactersIn: "#-*> \t"))
        return DockFace(glyph: .symbol("note.text"), label: "Scratch", value: line.map { String($0.prefix(28)) } ?? "Empty")
    }

    /// The stopwatch: its time, running or paused.
    public static func stopwatch(_ watch: DockStopwatch, now: Date) -> DockFace {
        let elapsed = watch.elapsed(now)
        return DockFace(glyph: .symbol(watch.running ? "stopwatch.fill" : "stopwatch"), label: watch.running ? "Stopwatch" : elapsed > 0 ? "Paused" : "Stopwatch",
                        value: RecordingClock.label(elapsed))
    }

    /// The busiest app by each of `picked`, from the sampler's lists (its name over what it uses).
    public static func topApps(_ picked: [DockTopApp], cpu: [SystemStats.Row], memory: [SystemStats.Row]) -> [DockFace] {
        picked.map { by in
            let top = (by == .cpu ? cpu : memory).first
            return DockFace(glyph: .symbol(by == .cpu ? "flame" : "memorychip"), label: by == .cpu ? "Top CPU" : "Top memory",
                            value: top.map { "\(short($0.name)) \($0.value)" } ?? "…")
        }
    }

    /// Battery's look on the faces that carry a level: a ring, a gauge or dots for the glyph (text leaves them as they
    /// are); the power draw has no level, so it keeps its bolt.
    public static func look(_ faces: [DockFace], _ look: DockBatteryLook) -> [DockFace] {
        guard look != .text else { return faces }
        return faces.map { face in
            guard let share = face.meter else { return face }
            var looked = face
            looked.glyph = switch look {
            case .ring: .ring(share)
            case .gauge: .gauge(share)
            case .dots: .dots(filled: Int((share * 5).rounded()), count: 5)
            case .text: face.glyph
            }
            return looked
        }
    }
}
