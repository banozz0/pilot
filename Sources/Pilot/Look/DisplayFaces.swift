import AppKit
import CoreText
import PilotCore

/// The themes' display faces (design round 4, pick 5; card agent-bo-95422890): OFL fonts bundled in Pilot.app's
/// Resources/Fonts/<file>/<file>.ttf with their licence beside them, registered for Pilot's process only at launch and
/// never installed on the Mac. A face is made from its file at the theme's weight and axes (Fraunces' SOFT, Recursive's
/// CASL), its optical size following the point size as a browser's auto does: the file is read once, each size made once.
@MainActor
enum DisplayFaces {
    /// Where the faces are: the bundle's Fonts; the tests point it at Packaging/Fonts.
    static var directory: URL? = Bundle.main.resourceURL?.appending(path: "Fonts")
    private static var made: [Made: NSFont] = [:]
    private struct Made: Hashable { let face: DisplayFace, size: CGFloat }
    /// Each file's first descriptor and the variation axes it has, read once.
    private static var files: [String: (descriptor: CTFontDescriptor, axes: Set<UInt32>)] = [:]

    static func url(_ face: DisplayFace) -> URL? { directory?.appending(path: "\(face.file)/\(face.file).ttf") }

    /// Registers every designed theme's face for this process, off the main thread so launch does not wait on a few MB of
    /// fonts (DisplayFaces.font reads the files itself, so nothing waits on this). The styles' faces (story 137) are read
    /// from their files only, never registered: a registered JetBrains Mono or Geist Mono would change the
    /// monospace fallback (Look.monoFont) on a Mac without them.
    static func registerInBackground() {
        let urls = PilotTheme.designed.compactMap { url($0.face) }
        Task.detached(priority: .utility) { _ = register(urls) }
    }

    /// Registers the designed faces; returns how many are available (registered now or before).
    @discardableResult
    static func register() -> Int { register(PilotTheme.designed.compactMap { url($0.face) }) }

    nonisolated private static func register(_ urls: [URL]) -> Int {
        urls.filter { url in
            let file = url.lastPathComponent
            guard FileManager.default.fileExists(atPath: url.path) else {
                looklog.error("display face \(file, privacy: .public): not in the app's Resources")
                return false
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Registered already (a second call) still counts: the face is there.
                let code = (error?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? 0
                guard code == CTFontManagerError.alreadyRegistered.rawValue else {
                    looklog.error("display face \(file, privacy: .public) not registered: \(code)")
                    return false
                }
            }
            return true
        }.count
    }

    /// `face` at `size` points (before the theme's scale); the system face when it is a plain theme's or its file is
    /// missing.
    static func font(_ face: DisplayFace, size: CGFloat) -> NSFont {
        let key = Made(face: face, size: size)
        if let font = made[key] { return font }
        let system = NSFont.systemFont(ofSize: size, weight: .semibold)
        guard !face.isSystem, let (first, available) = file(face) else { return system }
        var axes: [UInt32: Double] = [tag("wght"): Double(face.weight), tag("opsz"): Double(size), tag("WONK"): 0, tag("MONO"): 0]
        for (name, value) in face.axes { axes[tag(name)] = value }
        let variation = Dictionary(uniqueKeysWithValues: axes.filter { available.contains($0.key) }.map { (NSNumber(value: $0.key), NSNumber(value: $0.value)) })
        let descriptor = variation.isEmpty ? first
            : CTFontDescriptorCreateCopyWithAttributes(first, [kCTFontVariationAttribute: variation] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
        made[key] = font
        return font
    }

    private static func file(_ face: DisplayFace) -> (CTFontDescriptor, Set<UInt32>)? {
        if let known = files[face.file] { return known }
        guard let url = url(face), let first = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
        else { return nil }
        let axes = Set(((CTFontCopyVariationAxes(CTFontCreateWithFontDescriptor(first, 12, nil)) as? [[String: Any]]) ?? []).compactMap {
            ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value
        })
        files[face.file] = (first, axes)
        return (first, axes)
    }

    /// An OpenType axis tag as CoreText's number: "wght" is 0x77676874.
    static func tag(_ name: String) -> UInt32 { name.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}
