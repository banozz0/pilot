import PilotCore
import SwiftUI

/// Binds › Swap keys (Q406): pairs of keys swapped at the HID level while Pilot runs, Caps Lock ↔ Control and the like,
/// written with Caps Lock's F18 as one mapping set and taken off at quit. A swap on a Hyper key is refused, and one the
/// layer keys or another tool's mapping later catch waits, its row saying why (Q407). Self-contained like Binds › Mouse.
struct KeySwapsPage: View {
    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink
    @State private var a: SwapKey = .capsLock
    @State private var b: SwapKey = .leftControl

    static let intro = "Swap two keys so each types the other, on every keyboard. Swaps apply while Pilot runs and go away when it quits."

    var body: some View {
        let settings = engine.settings
        let swaps = settings.keySwaps, layerKeys = settings.layerKeys, foreign = engine.foreignMapping
        let refusal = KeySwap(a, b).refusal(joining: swaps, layerKeys: layerKeys, foreign: foreign)
        KitPage(intro: Self.intro) {
            KitBlock(title: "Swap keys", symbol: "arrow.left.arrow.right") {
                BlockRow(first: true) {
                    picker("First key", $a)
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(ink.muted).accessibilityHidden(true)
                    picker("Second key", $b)
                    InfoMark(text: "Only these keys can be swapped. A Hyper key cannot: pick another Hyper key in General first.")
                    Spacer()
                    Button("Swap") { settings.keySwaps.append(KeySwap(a, b)) }.buttonStyle(.pilotPrimary).disabled(refusal != nil)
                }
                if let refusal { BlockRow { FinePrint(text: refusal, color: ink.red) } }
                ForEach(swaps, id: \.self) { swap in
                    BlockRow {
                        let problem = swap.problem(layerKeys: layerKeys, foreign: foreign)
                        TitledText(title: swap.label, detail: problem ?? "Each key types the other while Pilot runs").padding(.vertical, 4)
                            .opacity(problem == nil ? 1 : 0.6)
                        Spacer()
                        Button("Remove") { settings.keySwaps.removeAll { $0 == swap } }.buttonStyle(.pilot)
                    }
                }
            }
        }
    }

    private func picker(_ label: String, _ key: Binding<SwapKey>) -> some View {
        Picker(label, selection: key) {
            ForEach(SwapKey.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden().fixedSize()
    }
}
