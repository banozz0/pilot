import PilotCore
import SwiftUI

/// Launcher (C3, Sven 2026-10-10, design Wa6fPGPUhV2VcmJ4vGXZQ5; titled Menu until the page map, Sven 2026-10-17):
/// everything Hyper+Space shows, on one page with its tabs. Your menu is the root's rows (MenuRootBlock, story 152);
/// Abilities every ability Pilot has (AbilitiesList, story 155, was Binds › Abilities), with Folders and Passwords
/// (story 160) under the abilities they configure since the page map. Your menu also holds the extra rows the root can
/// list (MenuExtrasBlock, Sven 2026-10-20; on More from simplify-pages T15 until pages round 4, Sven's Q96). More holds
/// Translate's pair (TranslateBlock, from System's Keyboard layout card), and Aliases and Quicklinks, Defaults' blocks
/// and then their own tabs; and how the menu draws (Line, Classic or the Rail) and how apps show, Look's More's until
/// Sven's notes on build 19. File search went on to the Files page (Sven 2026-10-10).
struct MenuPage: View {
    /// None offscreen without one: Translate's block needs the engine's settings.
    @Environment(Engine.self) private var engine: Engine?
    let section: AppSection?
    /// The window's search, which Abilities filters by.
    var search = ""
    /// The row whose alias editor Aliases opens (the menu's Set alias…); `tookAlias` clears it as Aliases opens it. A
    /// value and a closure, not a binding: a binding is a dynamic property, and one made again with the window's part
    /// runs the page again whatever `==` says (topbar-search, after page-switch-4's Binds fix).
    var editAlias: Alias? = nil
    var tookAlias: () -> Void = {}
    /// Abilities' Set key: Binds' editor on that action.
    var editBind: (String) -> Void = { _ in }
    /// The books Aliases and Quicklinks edit; a render passes its own.
    var aliases: AliasBook = .shared
    var links: QuicklinkBook = .shared
    /// How much of Your menu stands side by side, followed as the window resizes; stacked until measured, as GeneralPage's.
    @State private var fit = Fit.stacked

    static let intro = "Hyper+Space: the rows it lists before you type, in your order."
    static let introInfo = "Its other tabs: everything Pilot can do and the rings. More holds Translate, aliases, quicklinks, the menu's layout and how apps show."
    /// The page width from which Your menu's preview stands beside its rows (simplify-pages T26): the rows at their
    /// least (a long title, its ⓘ, the arrows and the switch), the gap, the preview.
    static let rowsWidth: CGFloat = 372, gap: CGFloat = 18
    static let besideWidth = rowsWidth + gap + MenuRootPreview.width
    /// The page width from which More rows stands right of the preview too (Sven, 2026-11-14: left list, the preview
    /// narrow in the middle, right list): its rows at their least are Your menu's.
    static let acrossWidth = besideWidth + gap + rowsWidth

    /// Your menu's layouts by width: both lists with the preview between them, the rows beside the preview with More
    /// rows under, or all three stacked without the preview.
    enum Fit { case across, beside, stacked
        init(width: CGFloat) { self = width >= MenuPage.acrossWidth ? .across : width >= MenuPage.besideWidth ? .beside : .stacked }
    }

    /// More's index (simplify-pages T15). A row added to or moved off a block changes its count here; Aliases and
    /// Quicklinks are a list each.
    static let entries = [
        MoreEntry(id: .translate, symbol: "character.bubble", controls: 2),
        MoreEntry(id: .aliases, symbol: "character.textbox", controls: 1),
        MoreEntry(id: .quicklinks, symbol: "link", controls: 1),
        MoreEntry(id: .appsShowAs, symbol: "square.grid.2x2", controls: 1),
    ]

    var body: some View {
        switch section {
        case .abilities: AbilitiesList(search: search, setKey: editBind)
        // More, or a place on it a render names (the window turns a place into its More).
        case let place? where (place.onMore ?? place) == .menuMore:
            let settings = engine?.settings
            // The page's scroll, which brings the alias the menu asked for into view in its editor. Translate shows only
            // with the engine's settings.
            ScrollViewReader { scroll in
                KitMore(entries: Self.entries.filter { settings != nil || $0.id != .translate }) {
                    if let settings { TranslateBlock(settings: settings).moreBlock(.translate) }
                    AliasesList(book: aliases, asked: Binding(get: { editAlias }, set: { if $0 == nil { tookAlias() } }), page: scroll).moreBlock(.aliases)
                    QuicklinksList(book: links).moreBlock(.quicklinks)
                    AppsShowAsBlock(look: .shared)
                }
            }
        default:
            // An ability's own settings go under it on Abilities (page map, Sven 2026-10-17). The preview stands beside
            // the rows only when both fit; narrower it goes, as a stacked one would push the rows past the window. One
            // HStack, so the page's columns (PageFlow) take the row as one block.
            let extras = MenuExtrasBlock(settings: .shared).id(AppSection.menuExtras)
            KitLanding { KitPage(intro: Self.intro, info: Self.introInfo) {
                HStack(alignment: .top, spacing: Self.gap) {
                    MenuRootBlock(settings: .shared)
                    if fit != .stacked { MenuRootPreview(settings: .shared) }
                    if fit == .across { extras }
                }
                if fit != .across { extras }
            } }
            .onGeometryChange(for: Fit.self) { Fit(width: $0.size.width) } action: { fit = $0 }
        }
    }
}

/// Equal on what it shows from (the part, the words, the alias asked for, its books),
/// shown `.equatable()` by the window's part: its closures, made again with the part, never compare equal, so the
/// whole page was built again as its kept part was hidden, shown or put back (topbar-search; page-switch-4's Binds fix).
extension MenuPage: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated {
            a.section == b.section && a.search == b.search && a.editAlias == b.editAlias && a.aliases === b.aliases && a.links === b.links
        }
    }
}
