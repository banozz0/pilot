import Foundation

/// How Hyper+Space draws the menu (menu Rail and Classic, Sven 2026-10-12; Line the default since Q165, 2026-10-16): picked
/// on Look as Hyper+Space menu. Only the drawing changes; the navigator, keys and rows are the same model. Not
/// `MenuLayout`, which holds the branch rows.
public enum MenuLayoutStyle: String, CaseIterable, Sendable {
    /// The default (Q165): Classic's root, 431 wide, that grows into a 750 search on the first key; the search line
    /// completes and answers, the kinds sit in the foot (story 193; spec vault Projects/Pilot/specs/menu-morph.html).
    case line
    /// Omarchy's list, in JetBrains Mono (the default from Q134 to Q165).
    case classic
    /// The kinds in a rail beside the hits, each with its count.
    case rail

    public var title: String {
        switch self {
        case .rail: "Rail"
        case .classic: "Classic"
        case .line: "Line"
        }
    }

    /// A saved name, or Line for none or an unknown one.
    public init(saved: String?) { self = saved.flatMap(MenuLayoutStyle.init(rawValue:)) ?? .line }
}
