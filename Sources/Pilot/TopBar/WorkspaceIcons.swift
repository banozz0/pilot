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
