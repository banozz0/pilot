import PilotCore
import SwiftUI

/// Apps › Fonts (Sven, 2026-11-01: "for fonts i think its better to have its own page under configs in apps ... also offer
/// more fonts to download from install catalogue"): Use fonts in, moved off Install, and a link to Install's Fonts
/// category, where the font installs stay with every other install.
struct FontsPage: View {
    var fonts: PilotFonts = .shared
    var places: FontPlaces = .standard
    var installed: @MainActor (FontPlace) -> Bool = FontUse.installed
    /// Opens Install's catalogue on its Fonts category.
    var getMore: () -> Void = {}

    static let intro = "macOS has no system-wide font, so Pilot sets it in each app's own settings."
    /// The intro's ⓘ: the apps Pilot writes a font into, in Use fonts in's order, and that the rest keep their own.
    static var introInfo: String {
        let apps = FontPlace.known.map(\.app).reduce(into: ["Pilot"]) { if !$0.contains($1) { $0.append($1) } }
        return "Pilot sets it in: \(ListFormatter.localizedString(byJoining: apps)). Other apps keep their own font setting."
    }

    var body: some View {
        KitPage(intro: Self.intro, info: Self.introInfo) {
            FontUseBlock(fonts: fonts, places: places, installed: installed)
            KitBlock(title: "Get more fonts", symbol: "arrow.down.circle") {
                BlockRow(first: true) {
                    HStack(spacing: 10) {
                        FinePrint(text: "Coding and interface fonts, with Nerd Font versions for terminals, in Install's catalogue.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Open in Install", action: getMore).buttonStyle(.pilot)
                    }
                }
            }
        }
    }
}
