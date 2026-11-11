import Foundation
import IOKit.hid
import PilotCore
import Testing
@testable import Pilot

/// General's top (Sven 2026-10-10): Support's page and the update state a personal build reads from its own checkout.
@MainActor
@Suite("General page")
struct GeneralPageTests {
    @Test("Support opens Pilot's GitHub Sponsors page")
    func support() {
        #expect(GeneralPage.supportURL.absoluteString == "https://github.com/sponsors/banozz0")
    }

    @Test("git's count reads as current, behind or failed")
    func count() {
        #expect(PilotUpdates.state(count: "0\n") == .current)
        #expect(PilotUpdates.state(count: "12\n") == .behind(12))
        #expect(PilotUpdates.state(count: "fatal: bad revision") == .failed)
        #expect(PilotUpdates.state(count: nil) == .failed)
    }

    @Test("A bundle names its commit; a bare binary is a development build and never checks")
    func bundle() {
        let built = PilotUpdates(info: ["PilotCommit": "d09b380d5f1e2a3b", "PilotSource": "/tmp/pilot"])
        #expect(built.shortCommit == "d09b380")
        #expect(built.label == "Not checked yet")
        let bare = PilotUpdates(info: nil)
        bare.check()
        #expect(bare.state == .unknown)
        #expect(bare.label == "Development build")
        #expect(bare.shortCommit == nil)
    }

    @Test("Screen Recording is never read while Show exact menu bar items is off (ADR 0012); on, granted or its pane")
    func screenRecording() {
        #expect(MorePermissionRows.screenRecording(exactItems: false, lacks: true) == .notChecked)
        #expect(MorePermissionRows.screenRecording(exactItems: true, lacks: true) == .openSettings)
        #expect(MorePermissionRows.screenRecording(exactItems: true, lacks: false) == .granted)
    }

    @Test("Input Monitoring: granted, Allow before macOS asked, Privacy & Security once refused")
    func inputMonitoring() {
        #expect(MorePermissionRows.inputMonitoring(kIOHIDAccessTypeGranted) == .granted)
        #expect(MorePermissionRows.inputMonitoring(kIOHIDAccessTypeUnknown) == .ask)
        #expect(MorePermissionRows.inputMonitoring(kIOHIDAccessTypeDenied) == .openSettings)
    }

    @Test("System Events: allowed, refused, not asked, and an idle System Events keeping the last answer")
    func systemEvents() {
        #expect(MorePermissionRows.systemEvents(answer: 0, last: nil) == .granted)
        #expect(MorePermissionRows.systemEvents(answer: -1743, last: .granted) == .openSettings)
        #expect(MorePermissionRows.systemEvents(answer: -1744, last: nil) == .ask)
        #expect(MorePermissionRows.systemEvents(answer: -600, last: .granted) == .granted)
        #expect(MorePermissionRows.systemEvents(answer: -600, last: nil) == .ask)
    }

    @Test("The self-updating casks switch is Install's, in the same words on the page and in the pilot command")
    func selfUpdatingCasks() throws {
        let rig = SettingsSchemaPart2Tests.Rig()
        let get = try #require(rig.verbs.verbs["get"]?.detail)
        #expect(try get("update.selfUpdatingCasks")?.contains("\n\(InstallListsBlock.selfUpdatingTitle), on the install page.\n") == true)
    }
}
