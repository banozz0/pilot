import PilotCore
import SwiftUI

/// Launcher › More › Translate (simplify-pages T15; Your menu's from the page map, Sven 2026-10-17; on System's Keyboard layout card until then, card
/// agent-bo-95423002): the menu's Translate pair, the language everything goes into and where text already in it goes.
struct TranslateBlock: View {
    @Bindable var settings: PilotSettings

    static let note = "What Translate in Hyper+Space turns your words into."

    var body: some View {
        let pair = settings.translatePair
        KitBlock(title: "Translate", symbol: "character.bubble", note: Self.note) {
            languageRow("Translate into", pair.home, first: true,
                        info: "Translate turns text in any other language into this one.") { settings.translatePair = pair.with(home: $0) }
            languageRow("\(Translate.name(pair.home)) goes into", pair.other,
                        info: "Text already in \(Translate.name(pair.home)) is turned into this one.") { settings.translatePair = pair.with(other: $0) }
        }
    }

    private func languageRow(_ label: String, _ code: String, first: Bool = false, info: String,
                             pick: @escaping (String) -> Void) -> some View {
        BlockRow(first: first) {
            HStack(spacing: 6) { Text(label); InfoMark(text: info) }
            Spacer()
            Picker(label, selection: Binding(get: { code }, set: pick)) {
                ForEach(TranslatePair.languages, id: \.self) { Text(Translate.name($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }
}
