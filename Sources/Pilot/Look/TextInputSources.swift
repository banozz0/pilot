import Carbon
import PilotCore

/// macOS's Text Input Sources (Carbon's TIS calls) as the keyboard layout setting reads them (story 111, card
/// agent-bo-95422793): the enabled sources, and TISSelectInputSource for a pick. Never TISEnableInputSource,
/// TISDisableInputSource or TISRegisterInputSource: Pilot only switches between what macOS already has enabled.
@MainActor
struct TextInputSources: InputSourceSystem {
    struct NotSelected: Error, CustomStringConvertible {
        let id: String, status: OSStatus
        var description: String { "macOS did not switch to \(id) (status \(status))" }
    }

    func all() -> [InputSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let currentID = current.flatMap { Self.string($0, kTISPropertyInputSourceID) }
        return list.compactMap { source in
            guard let id = Self.string(source, kTISPropertyInputSourceID) else { return nil }
            return InputSource(id: id, name: Self.string(source, kTISPropertyLocalizedName) ?? id,
                               isKeyboard: Self.string(source, kTISPropertyInputSourceCategory) == kTISCategoryKeyboardInputSource as String,
                               isEnabled: Self.bool(source, kTISPropertyInputSourceIsEnabled),
                               isSelectable: Self.bool(source, kTISPropertyInputSourceIsSelectCapable), isCurrent: id == currentID)
        }
    }

    func select(_ id: String) throws {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let source = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first else { return }
        let status = TISSelectInputSource(source)
        guard status == noErr else { throw NotSelected(id: id, status: status) }
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        TISGetInputSourceProperty(source, key).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }

    private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        TISGetInputSourceProperty(source, key).map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? false
    }
}
