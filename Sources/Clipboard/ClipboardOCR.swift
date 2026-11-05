// Written from scratch for Pilot (card agent-bo-95423070); Raycast's and SuperCmd's image text are the behaviour reference.
import Foundation
import os
import Vision

/// Reads the text in an image: Apple's Vision in the app, a fake in tests.
public protocol TextRecognizing: Sendable {
    /// The image's lines, top to bottom, joined by new lines; empty when it holds none or cannot be read.
    func text(in image: Data) async -> String
    /// Where each of `words` is written in the image, ignoring case: boxes 0 to 1, origin top left. Read again for
    /// the previewed image only, so the store keeps no boxes.
    func boxes(of words: [String], in image: Data) async -> [CGRect]
    /// The QR codes' payloads in the image; none when it holds none. Only codes are looked for, which is cheap enough for
    /// the one previewed copy (Sven, Q398).
    func codes(in image: Data) async -> [String]
}

extension TextRecognizing {
    public func codes(in image: Data) async -> [String] { [] }
}

/// Vision's on-device text recognition, accurate, with language correction and the language detected: no network.
public struct VisionText: TextRecognizing {
    public init() {}

    public func text(in image: Data) async -> String {
        await lines(in: image).map(\.string).joined(separator: "\n")
    }

    public func boxes(of words: [String], in image: Data) async -> [CGRect] {
        guard !words.isEmpty else { return [] }
        return await lines(in: image).flatMap { line in
            words.flatMap { word in
                var boxes: [CGRect] = []
                var start = line.string.startIndex
                while let range = line.string.range(of: word, options: .caseInsensitive, range: start..<line.string.endIndex) {
                    if let box = line.boundingBox(for: range)?.boundingBox.verticallyFlipped() {
                        boxes.append(CGRect(origin: box.origin, size: CGSize(width: box.width, height: box.height)))
                    }
                    start = range.upperBound
                }
                return boxes
            }
        }
    }

    public func codes(in image: Data) async -> [String] {
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        return ((try? await request.perform(on: image)) ?? []).compactMap(\.payloadString).filter { !$0.isEmpty }
    }

    /// The image's lines, top to bottom, each its best reading; none when it cannot be read.
    private func lines(in image: Data) async -> [RecognizedText] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        return ((try? await request.perform(on: image)) ?? []).compactMap { $0.topCandidates(1).first }
    }
}

/// The boxes as pilot-text prints them, `x y width height` a line, and back; a line that is not four numbers is skipped.
public enum BoxLines {
    public static func text(_ boxes: [CGRect]) -> String {
        boxes.map { "\($0.minX) \($0.minY) \($0.width) \($0.height)\n" }.joined()
    }

    public static func boxes(_ text: String) -> [CGRect] {
        text.split(separator: "\n").compactMap { line in
            let n = line.split(separator: " ").compactMap { Double($0) }
            return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
        }
    }
}

/// Reads each image copy once, after it is stored and at launch for older ones, so the search finds its words and a
/// plain paste writes them. One image at a time, off the main thread; the store is written on the main actor.
@MainActor
public final class ClipboardOCR {
    private let store: ClipboardStore
    private let recognizer: any TextRecognizing
    private var running = false
    private var again = false
    /// After each image's text is stored: the open panel lists it then, not at the next keystroke. The first image a new
    /// build reads takes Vision about a minute (Sven, build 31: a screenshot searched for at once never showed up).
    public var onRead: (() -> Void)?

    public init(store: ClipboardStore, recognizer: any TextRecognizing = VisionText()) {
        self.store = store
        self.recognizer = recognizer
    }

    /// Starts reading the unread images; a call while it reads makes it look again once it is done.
    public func catchUp() {
        guard !running else { again = true; return }
        running = true
        Task(priority: .utility) {
            repeat {
                again = false
                await read()
            } while again
            running = false
        }
    }

    /// Reads every image unread when it starts, newest first, and returns how many it read. An image with no PNG or
    /// TIFF is marked read with no text.
    @discardableResult
    public func read() async -> Int {
        let ids: [Int64]
        do { ids = try store.unreadImages() } catch {
            clipLog.error("clipboard ocr list: \(String(describing: error), privacy: .public)")
            return 0
        }
        for id in ids {
            let data = try? store.image(of: id)
            let text = if let data { await recognizer.text(in: data) } else { "" }
            do {
                try store.setRecognised(id, text)
                clipLog.info("clipboard ocr id=\(id, privacy: .public) chars=\(text.count, privacy: .public)")
                onRead?()
            } catch {
                clipLog.error("clipboard ocr id=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return ids.count
    }
}

/// One line of text, or one code, read from an image (capture spec CP8): its words and where they are, 0 to 1 with the
/// origin at the top left; `code` for a QR or other barcode's payload. `words` holds each of the text's
/// whitespace-separated words' boxes in order, so a match inside the line can be covered alone (auto-redact).
public struct ReadLine: Codable, Equatable, Sendable {
    public let text: String
    public let box: CGRect
    public let code: Bool
    public let words: [CGRect]?

    public init(text: String, box: CGRect, code: Bool = false, words: [CGRect]? = nil) {
        self.text = text
        self.box = box
        self.code = code
        self.words = words
    }
}

/// Reads an image's lines with their boxes, and its codes: Vision in pilot-text, Vision here, a fake in tests.
public protocol LineReading: Sendable {
    func lines(in image: Data) async -> [ReadLine]
    /// The same read, throwing when the image could not be read at all, so a caller can tell a failed read from no text.
    func read(_ image: Data) async throws -> [ReadLine]
}

extension LineReading {
    public func read(_ image: Data) async throws -> [ReadLine] { await lines(in: image) }
}

extension VisionText: LineReading {
    /// Every line, top to bottom, then every code; none when the image cannot be read.
    public func lines(in image: Data) async -> [ReadLine] { (try? await read(image)) ?? [] }

    /// Every line, then every code; throws when Vision cannot read the image, so a failure is not "no text".
    public func read(_ image: Data) async throws -> [ReadLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let text = try await request.perform(on: image).compactMap { observation -> ReadLine? in
            guard let best = observation.topCandidates(1).first else { return nil }
            // Each word's own box, or none when Vision cannot place one: the boxes must line up with the words.
            var words: [CGRect]? = []
            for range in ReadLine.wordRanges(best.string) {
                guard let word = best.boundingBox(for: range) else { words = nil; break }
                words?.append(Self.rect(word.boundingBox.verticallyFlipped()))
            }
            return ReadLine(text: best.string, box: Self.rect(observation.boundingBox.verticallyFlipped()), words: words)
        }
        let codes = try await DetectBarcodesRequest().perform(on: image).compactMap { code -> ReadLine? in
            guard let payload = code.payloadString, !payload.isEmpty else { return nil }
            return ReadLine(text: payload, box: Self.rect(code.boundingBox.verticallyFlipped()), code: true)
        }
        return text + codes
    }

    private static func rect(_ r: NormalizedRect) -> CGRect { CGRect(origin: r.origin, size: CGSize(width: r.width, height: r.height)) }
}

/// The lines as pilot-text prints them, one JSON object a line, and back; and as copied: the words line by line, then
/// each code's payload.
public enum ReadLines {
    public static func json(_ lines: [ReadLine]) -> String {
        lines.compactMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }.map { $0 + "\n" }.joined()
    }

    public static func parse(_ text: String) -> [ReadLine] {
        text.split(separator: "\n").compactMap { try? JSONDecoder().decode(ReadLine.self, from: Data($0.utf8)) }
    }

    public static func copied(_ lines: [ReadLine]) -> String {
        (lines.filter { !$0.code } + lines.filter(\.code)).map(\.text).joined(separator: "\n")
    }
}
