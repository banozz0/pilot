import AppKit
import OSLog
import PilotCore
import PilotTiler

/// Hyper + right-click on the empty desktop (Q743; a file, a folder or a widget keeps its own menu): a native menu at the
/// pointer, each item what the rest of Pilot runs. Change wallpaper… opens the Carousel's Wallpapers mode on that screen
/// (spec desktop-controls T8): the current theme's wallpapers, or its cycling folders; Look's Browse as gallery keeps
/// the gallery (P90). Wallpaper settings… opens Look › Wallpaper on the clicked screen's row, or its
/// workspace's while each workspace has its own (Q333); Add widget puts a widget from the Widgets page where the
/// press was; New note is the notes panel's; Show desktop is the bind's, Restore windows while it holds them out; Look
/// switches the style and the theme as the Look page does; and Desktop icons hides Finder's icons or shows them again
/// (Q745), checked while they show. Nothing is kept once the menu closes.
@MainActor
enum DesktopMenu {
    /// The menu at `point` (a CGEvent's location, top left), after the tap's callback returned.
    static func open(at point: CGPoint) {
        let i = Screens.frames.firstIndex { $0.contains(point) }
        let screen = i.map { NSScreen.screens[$0] }
        desktopLog.notice("desktop menu: on \(screen?.localizedName ?? "no screen", privacy: .public)")
        BarMenu.pop(rows(at: point, on: screen, frame: i.map { Screens.frames[$0] }), at: NSPoint(x: point.x, y: Screens.primaryHeight - point.y))
    }

    private static func rows(at point: CGPoint, on screen: NSScreen?, frame: CGRect?) -> [BarMenu.Row] {
        let look = Look.shared, widgets = WidgetsPageModel.shared, display = screen?.displayUUID
        // Put with its top left at the press, as fractions of the screen's frame (Widget.Placement's x and y).
        let x = frame.map { Double((point.x - $0.minX) / $0.width) }, y = frame.map { Double((point.y - $0.minY) / $0.height) }
        let addable = (ReadyWidgets.all + widgets.store.installed().widgets).map { widget in
            BarMenu.Row.pick("\(widget.icon)  \(widget.title)") {
                widgets.add(widget, screen: display, x: x, y: y)
                if let note = widgets.note { HUD.tip(note) }
            }
        }
        let styles = PilotStyle.allCases.map { style in BarMenu.Row.pick(style.title, checked: look.style == style) { look.style = style } }
        let themes = PilotTheme.designed.map { theme in
            BarMenu.Row.pick(theme.name, checked: look.themeID == theme.id) {
                look.pick(theme.id)
                // What the Look page shows under its cards: Ghostty did not take the theme.
                if let error = look.lastError { HUD.tip(error) }
            }
        }
        let focus = WallpaperBlock.Focus(display: display, workspace: display.flatMap(WallpaperSettings.shared.shownWorkspace))
        return [
            .pick("Change wallpaper…") { WallpaperCarouselPanel.shared.open(on: screen) },
            .pick("Wallpaper settings…") { AppWindowController.shared.openWallpaper(focus) },
            .submenu("Add widget", addable),
            .pick("New note") { NotesPanel.shared.showNew() },
            .separator,
            .pick(showDesktopWorkspace() == nil ? label(showDesktop) : "Restore windows") { run(showDesktop) },
            .separator,
            .submenu("Look", [.header("Style")] + styles + [.header("Theme")] + themes),
            .pick("Desktop icons", checked: FinderDesktopIcons.shown) { run(desktopIcons) },
        ]
    }

    private static let showDesktop = "windows.showDesktop", desktopIcons = "system.desktopIcons"

    private static func label(_ id: String) -> String { Engine.shared?.action(id)?.label ?? id }

    private static func run(_ id: String) {
        desktopLog.notice("desktop menu: \(id, privacy: .public)")
        Engine.shared?.action(id)?.run()
    }
}

private let desktopLog = Logger(subsystem: "dev.banozz.pilot", category: "desktop")
