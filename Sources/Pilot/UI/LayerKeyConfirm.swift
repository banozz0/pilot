import PilotCore
import SwiftUI

/// The layer keys a pick would leave, waiting on LayerKeyConfirm.
struct LayerKeyChange: Identifiable {
    let keys: [LayerKey]
    var id: String { keys.rawValues }
}

/// The confirm before Caps Lock stops being Hyper (card agent-bo-95422775): on 2026-10-05 a stray click moved Hyper to
/// right Command with no question, and Sven lost Hyper. Settings › General and onboarding share it.
struct LayerKeyConfirm: View {
    let keys: [LayerKey]
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make \(keys.label) the Hyper key?").font(.system(size: 15, weight: .semibold))
            Text("Caps Lock goes back to Caps Lock and a tap no longer sends Escape. Hyper is \(keys.label) until you change it again on \(AppPlace(.hyperKey).path).")
                .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Use \(keys.label)", action: confirm).buttonStyle(.pilotPrimary)
            }
        }
        .padding(20)
        .frame(width: 380)
        .pilotSheet()
    }

    /// Keys picked: a pick that turns Caps Lock off waits in `asking` for the confirm, any other applies at once.
    static func pick(_ keys: [LayerKey], _ settings: PilotSettings, from source: LayerKeySource, asking: Binding<LayerKeyChange?>) {
        if LayerKey.asksFirst(from: settings.layerKeys, to: keys) { asking.wrappedValue = LayerKeyChange(keys: keys) }
        else { settings.setLayerKeys(keys, from: source) }
    }

    /// A key's tick over `pick`: on adds it, off takes it out; the last one left stays on.
    static func ticked(_ key: LayerKey, _ settings: PilotSettings, from source: LayerKeySource,
                       asking: Binding<LayerKeyChange?>) -> Binding<Bool> {
        Binding(get: { settings.layerKeys.contains(key) },
                set: { on in pick(on ? settings.layerKeys + [key] : settings.layerKeys.filter { $0 != key }, settings, from: source, asking: asking) })
    }
}

extension View {
    /// Shows LayerKeyConfirm while `asking` holds keys; Confirm applies them from `source`, Cancel keeps the keys as they were.
    func layerKeyConfirm(_ asking: Binding<LayerKeyChange?>, settings: PilotSettings, from source: LayerKeySource) -> some View {
        sheet(item: asking) { change in
            LayerKeyConfirm(keys: change.keys, confirm: {
                settings.setLayerKeys(change.keys, from: source)
                asking.wrappedValue = nil
            }, cancel: { asking.wrappedValue = nil })
            .floating()
        }
    }
}
