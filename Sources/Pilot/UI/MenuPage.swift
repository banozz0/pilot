import PilotCore
import SwiftUI

/// Launcher (C3, Sven 2026-10-10, design Wa6fPGPUhV2VcmJ4vGXZQ5; titled Menu until the page map, Sven 2026-10-17):
/// everything Hyper+Space shows, on one page with its tabs. Your menu is the root's rows (MenuRootBlock, story 152), the
/// extra rows it can list after them (MenuExtrasBlock, Sven 2026-10-20) and
/// Translate's pair (TranslateBlock, from System's Keyboard layout card); Abilities every ability Pilot has
/// (AbilitiesList, story 155, was Binds › Abilities), with Folders and Passwords (story 160) under the abilities they
/// configure since the page map; Aliases and Quicklinks were Defaults' blocks. File search went on to the Files page
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

    static let intro = "Hyper+Space: the rows it lists first, what Translate turns words into, everything Pilot can do, aliases and quicklinks."

    var body: some View {
        switch section {
        case .abilities: AbilitiesList(search: search, setKey: editBind)
        case .aliases: ScrollViewReader { scroll in KitPage { AliasesList(book: aliases, asked: editAlias, page: scroll) } }
        case .quicklinks: KitPage { QuicklinksList(book: links) }
        default:
            // An ability's own settings go under it on Abilities (page map, Sven 2026-10-17); a block for the menu as a
            // whole goes under Translate.
            KitPage(intro: Self.intro) {
                MenuRootBlock(settings: .shared)
                MenuExtrasBlock(settings: .shared)
                if let settings = engine?.settings { TranslateBlock(settings: settings) }
            }
        }
    }
}
