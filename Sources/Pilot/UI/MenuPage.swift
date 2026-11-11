import PilotCore
import SwiftUI

/// Launcher (C3, Sven 2026-10-10, design Wa6fPGPUhV2VcmJ4vGXZQ5; titled Menu until the page map, Sven 2026-10-17):
/// everything Hyper+Space shows, on one page with its tabs. Your menu is the root's rows (MenuRootBlock, story 152);
/// Abilities every ability Pilot has (AbilitiesList, story 155, was Binds › Abilities), with Folders and Passwords
/// (story 160) under the abilities they configure since the page map. More (simplify-pages T15) holds the extra rows the
/// root can list (MenuExtrasBlock, Sven 2026-10-20), Translate's pair (TranslateBlock, from System's Keyboard layout
/// card), and Aliases and Quicklinks, Defaults' blocks and then their own tabs. File search went on to the Files page
/// (Sven 2026-10-10).
struct MenuPage: View {
    /// None offscreen without one: Translate's block needs the engine's settings.
    @Environment(Engine.self) private var engine: Engine?
    let section: AppSection?
    /// The window's search, which Abilities filters by.
    var search = ""
    /// The row whose alias editor Aliases opens (the menu's Set alias…); Aliases clears it.
    var editAlias: Binding<Alias?> = .constant(nil)
    /// Abilities' Set key: Binds' editor on that action.
    var editBind: (String) -> Void = { _ in }
    /// The books Aliases and Quicklinks edit; a render passes its own.
    var aliases: AliasBook = .shared
    var links: QuicklinkBook = .shared
    /// Whether the page is `besideWidth` wide, followed as the window resizes; narrow until measured, as GeneralPage's.
    @State private var wide = false

    static let intro = "Hyper+Space: the rows it lists before you type, in your order."
    static let introInfo = "Its other tabs: everything Pilot can do and the rings. More holds the rows you can add, Translate, aliases and quicklinks."
    /// The page width from which Your menu's preview stands beside its rows (simplify-pages T26): the rows at their
    /// least (a long title, its ⓘ, the arrows and the switch), the gap, the preview.
    static let rowsWidth: CGFloat = 372, gap: CGFloat = 18
    static let besideWidth = rowsWidth + gap + MenuRootPreview.width

    /// More's index (simplify-pages T15). A row added to or moved off a block changes its count here; Aliases and
    /// Quicklinks are a list each.
    static let entries = [
        MoreEntry(id: .menuExtras, symbol: "plus.rectangle.on.rectangle", controls: MenuRoot.extraRows.count),
        MoreEntry(id: .translate, symbol: "character.bubble", controls: 2),
        MoreEntry(id: .aliases, symbol: "character.textbox", controls: 1),
        MoreEntry(id: .quicklinks, symbol: "link", controls: 1),
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
                    MenuExtrasBlock(settings: .shared).moreBlock(.menuExtras)
                    if let settings { TranslateBlock(settings: settings).moreBlock(.translate) }
                    AliasesList(book: aliases, asked: editAlias, page: scroll).moreBlock(.aliases)
                    QuicklinksList(book: links).moreBlock(.quicklinks)
                }
            }
        default:
            // An ability's own settings go under it on Abilities (page map, Sven 2026-10-17). The preview stands beside
            // the rows only when both fit; narrower it goes, as a stacked one would push the rows past the window.
            KitPage(intro: Self.intro, info: Self.introInfo) {
                HStack(alignment: .top, spacing: Self.gap) {
                    MenuRootBlock(settings: .shared)
                    if wide { MenuRootPreview(settings: .shared) }
                }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width >= Self.besideWidth } action: { wide = $0 }
        }
    }
}
