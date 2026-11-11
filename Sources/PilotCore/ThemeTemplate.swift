import Foundation

/// Palette substitution only: never paths, programs, expressions or shell evaluation.
public enum ThemeTemplate {
    public static func render(_ template: String, palette: [String: String]) throws -> String {
        guard !template.utf8.contains(0) else { throw ThemeFailure("template contains NUL") }
        var remaining = template[...], result = ""
        while let start = remaining.range(of: "{{") {
            let literal = remaining[..<start.lowerBound]
            guard !literal.contains("}}"), let end = remaining[start.upperBound...].range(of: "}}") else { throw ThemeFailure("broken palette placeholder") }
            let role = String(remaining[start.upperBound..<end.lowerBound])
            guard !role.isEmpty, let value = palette[role],
                  value.count == 7, value.first == "#", value.dropFirst().allSatisfy(\.isHexDigit) else { throw ThemeFailure("unknown or invalid palette placeholder: \(role)") }
            result += literal + value
            remaining = remaining[end.upperBound...]
        }
        guard !remaining.contains("}}") else { throw ThemeFailure("broken palette placeholder") }
        return result + remaining
    }
}
