import PilotCore
import SwiftUI

/// Design round pages-fill (Sven, 2026-11-25, combined-15 build 3216: "the half empty pages in pilot. also menubar page can
/// it be better organised?"): the layouts the round shows him, one switch per kind of empty page, each off (today's page)
/// by default. Only `PagesFillRenders` sets them, before it builds a window; the pick ships in their place and the rest go.
@MainActor
enum PagesFill {
    /// A front with a More a tab away (Captures, Update & Clean): More stays a tab; its blocks join the front in a tall
    /// page, the tab kept for a small window; or its blocks stand on the front for good and the tab goes.
    enum More { case tab, whenTall, folded }
    static var more = More.tab

    /// A preview that stays small in a big window (Rings' ring, Folders' designs): as today; drawn as big as the page
    /// gives it; or the detail it stands for brought forward under it (every wedge's action and key, every kind's designs).
    enum Preview { case asIs, grows, detail }
    static var preview = Preview.asIs

    /// Dock's front, one list 1400 pt wide: as today; its widgets in two columns, in the dock and not; or the dock's look
    /// (with More's rows, the tab gone) in a column beside the widgets.
    enum Dock { case asIs, twoColumns, lookBeside }
    static var dock = Dock.asIs

    /// The Menu bar page: as today (Q182's order); the bar's look in one row and the item groups in the page's columns; the
    /// set-once blocks behind More; or two tabs, Bar and Items.
    enum MenuBar { case asIs, columns, more, tabs }
    static var menuBar = MenuBar.asIs

    /// The page area's height from which a More's blocks join the front (`More.whenTall`): the 1290 pt window's page is
    /// 1168 pt tall, the first window's 716.
    static let tall: CGFloat = 1000
}

/// The page's own height, read without a GeometryReader in the tree: whether it is at least `PagesFill.tall`.
struct TallPage<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var tall = false

    var body: some View {
        content(tall)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onGeometryChange(for: Bool.self) { $0.size.height >= PagesFill.tall } action: { tall = $0 }
    }
}

extension View {
    /// A More tab's block tag (the index's scroll spy), only on the tab: a block brought to the front flows into the
    /// page's columns untagged (pages-fill).
    @ViewBuilder func moreBlock(_ place: AppSection, on: Bool) -> some View {
        if on { moreBlock(place) } else { self }
    }
}
