import AppKit
import Foundation
import Observation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Status lights item's sources (Q194-Q196, Q201, Q202), on fakes: no test reads the microphone, the cameras,
/// Ghostex or the Downloads folder.
@MainActor
@Suite("Status lights")
struct StatusLightsTests {
    @Observable @MainActor
    final class Flag {
        var on = false
    }

    /// Every source a fake the test flips; a watch's callback kept so the test fires it as macOS (or Ghostex) would.
    @MainActor
    final class Fakes {
        var mic = MicState()
        var camera = false
        let recording = Flag()
        var ghostex: Data?
        var agentReads = 0
        var micChanged: (@MainActor () -> Void)?
        var cameraChanged: (@MainActor () -> Void)?
        var agentsChanged: (@MainActor () -> Void)?
        var folderChanged: (@MainActor () -> Void)?
        var cancelled = 0
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let folder: URL?

        init(folder: URL? = nil) { self.folder = folder }

        func lights(pilotListening: @escaping @MainActor () -> Bool = { false }) -> StatusLights {
            let read = Reader(self)
            return StatusLights(readAgents: { await read.data() },
                                watchAgents: { self.agentsChanged = $0; return Watch { self.cancelled += 1 } },
                                micInUse: { self.mic }, watchMic: { self.micChanged = $0; return Watch { self.cancelled += 1 } },
                                cameraInUse: { self.camera }, watchCamera: { self.cameraChanged = $0; return Watch { self.cancelled += 1 } },
                                pilotListening: pilotListening, pilotRecording: { self.recording.on }, downloadsFolder: { self.folder },
                                watchFolder: { _, changed in self.folderChanged = changed; return Watch { self.cancelled += 1 } },
                                clock: { self.now }, agentGap: .milliseconds(1))
        }
    }

    /// Hands the fakes' Ghostex answer to the off-main read.
    final class Reader: @unchecked Sendable {
        let fakes: Fakes
        init(_ fakes: Fakes) { self.fakes = fakes }
        func data() async -> Data? { await MainActor.run { fakes.agentReads += 1; return fakes.ghostex } }
    }

    /// Told synchronously, as the change is made.
    final class Told: @unchecked Sendable {
        var yes = false
    }

    /// Whether reading `lights` is told of the next change, with no timer: the change itself pushes.
    static func pushes(_ lights: StatusLights, _ change: () -> Void) -> Bool {
        let told = Told()
        withObservationTracking { _ = lights.lights } onChange: { told.yes = true }
        change()
        return told.yes
    }

    /// A Ghostex session as `ghostex sessions --json --full` lists it.
    static func session(_ ref: String, _ title: String, activity: String, said: String? = nil, at: Double = 1_800_000_000_000,
                        thread: Bool = false, questions: Int = 0, message: String? = nil, status: String = "running") -> [String: Any] {
        var s: [String: Any] = ["globalRef": ref, "displayTitle": title, "status": status, "agentName": "claude", "activity": activity,
                                "projectName": "pilot", "pendingQuestionCount": questions]
        if thread { s["coordinatorRole"] = "thread" }
        if let said { s["programStatus"] = ["state": said, "message": message ?? "", "records": [["updatedAtMs": at]]] }
        return s
    }

    static func json(_ sessions: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: ["sessions": sessions]) }

    /// Waits for the agents' read to land, the main actor left free for it.
    static func settle(_ lights: StatusLights, until: @MainActor () -> Bool) async {
        for _ in 0..<200 where !until() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("Ghostex's list: working, waiting on the user, a thread's done, a status done for ten minutes; plain terminals and old ends stay quiet")
    func agents() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = Self.json([
            Self.session("A", "Status lights", activity: "working", said: "working", message: "Writing the orbit"),
            Self.session("B", "Pilot coordinator", activity: "attention", said: "working"),
            Self.session("C", "Capture bar item", activity: "attention", said: "done", thread: true),
            Self.session("D", "API providers", activity: "idle", said: "done", at: 1_800_000_000_000 - 120_000, thread: true),
            Self.session("E", "Old thread", activity: "idle", said: "done", at: 1_800_000_000_000 - 900_000, thread: true),
            Self.session("F", "Asks", activity: "idle", questions: 1),
            Self.session("G", "Blocked", activity: "idle", said: "blocked"),
            Self.session("H", "Asleep", activity: "working", status: "sleep"),
            ["globalRef": "I", "status": "running", "activity": "working", "title": "zsh"],
        ])
        let lit = GhostexAgents.lights(data, now: now)
        #expect(lit.map(\.title) == ["Status lights", "Pilot coordinator", "Capture bar item", "API providers", "Asks", "Blocked"])
        #expect(lit.map(\.state) == [.working, .waiting, .done, .done, .waiting, .error])
        #expect(lit[0].detail == "Writing the orbit" && lit[0].source == "Ghostex · pilot" && lit[0].jump == .ghostex("A") && lit[0].go == "Open chat")
        #expect(lit[1].detail == nil)
        #expect(GhostexAgents.lights(Data("not json".utf8)).isEmpty)
    }

    @Test("The dots: agents, privacy, jobs, each family's most urgent first, extra lights fold; the popover groups by family")
    func dots() {
        func light(_ id: String, _ family: StatusLight.Family, _ state: StatusLight.State) -> StatusLight {
            StatusLight(id: id, family: family, state: state, title: id, source: "test")
        }
        let lights = [light("a1", .agent, .working), light("a2", .agent, .done), light("a3", .agent, .waiting), light("a4", .agent, .working),
                      light("m", .privacy, .watching), light("j1", .job, .working), light("j2", .job, .error), light("j3", .job, .working)]
        #expect(StatusDots.shown(lights).map(\.id) == ["a3", "a1", "a4", "m", "j2", "j1"])
        #expect(StatusDots.shown([]).isEmpty)
        #expect(StatusDots.groups(lights).map(\.family) == [.agent, .privacy, .job])
        #expect(StatusDots.groups(lights)[0].lights.map(\.id) == ["a3", "a1", "a4", "a2"])
        #expect(StatusDots.summary([]) == "Status lights: nothing lit")
        #expect(StatusDots.summary(lights) == "1 waiting on you, 1 failed, 1 in use, 4 working, 1 done")
    }

    @Test("Privacy: each app recording, Pilot's dictation, the camera and Pilot's recording; a muting alone lights nothing")
    func privacy() {
        let fakes = Fakes(), listening = Flag()
        let lights = fakes.lights(pilotListening: { listening.on })
        lights.start()
        defer { lights.stop() }
        #expect(lights.lights.isEmpty)
        fakes.mic = MicState(apps: [], muted: true)
        fakes.micChanged?()
        #expect(lights.lights.isEmpty)
        fakes.mic = MicState(apps: ["Zoom"], muted: true)
        fakes.micChanged?()
        #expect(lights.lights.map(\.title) == ["Zoom"] && lights.lights[0].detail == "The input is muted" && lights.lights[0].jump == .app("Zoom"))
        listening.on = true
        #expect(lights.lights.map(\.title) == ["Zoom", "Pilot dictation"])
        fakes.camera = true
        fakes.cameraChanged?()
        fakes.recording.on = true
        #expect(lights.lights.map(\.id) == ["mic.Zoom", "mic.pilot", "camera", "recording"])
        #expect(lights.lights.allSatisfy { $0.family == .privacy && $0.state == .watching })
        #expect(lights.lights[2].jump == .settings(StatusLights.cameraPane))
    }

    @Test("A change pushes without a timer, and the watches run only while the item is held")
    func pushes() {
        let fakes = Fakes(), lights = fakes.lights()
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), readBattery: { nil }, readWiFi: { nil },
                                   watchStats: { _ in Task {} }, statusLights: lights)
        #expect(!lights.isWatching && fakes.micChanged == nil)
        readings.hold(.modes)
        #expect(lights.isWatching && readings.liveTimers == 0)
        #expect(Self.pushes(lights) { fakes.mic.apps = ["Zoom"]; fakes.micChanged?() })
        #expect(Self.pushes(lights) { fakes.camera = true; fakes.cameraChanged?() })
        #expect(Self.pushes(lights) { fakes.recording.on = true })
        #expect(Self.pushes(lights) { lights.push(id: "build", state: .working, title: "swift build", family: .job, detail: nil, session: nil) })
        // A callback with nothing changed redraws nothing.
        #expect(!Self.pushes(lights) { fakes.micChanged?() })

        readings.release(.modes)
        // Mic, camera and Ghostex; no Downloads watch without the folder.
        #expect(!lights.isWatching && fakes.cancelled == 3 && readings.liveTimers == 0)
        readings.hold(.modes)
        readings.pause()
        #expect(!lights.isWatching)
        fakes.mic.apps = []
        readings.resume()
        #expect(lights.isWatching && !lights.lights.contains { $0.id == "mic.Zoom" })
        readings.release(.modes)
    }

    @Test("Ghostex is read on start and on its writes, a burst costing one more read, never on a clock")
    func agentReads() async {
        let fakes = Fakes()
        fakes.ghostex = Self.json([Self.session("A", "Status lights", activity: "working")])
        let lights = fakes.lights()
        lights.start()
        defer { lights.stop() }
        await Self.settle(lights) { lights.lights.count == 1 }
        #expect(lights.lights.map(\.state) == [.working] && fakes.agentReads == 1)
        fakes.ghostex = Self.json([Self.session("A", "Status lights", activity: "attention")])
        for _ in 0..<5 { fakes.agentsChanged?() }
        await Self.settle(lights) { lights.lights.first?.state == .waiting }
        #expect(lights.lights.map(\.state) == [.waiting])
        try? await Task.sleep(for: .milliseconds(30))
        #expect(fakes.agentReads == 2)
        // Nothing written, nothing read.
        try? await Task.sleep(for: .milliseconds(30))
        #expect(fakes.agentReads == 2)
    }

    @Test("Opening the popover lets the done and failed lights go from the dots and keeps them there until it closes")
    func seen() {
        let fakes = Fakes(), lights = fakes.lights()
        lights.push(id: "build", state: .done, title: "swift build", family: .job, detail: "exit 0", session: nil)
        lights.push(id: "test", state: .error, title: "swift test", family: .job, detail: "exit 1", session: "S1:P:G")
        lights.push(id: "dl", state: .working, title: "Xcode.xip", family: .job, detail: nil, session: nil)
        #expect(lights.lights.count == 3 && lights.all().first { $0.title == "swift test" }?.jump == .ghostex("S1:P:G"))
        let kept = lights.opened()
        #expect(lights.lights.map(\.title) == ["Xcode.xip"] && lights.all(keeping: kept).count == 3)
        #expect(lights.all().map(\.title) == ["Xcode.xip"])
        // A new ending lights again; a clear puts a light out.
        lights.push(id: "build", state: .done, title: "swift build", family: .job, detail: nil, session: nil)
        #expect(lights.lights.count == 2)
        lights.push(id: "build", state: nil, title: "build", family: .job, detail: nil, session: nil)
        lights.push(id: "dl", state: nil, title: "dl", family: .job, detail: nil, session: nil)
        #expect(lights.all().isEmpty)
    }

    @Test("A done job goes out after ten minutes, read on the next change; a failed one stays until seen")
    func doneFades() {
        let fakes = Fakes(), lights = fakes.lights()
        lights.push(id: "build", state: .done, title: "swift build", family: .job, detail: nil, session: nil)
        lights.push(id: "test", state: .error, title: "swift test", family: .job, detail: nil, session: nil)
        fakes.now += 601
        lights.push(id: "other", state: .working, title: "make", family: .job, detail: nil, session: nil)
        #expect(lights.lights.map(\.title) == ["make", "swift test"])
    }

    @Test("Downloads: a partial file is working, its own file once done; a cancelled one goes quiet")
    func downloads() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "status-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fakes = Fakes(folder: folder), lights = fakes.lights()
        lights.start()
        defer { lights.stop() }
        let partial = folder.appending(path: "Xcode.xip.download"), gone = folder.appending(path: "big.zip.crdownload")
        try Data().write(to: partial)
        try Data().write(to: gone)
        fakes.folderChanged?()
        #expect(lights.lights.map(\.title) == ["Xcode.xip", "big.zip"] && lights.lights.allSatisfy { $0.state == .working })
        #expect(lights.lights.map(\.source) == ["Safari", "Chrome"] && lights.lights[0].jump == .file(partial))
        try FileManager.default.moveItem(at: partial, to: folder.appending(path: "Xcode.xip"))
        try FileManager.default.removeItem(at: gone)
        fakes.folderChanged?()
        #expect(lights.lights.map(\.title) == ["Xcode.xip"] && lights.lights[0].state == .done && lights.lights[0].go == "Show in Finder")
        #expect(Downloads.final("notes.txt") == nil && Downloads.final("a.tar.gz.part") == "a.tar.gz")
    }

    @Test("pilot light pushes a job, refuses a state it lacks, and clears")
    func verb() async {
        let lights = Fakes().lights()
        let verbs = ControlVerbs()
        verbs.registerLight { lights }
        func ask(_ args: String...) async -> ControlAnswer { await verbs.answer(ControlRequest(id: .number(1), verb: "light", args: args), peer: nil) }
        let answer = await ask("build", "working", "--title", "swift build", "--session", "S1:P:G")
        #expect(answer.result == .object(["id": .string("build"), "state": .string("working")]))
        #expect(lights.lights.map(\.title) == ["swift build"] && lights.lights.first?.family == .job && lights.lights.first?.jump == .ghostex("S1:P:G"))
        #expect(await ask("build", "sleeping").error?.code == .badValue)
        #expect(await ask("build", "clear").ok)
        #expect(lights.all().isEmpty)
    }

    @Test("The top bar draws nothing while no light is lit and one dot per lit light; the Menu bar page's strip keeps unlit dots")
    func hidesWhenQuiet() throws {
        let lights = Fakes().lights()
        let sources = MenuBarStatusItemsTests.sources(StripStyleTests.sampler(), statusLights: lights)
        let slot = BarSlot.item(BarSettings.defaults.entry(.modes))
        // In the top bar, or in the Menu bar page's top strip (in the top bar's own strip too); laid out offscreen.
        func width(preview: Bool) -> CGFloat {
            NSHostingView(rootView: TopBarSlotView(slot: slot, screen: "", sources: sources, store: BarItemsStore.shared)
                .environment(\.inTopBar, true).environment(\.barPreview, preview).pilotTheme()).fittingSize.width
        }
        func near(_ a: CGFloat, _ b: Double) -> Bool { abs(a - b) < 0.5 }
        #expect(width(preview: false) == 0)
        let unlit = width(preview: true)
        #expect(unlit >= Double(StatusDots.quiet) * StatusDots.box)
        lights.push(id: "build", state: .working, title: "swift build", family: .job, detail: nil, session: nil)
        let one = width(preview: false)
        #expect(one >= StatusDots.box)
        lights.push(id: "test", state: .error, title: "swift test", family: .job, detail: nil, session: nil)
        lights.push(id: "ask", state: .waiting, title: "Coordinator", family: .agent, detail: nil, session: nil)
        #expect(near(width(preview: false) - one, 2 * StatusDots.box))
        #expect(near(width(preview: true), width(preview: false)))
    }
}
