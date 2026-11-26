import Foundation

/// The menu's calculator (card agent-bo-95422933; Vicinae's and Omarchy's calculator): arithmetic and unit conversions
/// typed at the root answer as the first row, Return copies the result. A parser of its own, never NSExpression, which
/// raises an Objective-C exception on text it cannot read.
public enum Calculator {
    /// The answer to what was typed, or nil when it is not a sum or a conversion: a bare number (-42 included), a date
    /// written 2024-10-06, a word, an app name.
    public static func answer(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= MenuNavigator.minimumQuery, t.contains(where: \.isNumber) else { return nil }
        if let conversion = convert(t) { return conversion }
        guard t.contains(where: { "+-*/×÷^%()".contains($0) }), !isDate(t), let value = evaluate(t), value.isFinite else { return nil }
        let result = format(value)
        return result == t ? nil : result
    }

    /// The menu's row for the answer, if any: the result as its title, Return copies it.
    public static func entries(for text: String) -> [MenuEntry] {
        answer(text).map { row($0, detail: "= \(text.trimmingCharacters(in: .whitespaces))") } ?? []
    }

    /// An answer row: the result as its title, Return copies it (CalculatorWorld's too).
    static func row(_ result: String, detail: String) -> [MenuEntry] {
        [MenuEntry(title: result, target: .copy(result), detail: "\(detail) · Return copies", isAnswer: true)]
    }

    /// A date written with dashes, 2024-10-06, which reads as a subtraction.
    static func isDate(_ t: String) -> Bool { t.wholeMatch(of: /\d{4}-\d{1,2}-\d{1,2}/) != nil }

    // MARK: arithmetic: + - * / ^ %, brackets, unary minus, decimals with a point or a comma.

    static func evaluate(_ text: String) -> Double? {
        var p = Parser(c: Array(text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: ".").filter { !$0.isWhitespace }))
        let v = p.sum()
        return p.done ? v : nil
    }

    private struct Parser {
        let c: [Character]
        var i = 0
        var done: Bool { i == c.count }
        mutating func eat(_ x: Character) -> Bool { if i < c.count && c[i] == x { i += 1; return true }; return false }

        /// Left to right over one precedence level: `next` reads each operand, `ops` joins them.
        mutating func chain(_ next: (inout Parser) -> Double?, _ ops: [Character: (Double, Double) -> Double]) -> Double? {
            guard var v = next(&self) else { return nil }
            while i < c.count, let op = ops[c[i]] {
                i += 1
                guard let r = next(&self) else { return nil }
                v = op(v, r)
            }
            return v
        }
        mutating func sum() -> Double? { chain({ $0.product() }, ["+": (+), "-": (-)]) }
        mutating func product() -> Double? {
            chain({ $0.power() }, ["*": (*), "/": (/), "%": { $0.truncatingRemainder(dividingBy: $1) }])
        }
        /// Right-associative: 2^3^2 is 2^9.
        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            return eat("^") ? power().map { pow(base, $0) } : base
        }
        mutating func unary() -> Double? {
            if eat("-") { return unary().map { -$0 } }
            if eat("+") { return unary() }
            return atom()
        }
        mutating func atom() -> Double? {
            if eat("(") { guard let v = sum(), eat(")") else { return nil }; return v }
            let start = i
            while i < c.count, c[i].isNumber || c[i] == "." { i += 1 }
            return i > start ? Double(String(c[start..<i])) : nil
        }
    }

    // MARK: conversions: "<number> <unit> in|to|into <unit>", a unit by its symbol or its name ("20 hours into seconds").

    private static func convert(_ text: String) -> String? {
        let parts = text.split(separator: " ")
        guard parts.count >= 3, ["in", "to", "into"].contains(parts[parts.count - 2].lowercased()) else { return nil }
        // The target as typed ("72000 seconds"); the number and its unit may be one word or two ("20h", "20 hours").
        let target = String(parts[parts.count - 1]), left = parts.dropLast(2).joined().lowercased()
        let numberEnd = left.firstIndex { !($0.isNumber || $0 == "." || $0 == "," || $0 == "-") } ?? left.endIndex
        guard let value = evaluate(String(left[..<numberEnd])), let from = unit(String(left[numberEnd...])),
              // One family by its base unit: Foundation's own units are a private subclass, a day or a week is not.
              let to = unit(target.lowercased()), type(of: from).baseUnit() == type(of: to).baseUnit() else { return nil }
        return "\(format(Measurement(value: value, unit: from).converted(to: to).value)) \(target)"
    }

    /// Every unit by its symbol, then by its name, singular and plural ("hour", "hours"), a metre also a meter; a year
    /// is 365 days. Built once.
    private static let units: [String: Dimension] = {
        var units: [String: Dimension] = [
            "mm": UnitLength.millimeters, "cm": UnitLength.centimeters, "m": UnitLength.meters, "km": UnitLength.kilometers,
            "in": UnitLength.inches, "inch": UnitLength.inches, "inches": UnitLength.inches, "ft": UnitLength.feet,
            "foot": UnitLength.feet, "feet": UnitLength.feet, "yd": UnitLength.yards, "mi": UnitLength.miles,
            "g": UnitMass.grams, "kg": UnitMass.kilograms, "lb": UnitMass.pounds, "lbs": UnitMass.pounds, "oz": UnitMass.ounces,
            "c": UnitTemperature.celsius, "f": UnitTemperature.fahrenheit, "k": UnitTemperature.kelvin,
            "celsius": UnitTemperature.celsius, "fahrenheit": UnitTemperature.fahrenheit, "kelvin": UnitTemperature.kelvin,
            "ml": UnitVolume.milliliters, "l": UnitVolume.liters, "gal": UnitVolume.gallons, "cup": UnitVolume.cups,
            "kmh": UnitSpeed.kilometersPerHour, "mph": UnitSpeed.milesPerHour,
            "b": UnitInformationStorage.bytes, "kb": UnitInformationStorage.kilobytes, "mb": UnitInformationStorage.megabytes,
            "gb": UnitInformationStorage.gigabytes, "tb": UnitInformationStorage.terabytes,
            "ms": UnitDuration.milliseconds, "s": UnitDuration.seconds, "min": UnitDuration.minutes, "h": UnitDuration.hours,
        ]
        let named: [String: Dimension] = [
            "millimetre": UnitLength.millimeters, "centimetre": UnitLength.centimeters, "metre": UnitLength.meters,
            "kilometre": UnitLength.kilometers, "yard": UnitLength.yards, "mile": UnitLength.miles,
            "gram": UnitMass.grams, "kilogram": UnitMass.kilograms, "pound": UnitMass.pounds, "ounce": UnitMass.ounces,
            "millilitre": UnitVolume.milliliters, "litre": UnitVolume.liters, "gallon": UnitVolume.gallons,
            "byte": UnitInformationStorage.bytes, "kilobyte": UnitInformationStorage.kilobytes,
            "megabyte": UnitInformationStorage.megabytes, "gigabyte": UnitInformationStorage.gigabytes,
            "terabyte": UnitInformationStorage.terabytes,
            "millisecond": UnitDuration.milliseconds, "second": UnitDuration.seconds, "minute": UnitDuration.minutes,
            "hour": UnitDuration.hours,
            "day": UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400)),
            "week": UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800)),
            "year": UnitDuration(symbol: "yr", converter: UnitConverterLinear(coefficient: 31_536_000)),
        ]
        for (name, unit) in named {
            for spelling in [name, name.replacingOccurrences(of: "tre", with: "ter")] { units[spelling] = unit; units[spelling + "s"] = unit }
        }
        return units
    }()

    private static func unit(_ s: String) -> Dimension? { units[s.replacingOccurrences(of: "°", with: "")] }

    /// Ten significant digits, a point, no grouping; made once, since the menu calls it on every keystroke.
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumSignificantDigits = 10
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Whole numbers as they are; the rest to ten significant digits, no trailing zeros.
    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return formatter.string(from: v as NSNumber) ?? String(v)
    }
}
