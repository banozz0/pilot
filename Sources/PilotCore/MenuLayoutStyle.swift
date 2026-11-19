import Foundation

/// How the Hyper+Space menu draws: Line, Instrument's one menu (Q165; spec vault Projects/Pilot/specs/menu-morph.html), or
/// Classic, which only Toybox's own menu (ToyMenu) still sizes itself by. The Rail and Classic as looks to pick went in the
/// feature trim (2026-11-19). Not `MenuLayout`, which holds the branch rows.
public enum MenuLayoutStyle: String, CaseIterable, Sendable {
    /// Classic's root, 431 wide, that grows into a 750 search on the first key; the search line completes and answers, the
    /// kinds sit in the foot (story 193).
    case line
    /// Toybox's: the menu sized as Omarchy's list.
    case classic
}
