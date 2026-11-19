import PilotCore
import SwiftUI

/// The bar's and its popovers' words and marks in the style's colours: what Instrument's bar items, dropdowns and drops
/// read their text, accent and fonts from.
struct BarInk {
    let style: StyleTokens

    @MainActor var text: Color { style.color(\.text) }
    @MainActor var text2: Color { style.color(\.text2) }
    @MainActor var muted: Color { style.color(\.text3) }
    /// The accent as a mark or words.
    @MainActor var accent: Color { style.color(\.accentText) }
    /// The accent as a fill, with the ink on it.
    @MainActor var accentFill: Color { style.color(\.accent) }
    @MainActor var selected: Color { style.color(\.sunken) }
    /// A popover's title.
    @MainActor var headline: Font { .headline }
    /// Numbers.
    @MainActor func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { Theme.mono(size, weight: weight) }
    /// Small words under a heading.
    @MainActor var detail: Font { Theme.detail }
}
