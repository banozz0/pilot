import AppKit
import CoreAudio
import CoreMediaIO
import Observation
import PilotCore

/// What the Status lights item shows (Sven, 2026-10-16, Q194-Q196, Q201, Q202): the lit sources among the agents, privacy
/// and jobs. Every source pushes, nothing here polls, and nothing runs while the item is off every shown bar
/// (BarReadings holds it):
/// - agents: Ghostex's session list, read again only when Ghostex writes its state, at most every few seconds;
/// - privacy: CoreAudio's per-process input (the apps recording), CoreMediaIO's cameras running, Pilot's own dictation
///   and screen recording, all listeners or observed;
/// - jobs: one FSEvents stream on ~/Downloads (only with Full Disk Access, so no folder prompt), and `pilot light`
///   pushes from a shell hook (builds).
/// Injected, so tests run over fakes and never touch the microphone, the cameras, Ghostex or the Downloads folder.
@Observable @MainActor
final class StatusLights {
    /// Starts watching and calls back on each change, on the main actor; nil when there is nothing to watch.
    typealias Watching = @MainActor (@escaping @MainActor () -> Void) -> Watch?

    static let shared = StatusLights()

    /// Ghostex's running agents, as last read.
    private(set) var agents: [StatusLight] = []
    /// The apps recording from the microphone and whether the input is muted (Sven, 2026-10-16: the light means "an app
    /// is recording you", never a headset that is only playing).
    private(set) var micState = MicState()
    private(set) var cameraOn = false
    /// The downloads in flight and those finished since the popover last showed them.
    private(set) var downloads: [StatusLight] = []
    /// What `pilot light` pushed: builds and long jobs, by their light's id.
    private(set) var pushed: [String: StatusLight] = [:]
    /// Done and failed lights the popover has shown: the dots drop them, the popover keeps those it opened with.
    private(set) var seen: Set<String> = []
    @ObservationIgnored private let readAgents: @Sendable () async -> Data?
    @ObservationIgnored private let watchAgents: Watching
    @ObservationIgnored private let micInUse: @MainActor () -> MicState
    @ObservationIgnored private let watchMic: Watching
    @ObservationIgnored private let cameraInUse: @MainActor () -> Bool
    @ObservationIgnored private let watchCamera: Watching
    /// Pilot's own dictation and screen recording: observed, so their lights follow them with nothing armed.
    @ObservationIgnored private let pilotListening: @MainActor () -> Bool
    @ObservationIgnored private let pilotRecording: @MainActor () -> Bool
    /// ~/Downloads when Pilot may read it, asked on each start so a later grant counts.
    @ObservationIgnored private let downloadsFolder: @MainActor () -> URL?
    @ObservationIgnored private var downloadsAt: URL?
    @ObservationIgnored private let watchFolder: @MainActor (URL, @escaping @MainActor () -> Void) -> Watch?
    @ObservationIgnored private let clock: () -> Date
    /// The least time between two reads of Ghostex's list, however often it writes.
    @ObservationIgnored private let agentGap: Duration
    @ObservationIgnored private var watches: [Watch]?
    @ObservationIgnored private var agentRead: Task<Void, Never>?
    @ObservationIgnored private var agentAgain = false
    /// When each finished download or pushed job ended: done lights go out after StatusLight.doneFor.
    @ObservationIgnored private var ended: [String: Date] = [:]

    init(readAgents: @escaping @Sendable () async -> Data? = StatusLights.ghostexSessions,
         watchAgents: @escaping Watching = StatusLights.watchGhostex,
         micInUse: @escaping @MainActor () -> MicState = StatusLights.micInUse, watchMic: @escaping Watching = StatusLights.watchMic,
         cameraInUse: @escaping @MainActor () -> Bool = StatusLights.cameraInUse, watchCamera: @escaping Watching = StatusLights.watchCamera,
         pilotListening: @escaping @MainActor () -> Bool = { PilotDictation.shared.isListening },
         pilotRecording: @escaping @MainActor () -> Bool = { Recorder.shared.isActive },
         downloadsFolder: @escaping @MainActor () -> URL? = StatusLights.downloadsFolder,
         watchFolder: @escaping @MainActor (URL, @escaping @MainActor () -> Void) -> Watch? = StatusLights.watchDownloads,
         clock: @escaping () -> Date = Date.init, agentGap: Duration = .seconds(3)) {
        self.readAgents = readAgents
        self.watchAgents = watchAgents
        self.micInUse = micInUse
        self.watchMic = watchMic
        self.cameraInUse = cameraInUse
        self.watchCamera = watchCamera
        self.pilotListening = pilotListening
        self.pilotRecording = pilotRecording
        self.downloadsFolder = downloadsFolder
        self.watchFolder = watchFolder
        self.clock = clock
        self.agentGap = agentGap
    }

    /// Every lit source but the done and failed ones the popover has shown, save those it `keeps` (the ones it opened
    /// with): agents, privacy, jobs.
    func all(keeping kept: Set<String> = []) -> [StatusLight] {
        (agents + privacy + downloads + pushed.values.sorted { $0.id < $1.id }).filter { !seen.contains($0.id) || kept.contains($0.id) }
    }

    /// What the dots draw.
    var lights: [StatusLight] { all() }

    /// The privacy family: each app recording from the microphone, the camera, Pilot's dictation and recording.
    var privacy: [StatusLight] {
        let listening = pilotListening()
        let muted = micState.muted ? "The input is muted" : nil
        var lit = micState.apps.map {
            StatusLight(id: "mic.\($0)", family: .privacy, state: .watching, title: $0, source: "microphone", detail: muted, jump: .app($0))
        }
        if listening {
            lit.append(StatusLight(id: "mic.pilot", family: .privacy, state: .watching, title: "Pilot dictation", source: "microphone", detail: muted))
        }
        if cameraOn {
            // macOS names no app for a camera: its Settings pane lists the apps allowed it.
            lit.append(StatusLight(id: "camera", family: .privacy, state: .watching, title: "Camera", source: "camera",
                                   detail: "An app is using the camera", jump: .settings(Self.cameraPane)))
        }
        if pilotRecording() {
            lit.append(StatusLight(id: "recording", family: .privacy, state: .watching, title: "Pilot", source: "screen recording",
                                   detail: "Recording the screen"))
        }
        return lit
    }

    /// Whether it is watching, for the tests.
    var isWatching: Bool { watches != nil }

    /// The item is on a shown bar, or the screen is in use again: read now, then follow each change.
    func start() {
        guard watches == nil else { return }
        readMic()
        readCamera()
        downloadsAt = downloadsFolder()
        readDownloads()
        readAgentsSoon()
        var all = [watchMic { [weak self] in self?.readMic() }, watchCamera { [weak self] in self?.readCamera() },
                   watchAgents { [weak self] in self?.readAgentsSoon() }]
        if let downloadsAt { all.append(watchFolder(downloadsAt) { [weak self] in self?.readDownloads() }) }
        watches = all.compactMap { $0 }
    }

    func stop() {
        watches?.forEach { $0.cancel() }
        watches = nil
        agentRead?.cancel()
        agentRead = nil
        agentAgain = false
    }

    /// The popover opened: the done and failed lights it shows are seen, so the dots drop them now; it keeps the ids
    /// returned while it is open.
    func opened() -> Set<String> {
        prune()
        let ended = Set(all().filter { $0.state == .done || $0.state == .error }.map(\.id))
        seen.formUnion(ended)
        return ended
    }

    /// A row's click: where the light comes from.
    func open(_ light: StatusLight) { Self.jump(light.jump) }

    /// A `pilot light` push: a job (or an agent) working, done, failed or cleared.
    func push(id: String, state: StatusLight.State?, title: String, family: StatusLight.Family, detail: String?, session: String?) {
        let key = "pushed.\(id)"
        guard let state else {
            pushed[key] = nil
            return
        }
        seen.remove(key)
        ended[key] = state == .done || state == .error ? clock() : nil
        pushed[key] = StatusLight(id: key, family: family, state: state, title: title, source: session == nil ? "pilot light" : "Ghostex",
                                 detail: detail, jump: session.map(StatusJump.ghostex) ?? .none)
        prune()
    }

    private func readMic() {
        let now = micInUse()
        if now != micState { micState = now }
    }

    private func readCamera() {
        let now = cameraInUse()
        if now != cameraOn { cameraOn = now }
    }

    /// One read of Ghostex's list now, or once the last one is `agentGap` old: a busy Ghostex writes its state many
    /// times a second, and each burst costs one read.
    private func readAgentsSoon() {
        guard agentRead == nil else { agentAgain = true; return }
        agentRead = Task { [weak self, readAgents, agentGap] in
            // Writes before this read began are in it: only those during it ask for another.
            self?.agentAgain = false
            let read = await readAgents(), at = self?.clock() ?? Date()
            // The list is parsed off the main actor: it is a few hundred kilobytes with many sessions.
            let now = await Task.detached(priority: .utility) { read.map { GhostexAgents.lights($0, now: at) } }.value
            guard !Task.isCancelled, let self else { return }
            if let now {
                if now != agents { agents = now }
                prune()
            }
            try? await Task.sleep(for: agentGap)
            guard !Task.isCancelled else { return }
            agentRead = nil
            if agentAgain {
                agentAgain = false
                readAgentsSoon()
            }
        }
    }

    /// The partial downloads in the folder are working; one that became its own file is done.
    private func readDownloads() {
        guard let folder = downloadsAt else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let present = Set(names)
        var now = names.compactMap { name in Downloads.final(name).map { (name, $0) } }.sorted { $0.0 < $1.0 }.map { name, final in
            StatusLight(id: "download.\(final)", family: .job, state: .working, title: final, source: Downloads.source(name),
                        detail: "Downloading", jump: .file(folder.appending(path: name)))
        }
        let working = Set(now.map(\.id))
        // A partial that went: its file is there when it finished, gone when it was cancelled.
        for light in downloads where !working.contains(light.id) {
            guard present.contains(light.title) else { continue }
            if light.state == .working { ended[light.id] = clock() }
            now.append(StatusLight(id: light.id, family: .job, state: .done, title: light.title, source: light.source,
                                   detail: "Downloaded", jump: .file(folder.appending(path: light.title))))
        }
        if now != downloads { downloads = now }
        prune()
    }

    /// Done lights go out after StatusLight.doneFor, read on each change rather than on a timer; seen ids no source
    /// lights any more are forgotten.
    private func prune() {
        let cutoff = clock().addingTimeInterval(-StatusLight.doneFor)
        let old = Set(ended.filter { $0.value < cutoff }.map(\.key))
        if !old.isEmpty {
            downloads.removeAll { old.contains($0.id) && $0.state == .done }
            for id in old where pushed[id]?.state == .done { pushed[id] = nil }
            old.forEach { ended[$0] = nil }
        }
        let lit = Set((agents + downloads + pushed.values).map(\.id))
        if !seen.isSubset(of: lit) { seen.formIntersection(lit) }
    }

    // MARK: The real sources

    static let cameraPane = "com.apple.preference.security?Privacy_Camera"

    /// Ghostex's CLI inside its app, where Ghostex keeps it current; nil without Ghostex.
    nonisolated static let ghostex: URL? = ["/Applications/Ghostex.app/Contents/Resources/CLI/ghostex", "/opt/homebrew/bin/ghostex"]
        .map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }

    /// `ghostex sessions --json --full` in a child, off the main actor; nil without Ghostex, when it fails or after 10 s.
    nonisolated static func ghostexSessions() async -> Data? {
        guard let ghostex else { return nil }
        return try? await ChildProcess.data(ghostex.path(percentEncoded: false), ["sessions", "--json", "--full"], timeout: .seconds(10))
    }

    /// Ghostex's state store (gxserver's SQLite and its log), written whenever a session's activity or status moves;
    /// nil without Ghostex.
    static func watchGhostex(_ changed: @escaping @MainActor () -> Void) -> Watch? {
        let folder = URL.homeDirectory.appending(path: ".local/state/ghostex/gxserver")
        guard ghostex != nil, FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return nil }
        return FolderWatch.start(folder, only: { $0.hasPrefix("state.db") }, changed: changed)
    }

    /// The partial downloads in a folder coming and going: other files' writes wake nothing.
    static func watchDownloads(_ folder: URL, _ changed: @escaping @MainActor () -> Void) -> Watch? {
        FolderWatch.start(folder, only: { Downloads.final($0) != nil }, changed: changed)
    }

    /// ~/Downloads when Pilot may read it (Full Disk Access): without it, reading the folder would raise macOS's prompt.
    static func downloadsFolder() -> URL? {
        guard FileIndex.hasFullDiskAccess() else { return nil }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// Where a row goes: the agent's Ghostex session, the app in front, the file in Finder, a Settings pane.
    static func jump(_ jump: StatusJump) {
        switch jump {
        case .ghostex(let ref):
            guard let ghostex else { return }
            let process = Process()
            process.executableURL = ghostex
            process.arguments = ["focus", ref]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        case .app(let name):
            NSWorkspace.shared.runningApplications.first { $0.localizedName == name && $0.activationPolicy == .regular }?.activate()
        case .file(let url):
            let there = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
            NSWorkspace.shared.activateFileViewerSelecting([there ? url : url.deletingLastPathComponent()])
        case .settings(let pane): SystemModule.pane(pane)
        case .none: break
        }
    }

    /// Whether any camera runs for some app: CoreMediaIO's devices, each one's "running somewhere".
    static func cameraInUse() -> Bool {
        cameras().contains { camera in
            var address = cmio(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)), value = UInt32(0), used = UInt32(0)
            return CMIOObjectGetPropertyData(camera, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == 0 && value != 0
        }
    }

    /// Follows the camera list and each camera's "running somewhere"; a burst of changes is one re-arm and one read.
    static func watchCamera(_ changed: @escaping @MainActor () -> Void) -> Watch? {
        let running = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        let watch = PropertyListeners(.camera, wanted: {
            Set([PropertyKey(CMIOObjectID(kCMIOObjectSystemObject), CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))]
                + cameras().map { PropertyKey($0, running) })
        }, changed: changed)
        guard watch.arm() else { return nil }
        return Watch { MainActor.assumeIsolated { watch.disarm() } }
    }

    private static func cmio(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func cameras() -> [CMIOObjectID] {
        var address = cmio(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)), size = UInt32(0), used = UInt32(0)
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        return CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == 0 ? ids : []
    }

    /// The apps recording from the microphone: CoreAudio's processes running input (macOS 14.4), each named as its app
    /// (a browser's helper as the browser), Pilot's own left out (its dictation is a light of its own, its recording
    /// another); and whether the default input is muted at the device.
    /// The device's "running somewhere" was the old reading, and it is on while a headset whose microphone and speaker
    /// are one device only plays.
    static func micInUse() -> MicState {
        let apps = processes().filter { Self.flag($0, kAudioProcessPropertyIsRunningInput) }.compactMap { process -> String? in
            var pid = pid_t(0), size = UInt32(MemoryLayout<pid_t>.size), address = Self.address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr, pid != getpid() else { return nil }
            return appName(pid: pid, bundle: Self.text(process, kAudioProcessPropertyBundleID))
        }
        var seen = Set<String>()
        return MicState(apps: apps.filter { seen.insert($0).inserted }, muted: defaultInput().map(inputMuted) ?? false)
    }

    /// An app's name for a process: its own when it is an app, else the running app whose bundle id its own extends
    /// (com.google.Chrome.helper is Google Chrome's); WebKit's processes are Safari's.
    static func appName(pid: pid_t, bundle: String?) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app.localizedName }
        if let bundle, bundle.hasPrefix("com.apple.WebKit") { return "Safari" }
        var parts = (bundle ?? "").split(separator: ".").map(String.init)
        while parts.count > 2 {
            parts.removeLast()
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: parts.joined(separator: ".")).first {
                return app.localizedName
            }
        }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundle
    }

    /// Whether the input is muted at the device: its input mute, where it has one.
    static func inputMuted(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var muted = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectHasProperty(device, &address) && AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr && muted != 0
    }

    /// Follows every process's input, the process list, the default input and its mute; a burst of changes is one
    /// re-arm (listeners added only for processes that came, removed for those that went) and one read.
    static func watchMic(_ changed: @escaping @MainActor () -> Void) -> Watch? {
        let watch = PropertyListeners(.audio, wanted: micKeys, changed: changed)
        guard watch.arm() else { return nil }
        return Watch { MainActor.assumeIsolated { watch.disarm() } }
    }

    /// The microphone's listeners as things now are.
    static func micKeys() -> Set<PropertyKey> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var keys: Set<PropertyKey> = [PropertyKey(system, kAudioHardwarePropertyProcessObjectList),
                                      PropertyKey(system, AudioDirection.input.defaultSelector)]
        keys.formUnion(processes().map { PropertyKey($0, kAudioProcessPropertyIsRunningInput) })
        if let input = defaultInput() { keys.insert(PropertyKey(input, kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)) }
        return keys
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processes() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList), size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        return AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr ? ids : []
    }

    private static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector), value = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func text(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func defaultInput() -> AudioObjectID? { CoreAudioSystem().defaultDevice(.input) }
}

/// One FSEvents stream on a folder, its events gathered for a second and delivered on the main queue; `only` keeps
/// the files whose names it takes. It wakes on writes alone, never on a clock.
enum FolderWatch {
    @MainActor static func start(_ folder: URL, only: ((String) -> Bool)? = nil, changed: @escaping @MainActor () -> Void) -> Watch? {
        final class Box {
            let only: ((String) -> Bool)?
            let changed: @MainActor () -> Void
            init(_ only: ((String) -> Bool)?, _ changed: @escaping @MainActor () -> Void) { self.only = only; self.changed = changed }
        }
        let box = Unmanaged.passRetained(Box(only, changed))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
            let names = (unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).prefix(count).map { ($0 as NSString).lastPathComponent }
            guard box.only.map({ only in names.contains(where: only) }) ?? true else { return }
            MainActor.assumeIsolated { box.changed() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path(percentEncoded: false)] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else {
            box.release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            box.release()
            return nil
        }
        return Watch {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            box.release()
        }
    }
}
