import AppKit
import PilotCore
import SwiftUI

/// The panels' look (card agent-bo-95422727; design round 4, card agent-bo-95422895): every panel draws its own ground,
/// corner and edge in the picked style (Toybox's pop block), with no theme ground, hairline or material under it.
extension Look {
    /// The tokens `surface` draws its own chrome from.
    func chromeTokens(_ surface: StyleSurface) -> StyleTokens { StyleTokens.of(style, theme: theme) }

    /// The clear room round `surface`'s panel for the shadow its own face draws (PopSurface.margins); none for a face with
    /// no soft shadow (Toybox's).
    func chromeMargins(_ surface: StyleSurface) -> NSEdgeInsets { PopSurface.margins(chromeTokens(surface)) }

    /// The panels Glass reaches besides the window (Glass everywhere, Sven 2026-10-19, Q356): the Hyper+Space menu,
    /// clipboard history, quick notes and Quick AI, and an extension's detail in the menu (Sven 2026-10-25, Q474). The bar
    /// keeps its own Background; an extension's bar popover takes Glass itself (extensionGlass); the HUDs, the other
    /// popovers and the rest stay solid.
    static let glassPanels: Set<StyleSurface> = [.menu, .clipboard, .notes, .quickAI, .extensionDetail]

    /// An extension's bar popover is on Glass: Glass is on, in a style that takes it (Q474).
    var extensionGlass: Bool { material(on: .barPopovers) == .glass }

    /// `surface` is a panel on Liquid Glass: one of glassPanels while Glass is on, in a style that takes it.
    func glassFace(_ surface: StyleSurface) -> Bool { Self.glassPanels.contains(surface) && material(on: surface) == .glass }

    /// The tint of every Glass Pilot draws behind its window and panels: the style's ground at the ground layer's strength
    /// (Transparency's table), the top bar Glass's material and share (42 % at Transparency 100 %).
    func glassTint(on surface: StyleSurface) -> NSColor {
        NSColor(Color(chromeTokens(surface).colors.canvas)).withAlphaComponent(CGFloat(layers.ground))
    }

    /// The AppKit appearance of `surface`'s panel: its style's dark or light.
    func appearance(for surface: StyleSurface) -> NSAppearance? { NSAppearance(named: chromeTokens(surface).dark ? .darkAqua : .aqua) }
}

/// A small mono heading in the muted colour: "pilot menu › apps", "pinned".
struct PanelHeading: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    let text: String
    /// Nil for the quiet heading: the style's quiet colour.
    var color: Color?
    var body: some View {
        if style.kind == .toybox {
            Text(text).styleText(\.eyebrow).foregroundStyle(color ?? style.color(\.text3)).lineLimit(1).accessibilityAddTraits(.isHeader)
        } else {
            Text(text).font(ink.themeMono(12, weight: .medium)).foregroundStyle(color ?? Theme.muted).lineLimit(1).accessibilityAddTraits(.isHeader)
        }
    }
}

/// One footer hint: the key, then what it does.
typealias KeyHint = (key: String, label: String)
