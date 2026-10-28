import Foundation
import PilotCore

/// macOS's screen zoom, Accessibility › Zoom (Sven, Q435). No API a signed app may call turns it on or steps it:
/// universalaccessd refuses other callers. So Pilot posts macOS's own Zoom shortcuts, symbolic hotkeys 15, 17 and 19, on
/// the keys the user's table holds (ADR 0001: posted keys only into macOS's own shortcuts). They answer only while
/// "Use keyboard shortcuts to zoom" is on; while it is off a tip says so, its button opening that pane. Pilot never
/// turns it on.
@MainActor
enum ScreenZoom {
    enum Step: Int { case toggle = 15, zoomIn = 17, zoomOut = 19 }

    /// macOS's own keys for each, Option+Command+8, = and −, for a row the table holds without keys.
    static let defaults: [Step: Key] = [.toggle: Key("8", [.alt, .cmd], hyper: false), .zoomIn: Key("=", [.alt, .cmd], hyper: false),
                                        .zoomOut: Key("-", [.alt, .cmd], hyper: false)]

    /// After the tap callback returns: the preference reads are calls to cfprefsd.
    static func press(_ step: Step) {
        Task { @MainActor in
            let row = SymbolicHotKeys.hotKeys(in: ShortcutConflicts.Domain.live.read()).first { $0.id == step.rawValue }
            // No row: Zoom's own switch says whether its shortcuts are on.
            let on = row?.enabled ?? (CFPreferencesCopyAppValue("closeViewHotkeysEnabled" as CFString, "com.apple.universalaccess" as CFString) as? Bool == true)
            guard on, let key = row?.key ?? defaults[step] else {
                slog.notice("screen zoom \(step.rawValue): Zoom's keyboard shortcuts are off")
                return HUD.tip("Screen zoom needs Accessibility › Zoom › Use keyboard shortcuts to zoom on.", seconds: 6,
                               action: HUD.TipAction(title: "Open Settings") { SystemModule.pane("com.apple.Accessibility-Settings.extension?Zoom") })
            }
            Post.key(key.keyCode, key.modifiers)
            slog.notice("screen zoom \(step.rawValue): posted \(key.label, privacy: .public)")
        }
    }
}
