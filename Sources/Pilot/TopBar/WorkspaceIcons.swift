import PilotCore
import SwiftUI

/// Workspaces' icons style (card agent-bo-95423019, design JJPiA9o30SA direction B's left island): a workspace's apps as
/// their own icons, each once in the tiler's order, at most 3 then +N; full strength on the current workspace, 55 percent
/// on the others, so the current one reads first.
struct WorkspaceAppIcons: View {
    @Environment(\.style) private var style
    let workspace: OccupiedWorkspace
    let lit: Bool

    var body: some View {
        let icons = TopBarWorkspaces.Icons(workspace.apps)
        HStack(spacing: 4) {
            CompactApps(names: icons.apps, bundles: workspace.bundles)
            if let more = icons.moreLabel {
                if style.kind == .instrument {
                    Text(more).font(style.font(\.key, size: 10)).foregroundStyle(style.color(\.text2))
                } else {
                    Text(more).font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(style.color(\.text2))
                }
            }
        }
        .opacity(lit ? 1 : 0.55)
        .accessibilityHidden(true)
    }
}

/// The layout glyph (layouts round 1, Sven's Q234): the workspace a bar's screen shows draws its ready layout in place
/// of its number, as Omarchy's bar does, so a click there (which cycles it) shows what it cycles. The glyph is the
/// layout's own picture, LayoutPreset.tiles at `count` windows on a screen-shaped box, each tile filled in the text's
/// colour a point apart.
struct LayoutGlyph: View {
    let preset: LayoutPreset
    static let size = CGSize(width: 16, height: 11)

    /// Enough windows to tell each apart: Main + stack's 2x2 half shows at five.
    static func count(_ preset: LayoutPreset) -> Int {
        switch preset {
        case .mainStack: 5
        case .grid, .scrolling: 4
        case .centred, .rows, .stage: 3
        }
    }

    var body: some View {
        let tiles = preset.tiles(Self.count(preset), in: CGRect(origin: .zero, size: Self.size))
        ZStack(alignment: .topLeading) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                let inset = tile.insetBy(dx: 0.5, dy: 0.5)
                RoundedRectangle(cornerRadius: min(1.5, inset.width / 3), style: .continuous).fill(.foreground)
                    .frame(width: max(inset.width, 0.5), height: max(inset.height, 0.5))
                    .offset(x: inset.minX, y: inset.minY)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}
