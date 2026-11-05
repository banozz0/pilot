import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import IOKit.hid
import PilotCore

/// The macOS grants `pilot permit` reads and asks for (P30): the ones General, Voice and onboarding show an Allow for,
/// beyond Accessibility and Full Disk Access, which only Privacy & Security turns on.
enum Permit: String, CaseIterable, Sendable {
    case microphone, inputMonitoring, automation, screenRecording, calendars, reminders, personalVoice

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .inputMonitoring: "Input Monitoring"
        case .automation: "Automation for System Events"
        case .screenRecording: "Screen Recording"
        case .calendars: "Calendars"
        case .reminders: "Reminders"
        case .personalVoice: "Personal Voice"
        }
    }
}

/// What `pilot permit` reaches: each grant read without a prompt, and each Allow, which asks as its row's does: macOS's
/// prompt when Pilot was never asked, its Privacy & Security pane after. A test hands in its own, so nothing is asked.
@MainActor
final class ControlPermits {
    var gate = AllowPrompt.gate
    var engine: @MainActor () -> Engine? = { Engine.shared }
    /// One grant's state, read without a prompt: granted, denied, notAsked, notGranted, writeOnly, unsupported, unknown,
    /// or notRead.
    var read: @MainActor (Permit) async -> String = { await ControlPermits.state($0) }
    /// Whether Screen Recording's state may be read (ADR 0012): while Show exact menu bar items is on, or while the
    /// Window shelf's pictures are Stills or Live, the features that already read it.
    var mayReadScreen: @MainActor () -> Bool = {
        BarItemsStore.shared.settings.exactMenuItems || ShelfPictures.shared.mode != .off
    }
    /// Its row's Allow.
    var ask: @MainActor (Permit, Engine) async -> Void = { await ControlPermits.allow($0, engine: $1) }

    /// A grant's state as read before any Allow: Screen Recording only while a feature that uses it is on (ADR 0012),
    /// else notRead.
    func shown(_ permit: Permit) async -> String {
        permit == .screenRecording && !mayReadScreen() ? "notRead" : await read(permit)
    }

    /// No prompt in any of these (Screen Recording's read is CGPreflightScreenCaptureAccess, as onboarding's).
    static func state(_ permit: Permit) async -> String {
        switch permit {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return "granted"
            case .notDetermined: return "notAsked"
            default: return "denied"
            }
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return "granted"
            case kIOHIDAccessTypeDenied: return "denied"
            default: return "notAsked"
            }
        case .automation:
            // System Events idle answers -600 whatever the grant (GeneralPage.systemEvents(answer:last:)).
            switch await Task.detached(operation: { ControlStatus.mayControlSystemEvents() }).value {
            case 0: return "granted"
            case -1743: return "denied"
            case -600: return "unknown"
            default: return "notAsked"
            }
        case .screenRecording:
            // A preflight cannot tell a no from never asked.
            return CGPreflightScreenCaptureAccess() ? "granted" : "notGranted"
        case .calendars, .reminders:
            switch EKEventStore.authorizationStatus(for: permit == .calendars ? .event : .reminder) {
            case .fullAccess: return "granted"
            case .notDetermined: return "notAsked"
            case .writeOnly: return "writeOnly"
            default: return "denied"
            }
        case .personalVoice:
            switch ReadAloudSettings.personalNow() {
            case .allowed: return "granted"
            case .denied: return "denied"
            case .notAsked: return "notAsked"
            case .unsupported: return "unsupported"
            }
        }
    }

    /// What each row's Allow does.
    static func allow(_ permit: Permit, engine: Engine) async {
        switch permit {
        case .microphone: await MicrophoneGrant.shared.ask()
        case .inputMonitoring: OnboardingGrants.shared.ask(.inputMonitoring, engine: engine)
        case .screenRecording: OnboardingGrants.shared.ask(.screenRecording, engine: engine)
        case .calendars: OnboardingGrants.shared.ask(.calendars, engine: engine)
        case .reminders: OnboardingGrants.shared.ask(.reminders, engine: engine)
        case .automation:
            if await state(.automation) == "denied" { SystemModule.pane("com.apple.preference.security?Privacy_Automation") }
            else { SystemModule.systemEvents("count processes") }   // macOS asks once, as onboarding's row does
        case .personalVoice: ReadAloudSettings.shared.askPersonal()
        }
    }
}

extension ControlVerbs {
    /// `permit`: bare, every grant's state, read without a prompt; with a grant, its Allow after Pilot's own Allow.
    func registerPermits(_ p: ControlPermits) {
        let names = Permit.allCases.map(\.rawValue)
        register(ControlVerb("permit", help: "Reads each macOS grant Pilot may ask for (no prompt; Screen Recording only while a feature that uses it is on, else notRead); with one named, asks macOS for it after Allow: its prompt the first time, Privacy & Security after.",
                             usage: "pilot permit [\(names.joined(separator: "|"))]",
                             flags: [],
                             schema: { .object(["grants": .array(names.map(JSONValue.string)),
                                                "states": .array(["granted", "denied", "notAsked", "notGranted", "writeOnly", "unsupported", "unknown", "notRead"].map(JSONValue.string))]) },
                             index: { .object(["grants": .array(names.map(JSONValue.string))]) }) { call throws(ControlError) in
            let args = call.arguments()
            guard let word = args.positional.first else {
                var states: [String: JSONValue] = [:]
                for permit in Permit.allCases {
                    states[permit.rawValue] = .string(await p.shown(permit))
                }
                return .object(states)
            }
            guard let permit = Permit(rawValue: word) else { throw ControlError(.badValue, "no grant \(word); they are \(names.joined(separator: ", "))") }
            guard let engine = p.engine() else { throw ControlError(.notReady, "Pilot's key engine is not running") }
            let before = await p.shown(permit)
            if before == "granted" { return .object(["permit": .string(word), "state": .string(before), "note": .string("granted already; nothing asked")]) }
            if permit == .personalVoice, before != "notAsked" {
                throw ControlError(.notReady, before == "unsupported" ? "this Mac has no Personal Voice"
                                   : "macOS asks only once; System Settings › Privacy & Security › Personal Voice changes it")
            }
            let ask = ControlGate.Ask("Ask macOS for \(permit.title)", before == "denied"
                                      ? "opens Privacy & Security, where it was turned off" : "shows macOS's own prompt, or Privacy & Security once it was answered")
            return try await p.gate.allow(ask, peer: call.peer) { () throws(ControlError) in
                await p.ask(permit, engine)
                log.notice("permit: asked for \(word, privacy: .public), from the pilot command")
                return .object(["permit": .string(word), "asked": .bool(true), "state": .string(await p.read(permit)),
                                "note": .string("answer on screen; pilot permit reads it after")])
            }
        })
    }
}
