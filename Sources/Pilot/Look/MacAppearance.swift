import Foundation
import PilotCore

/// macOS's Light or Dark mode for a theme (Sven Q43): read from the global AppleInterfaceStyle preference, set through
/// System Events' appearance preferences in a child osascript, never NSAppleScript on the main thread (it stalls the tap).
enum MacAppearance {
    static func isDark() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String == "Dark"
    }

    /// System Settings › Appearance › Auto: macOS picks Light or Dark by the time of day.
    static func isAuto() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return CFPreferencesCopyAppValue("AppleInterfaceStyleSwitchesAutomatically" as CFString, kCFPreferencesAnyApplication) as? Bool == true
    }

    static func script(dark: Bool) -> String { "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)" }

    /// Apply, Restore and recovery: the switch in a child osascript awaited off the main thread, so the Hyper tap never
    /// waits on it, then until macOS reads it back that way. A switch macOS never shows is a failure, not a quiet pass.
    static func switchTo(dark: Bool) async throws {
        do { _ = try await ChildProcess.run("/usr/bin/osascript", ["-e", script(dark: dark)], timeout: .seconds(5)) }
        catch let failure as ChildProcess.Failure { throw ThemeFailure("macOS didn't switch to \(dark ? "Dark" : "Light") mode: \(failure)") }
        for _ in 0..<40 { if isDark() == dark { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw ThemeFailure("macOS still shows \(dark ? "Light" : "Dark") mode 2 s after the switch to \(dark ? "Dark" : "Light")")
    }
}
