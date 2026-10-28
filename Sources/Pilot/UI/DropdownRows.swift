import AppKit
import PilotCore
import SwiftUI

/// What each of the dropdown's rows (Dropdown.Row) says and does, read by all three styles' dropdowns so they draw one
/// list.
extension Engine {
    /// The footer's groups: Check for updates only in a bundle with a feed or a commit to compare (PilotUpdates.canCheck).
    var dropdownFooter: [[Dropdown.Row]] { Dropdown.footer(canUpdate: PilotUpdates.shared.canCheck) }

    /// The row's key: its ⌘ key, or its action's bind as the dropdown signs it; nil when it has neither.
    func dropdownKey(_ row: Dropdown.Row) -> String? {
        if let command = row.command { return "⌘" + String(command).uppercased() }
        return row.actionID.flatMap(keyLabel)
    }

    /// An action's bind as the dropdown signs it ("⇪ T"); nil without one.
    func keyLabel(_ action: String) -> String? { Dropdown.keyLabel(binds.store.trigger(for: action), layerKeys: settings.layerKeys) }

    /// The row's title; Check for updates says what the last count found, as General does, or that Sparkle found one.
    func dropdownTitle(_ row: Dropdown.Row) -> String {
        let updates = PilotUpdates.shared
        return row == .updates && (updates.state != .unknown || updates.updateWaiting) ? updates.label : row.title
    }

    /// Runs the row. A pick closes the dropdown as a menu does, but the checkout's Check for updates, whose answer shows in
    /// its row; Sparkle answers in its own window.
    func runDropdownRow(_ row: Dropdown.Row) {
        if row != .updates || PilotUpdates.shared.route == .sparkle { BarPanel.shared.close() }
        switch row {
        case .openPilot: AppWindowController.shared.open()
        case .menu: PilotMenu.shared.toggle()
        case .clipboard, .aiChat: row.actionID.flatMap { action($0) }?.run()
        case .updates: PilotUpdates.shared.check()
        case .feedback: SendFeedback.choose(layerKeys: settings.layerKeys)
        case .support: NSWorkspace.shared.open(GeneralPage.supportURL)
        case .quit: NSApp.terminate(nil)
        case .printObservers: printObservers()
        case .rescue: rescue.run()
        }
    }
}

extension View {
    /// The row's ⌘ key, live while the dropdown has the keyboard.
    func dropdownCommand(_ row: Dropdown.Row) -> some View {
        keyboardShortcut(row.command.map { KeyboardShortcut(KeyEquivalent($0)) })
    }
}
