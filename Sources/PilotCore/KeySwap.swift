import Foundation

/// A key Binds › Swap keys offers (Q406): Caps Lock, each side of Control, Option and Command, Escape, Tab, Return,
/// Delete and the F keys. F18 is not offered: Caps Lock becomes it while it is a layer key. Fn is left out: its usage
/// is Apple's vendor page, unverified against hidutil.
public enum SwapKey: String, CaseIterable, Codable, Identifiable, Sendable {
    case capsLock, leftControl, rightControl, leftOption, rightOption, leftCommand, rightCommand
    case escape, tab, returnKey = "return", delete
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f19, f20

    public var id: String { rawValue }

    /// The layer key this is, for the seven that can be one.
    public var layerKey: LayerKey? { LayerKey(rawValue: rawValue) }

    /// F1 to F20's number.
    private var fNumber: Int? { rawValue.hasPrefix("f") ? Int(rawValue.dropFirst()) : nil }

    public var label: String {
        if let key = layerKey { return key.label }
        if let n = fNumber { return "F\(n)" }
        switch self {
        case .escape: return "Escape"
        case .tab: return "Tab"
        case .returnKey: return "Return"
        default: return "Delete"
        }
    }

    /// The key's HID usage (page 7), as UserKeyMapping names it.
    public var hidUsage: Int {
        if let key = layerKey { return key.hidUsage }
        if let n = fNumber { return 0x7_0000_0000 + (n <= 12 ? 0x3A + n - 1 : 0x68 + n - 13) }
        switch self {
        case .escape: return 0x7_0000_0029
        case .tab: return 0x7_0000_002B
        case .returnKey: return 0x7_0000_0028
        default: return 0x7_0000_002A
        }
    }
}

/// Two keys swapped at the HID level while Pilot runs (Q406): each types the other, two UserKeyMapping entries.
public struct KeySwap: Hashable, Sendable {
    public var a: SwapKey
    public var b: SwapKey
    public init(_ a: SwapKey, _ b: SwapKey) { self.a = a; self.b = b }

    /// The stored word, "capsLock:leftControl".
    public var word: String { "\(a.rawValue):\(b.rawValue)" }

    public init?(word: String) {
        let parts = word.split(separator: ":").map(String.init)
        guard parts.count == 2, let a = SwapKey(rawValue: parts[0]), let b = SwapKey(rawValue: parts[1]), a != b else { return nil }
        self.init(a, b)
    }

    /// The stored words as swaps: unknown ones dropped.
    public static func parse(_ words: [String]) -> [KeySwap] { words.compactMap(KeySwap.init(word:)) }

    /// A typed "first:second", or bad-value.
    public static func parsed(_ word: String) throws(ControlError) -> KeySwap {
        guard let swap = KeySwap(word: word) else { throw ControlError(.badValue, "\(word) is not two different keys as first:second") }
        return swap
    }

    /// `swap` joining `swaps`, or bad-value saying why not (refusal).
    public static func adding(_ swap: KeySwap, to swaps: [KeySwap], layerKeys: [LayerKey], foreign: [KeyMappingEntry]) throws(ControlError) -> [KeySwap] {
        if let refusal = swap.refusal(joining: swaps, layerKeys: layerKeys, foreign: foreign) { throw ControlError(.badValue, refusal) }
        return swaps + [swap]
    }

    /// Whether `other` names the same two keys, in either order.
    public func matches(_ other: KeySwap) -> Bool { Set(keys) == Set(other.keys) }

    public var label: String { "\(a.label) ↔ \(b.label)" }
    public var keys: [SwapKey] { [a, b] }

    public var entries: [KeyMappingEntry] {
        [KeyMappingEntry(src: a.hidUsage, dst: b.hidUsage), KeyMappingEntry(src: b.hidUsage, dst: a.hidUsage)]
    }

    /// Q407: a swap on a Hyper key waits until another key is Hyper. Nil when it holds none.
    public func hyperProblem(_ layerKeys: [LayerKey]) -> String? {
        guard let key = keys.compactMap(\.layerKey).first(where: layerKeys.contains) else { return nil }
        return "\(key.label) is \(layerKeys.count == 1 ? "your" : "a") Hyper key. Pick another Hyper key on the Pilot page first."
    }

    /// Why the swap does not apply now, nil when it does: a Hyper key in it, or a key another tool's mapping remaps,
    /// which Pilot never fights.
    public func problem(layerKeys: [LayerKey], foreign: [KeyMappingEntry]) -> String? {
        if let hyper = hyperProblem(layerKeys) { return hyper }
        guard let key = keys.first(where: { k in foreign.contains { $0.src == k.hidUsage } }) else { return nil }
        return "Another tool remaps \(key.label) (a key mapping Pilot did not write). Remove it to swap the key here."
    }

    /// Why `self` cannot join `swaps`, nil when it can: each key is in one swap at most.
    public func refusal(joining swaps: [KeySwap], layerKeys: [LayerKey], foreign: [KeyMappingEntry]) -> String? {
        if a == b { return "Pick two different keys." }
        if let key = keys.first(where: { k in swaps.contains { $0.keys.contains(k) } }) { return "\(key.label) is already swapped." }
        return problem(layerKeys: layerKeys, foreign: foreign)
    }
}

extension KeyMappingEntry {
    /// Every entry Pilot writes (Q406): Caps Lock to F18 while it is a layer key no other tool remaps, and both entries of
    /// each swap that applies now.
    public static func pilotSet(layerKeys: [LayerKey], swaps: [KeySwap], foreign: [KeyMappingEntry]) -> [KeyMappingEntry] {
        let capsLock = layerKeys.contains(.capsLock) && !RemapConflict.isForeign(.capsLock, in: foreign, own: [])
        return (capsLock ? [.pilotCapsLockToF18] : [])
            + swaps.filter { $0.problem(layerKeys: layerKeys, foreign: foreign) == nil }.flatMap(\.entries)
    }

    /// Every entry Pilot wrote or may have: what it last wrote, Caps Lock to F18 and the stored swaps', so a killed
    /// Pilot's leftovers are its own too.
    public static func pilotOwned(written: [KeyMappingEntry], swaps: [KeySwap]) -> Set<KeyMappingEntry> {
        Set(written + [.pilotCapsLockToF18] + swaps.flatMap(\.entries))
    }

    /// The one mapping set to write: `current` less every entry of Pilot's (`own`: what it wrote or may have), then
    /// `next`. Entries Pilot did not write stay; removing one of Pilot's never drops another.
    public static func merged(_ current: [KeyMappingEntry], own: Set<KeyMappingEntry>, next: [KeyMappingEntry]) -> [KeyMappingEntry] {
        current.filter { !own.contains($0) && !next.contains($0) } + next
    }
}
