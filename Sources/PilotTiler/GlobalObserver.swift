// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/GlobalObserver.swift
import AppKit
import os

enum GlobalObserver {
    private static func onNotif(_ notification: Notification) {
        // Third line of defence against lock screen window. See: closedWindowsCache
        // Second and third lines of defence are technically needed only to avoid potential flickering
        if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let notifName = notification.name.rawValue
        Task.startUnstructured { @MainActor in
            if !isTilerEnabled { return }
            if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName), optimisticallyPreLayoutWorkspaces: true)
            } else {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName))
            }
        }
    }

    private static func onHideApp(_ notification: Notification) {
        let notifName = notification.name.rawValue
        Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.globalObserver(notifName), token) {
                if config.automaticallyUnhideMacosHiddenApps {
                    if let w = prevFocus?.windowOrNil,
                       try w.macAppUnsafe.nsApp.isHidden,
                       // "Hide others" (cmd-alt-h) -> don't force focus
                       // "Hide app" (cmd-h) -> force focus
                       MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1
                    {
                        // Force focus
                        _ = try w.focusWindow()
                        w.nativeFocus()
                    }
                    for app in MacApp.allAppsMap.values {
                        app.nsApp.unhide()
                    }
                }
            }
        }
    }

    @MainActor
    static func initObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main, using: onHideApp)
        nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: onNotif)

        // Pilot: AeroSpace's NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp), through a session tap (below)
        installLeftMouseUpTap { _ in
            // todo reduce number of refreshSession in the callback
            //  resetManipulatedWithMouseIfPossible might call its own refreshSession
            //  The end of the callback calls refreshSession
            Task.startUnstructured { @MainActor in
                // Pilot: AeroSpace's `token` renamed `allowed` here, as the commit guard reads that line as a credential
                guard let allowed = RunSessionGuard.isServerEnabled else { return }
                try await resetManipulatedWithMouseIfPossible()
                // Pilot: a held gap ends here too, should its handle miss the release (card agent-bo-95423035)
                if gapDrag != nil { return TilerGaps.release() }
                // Pilot: a dragged tiled window lands where it was released (dropWithMouse.swift); one Esc cancelled, nowhere
                if draggedWindowId != nil || cancelledDragWindowId != nil { return try await endMouseDrag(at: mouseLocation, allowed) }
                let mouseLocation = mouseLocation
                // Pilot: a Dock click on an app Show desktop holds brings its windows back (ShownDesktop.swift)
                if shownDesktop != nil { await endShownDesktopOnDockClick(at: mouseLocation) }
                let clickedMonitor = mouseLocation.monitorApproximation
                switch true {
                    // Detect clicks on desktop of different monitors
                    case clickedMonitor.visibleRect.contains(mouseLocation) && clickedMonitor.activeWorkspace != focus.workspace:
                        _ = try await runLightSession(.globalObserverLeftMouseUp, allowed) {
                            clickedMonitor.activeWorkspace.focusWorkspace()
                        }
                    // Detect close button clicks for unfocused windows. Yes, kAXUIElementDestroyedNotification is that unreliable
                    //  And trigger new window detection that could be delayed due to mouseDown event
                    default:
                        scheduleCancellableCompleteRefreshSession(.globalObserverLeftMouseUp)
                }
            }
        }
    }

    /// Pilot: a listen-only session tap, not AeroSpace's NSEvent global monitor, which never sees an event sent to its own
    /// app (Apple: "dispatched to applications other than the one in which it is installed"). In-process, the release of a
    /// drag of Pilot's own window never arrived: the drag stuck, layout skipped that window, and the next drag of any
    /// other window refreshed on every move, snapping it back to its tile (live bugs, card agent-bo-95422999).
    @MainActor private static var leftMouseUpTap: CFMachPort?
    @MainActor private static var onLeftMouseUp: (NSEvent?) -> Void = { _ in }

    @MainActor
    private static func installLeftMouseUpTap(_ handler: @escaping (NSEvent?) -> Void) {
        onLeftMouseUp = handler
        guard let tap = unsafe CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                                 eventsOfInterest: CGEventMask(1) << CGEventType.leftMouseUp.rawValue,
                                                 callback: leftMouseUpCallback, userInfo: nil) else {
            // AeroSpace's monitor still ends every other app's drag
            Logger(subsystem: "dev.banozz.pilot", category: "tiler").error("mouse-up tap not created: Pilot's own windows' drags never end")
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { handler($0) }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        leftMouseUpTap = tap
    }

    private static let leftMouseUpCallback: CGEventTapCallBack = { _, type, event, _ in
        // The tap's run loop source lives on the main run loop, so this runs on the main thread.
        MainActor.assumeIsolated {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let leftMouseUpTap { CGEvent.tapEnable(tap: leftMouseUpTap, enable: true) }
            } else {
                onLeftMouseUp(nil)
            }
        }
        return unsafe Unmanaged.passUnretained(event)
    }
}
