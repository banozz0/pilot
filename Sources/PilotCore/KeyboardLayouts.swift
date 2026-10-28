import Foundation

/// One of macOS's input sources as the keyboard layout setting reads it (story 111, card agent-bo-95422793).
public struct InputSource: Equatable, Sendable {
    public let id: String
    public let name: String
    /// A keyboard layout or input method, not a palette or a mode.
    public let isKeyboard: Bool
    public let isEnabled: Bool
    public let isSelectable: Bool
    public let isCurrent: Bool

    public init(id: String, name: String, isKeyboard: Bool, isEnabled: Bool, isSelectable: Bool, isCurrent: Bool) {
        self.id = id; self.name = name; self.isKeyboard = isKeyboard; self.isEnabled = isEnabled
        self.isSelectable = isSelectable; self.isCurrent = isCurrent
    }
}

/// macOS's Text Input Sources for real (the app's TIS reader), a fake in tests. Selecting is the only change it makes:
/// Pilot never enables, disables or adds an input source.
@MainActor public protocol InputSourceSystem {
    func all() -> [InputSource]
    func select(_ id: String) throws
}

/// The keyboard layout setting: the enabled keyboard layouts and input methods macOS can select, by name, the current
/// one marked; a pick selects that one.
@MainActor
public struct KeyboardLayouts {
    let system: any InputSourceSystem

    public init(system: any InputSourceSystem) { self.system = system }

    public var choices: [InputSource] {
        system.all().filter { $0.isKeyboard && $0.isEnabled && $0.isSelectable }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Selects a source of `listed` (the choices on screen) that is not the current one; anything else selects
    /// nothing. Returns whether it selected.
    @discardableResult
    public func pick(_ id: String, from listed: [InputSource]) throws -> Bool {
        guard let source = listed.first(where: { $0.id == id }), !source.isCurrent else { return false }
        try system.select(id)
        return true
    }
}
