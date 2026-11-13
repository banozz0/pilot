import Foundation
import PilotCore

extension ControlVerbs {
    /// `nudges`: smart nudges' state, and one check of all three now or at a given time (spec smart-nudges), so each is
    /// proved without waiting for a meeting, a limit or the night. A check can pause what plays, so it asks Allow first.
    func registerSmartNudges(_ nudges: @escaping @MainActor () -> SmartNudgeCenter = { .shared }, gate: ControlGate = AllowPrompt.gate) {
        register(ControlVerb("nudges", help: "Smart nudges: what each is set to and holds, or one check of them now or at a time.",
                             usage: "pilot nudges [check [--at <ISO 8601 time>]]",
                             flags: [.init("at", help: "check as if it were this time, 2030-01-07T09:58:00Z: the meeting due then, quiet hours then")]) { call throws(ControlError) in
            let args = call.arguments()
            let center = nudges()
            switch args.positional.first {
            case nil: return Self.nudgeState(center, at: Date())
            case "check":
                var at = Date()
                if let text = args.value("at") {
                    guard let date = try? Date(text, strategy: .iso8601) else { throw ControlError(.badValue, "--at takes an ISO 8601 time, not \(text)") }
                    at = date
                }
                let ask = ControlGate.Ask("Check smart nudges", "Pauses what plays if a meeting is due, and posts any AI limit warning or quiet hours summary")
                return try await gate.allow(ask, peer: call.peer) { () throws(ControlError) in
                    await Self.nudgeCheck(center, at: at)
                }
            case let word?: throw ControlError(.badRequest, "no nudges \(word); try pilot nudges or pilot nudges check")
            }
        })
    }

    /// Each nudge's switch and figure, and what it holds: the meeting ahead, the AI windows read and warned, the held ones.
    static func nudgeState(_ center: SmartNudgeCenter, at date: Date) -> JSONValue {
        let access: String = switch center.calendarAccess {
        case nil: "not read"
        case .undetermined?: "not asked"
        case .granted?: "given"
        case .denied?: "refused"
        }
        return .object([
            "pauseMusic": .object(["on": .bool(center.pauseMusic), "minutes": .number(Double(center.minutes)),
                                   "anyEvent": .bool(center.anyEvent), "calendar": .string(access)]),
            "aiLimit": .object(["on": .bool(center.aiLimit), "threshold": .number(Double(center.threshold)),
                                "windows": .array(center.aiWindows.map { .string("\($0.key) \(Int($0.used.rounded()))% used") }),
                                "warned": .array(center.warned.map(JSONValue.string))]),
            "quietHours": .object(["on": .bool(center.quietHours), "from": .string(center.quietFrom), "to": .string(center.quietTo),
                                   "quietNow": .bool(center.isQuiet(at: date)), "held": .number(Double(center.held.count))]),
        ])
    }

    /// One check at `date`: the meeting due then, AI usage's last answer read again, and anything held released once
    /// quiet hours are over; says what each did.
    static func nudgeCheck(_ center: SmartNudgeCenter, at date: Date) async -> JSONValue {
        let meeting = await center.checkMeetings(at: date).said
        let warned = center.lastAIAnswer().map { center.barAnswered(AILimit.extensionID, $0, at: date) } ?? []
        let released = center.releaseIfDue(at: date)
        return .object([
            "at": .string(date.formatted(.iso8601)),
            "pauseMusic": meeting.map(JSONValue.string) ?? .string(center.pauseMusic ? "no meeting due" : "off"),
            "aiLimit": .array(warned.map(JSONValue.string)),
            "quietHours": .object(["quietNow": .bool(center.isQuiet(at: date)), "held": .number(Double(center.held.count)),
                                   "released": .bool(released)]),
        ])
    }
}
