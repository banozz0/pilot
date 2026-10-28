import Foundation

/// The calculator's money, time zones and dates (card agent-bo-95423047; Raycast's and SuperCmd's calculator, ideas
/// only): "40 eur in usd", "5pm london in malta", "time in tokyo", "today + 30 days", "days until 2026-12-25". A root
/// answer of its own after Calculator's sums and units (RootAnswers), so nothing the calculator answered before changes.
public enum CalculatorWorld {
    typealias Answer = (result: String, detail: String?)

    /// The menu's row for what was typed, if any: the result as its title, Return copies it.
    public static func entries(for text: String, now: Date, zone: TimeZone, rates: RateState?) -> [MenuEntry] {
        let t = text.trimmingCharacters(in: .whitespaces), lower = t.lowercased(), sides = split(lower)
        guard let found = money(sides, rates: rates, now: now) ?? time(sides, now: now, zone: zone) ?? date(lower, now: now, zone: zone)
        else { return [] }
        return Calculator.row(found.result, detail: found.detail ?? "= \(t)")
    }

    /// The text either side of its last " in " or " to ".
    private static func split(_ lower: String) -> (left: String, right: String)? {
        guard let sep = [" in ", " to "].compactMap({ lower.range(of: $0, options: .backwards) }).max(by: { $0.lowerBound < $1.lowerBound })
        else { return nil }
        let left = lower[..<sep.lowerBound].trimmingCharacters(in: .whitespaces), right = lower[sep.upperBound...].trimmingCharacters(in: .whitespaces)
        return left.isEmpty || right.isEmpty ? nil : (left, right)
    }

    // MARK: money: "<amount> <currency> in|to <currency>", a currency by its code, its sign or its name.

    private static let signs: [Character: String] = ["€": "eur", "$": "usd", "£": "gbp", "¥": "jpy"]
    private static let names = ["euro": "eur", "euros": "eur", "dollar": "usd", "dollars": "usd", "pound": "gbp", "pounds": "gbp", "yen": "jpy"]

    private static func money(_ sides: (left: String, right: String)?, rates: RateState?, now: Date) -> Answer? {
        guard let state = rates, let (left, right) = sides else { return nil }
        func rate(_ word: String) -> (code: String, rate: Double)? {
            let code = word.count == 1 ? word.first.flatMap { signs[$0] } : names[word] ?? word
            guard let code, let rate = state.rates.rates[code] ?? (code == state.rates.base ? 1 : nil), rate > 0 else { return nil }
            return (code, rate)
        }
        var amount = left
        let from: (code: String, rate: Double)?
        if let i = amount.firstIndex(where: { signs[$0] != nil }) {
            from = rate(String(amount.remove(at: i)))
        } else {
            let word = String(amount.reversed().prefix(while: \.isLetter).reversed())
            from = rate(word)
            amount.removeLast(word.count)
        }
        guard let from, let to = rate(right), let value = Calculator.evaluate(amount.trimmingCharacters(in: .whitespaces)) else { return nil }
        let day = state.rates.date
        // Judged by Pilot's own fetch, never the rates' date: the source runs a day behind.
        let old = state.offline || now.timeIntervalSince(state.fetched) >= 86_400
        return ("\(Calculator.format(value / from.rate * to.rate)) \(to.code.uppercased())",
                "= \(Calculator.format(value)) \(from.code.uppercased()) · \(old ? "offline, " : "")rates from \(day)")
    }

    // MARK: time zones: "<time> [place] in|to <place>", "time in <place>".

    private static func time(_ sides: (left: String, right: String)?, now: Date, zone: TimeZone) -> Answer? {
        guard let (left, right) = sides, let (target, there) = place(right) else { return nil }
        if left == "time" || left == "now" { return (formatted(now, "HH:mm", target), "Time in \(there) now, \(formatted(now, "EEE d MMM", target))") }
        guard let m = left.wholeMatch(of: /(noon|midnight|(\d{1,2})(?::(\d{2}))?\s*(am|pm)?)(?:\s+(.+))?/) else { return nil }
        var hour = m.1 == "noon" ? 12 : 0, minute = m.3.flatMap { Int($0) } ?? 0
        if let h = m.2.flatMap({ Int($0) }) {
            // A bare number is a count, not a time: 5 needs am, pm or minutes.
            guard m.4 != nil || m.3 != nil, minute < 60, m.4 == nil ? h < 24 : (1...12).contains(h) else { return nil }
            hour = m.4.map { h % 12 + ($0 == "pm" ? 12 : 0) } ?? h
        }
        let from: (zone: TimeZone, phrase: String)
        if let named = m.5 {
            guard let (z, name) = place(String(named)) else { return nil }
            from = (z, "in \(name)")
        } else {
            from = (zone, "here")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = from.zone
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        (parts.hour, parts.minute) = (hour, minute)
        guard let instant = calendar.date(from: parts) else { return nil }
        let start = formatted(instant, "yyyy-MM-dd", from.zone), end = formatted(instant, "yyyy-MM-dd", target)
        let when = start == end ? "" : end > start ? ", the next day" : ", the day before"
        let at = formatted(instant, "HH:mm", target)
        return (at, "\(m.1) \(from.phrase) is \(at) in \(there)\(when)")
    }

    /// A place by a city in a zone's name ("london", "new york", "bogotá") or a few countries and abbreviations; its
    /// name as typed, capitalised.
    private static func place(_ text: String) -> (TimeZone, String)? {
        let key = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard let id = aliases[key] ?? cities[key], let zone = TimeZone(identifier: id) else { return nil }
        return (zone, key.count <= 3 ? text.uppercased() : text.capitalized)
    }

    private static let aliases = [
        "uk": "Europe/London", "england": "Europe/London", "colombia": "America/Bogota", "spain": "Europe/Madrid",
        "nyc": "America/New_York", "ny": "America/New_York", "la": "America/Los_Angeles", "sf": "America/Los_Angeles",
        "san francisco": "America/Los_Angeles", "utc": "UTC", "gmt": "GMT", "cet": "Europe/Paris", "est": "America/New_York",
        "pst": "America/Los_Angeles", "jst": "Asia/Tokyo",
    ]

    /// Every zone's city, "America/New_York" as "new york"; the first zone keeps a city two share.
    private static let cities: [String: String] = {
        var out: [String: String] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers {
            guard let city = id.split(separator: "/").last?.replacingOccurrences(of: "_", with: " ").lowercased(), out[city] == nil else { continue }
            out[city] = id
        }
        return out
    }()

    private static func formatted(_ date: Date, _ format: String, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = format
        return f.string(from: date)
    }

    // MARK: dates: "<day> + or - <n> <unit>", "in <n> <unit>", "<n> <unit> ago", "days until|since <day>".

    private static let unitWords: [Substring: Calendar.Component] = ["day": .day, "week": .weekOfYear, "month": .month, "year": .year]

    private static func date(_ lower: String, now: Date, zone: TimeZone) -> Answer? {
        // Every date sum holds a number or starts "days"; the rest of the typing stops here.
        guard lower.contains(where: \.isNumber) || lower.hasPrefix("days ") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        func day(_ s: Substring) -> Date? {
            switch s {
            case "today": return today
            case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
            case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
            default:
                guard Calculator.isDate(String(s)) else { return nil }
                let p = s.split(separator: "-").compactMap { Int($0) }
                return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
            }
        }
        func shifted(_ from: Date?, _ n: Int, _ word: Substring) -> Answer? {
            guard let from, let unit = unitWords[word.hasSuffix("s") ? word.dropLast() : word],
                  let d = calendar.date(byAdding: unit, value: n, to: from) else { return nil }
            return (formatted(d, "EEE d MMM yyyy", zone), nil)
        }
        if let m = lower.wholeMatch(of: /(\S+)\s*([+-])\s*(\d+)\s*([a-z]+)/), let n = Int(m.3) { return shifted(day(m.1), m.2 == "-" ? -n : n, m.4) }
        if let m = lower.wholeMatch(of: /in (\d+) ([a-z]+)/), let n = Int(m.1) { return shifted(today, n, m.2) }
        if let m = lower.wholeMatch(of: /(\d+) ([a-z]+) ago/), let n = Int(m.1) { return shifted(today, -n, m.2) }
        if let m = lower.wholeMatch(of: /days (until|till|to|since) (\S+)/), let target = day(m.2),
           let n = calendar.dateComponents([.day], from: today, to: target).day {
            let days = m.1 == "since" ? -n : n
            return ("\(days) day\(abs(days) == 1 ? "" : "s")", nil)
        }
        return nil
    }
}
