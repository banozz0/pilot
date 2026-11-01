import AppKit
import PilotCore
import SwiftUI

/// Something a quick switch turns on and off.
@MainActor
protocol QuickSwitchable: AnyObject {
    var isOn: Bool { get }
    func toggle()
}

/// The dropdown's quick switches (card agent-bo-95422912): the Hyper key (card agent-bo-95422986), the tiler's tiling,
/// the top bar, Keep awake, the clipboard's recording and the dictation key (spec pilot-1-1 T29); injected, so tests run
/// each over fakes of what it drives.
@MainActor
struct QuickSwitches {
    let hyper: QuickSwitchable, tiling: QuickSwitchable, topBar: QuickSwitchable, keepAwake: QuickSwitchable, clipboard: QuickSwitchable,
        dictation: QuickSwitchable

    subscript(_ which: Dropdown.Switch) -> QuickSwitchable {
        switch which {
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
extension TopBarController: QuickSwitchable {
    func toggle() { set(!isOn) }
}
/// The dropdown's Tiling switch (card agent-bo-95422912): `enable off` stops the tiler tiling and managing
/// windows, and brings the windows of hidden workspaces onto the visible screen (as AeroSpace's enable did);
/// `enable on` tiles again. Pilot remembers what it last set, as the tiler does not report it; off while the tiler is not
/// running.
@Observable @MainActor
final class TilingSwitch: QuickSwitchable {
    private(set) var tiling = true
    @ObservationIgnored private let answering: @MainActor () -> Bool
    @ObservationIgnored private let enable: @MainActor (Bool) async throws -> Void

    init(answering: @escaping @MainActor () -> Bool, enable: @escaping @MainActor (Bool) async throws -> Void) {
        self.answering = answering
        self.enable = enable
    }

    /// The real one, Pilot's tiler.
    convenience init(_ tiler: TilerService) {
        self.init(answering: { tiler.isAnswering }, enable: { on in try await tiler.runner.run(.enable(on)) })
    }

    var isOn: Bool { answering() && tiling }

    func toggle() {
        let on = !tiling
        Task {
            do {
                try await enable(on)
                tiling = on
                wslog.notice("tiling \(on ? "on" : "off", privacy: .public)")
            } catch {
                wslog.error("tiling \(on ? "on" : "off", privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// A quick switch on at every launch, never saved, so it is never forgotten off for good: the clipboard's recording
/// (card agent-bo-95422912; paused, nothing copied is kept) and the Hyper key (card agent-bo-95422986; off, the layer
/// key and chord Hyper do what macOS says, plain combos still run).
@Observable @MainActor
final class SessionSwitch: QuickSwitchable {
    static let clipboard = SessionSwitch { ClipboardHistory.shared.setRecording($0) }
    private(set) var isOn = true
    @ObservationIgnored private let apply: @MainActor (Bool) -> Void

    init(apply: @escaping @MainActor (Bool) -> Void) { self.apply = apply }

    func toggle() {
        isOn.toggle()
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
    var dropdown: AnyView {
        AnyView(PilotDropdown(switches: QuickSwitches(hyper: hyperSwitch, tiling: tilingSwitch, topBar: topBar, keepAwake: KeepAwake.shared,
                                                      clipboard: SessionSwitch.clipboard, dictation: dictationSwitch)).environment(self))
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
