import AppKit
import PilotCore

/// The pill's Controls readings (spec desktop-controls T7), once the tall Pilot menu's optional blocks (gone 2026-11-20,
/// the menu fixed to the simple one): sound and brightness, read only while the view shows, and a row of the Extensions
/// view opening its page.
@MainActor
enum DropdownBlocks {
    /// Holds the sound reader and reads brightness once, until the calling task is cancelled (the view closes).
    static func holdControls(readings: BarReadings) async {
        var held: Set<BarKind> = []
        readings.hold([.volume], replacing: &held)
        defer { readings.hold([], replacing: &held) }
        await ScreenBrightness.read()
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }

    static func sound(_ readings: BarReadings) -> DropdownPanelValues.Sound? {
        let output = readings.sound.side(.output)
        guard let volume = output.volume?.value else { return nil }
        return .init(device: output.devices.first { $0.id == output.current }?.name ?? "Output", level: Double(volume), muted: output.muted ?? false)
    }

    /// The focused screen and its display id, whose brightness the view shows and sets.
    static var focused: (screen: NSScreen, id: UInt32)? {
        guard let screen = Screens.focusedScreen ?? NSScreen.main, let id = WallpaperScreen.number(screen) else { return nil }
        return (screen, id)
    }

    /// `screen`'s brightness, nil while it has no control or is not read yet; the view reads the focused screen once.
    static func display(_ screen: (screen: NSScreen, id: UInt32)) -> DropdownPanelValues.Display? {
        ScreenBrightness.engine.screens[screen.id]?.level.map { .init(name: screen.screen.localizedName, level: $0) }
    }

    /// A row of the Extensions view: the extension's page in Pilot's window (Q76), or its place on Extensions when it
    /// has no page.
    static func openPage(_ ids: [String], at i: Int, bar: ExtensionBar = .shared) {
        let items = bar.items(ids)
        guard items.indices.contains(i) else { return }
        BarPanel.shared.close()
        if items[i].hasPage { AppWindowController.shared.openExtensionPage(items[i].id) }
        else { AppWindowController.shared.open(AppPlace(.extensions), extension: items[i].id) }
    }

    /// The Sound slider's press. (Brightness is set on the screen the view reads, in PillDrop.)
    static func setSound(_ level: Double, readings: BarReadings) { readings.sound.setVolume(Float(level), .output) }
}
