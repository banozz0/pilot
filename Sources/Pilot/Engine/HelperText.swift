import Clipboard
import Foundation
import PilotCore

/// The clipboard's image text, read in pilot-text, a child that exits after each image (story 142): Vision's models and
/// buffers stayed in Pilot after its first image copy, about 60 MB of idle footprint (2026-10-11). Without the helper
/// beside the app (swift run, the tests) Vision reads here, as before.
struct HelperText: TextRecognizing {
    static let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/pilot-text")
    let helper: String

    /// The helper when the bundle holds it, else Vision in this process, said in the log.
    static let standard: any TextRecognizing = {
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return HelperText(helper: bundled.path) }
        cliplog.notice("pilot-text not in the bundle: image text is read in Pilot")
        return VisionText()
    }()

    func text(in image: Data) async -> String {
        await read(["text"], image) ?? ""
    }

    func boxes(of words: [String], in image: Data) async -> [CGRect] {
        guard !words.isEmpty, let out = await read(["boxes"] + words, image) else { return [] }
        return BoxLines.boxes(out)
    }

    func codes(in image: Data) async -> [String] {
        guard let out = await read(["codes"], image) else { return [] }
        return out.split(separator: "\n").compactMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) }
    }

    /// Nil, logged, when the helper fails. Five minutes before it is stopped: Vision compiles its model on the first image
    /// a new build reads, 60 to 85 s on 2026-10-11, and 0.4 s an image after that.
    private func read(_ arguments: [String], _ image: Data) async -> String? {
        do { return try await ChildProcess.run(helper, arguments, input: image, timeout: .seconds(300)) } catch {
            cliplog.error("pilot-text \(arguments.first ?? "", privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
