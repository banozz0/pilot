// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/focusCache.swift
@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil
/// Pilot (live bug 2026-10-24): macOS's focused window the tiler refused, on no workspace yet (still minimized as it
/// comes back from the Dock), so a later session takes it once it is back on one.
@MainActor private var refusedNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) throws {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        let kept = keptFocus(over: nativeFocused)
        // Pilot (scrolling focus, 2026-10-12): macOS's focus overriding the tiler's is logged, to tell a refused hand-off from one undone
        if let nativeFocused, focus.windowOrNil !== nativeFocused {
            tilerLog.notice("focus from macOS: window \(nativeFocused.windowId, privacy: .public) over the tiler's \(focus.windowOrNil?.windowId ?? 0, privacy: .public)\(kept == nil ? "" : ", kept by its app's rule", privacy: .public)")
        }
        let taken = try (kept ?? nativeFocused)?.focusWindow() == true
        refusedNativeFocusedWindowId = (taken || kept != nil) ? nil : nativeFocused?.windowId
        if let refused = refusedNativeFocusedWindowId {
            tilerLog.notice("focus from macOS: window \(refused, privacy: .public) refused, on no workspace")
        }
        kept?.nativeFocus()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    } else if let nativeFocused, nativeFocused.windowId == refusedNativeFocusedWindowId, try nativeFocused.focusWindow() {
        refusedNativeFocusedWindowId = nil
        tilerLog.notice("focus from macOS: window \(nativeFocused.windowId, privacy: .public) taken, back on a workspace")
    }
    // Pilot: a test's window has no MacApp; every window macOS focuses has one
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId
}

/// Pilot (live bug 2026-10-20): the next session takes macOS's focused window, even the one last known (a refused hand-off).
@MainActor func forgetNativeFocus() { lastKnownNativeFocusedWindowId = nil }

/// Pilot (scrolling layout T11): a window just opened by an app whose new windows keep focus where it was, the window
/// focused then, and when.
@MainActor var keepingFocus: (opened: UInt32, kept: UInt32, at: ContinuousClock.Instant)? = nil

/// The window focus goes back to once macOS focused the one just opened (keepingFocus), within a second of it opening, so a
/// click on it later stays; macOS focusing anything else ends the wait, so it acts on the first focus change and no other.
@MainActor func keptFocus(over nativeFocused: Window?, now: ContinuousClock.Instant = .now) -> Window? {
    guard let keeping = keepingFocus else { return nil }
    keepingFocus = nil
    guard nativeFocused?.windowId == keeping.opened, now - keeping.at < .seconds(1) else { return nil }
    return Window.get(byId: keeping.kept)
}
