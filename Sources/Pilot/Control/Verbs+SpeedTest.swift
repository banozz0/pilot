import Foundation
import PilotCore

extension ControlVerbs {
    /// `speedtest`: the key's speed test (macOS's networkQuality, about 20 s), waited on to its line; a run the key started
    /// is joined, never doubled.
    func registerSpeedTest(_ jobs: ControlJobs) {
        register(ControlVerb("speedtest", help: "Tests internet speed as its key does (about 20 s) and answers download, upload and responsiveness.",
                             flags: []) { _ throws(ControlError) in
            let line = await (try jobs.speedTest()).value
            return .object(["result": .string(line), "measured": .bool(line != SpeedTest.failed)])
        })
    }
}
