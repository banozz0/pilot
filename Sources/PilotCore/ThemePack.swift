import Foundation
import CryptoKit

/// Portable data only. Destination authority belongs to local bindings, never to a pack.
public struct ThemePack: Codable, Equatable, Sendable {
    public var schema: Int
    public var id, title: String
    public var dark: Bool
    public var palette: [String: String]
    public var variants: [String: [String: String]]? = nil
    public var styles: [String]
    public var wallpapers: [String]
    public var adapters: [String: JSONValue]
    public var material: ThemeMaterial? = nil
    public var barPreset: BarPreset? = nil
    public var customMappings: [ThemeMapping]? = nil
    /// The pack's own picture, a path inside its folder (spec desktop-controls T14, Sven's Q26): Themes mode shows it in
    /// place of the desktop Pilot draws. Read with the same in-folder checks as the wallpapers.
    public var preview: String? = nil

    public init(schema: Int = 1, id: String, title: String, dark: Bool, palette: [String: String],
                variants: [String: [String: String]]? = nil, styles: [String] = [], wallpapers: [String] = [], adapters: [String: JSONValue] = [:]) {
        self.schema = schema; self.id = id; self.title = title; self.dark = dark; self.palette = palette
        self.variants = variants; self.styles = styles; self.wallpapers = wallpapers; self.adapters = adapters
    }
    public func compatible(with style: String) -> Bool {
        (styles.isEmpty || styles.contains(style)) && (!["toybox", "toybox-night"].contains(id) || style == "toybox")
    }

    public static func decode(_ bytes: Data) throws -> Self {
        let allowed: Set<String> = ["schema", "id", "title", "dark", "palette", "styles", "wallpapers", "adapters", "variants", "material", "barPreset", "customMappings", "preview"]
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys).isSubset(of: allowed) else { throw ThemeFailure("invalid manifest fields; packs cannot grant authority") }
        let pack = try JSONDecoder().decode(Self.self, from: bytes)
        guard pack.schema == 1, validID(pack.id), !pack.title.isEmpty,
              pack.title.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              Set(pack.styles).isSubset(of: ["instrument", "toybox"]),
              Set(OmarchyTheme.roles).isSubset(of: Set(pack.palette.keys)),
              pack.palette.values.allSatisfy({ colorValue($0) != nil }),
              pack.wallpapers.allSatisfy(ThemeFiles.relative), pack.preview.map(ThemeFiles.relative) ?? true else { throw ThemeFailure("invalid schema, identity, compatibility, roles or assets") }
        for (mode, palette) in pack.variants ?? [:] {
            guard ["dark", "light"].contains(mode), Set(OmarchyTheme.roles).isSubset(of: Set(palette.keys)),
                  palette.values.allSatisfy({ colorValue($0) != nil }),
                  mode != (pack.dark ? "dark" : "light") || palette == pack.palette else { throw ThemeFailure("invalid or conflicting supplied palette variant") }
        }
        try ThemeLedger.validateFields(bytes, field: "barPreset", encoded: pack.barPreset.map { try ThemeDigest.encoded($0) })
        try ThemeLedger.validateFields(bytes, field: "customMappings", encoded: pack.customMappings.map { try ThemeDigest.encoded($0) })
        guard Set((pack.customMappings ?? []).map(\.id)).count == (pack.customMappings ?? []).count else { throw ThemeFailure("duplicate custom mapping identity") }
        for mapping in pack.customMappings ?? [] { try mapping.validate(palette: pack.palette) }
        try pack.material?.validate()
        if pack.material != nil {
            guard let fields = object["material"] as? [String: Any], Set(fields.keys) == ["glass", "transparency", "blur"] else { throw ThemeFailure("unsupported material fields") }
        }
        return pack
    }

    public static func validID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }
        return (1...80).contains(bytes.count) && bytes.first.map(alphanumeric) == true && bytes.allSatisfy { alphanumeric($0) || $0 == 45 }
    }

    private static func colorValue(_ text: String) -> UInt32? {
        let bytes = Array(text.utf8)
        guard bytes.count == 7, bytes[0] == 35,
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return UInt32(text.dropFirst(), radix: 16)
    }
    public func adapter(_ name: String) -> ThemePack {
        ThemePack(schema: schema, id: id, title: title, dark: dark, palette: palette, variants: variants, styles: styles, wallpapers: wallpapers,
                  adapters: [name: adapters[name] ?? .object([:])])
    }
    public var ghostty: OmarchyTheme { OmarchyTheme(id: id, name: title, dark: dark, colors: palette) }

    /// Resolve colours without changing the style's geometry or typography.
    public func appearance(keeping base: PilotTheme) -> PilotTheme {
        // Decoded packs are validated; direct Codable construction must never trap either. A `native_` role overrides the
        // terminal slot where a source's ANSI colours do not carry that meaning (Matte Black's yellow slot is a red).
        func c(_ role: String, _ native: String? = nil) -> UInt32 { (native.flatMap { palette["native_" + $0] } ?? palette[role]).flatMap(Self.colorValue) ?? 0 }
        return PilotTheme(id: id, name: title, tagline: "Theme pack", source: id, dark: dark,
                          ground: c("background"), sidebar: c("dark_background"), surface: c("darker_background"),
                          raised: c("lighter_background"), line: c("muted", "line"), line2: c("dark_foreground", "line2"),
                          text: c("foreground"), text2: c("light_foreground"), text3: c("muted", "text3"), accent: c("accent"),
                          second: c("cyan", "second"), third: c("magenta", "third"), good: c("green", "good"), amber: c("yellow", "amber"), problem: c("red", "problem"),
                          graphs: [c("cyan", "graph1"), c("magenta", "graph2"), c("yellow", "graph3")], selection: id == base.id ? base.selection : Paint(c("selection", "selection"), palette["native_selection"] == nil ? 1 : (dark ? 0.16 : 0.14)),
                          onAccent: id == base.id ? base.onAccent : nil, focus: base.focus, radius: base.radius, face: base.face, wallpaper: base.wallpaper)
    }
}

public struct ThemeFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

public enum ThemeDigest {
    public static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
