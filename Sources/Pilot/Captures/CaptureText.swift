import Clipboard
import Foundation
import PilotCore

/// The capture's text (spec `capture.html` CP8): its lines with their boxes and its QR codes, read in pilot-text, a
/// child that exits after each image, so Vision never stays in Pilot (story 142); Vision here without the helper (swift
/// run, the tests).
struct CaptureText: LineReading {
    let helper: String

    static let standard: any LineReading = {
        if FileManager.default.isExecutableFile(atPath: HelperText.bundled.path) { return CaptureText(helper: HelperText.bundled.path) }
        return VisionText()
    }()

    func lines(in image: Data) async -> [ReadLine] {
        do { return ReadLines.parse(try await ChildProcess.run(helper, ["lines"], input: image, timeout: .seconds(300))) } catch {
            PilotCapture.log.error("pilot-text lines: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Capture subject's cutter (P72): the same child, so Vision never stays in Pilot either; Vision here without it.
    static let subjects: any SubjectCutting = {
        if FileManager.default.isExecutableFile(atPath: HelperText.bundled.path) { return CaptureText(helper: HelperText.bundled.path) }
        return VisionSubject()
    }()

    /// What a read says in one line: how many lines went on the pasteboard and the first of them.
    static func said(_ lines: [ReadLine]) -> String {
        guard let first = lines.first(where: { !$0.code }) ?? lines.first else { return "No text found." }
        let count = lines.count
        let what = lines.allSatisfy(\.code) ? (count == 1 ? "1 code" : "\(count) codes") : (count == 1 ? "1 line" : "\(count) lines")
        return "Copied \(what): “\(first.text.count > 60 ? String(first.text.prefix(59)) + "…" : first.text)”"
    }
}

extension CaptureText: SubjectCutting {
    /// Nil when the child found no subject (it exits 1) or failed, logged; the same five minutes as a read, for the
    /// model a new build compiles first.
    func subject(in png: Data) async -> Data? {
        do { return try await ChildProcess.data(helper, ["subject"], input: png, timeout: .seconds(300)) } catch {
            PilotCapture.log.notice("pilot-text subject: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
