import Foundation

/// One UserKeyMapping entry: HID usage in, HID usage out.
public struct KeyMappingEntry: Hashable, Sendable {
    public var src: Int
    public var dst: Int
    public init(src: Int, dst: Int) { self.src = src; self.dst = dst }

    /// The one entry Pilot writes: Caps Lock to F18.
    public static let pilotCapsLockToF18 = KeyMappingEntry(src: LayerKey.capsLock.hidUsage, dst: LayerKey.f18Usage)
    private static let separators = CharacterSet(charactersIn: " ;")

    /// The distinct entries in `hidutil property --get UserKeyMapping`, which prints one block per HID service with
    /// each entry's Dst line before its Src line.
    public static func parse(hidutil output: String) -> [KeyMappingEntry] {
        var entries: [KeyMappingEntry] = []
        var dst: Int?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=").map { $0.trimmingCharacters(in: separators) }
            guard parts.count == 2, let value = Int(parts[1]) else { continue }
            if parts[0] == "HIDKeyboardModifierMappingDst" { dst = value }
            if parts[0] == "HIDKeyboardModifierMappingSrc", let d = dst {
                let entry = KeyMappingEntry(src: value, dst: d)
                if !entries.contains(entry) { entries.append(entry) }
                dst = nil
            }
        }
        return entries
    }
}

/// Another tool remapping the layer key (story 37): a UserKeyMapping entry on it that Pilot did not write. Pilot names
/// it and never fights it.
public enum RemapConflict {
    /// Whether a mapping Pilot did not write remaps any of `layerKeys`; `own` is every entry Pilot wrote or may have
    /// (KeyMappingEntry.pilotOwned).
    public static func exists(layerKeys: [LayerKey], userKeyMapping: [KeyMappingEntry], own: Set<KeyMappingEntry>) -> Bool {
        layerKeys.contains { isForeign($0, in: userKeyMapping, own: own) }
    }

    /// Whether a mapping Pilot did not write remaps `key`: then Pilot never remaps it itself.
    public static func isForeign(_ key: LayerKey, in userKeyMapping: [KeyMappingEntry], own: Set<KeyMappingEntry>) -> Bool {
        userKeyMapping.contains { $0.src == key.hidUsage && !own.contains($0) }
    }

    /// The HUD tip.
    public static func tip(for layerKeys: [LayerKey]) -> String {
        "Another tool remaps \(layerKeys.label) (a key mapping Pilot did not write). Remove it so Pilot owns the key."
    }
}
