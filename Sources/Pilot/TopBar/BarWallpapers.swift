import AppKit
import PilotCore
import SwiftUI

/// The wallpaper under each screen's bar (WallpaperStrip.Grid), which a Glass or Clear bar inks and tones itself for
/// (BarTone; Sven, Q254). Read off the main thread from the picture's file, again only when a screen's picture,
/// size or strip changed: on the bars being shown, a screen change, a Space change (each Space can have its own
/// picture) and Pilot's own wallpaper step. macOS posts nothing when System Settings changes the picture, so that one
/// shows at the next of these.
@MainActor @Observable
final class BarWallpapers {
    static let shared = BarWallpapers()

    /// Each screen's strip, by its name; none while its picture cannot be read.
    private(set) var strips: [String: WallpaperStrip.Grid] = [:]
    /// What each screen's strip was read from, so an event that changed nothing reads nothing.
    @ObservationIgnored private var read: [String: Source] = [:]
    @ObservationIgnored private var screens: [TopBarGeometry.Screen] = []
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    struct Source: Equatable, Sendable {
        let url: URL
        let size: CGSize
        let strip: Double
        let placement: WallpaperStrip.Placement
    }

    /// Reads the strips under `screens`' bars and follows them from then on.
    func follow(_ screens: [TopBarGeometry.Screen]) {
        self.screens = screens
        if observers.isEmpty {
            let workspace = NSWorkspace.shared.notificationCenter, app = NotificationCenter.default
            observers = [(workspace, NSWorkspace.activeSpaceDidChangeNotification), (app, NSApplication.didChangeScreenParametersNotification),
                         (app, WallpaperSwitch.changed)].map { center, name in
                (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
        }
        refresh()
    }

    /// Reads each screen whose picture, size or strip changed; forgets screens gone.
    func refresh() {
        let names = Set(screens.map(\.name))
        for gone in read.keys where !names.contains(gone) { read[gone] = nil; strips[gone] = nil }
        for screen in screens {
            guard let ns = NSScreen.screens.first(where: { $0.localizedName == screen.name }),
                  let url = WallpaperSwitch.current(on: ns) else { continue }
            let source = Source(url: url, size: ns.frame.size, strip: screen.strip, placement: Self.placement(ns))
            guard read[screen.name] != source else { continue }
            read[screen.name] = source
            let name = screen.name
            Task {
                let grid = await Task.detached {
                    WallpaperStrip.grid(source.url, screen: source.size, strip: source.strip, placement: source.placement)
                }.value
                // A newer read for this screen wins.
                guard read[name] == source, strips[name] != grid else { return }
                strips[name] = grid
            }
        }
    }

    /// How macOS places the picture on `screen` (Fill Screen when it says nothing).
    static func placement(_ screen: NSScreen) -> WallpaperStrip.Placement {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let fill = (options[.fillColor] as? NSColor).map { Contrast.rgb(Color(nsColor: $0).rgb) } ?? [0, 0, 0]
        return WallpaperStrip.Placement(scaling: (options[.imageScaling] as? NSNumber)?.intValue ?? 3,
                                        clips: (options[.allowClipping] as? NSNumber)?.boolValue ?? true, fill: fill)
    }
}
