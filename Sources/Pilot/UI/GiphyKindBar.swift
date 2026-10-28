import PilotCore
import SwiftUI

/// Stickers and GIFs' switch (Sven 2026-10-12): what GIPHY is asked for, its GIFs or its stickers, as two chips under the
/// search; Tab or a click flips it and the menu keeps the pick. The folder's pictures and the emoji list under both.
struct GiphyKindBar: View {
    @Bindable var model: MenuModel
    /// Its height in Instrument, chips and padding, which the panel adds over the list (MenuPanelSize.instrument).
    static let instrumentHeight: CGFloat = 38

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Giphy.Kind.allCases, id: \.self) { kind in
                let on = model.giphyKind == kind
                Button { model.pickGiphy(kind) } label: {
                    Chip(text: kind.title, on: on, count: on ? nil : "Tab", symbol: kind == .gifs ? "play.rectangle" : "sparkles")
                }
                .buttonStyle(.plain)
                .help("GIPHY's \(kind.title.lowercased()); Tab switches")
                .accessibilityLabel("GIPHY \(kind.title)\(on ? ", shown" : "; Tab")")
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("GIPHY GIFs or stickers")
    }
}
