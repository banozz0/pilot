import AppKit
import PilotCore
import SwiftUI

/// Something a quick switch turns on and off.
@MainActor
protocol QuickSwitchable: AnyObject {
    var isOn: Bool { get }
    func toggle()
}

/// The dropdown's quick switches (card agent-bo-95422912): the launcher and the key binds (Pilot's on/off switch, spec
/// pilot-ui-redesign T4), the tiler's tiling, the top bar, Keep awake, the clipboard's recording and the dictation key
/// (spec pilot-1-1 T29); injected, so tests run each over fakes of what it drives.
@MainActor
struct QuickSwitches {
    /// `hyper` is Key binds, the `.hyper` case's switch.
    let hyper: QuickSwitchable, tiling: QuickSwitchable, topBar: QuickSwitchable, keepAwake: QuickSwitchable, clipboard: QuickSwitchable,
        dictation: QuickSwitchable, launcher: QuickSwitchable

    init(hyper: QuickSwitchable, tiling: QuickSwitchable, topBar: QuickSwitchable, keepAwake: QuickSwitchable, clipboard: QuickSwitchable,
         dictation: QuickSwitchable, launcher: QuickSwitchable = SessionSwitch.launcher) {
        self.hyper = hyper; self.tiling = tiling; self.topBar = topBar; self.keepAwake = keepAwake; self.clipboard = clipboard
        self.dictation = dictation; self.launcher = launcher
    }

    subscript(_ which: Dropdown.Switch) -> QuickSwitchable {
        switch which {
        case .launcher: launcher
        case .hyper: hyper
        case .tiling: tiling
        case .topBar: topBar
        case .keepAwake: keepAwake
        case .clipboard: clipboard
        case .dictation: dictation
        }
    }
}

/// The dropdown's Dictation switch (spec pilot-1-1 T29): Voice › Dictation key on or off. Off remembers the key, so on
/// brings it back; a key Hyper took since, or none remembered, comes back as the first key on offer.
@MainActor
final class DictationKeySwitch: QuickSwitchable {
    private let settings: PilotSettings
    private var last: DictationKey?

    init(settings: PilotSettings) { self.settings = settings }

    var isOn: Bool { settings.dictationKey != .off }

    func toggle() {
        if isOn {
            last = settings.dictationKey
            settings.dictationKey = .off
        } else {
            let offered = DictationKey.offered(layerKeys: settings.layerKeys).filter { $0 != .off }
            settings.dictationKey = last.flatMap { offered.contains($0) ? $0 : nil } ?? offered.first ?? .off
        }
    }
}

extension KeepAwake: QuickSwitchable {}
/// Key binds (spec pilot-ui-redesign T4): Pilot's saved on/off switch, `switch.on`. Off keeps only the launcher's key
/// (Open question 4, Engine.runs).
extension PilotSwitch: QuickSwitchable {
    func toggle() { set(!isOn) }
}
extension TopBarController: QuickSwitchable {
    func toggle() { set(!isOn) }
}
/// The dropdown's Tiling switch (card agent-bo-95422912), the same one as Windows › Tiling's: off stops the tiler and
/// brings the windows of hidden workspaces onto the visible screen (as AeroSpace's enable did); on starts it again. Saved
/// (Settings' `tiling.on`), so off stays off at the next launch; off while the tiler is not running.
@Observable @MainActor
final class TilingSwitch: QuickSwitchable {
    private(set) var tiling: Bool
    @ObservationIgnored private let answering: @MainActor () -> Bool
    @ObservationIgnored private let enable: @MainActor (Bool) async throws -> Void

    init(answering: @escaping @MainActor () -> Bool, enable: @escaping @MainActor (Bool) async throws -> Void, tiling: Bool = true) {
        self.answering = answering
        self.enable = enable
        self.tiling = tiling
    }

    /// The real one: Settings' switch, which the engine follows by starting or stopping Pilot's tiler.
    convenience init(_ tiler: TilerService, settings: PilotSettings) {
        self.init(answering: { tiler.isAnswering }, enable: { on in settings.tiling = on }, tiling: settings.tiling)
    }

    var isOn: Bool { answering() && tiling }

    /// The switch changed elsewhere (its page, `pilot set`): shown as it is now.
    func follow(_ on: Bool) { tiling = on }

    func toggle() {
        let on = !tiling
        Task {
            do {
                try await enable(on)
                tiling = on
            } catch {
                wslog.error("tiling \(on ? "on" : "off", privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// A quick switch. Without `saved` it is on at every launch, never saved, so it is never forgotten off for good: the
/// Hyper key (card agent-bo-95422986; off, the layer key and chord Hyper do what macOS says, plain combos still run).
/// With `saved` it keeps its state across launches under that key, `standard` until first flipped: the clipboard's
/// recording (card agent-bo-95422912; paused, nothing copied is kept; a new install's starts off, Sven's pick
/// 2026-11-19; Off lasts, Open question 5 of spec pilot-ui-redesign) and the launcher (`launcher.on`, T4).
@Observable @MainActor
final class SessionSwitch: QuickSwitchable {
    static let clipboard = SessionSwitch(saved: "clipboard.recording", standard: Install.startsOn) { ClipboardHistory.shared.setRecording($0) }
    /// The launcher: off, its key (Hyper+Space) opens nothing and a tip names the switch (Engine's tap.onRun).
    /// With Key binds off too, the tap stops (Engine.bindSwitchesChanged).
    static let launcher = SessionSwitch(saved: "launcher.on", standard: true) { on in
        mlog.notice("launcher \(on ? "on" : "off", privacy: .public)")
        Engine.shared?.bindSwitchesChanged()
    }
    private(set) var isOn: Bool
    @ObservationIgnored private let apply: @MainActor (Bool) -> Void
    @ObservationIgnored private let saved: String?
    @ObservationIgnored private let defaults: UserDefaults

    init(saved: String? = nil, standard: Bool = true, defaults: UserDefaults = .pilot(), apply: @escaping @MainActor (Bool) -> Void) {
        self.apply = apply
        self.saved = saved
        self.defaults = defaults
        isOn = saved.map { defaults.object(forKey: $0) as? Bool ?? standard } ?? true
    }

    func toggle() {
        isOn.toggle()
        if let saved { defaults.set(isOn, forKey: saved) }
        apply(isOn)
    }

    func set(_ on: Bool) { if on != isOn { toggle() } }
}

/// Pilot's menu-bar dropdown (card agent-bo-95422912, compact since spec pilot-1-1 T29): Status with any problem first,
/// the workspaces, six switches, Now while something runs, the rows with their keys, then Check for updates, Settings
/// and Quit; holding Option adds the developer rows. Everything the old dropdown offered is here (Dropdown.carried).
struct PilotDropdown: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let switches: QuickSwitches
    /// Option is held: the developer rows show, from the press that opened the dropdown or any later one.
    @State private var option: Bool

    init(switches: QuickSwitches, option: Bool = NSEvent.modifierFlags.contains(.option)) {
        self.switches = switches
        _option = State(initialValue: option)
    }

    /// Instrument and Toybox draw their own (InstrumentDropdown, ToyDropdown) on the same blocks and switches.
    var body: some View {
        Group {
            switch style.kind {
            case .instrument: InstrumentDropdown(switches: switches, option: option)
            case .toybox: ToyDropdown(switches: switches, option: option)
            }
        }
        .onModifierKeysChanged(mask: .option) { _, keys in option = keys.contains(.option) }
        // Check for updates says what it found from the first open, as General's header does on its first show; a window
        // opened or moved since the last workspace change shows up the moment the dropdown opens.
        .task {
            PilotUpdates.shared.countOnce()
            await engine.observers.tiler.refreshOccupied()
        }
    }
}

extension Engine {
    /// Pilot's dropdown (card agent-bo-95422912), with its quick switches on the real tiler, top bar, Keep awake,
    /// clipboard and dictation key.
    var dropdown: AnyView { AnyView(PilotDropdown(switches: quickSwitches).environment(self)) }

    /// The quick switches, the Pilot menu's and the pill's Controls view's.
    var quickSwitches: QuickSwitches {
        QuickSwitches(hyper: pilotSwitch, tiling: tilingSwitch, topBar: topBar, keepAwake: KeepAwake.shared,
                      clipboard: SessionSwitch.clipboard, dictation: dictationSwitch, launcher: SessionSwitch.launcher)
    }

}

extension PilotDropdown {
    /// Nothing, before the engine exists.
    static var none: AnyView { AnyView(EmptyView()) }
}

/// The Now block's timer line in every style.
enum NowTimer {
    /// "Focus, 24:59 left", ", paused" after it while held; nil with no timer.
    @MainActor static func line(_ timer: ExtensionTimer) -> String? {
        guard let title = timer.title, let countdown = timer.countdown else { return nil }
        return "\(title), \(countdown) left\(timer.isPaused ? ", paused" : "")"
    }
}
