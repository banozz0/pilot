import Foundation

// The answer as a person reads it at a terminal: one printer for every verb's JSON, so no verb carries text of its own.
// A pipe, a file and --json keep the JSON, so scripts and the AI helper (Bash without a tty) never see this.

/// Text only for a terminal and only when no --json asked for JSON: the command's own before the verb, or a verb's after
/// it (`pilot actions --json`).
func printsText(terminal: Bool, words: [String]) -> Bool {
    terminal && !words.prefix(while: { $0 != "--" }).contains("--json")
}

/// `result` as short lines: a top-level "line" first, scalars as aligned `key  value`, objects as indented sections,
/// arrays of objects as one row each, most identifying field first.
func readable(_ result: Any) -> String {
    TextAnswer.lines(result, top: true).joined(separator: "\n")
}

enum TextAnswer {
    static let rowCap = 25, inlineCap = 8, numberCap = 12
    static let identifying = ["id", "name", "title", "label", "action", "row"]

    static func lines(_ value: Any, top: Bool = false) -> [String] {
        switch value {
        case let object as [String: Any]: return section(object)
        case let array as [Any] where hasRows(array): return rows(array)
        case let array as [Any] where top: return capped(array.compactMap(scalar), rest: array.count - rowCap)
        default: return scalar(value).map { [$0] } ?? []
        }
    }

    /// An object: its line, then scalars aligned, then each nested object or list under its key.
    static func section(_ object: [String: Any]) -> [String] {
        var out: [String] = []
        if let line = object["line"] as? String, !line.isEmpty { out.append(line) }
        var pairs: [(String, String)] = [], nested: [(String, [String])] = []
        for key in object.keys.sorted() where key != "line" {
            let value = object[key]!
            if value is [String: Any] || (value as? [Any]).map(hasRows) == true {
                let body = lines(value)
                if !body.isEmpty { nested.append((words(key), body)) }
            } else if let text = inline(value) {
                pairs.append((words(key), text))
            }
        }
        let width = pairs.map(\.0.count).max() ?? 0
        for (key, text) in pairs {
            let lead = key.padding(toLength: width + 2, withPad: " ", startingAt: 0)
            // A value of several lines starts under its key's value column.
            out.append(lead + text.replacingOccurrences(of: "\n", with: "\n" + String(repeating: " ", count: width + 2)))
        }
        for (key, body) in nested { out.append(key); out += body.map { "  " + $0 } }
        return out
    }

    /// A list of objects, a row each: the identifying field padded to a column, then the rest as `key value`.
    static func rows(_ array: [Any]) -> [String] {
        let objects = array.compactMap { $0 as? [String: Any] }
        let parts = objects.map { object -> (String, String) in
            let key = identifying.first { object[$0].flatMap(scalar) != nil }
            let rest = object.keys.sorted().filter { $0 != key }.compactMap { field -> String? in
                let value = object[field]!
                if isBool(value) { return (value as! Bool) ? words(field) : nil }
                if let list = value as? [Any], hasRows(list) { return "\(words(field)) \(list.count)" }
                if let nested = value as? [String: Any] {
                    let inner = nested.keys.sorted().compactMap { k in nested[k].flatMap(inline).map { "\(words(k)) \($0)" } }
                    return inner.isEmpty ? nil : "\(words(field)) (\(inner.joined(separator: ", ")))"
                }
                return inline(value).map { "\(words(field)) \($0)" }
            }
            return (key.flatMap { object[$0].flatMap(scalar) } ?? "", rest.joined(separator: ", "))
        }
        let width = parts.map(\.0.count).max() ?? 0
        let shown = parts.map { lead, rest in
            rest.isEmpty ? lead : lead.isEmpty ? rest : lead.padding(toLength: width + 2, withPad: " ", startingAt: 0) + rest
        }
        return capped(shown, rest: objects.count - rowCap)
    }

    static func hasRows(_ list: [Any]) -> Bool { list.contains { $0 is [String: Any] } }

    static func capped(_ lines: [String], rest: Int) -> [String] {
        rest > 0 ? Array(lines.prefix(rowCap)) + ["… \(rest) more (--json for all)"] : lines
    }

    /// A value on one line: a scalar, or a list of scalars comma-joined; a long list of numbers as its count, total and
    /// peak; nil for what reads as nothing (null, empty).
    static func inline(_ value: Any) -> String? {
        guard let list = value as? [Any] else { return scalar(value) }
        let numbers = list.compactMap { isBool($0) ? nil : ($0 as? NSNumber)?.doubleValue }
        if numbers.count == list.count, list.count > numberCap {
            return "\(list.count) values, total \(number(numbers.reduce(0, +))), max \(number(numbers.max() ?? 0))"
        }
        let items = list.compactMap(scalar)
        guard !items.isEmpty else { return nil }
        let more = items.count - inlineCap
        return items.prefix(inlineCap).joined(separator: ", ") + (more > 0 ? ", … \(more) more" : "")
    }

    static func scalar(_ value: Any) -> String? {
        switch value {
        case _ where isBool(value): (value as! Bool) ? "yes" : "no"
        case let n as NSNumber: number(n.doubleValue)
        case let s as String: s.isEmpty ? nil : s
        default: nil
        }
    }

    static func isBool(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func number(_ x: Double) -> String {
        x.rounded() == x && abs(x) < 1e15 ? String(Int64(x)) : String(x)
    }

    /// camelCase as words: "loginItem" → "login item"; "macOS" stays whole.
    static func words(_ key: String) -> String {
        guard key != "macOS" else { return key }
        var out = "", previous: Character?
        for c in key {
            if c.isUppercase, let p = previous, p.isLowercase || p.isNumber { out.append(" ") }
            out += c.lowercased()
            previous = c
        }
        return out
    }
}
