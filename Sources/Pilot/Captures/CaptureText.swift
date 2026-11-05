import Clipboard
import CoreGraphics
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
        do { return try await read(image) } catch {
            PilotCapture.log.error("pilot-text lines: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Throws when the child fails or runs past five minutes: a failed read is not a read that found nothing.
    func read(_ image: Data) async throws -> [ReadLine] {
        ReadLines.parse(try await ChildProcess.run(helper, ["lines"], input: image, timeout: .seconds(300)))
    }

    /// `image`'s lines and codes, encoded and read off the main thread; nil when it could not be encoded or read (logged),
    /// so Redact never says "Nothing sensitive found" about text it never saw.
    static func read(_ image: CGImage, scale: CGFloat, with reader: any LineReading) async -> [ReadLine]? {
        guard let png = await PilotCapture.encoding(image, scale: scale).value else {
            PilotCapture.log.error("capture text: the picture could not be encoded")
            return nil
        }
        do { return try await reader.read(png) } catch {
            PilotCapture.log.error("capture text: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Capture subject's cutter (P72): the same child, so Vision never stays in Pilot either; Vision here without it.
    static let subjects: any SubjectCutting = {
        if FileManager.default.isExecutableFile(atPath: HelperText.bundled.path) { return CaptureText(helper: HelperText.bundled.path) }
        return VisionSubject()
    }()

    /// The edges a crop snaps to round the text read (C3): each line's box in `from` (document points; a read's boxes are
    /// fractions of the picture it read, from its top left), a few points out so a crop there never shaves a letter.
    static func edges(_ lines: [ReadLine], in from: CGRect) -> (xs: [CGFloat], ys: [CGFloat]) {
        let boxes = lines.map { line in
            CGRect(x: from.minX + line.box.minX * from.width, y: from.minY + line.box.minY * from.height,
                   width: line.box.width * from.width, height: line.box.height * from.height).insetBy(dx: -4, dy: -3)
        }
        return (boxes.flatMap { [$0.minX, $0.maxX] }, boxes.flatMap { [$0.minY, $0.maxY] })
    }

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
