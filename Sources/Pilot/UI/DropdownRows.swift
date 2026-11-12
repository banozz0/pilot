import AppKit
import PilotCore
import SwiftUI

/// What each of the dropdown's rows (Dropdown.Row) says and does, read by both styles' dropdowns so they draw one list.
extension Engine {
    /// The footer's line: Check for updates only in a bundle with a feed or a commit to compare (PilotUpdates.canCheck).
    var dropdownFooter: [Dropdown.Row] { Dropdown.footer(canUpdate: PilotUpdates.shared.canCheck) }

    /// The row's key: its ⌘ key, or its action's bind as the dropdown signs it; Dictate the dictation key while one is
    /// picked ("right ⌃", Voice › Dictation key); nil when it has none.
    func dropdownKey(_ row: Dropdown.Row) -> String? {
        if let command = row.command { return "⌘" + String(command).uppercased() }
        if row == .dictate, let sign = settings.dictationKey.sign { return sign }
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
        case .settings: AppWindowController.shared.open()
        case .menu: PilotMenu.shared.toggle()
        case .clipboard, .aiChat, .quickNotes, .dictate, .captureArea, .screenRecording: row.actionID.flatMap { action($0) }?.run()
        // The keys map is Binds' keyboard; its A4 picture is Save map there.
        case .keysMap: AppWindowController.shared.open(AppPlace(.binds))
        case .extensions: AppWindowController.shared.open(AppPlace(.extensions))
        case .updates: PilotUpdates.shared.check()
        case .quit: NSApp.terminate(nil)
        case .printObservers: printObservers()
        case .rescue: rescue.run()
        }
    }
}

/// What runs now, the dropdown's Now block (spec pilot-1-1 T29): a recording, the focus timer, Extras downloading. Read
/// in the block itself, so its clock, countdown and share redraw only it.
@MainActor
enum DropdownNow {
    enum Item { case recording, timer(String), download(title: String, share: Double) }

    static var items: [Item] {
        var items: [Item] = []
        if Recorder.shared.isActive { items.append(.recording) }
        if let line = NowTimer.line(ExtensionTimer.shared) { items.append(.timer(line)) }
        if let share = ExtrasDownloads.shared.share {
            // The download running, by its name; "Downloading extras" when more than one does.
            let running = ExtrasDownloads.shared.downloads.filter(\.isRunning)
            items.append(.download(title: running.count == 1 ? running[0].title : "Downloading extras", share: share))
        }
        return items
    }

    /// The first recording or running timer, as its row: what takes the pill-first bar's compact face over (Q164).
    /// Downloads never do.
    static var live: DropdownPanelValues.Running? {
        zip(items, rows).first { item, _ in if case .download = item { false } else { true } }?.1
    }

    /// The running rows as the Pilot menu's Now block and the pill's Activity view draw them.
    static var rows: [DropdownPanelValues.Running] {
        items.map { item in
            switch item {
            case .recording: .init(symbol: "video", title: "Screen recording", detail: "Recording", reading: Recorder.shared.reading?.words)
            case .timer(let line):
                .init(symbol: "timer", title: ExtensionTimer.shared.title ?? "Timer", detail: line, reading: ExtensionTimer.shared.countdown,
                      canPause: !ExtensionTimer.shared.buttons.isEmpty)
            case .download(let title, let share):
                // Only the terminal pack's download can be cancelled.
                .init(symbol: "arrow.down.to.line", title: title, detail: "Downloading", reading: "\(Int(share * 100)) %", share: share,
                      canStop: title == OnboardingExtras.terminalTitle)
            }
        }
    }

    /// Pause (`pause` true) or Stop on row `i`.
    static func press(_ i: Int, pause: Bool) {
        let items = items
        guard items.indices.contains(i) else { return }
        switch items[i] {
        case .recording: Recorder.shared.stop()
        case .timer: pause ? ExtensionTimer.shared.press(0) : ExtensionTimer.shared.stop()
        case .download:
            // Only the terminal pack's download draws Stop; another that slips in says why.
            let running = ExtrasDownloads.shared.downloads.filter(\.isRunning)
            if running.count == 1, running[0].title == OnboardingExtras.terminalTitle { ExtrasDownloads.shared.cancelTerminal() }
            else { HUD.tip("This download can't be stopped; it finishes on its own") }
        }
    }
}

extension View {
    /// The row's ⌘ key, live while the dropdown has the keyboard.
    func dropdownCommand(_ row: Dropdown.Row) -> some View {
        keyboardShortcut(row.command.map { KeyboardShortcut(KeyEquivalent($0)) })
    }
}
