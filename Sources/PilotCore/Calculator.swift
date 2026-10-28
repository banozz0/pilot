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

    // MARK: conversions: "<number> <unit> in|to <unit>".

    private static func convert(_ text: String) -> String? {
        let parts = text.lowercased().split(separator: " ").map(String.init)
        guard let sep = parts.lastIndex(where: { $0 == "in" || $0 == "to" }), sep >= 1, sep == parts.count - 2,
              let target = parts.last else { return nil }
        let left = parts[..<sep].joined()
        let numberEnd = left.firstIndex { !($0.isNumber || $0 == "." || $0 == "," || $0 == "-") } ?? left.endIndex
        guard let value = evaluate(String(left[..<numberEnd])), let from = unit(String(left[numberEnd...])),
              let to = unit(target), type(of: from) == type(of: to) else { return nil }
        return "\(format(Measurement(value: value, unit: from).converted(to: to).value)) \(target)"
    }

    private static let units: [String: Dimension] = [
        "mm": UnitLength.millimeters, "cm": UnitLength.centimeters, "m": UnitLength.meters, "km": UnitLength.kilometers,
        "in": UnitLength.inches, "inch": UnitLength.inches, "ft": UnitLength.feet, "yd": UnitLength.yards, "mi": UnitLength.miles,
        "g": UnitMass.grams, "kg": UnitMass.kilograms, "lb": UnitMass.pounds, "lbs": UnitMass.pounds, "oz": UnitMass.ounces,
        "c": UnitTemperature.celsius, "f": UnitTemperature.fahrenheit, "k": UnitTemperature.kelvin,
        "ml": UnitVolume.milliliters, "l": UnitVolume.liters, "gal": UnitVolume.gallons, "cup": UnitVolume.cups,
        "kmh": UnitSpeed.kilometersPerHour, "mph": UnitSpeed.milesPerHour,
        "b": UnitInformationStorage.bytes, "kb": UnitInformationStorage.kilobytes, "mb": UnitInformationStorage.megabytes,
        "gb": UnitInformationStorage.gigabytes, "tb": UnitInformationStorage.terabytes,
        "s": UnitDuration.seconds, "min": UnitDuration.minutes, "h": UnitDuration.hours,
    ]

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
