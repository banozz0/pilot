import CoreText
import Foundation
import Observation
import SwiftUI
import PilotCore

/// Pilot's own two fonts (Sven, Q711: "in pilot ... use fonts that i want"): its words and its mono, each an installed
/// family or nil for the style's own (Geist and Geist Mono in Instrument, Nunito and JetBrains Mono in Toybox). Ink and
/// Theme.mono read them as they draw, so every page follows at once; `pilot get|set fonts.ui|fonts.mono` reach them.
@Observable @MainActor
final class PilotFonts {
    static let shared = PilotFonts()

    private(set) var ui: String? { didSet { save(ui, Part.ui.rawValue) } }
    private(set) var mono: String? { didSet { save(mono, Part.mono.rawValue) } }

    @ObservationIgnored private let defaults: UserDefaults

    /// Each one's defaults key, which is its setting's too.
    enum Part: String { case ui = "fonts.ui", mono = "fonts.mono" }

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        ui = defaults.string(forKey: Part.ui.rawValue)
        mono = defaults.string(forKey: Part.mono.rawValue)
    }

    /// Sets one, nil for the style's own; a family not installed is refused, so nothing draws in a fallback face. Mono takes
    /// any family here, as the command may; Use fonts in offers it the fixed-pitch ones.
    func set(_ part: Part, _ family: String?) throws(FontProblem) {
        let installed = try family.map { family throws(FontProblem) in
            guard let match = InstalledFonts.match(family) else { throw .badFamily }
            return match
        }
        switch part {
        case .ui: ui = installed
        case .mono: mono = installed
        }
    }

    func family(_ part: Part) -> String? { part == .ui ? ui : mono }

    /// The picked family as a face at `size` (fixed, as the styles' own faces are); nil draws the style's own.
    func face(_ part: Part, _ size: CGFloat, _ weight: Font.Weight) -> Font? {
        family(part).map { .custom($0, fixedSize: size).weight(weight) }
    }

    private func save(_ value: String?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// The font families on this Mac, from CoreText, which any thread may ask: Use fonts in reads them off the main thread as
/// it shows; the fixed-pitch ones for terminals, editors and Pilot's mono.
enum InstalledFonts {
    static func families() -> [String] {
        ((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// The families with a monospaced face: one CoreText match on the trait, not a look at every face (seconds, cold).
    static func monoFamilies() -> [String] {
        let mono = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitMonoSpace.rawValue]] as CFDictionary)
        let found = (CTFontDescriptorCreateMatchingFontDescriptors(mono, NSSet(array: [kCTFontTraitsAttribute]) as CFSet) as? [CTFontDescriptor]) ?? []
        return Set(found.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }).filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The installed family a name means, any case; nil when none is.
    static func match(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        return families().first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}
