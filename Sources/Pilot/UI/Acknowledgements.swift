import Foundation
import SwiftUI

/// One third-party piece Pilot bundles or downloads, as General › About's Acknowledgements lists it (SH10): its name, its
/// licence's name, what Pilot uses it for and the files holding its full text, which Scripts/build-app.sh copies into
/// Contents/Resources. A courtesy credit (no code of it in Pilot) has no files.
struct Acknowledgement: Identifiable, Hashable {
    let name: String
    let licence: String
    let what: String
    /// Its texts, relative to `directory`.
    var files: [String] = []
    var id: String { name }

    /// Where the texts are: the bundle's Resources; the renders point it at Packaging.
    @MainActor static var directory: URL? = Bundle.main.resourceURL

    /// The themes' display faces, each folder holding its face and the OFL beside it (DisplayFaces).
    static let faces = ["BricolageGrotesque", "Fraunces", "Fredoka", "Geist", "GeistMono", "InstrumentSerif", "JetBrainsMono",
                        "Nunito", "Recursive", "Syne", "Unbounded", "YoungSerif"]

    /// Bundled first, then the models Pilot downloads on a click, then the courtesy credit.
    static let known: [Acknowledgement] = [
        .init(name: "AeroSpace", licence: "MIT", what: "Pilot's tiler is ported from it", files: ["AeroSpace-LICENSE.txt"]),
        .init(name: "Cardinal", licence: "MIT", what: "The file index's engine", files: ["Cardinal-LICENSE.txt", "Cardinal-NOTICE.txt"]),
        .init(name: "Rust crates", licence: "MIT, Apache 2.0 and others", what: "The file index's libraries",
              files: ["Rust-crates-LICENSES.txt"]),
        .init(name: "Ghostty", licence: "MIT and others", what: "The terminal in bar drops",
              files: ["Ghostty-LICENSE.txt", "Ghostty-THIRD-PARTY.txt"]),
        .init(name: "WhisperKit", licence: "MIT", what: "Runs Whisper for dictation", files: ["WhisperKit-LICENSE.txt", "WhisperKit-NOTICES.txt"]),
        .init(name: "FluidAudio", licence: "Apache 2.0", what: "Runs Parakeet and the Kokoro voices",
              files: ["FluidAudio-LICENSE.txt", "FluidAudio-NOTICES.txt"]),
        .init(name: "Real-ESRGAN", licence: "BSD 3-Clause", what: "The upscaler's built-in model", files: ["Real-ESRGAN-LICENSE.txt"]),
        .init(name: "Omarchy", licence: "MIT", what: "The themes' colours", files: ["Omarchy-LICENSE.txt"]),
        .init(name: "gemoji", licence: "MIT", what: "Emoji names and keywords", files: ["gemoji-LICENSE.txt"]),
        .init(name: "Snapzy", licence: "BSD 3-Clause", what: "The capture editor's backdrop, capture history and Combine images", files: ["Snapzy-LICENSE.txt"]),
        .init(name: "NotificationNanny", licence: "MIT", what: "How notifications are read from Notification Center", files: ["NotificationNanny-LICENSE.txt"]),
        .init(name: "CodexBar", licence: "MIT", what: "The Claude mark on extension gauges", files: ["CodexBar-LICENSE.txt"]),
        .init(name: "Sparkle", licence: "MIT and others", what: "Pilot's updates", files: ["Sparkle-LICENSE.txt"]),
        .init(name: "Display fonts", licence: "SIL OFL 1.1", what: "The themes' twelve faces", files: faces.map { "Fonts/\($0)/OFL.txt" }),
        .init(name: "Whisper", licence: "MIT", what: "OpenAI's speech models, downloaded on your click", files: ["Whisper-LICENSE.txt"]),
        .init(name: "Parakeet Ultra", licence: "CC BY 4.0", what: "Moondream's speech model on NVIDIA's Parakeet, downloaded on your click",
              files: ["Parakeet-LICENSE.txt"]),
        .init(name: "Kokoro-82M", licence: "Apache 2.0", what: "hexgrad's voices, downloaded on your click", files: ["Kokoro-LICENSE.txt"]),
        .init(name: "RealESRGAN x4plus", licence: "BSD 3-Clause", what: "The larger upscaler, downloaded on your click",
              files: ["RealESRGAN-CoreML-LICENSE.txt"]),
        .init(name: "Maccy", licence: "MIT", what: "The reference for clipboard history"),
    ]

    /// `known`, then a row for each licence or notice file in `directory` no entry names, so a notice added to the bundle
    /// is never left unseen.
    static func list(in directory: URL?) -> [Acknowledgement] {
        let named = Set(known.flatMap(\.files))
        let files = directory.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        let rest = files.filter { file in
            !named.contains(file) && ["-LICENSE.txt", "-LICENSES.txt", "-NOTICE.txt", "-NOTICES.txt"].contains { file.hasSuffix($0) }
        }
        return known + rest.sorted().map { Acknowledgement(name: String($0.prefix { $0 != "-" }), licence: "Licence", what: "Bundled", files: [$0]) }
    }

    /// Its texts, each under its file's name when there are several; nil when this build holds none of them.
    func text(in directory: URL?) -> String? {
        let texts = files.compactMap { file in
            directory.flatMap { try? String(contentsOf: $0.appending(path: file), encoding: .utf8) }.map { (file, $0) }
        }
        guard !texts.isEmpty else { return nil }
        if files.count == 1 { return texts[0].1 }
        return texts.map { "──── \($0.0) ────\n\n\($0.1)" }.joined(separator: "\n\n")
    }
}

/// One acknowledgement's full licence text in a sheet over the window, selectable, with Done. The text is read once and
/// laid out a paragraph at a time as it scrolls: the Rust crates' and Ghostty's run to thousands of lines.
struct LicenceSheet: View {
    @Environment(\.ink) private var ink
    @Environment(\.dismiss) private var dismiss
    let entry: Acknowledgement
    @State private var paragraphs: [String]

    init(entry: Acknowledgement, directory: URL? = Acknowledgement.directory) {
        self.entry = entry
        let text = entry.text(in: directory) ?? "This build holds no copy of the text; Pilot.app carries it in Contents/Resources."
        _paragraphs = State(initialValue: text.components(separatedBy: "\n\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TitledText(title: Text(entry.name).font(ink.ui(15, .semibold)), detail: "\(entry.what) · \(entry.licence)")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(paragraphs.indices, id: \.self) { i in
                        Text(paragraphs[i] + "\n").font(ink.mono(11.5)).foregroundStyle(ink.text2).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .background(ink.raised, in: .rect(cornerRadius: 8))
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(18)
        .frame(width: 620, height: 520)
    }
}
