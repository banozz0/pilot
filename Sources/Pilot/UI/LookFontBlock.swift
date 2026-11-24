import CoreText
import PilotCore
import SwiftUI

/// Look › Font (Sven, 2026-11-23: "one fonts setting for pilot. It should be in the look page"): Pilot's own words and mono,
/// each an installed family or the style's own. Pilot sets no other app's font; more fonts come from Install's search.
struct LookFontBlock: View {
    @Environment(\.ink) private var ink
    @Bindable var fonts: PilotFonts
    @State private var families = FontFamilies.shared

    init(fonts: PilotFonts = .shared) { self.fonts = fonts }

    static let info = "The font Pilot's own windows, panels and menus draw their words and mono in. Other apps keep their own font setting."

    var body: some View {
        KitBlock(title: AppSection.lookFont.title, symbol: "textformat") {
            InfoMark(text: Self.info)
        } content: {
            BlockRow(first: true) { row(.ui, "Words", standard: "Geist", offered: families.all) }
                .landingRing(PilotFonts.Part.ui.rawValue)
            BlockRow { row(.mono, "Mono", standard: ink.isInstrument ? "Geist Mono" : "JetBrains Mono", offered: families.mono) }
                .landingRing(PilotFonts.Part.mono.rawValue)
        }
        .task { await families.load() }
    }

    /// One of Pilot's two: its name, and the installed families (the fixed-pitch ones for mono), the style's own first; the
    /// family in use stays listed even when it is not installed or not fixed-pitch.
    @ViewBuilder private func row(_ part: PilotFonts.Part, _ name: String, standard: String, offered: [String]) -> some View {
        let picked = fonts.family(part)
        let listed = picked.map { offered.contains($0) ? offered : [$0] + offered } ?? offered
        Text(name)
        Spacer()
        DropdownField(label: "Pilot \(name.lowercased()) font",
                      options: [(String?.none, "Style's own (\(standard))")] + listed.map { (Optional($0), $0) },
                      picked: picked) { try? fonts.set(part, $0) }
            .frame(width: 240)
    }
}

/// The font families Look › Font offers, read off the main thread once a run (the two lists side by side), and again only
/// after fonts are added or removed (Install's fonts, say), so showing Look again reads nothing.
@Observable @MainActor
final class FontFamilies {
    static let shared = FontFamilies()

    private(set) var all: [String] = []
    private(set) var mono: [String] = []
    @ObservationIgnored private var loaded = false

    private init() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
                                               object: nil, queue: .main) { _ in MainActor.assumeIsolated { FontFamilies.shared.loaded = false } }
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        async let all = Task.detached { InstalledFonts.families() }.value
        async let mono = Task.detached { InstalledFonts.monoFamilies() }.value
        (self.all, self.mono) = await (all, mono)
    }
}
