import AppKit
import CoreBluetooth
import CoreGraphics
import EventKit
import IOKit.hid
import PilotCore
import UserNotifications

/// The grants Permissions shows beyond Accessibility, Full Disk Access and System Events (Sven, 2026-10-28, Q4: "make sure
/// that we have all permissions shown in the onboarding"): each read without a prompt, and each row's Allow, which asks
/// as the feature's own first use does: macOS's prompt when Pilot was never asked, its Privacy & Security pane after.
@MainActor
final class OnboardingGrants {
    static let shared = OnboardingGrants()

    /// Made at the first ask and held: CoreBluetooth and EventKit answer only while their object lives.
    private lazy var bluetooth = IOBluetoothSystem()
    private lazy var calendar = EventKitCalendar()

    /// The rows read here, each without a prompt.
    struct Reading {
        var screenRecording = false, inputMonitoring = false, notifications = false, bluetooth = false, location = false, calendars = false

        func apply(to s: inout Onboarding.Status) {
            s.screenRecording = screenRecording; s.inputMonitoring = inputMonitoring; s.notifications = notifications
            s.bluetooth = bluetooth; s.location = location; s.calendars = calendars
        }
    }

    /// Nil in a test run: it has no bundle to answer for, and UNUserNotificationCenter throws without one.
    func read() async -> Reading? {
        guard !isTestRun else { return nil }
        let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return Reading(screenRecording: CGPreflightScreenCaptureAccess(),   // a read, no prompt (ADR 0012, amended 2026-10-28)
                       inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
                       notifications: [.authorized, .provisional].contains(notifications),
                       bluetooth: CBManager.authorization == .allowedAlways,
                       location: BarReadings.coreWLAN.locationAccess() == .allowed,
                       calendars: EKEventStore.authorizationStatus(for: .event) == .fullAccess)
    }

    func ask(_ row: Onboarding.Row, engine: Engine) {
        switch row {
        case .screenRecording: PilotCapture.shared.askScreenRecording()
        case .inputMonitoring: engine.mouseButtons.requestAccess()
        case .notifications:
            Task {
                let center = UNUserNotificationCenter.current()
                if await center.notificationSettings().authorizationStatus == .denied {
                    SystemModule.pane("com.apple.Notifications-Settings.extension?id=dev.banozz.pilot")
                } else {
                    _ = try? await center.requestAuthorization(options: [.alert])
                }
            }
        case .bluetooth:
            if bluetooth.authorization() == .denied { NSWorkspace.shared.open(SetupBluetooth.settingsPane); return }
            Task { _ = await bluetooth.requestAccess() }
        case .location:
            let wifi = BarReadings.coreWLAN
            if wifi.locationAccess() == .denied { return SystemModule.pane("com.apple.preference.security?Privacy_LocationServices") }
            Task { _ = await wifi.requestLocation() }
        case .calendars:
            if calendar.access == .denied { NSWorkspace.shared.open(ClockCalendar.privacy); return }
            Task { _ = await calendar.requestAccess() }
        case .accessibility, .systemEvents, .fullDiskAccess, .conflicts, .microphone: break
        }
    }
}
