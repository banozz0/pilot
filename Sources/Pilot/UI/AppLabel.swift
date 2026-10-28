import PilotCore
import SwiftUI

extension AppsShowAs {
    /// Look's pick, read as a view draws, so every list follows a change at once.
    @MainActor static var current: AppsShowAs { Look.shared.appsShowAs }
}

/// An app as a list shows it (story 154): its icon and its name, or only one as Look's Apps show as says. Icon only keeps
/// the name as the tooltip and VoiceOver's label; Title only the name alone. The caller styles the title; the plain init
/// draws the app's own icon (else `symbol` on a tile) and the name on one line.
struct AppLabel<Icon: View, Title: View>: View {
    let name: String
    var spacing: CGFloat = 8
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title

    var body: some View {
        let shows = AppsShowAs.current.shows()
        HStack(spacing: spacing) {
            if shows.icon { icon }
            if shows.title { title }
        }
        .appTip(name, when: !shows.title)
        .accessibilityElement(children: .ignore).accessibilityLabel(name)
    }
}

extension AppLabel where Icon == AppGlyph, Title == Text {
    init(name: String, bundle: String?, size: CGFloat, symbol: String = "questionmark.app.dashed", spacing: CGFloat = 8) {
        self.init(name: name, spacing: spacing) {
            AppGlyph(bundles: bundle.map { [$0] } ?? [], symbol: symbol, size: size)
        } title: {
            Text(name)
        }
    }
}

extension View {
    /// The app's name as the tooltip while Icon only hides it from the row.
    @ViewBuilder func appTip(_ name: String, when hidden: Bool) -> some View {
        if hidden { help(name) } else { self }
    }
}

/// An app as a native menu's item shows it (story 154): its icon at the menu's 16 pt beside its name, the name alone under
/// Title only. Under Icon only the item keeps its name too: a menu has no hover to show it.
struct AppMenuItem: View {
    let name: String
    let bundle: String?

    var body: some View {
        if AppsShowAs.current != .title, let icon = bundle.flatMap(AppsModule.menuIcon(bundle:)) {
            Label { Text(name) } icon: { Image(nsImage: icon) }
        } else {
            Text(name)
        }
    }
}

/// A few apps in a small space, the top bar's workspaces and the dropdown's workspace tiles (story 154): their icons, or
/// under Title only their names on one line, up to ten icons wide. Icon and title keeps the icons: there is no room for a
/// name each, and the bar stays as it was.
struct CompactApps: View {
    let names: [String]
    var bundles: [String: String] = [:]
    var size: CGFloat = 15
    var spacing: CGFloat = 4

    var body: some View {
        if AppsShowAs.current == .title {
            Text(names.joined(separator: " · ")).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: size * 10)
        } else {
            HStack(spacing: spacing) { ForEach(names, id: \.self) { AppIcon(name: $0, bundle: bundles[$0], size: size) } }
                .help(names.joined(separator: ", "))
        }
    }
}
