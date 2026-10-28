import Carbon
import PilotCore

/// The keyboard Binds draws (card agent-bo-95423003): the board's shape from the keyboard last typed on (ANSI or ISO) and
/// each key's character from the selected keyboard layout (UCKeyTranslate, display action, no modifiers, dead keys
/// typed as themselves). Read only; a layout with no Unicode data (an input method) keeps the US names.
@MainActor
enum KeyboardCaptions {
    /// The Mac's layout now, as the tenkeyless board and the compact one.
    struct Boards {
        let full: BindsKeyboard.Board, compact: BindsKeyboard.Board
        /// The compact board in two halves, for a page too narrow to name every key whole (card agent-bo-95423023).
        let split: BindsKeyboard.Board

        init(full: BindsKeyboard.Board, compact: BindsKeyboard.Board) {
            self.full = full
            self.compact = compact
            split = compact.split()
        }
    }

    /// The boards as last read; `reload()` after the layout changes.
    private(set) static var current = read()

    static func reload() -> Boards {
        current = read()
        return current
    }

    /// Every key either board shape draws, the keys a layout is asked about.
    private static let allCodes = BindsKeyboard.Board(.iso).codes.union(BindsKeyboard.Board(.ansi).codes)

    /// A modifier held while the keys are read: what the layout types with Shift or Option down (Setup's Keyboard layout).
    enum Held: UInt32 {
        case none = 0, shift = 2, option = 8
    }

    /// The layout in use with `held` down, read now (not kept in `current`).
    static func read(_ held: Held = .none) -> Boards {
        let type = UInt32(LMGetKbdType())
        let shape: BindsKeyboard.Shape = KBGetLayoutType(Int16(type)) == kKeyboardISO ? .iso : .ansi
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return Boards(full: .init(shape), compact: .init(shape, compact: true))
        }
        let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
        // Shift's letters are capitals already; Option's keep the case they type.
        let legends = legends(source, keyboardType: type, held: held), pc = pcLayout(id), capitals = held != .option
        return Boards(full: .init(shape, legends: legends, pcSwap: pc, capitals: capitals),
                      compact: .init(shape, legends: legends, pcSwap: pc, compact: true, capitals: capitals))
    }

    /// A PC layout on an ISO board ("com.apple.keylayout.British-PC"): its key left of 1 sends 50, its key by left Shift 10.
    static func pcLayout(_ id: String) -> Bool { id.hasSuffix("-PC") }

    /// The character each key types with `held` down (UCKeyTranslate's modifier byte), by key code.
    private static func legends(_ source: TISInputSource, keyboardType: UInt32, held: Held) -> [Int64: String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> [Int64: String] in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return [:] }
            var legends: [Int64: String] = [:]
            for code in allCodes {
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), held.rawValue, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
                guard status == noErr, length > 0 else { continue }
                let typed = String(utf16CodeUnits: chars, count: length)
                // Only the keys that type a character: Return, Tab, Esc and the F-keys translate to control codes.
                if typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) { legends[code] = typed }
            }
            return legends
        }
    }
}
