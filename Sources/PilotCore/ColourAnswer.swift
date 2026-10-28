import Foundation

/// A colour typed at the menu's root answers with itself (Menu Rail and Classic T3; Sven: a typed or copied hex gets a big
/// swatch card): #rgb, #rrggbb, #rrggbbaa (alpha dropped) or rgb(…). A bare `2bc4f0` never answers, since too many words
/// are hex. Return copies the hex in capitals; the five spellings are what the card and Cmd+K list, and the clipboard's
/// preview of a copied colour.
public enum ColourAnswer {
    /// The colour as 0xRRGGBB; nil when the text is not one colour literal. The same grammar as the clipboard's
    /// `ClipboardCapture.colourValue`, which PilotCore cannot import.
    public static func value(_ text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = trimmed.wholeMatch(of: /(?i)#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})/) {
            let digits = String(m.1)
            let six = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : String(digits.prefix(6))
            return UInt32(six, radix: 16)
        }
        guard let m = trimmed.wholeMatch(of: /(?i)rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(,\s*[\d.]+\s*)?\)/),
              let r = UInt32(m.1), let g = UInt32(m.2), let b = UInt32(m.3) else { return nil }
        return min(r, 255) << 16 | min(g, 255) << 8 | min(b, 255)
    }

    /// "#2BC4F0".
    public static func hex(_ colour: UInt32) -> String { "#" + String(format: "%06X", colour & 0xFFFFFF) }

    /// HEX, RGB, HSL, HSB and SwiftUI, in that order: `#2BC4F0` · `rgb(43, 196, 240)` · `hsl(193, 87%, 55%)` ·
    /// `hsb(193, 82%, 94%)` · `Color(red: 0.169, green: 0.769, blue: 0.941)`.
    public static func formats(_ colour: UInt32) -> [String] {
        let c = Contrast.rgb(colour), (h, s, l) = Contrast.hsl(colour)
        let top = c.max()!, bottom = c.min()!
        let pct = { (v: Double) in "\(Int((v * 100).rounded()))%" }, hue = Int(h.rounded()) % 360
        return [hex(colour),
                "rgb(\(c.map { String(Int($0)) }.joined(separator: ", ")))",
                "hsl(\(hue), \(pct(s)), \(pct(l)))",
                "hsb(\(hue), \(pct(top > 0 ? (top - bottom) / top : 0)), \(pct(top / 255)))",
                "Color(red: \(String(format: "%.3f", c[0] / 255)), green: \(String(format: "%.3f", c[1] / 255)), blue: \(String(format: "%.3f", c[2] / 255)))"]
    }

    /// The one answer row: the hex as its title, Return copies it.
    public static func entries(for query: String) -> [MenuEntry] {
        guard let colour = value(query) else { return [] }
        let f = formats(colour)
        return [MenuEntry(title: f[0], target: .copy(f[0]), detail: "\(f[1]) · Return copies", isAnswer: true,
                          icon: .glyph("paintpalette", .accent))]
    }
}
