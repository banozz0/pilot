import AppKit
import AVFoundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import PilotCore

/// Convert (card agent-bo-95423210): a file turned into another format beside it, on the Mac. Fixtures are made here,
/// into a fresh temporary folder per test; ffmpeg and cwebp run only where they are installed, a fake stands in for
/// the cancel and the missing-tool cases.
@Suite("Convert")
final class ConvertTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "pilot-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    static let installed = Converter.installed()
    static let none = Converter(tools: [:])

    func offered(_ names: String...) -> [ConvertFormat] { Self.none.options(for: names.map { URL(filePath: "/x/\($0)") }).map(\.format) }

    // MARK: what each file offers

    @Test("Each kind of file offers its formats, never the one it is already in")
    func offers() throws {
        #expect(offered("a.png") == [.jpg, .heic, .webp, .pdf])
        #expect(offered("a.JPEG") == [.png, .heic, .webp, .pdf], "jpeg is JPG, whatever the case")
        #expect(offered("a.pdf") == [.png, .jpg, .heic, .webp, .txt, .rtf, .docx, .html])
        #expect(offered("a.mov") == [.mp4, .m4a, .mp3, .gif])
        #expect(offered("a.wav") == [.m4a, .mp3])
        #expect(offered("a.docx") == [.rtf, .txt, .html, .pdf])
        #expect(offered("a.htm") == [.docx, .rtf, .txt, .pdf])
        #expect(offered("a.zip").isEmpty)
        #expect(offered("folder").isEmpty)
    }

    @Test("The Files page's list (Sven 2026-10-10) names every kind with what a file of it offers, and every format once at least")
    func catalogue() {
        #expect(Convert.catalogue.map(\.kind) == ["Pictures", "PDFs", "Video", "Sound", "Documents"])
        // A file of each kind in no format Convert writes, so it is offered the kind's whole list.
        let samples = ["a.tiff", "a.pdf", "a.m4v", "a.aiff", "a.odt"]
        for (row, file) in zip(Convert.catalogue, samples) { #expect(Set(row.to) == Set(offered(file)), "\(row.kind)") }
        #expect(Set(Convert.catalogue.flatMap(\.to)) == Set(ConvertFormat.allCases))
    }

    @Test("Several files offer the formats they share; one already in a format still offers it to the others")
    func shared() {
        #expect(offered("a.png", "b.jpg") == [.png, .jpg, .heic, .webp, .pdf])
        #expect(offered("a.png", "b.jpg", "c.txt") == [.pdf], "an image and a text share PDF")
        #expect(offered("a.png", "c.wav").isEmpty, "an image and a sound share nothing")
        #expect(offered("a.png", "b.png") == [.jpg, .heic, .webp, .pdf])
    }

    @Test("MP3, a video's GIF and WebP name the tool they need when it is missing, and nothing runs")
    func missingTool() async throws {
        let none = Self.none
        let options = none.options(for: [URL(filePath: "/x/a.mov")])
        #expect(options.first { $0.format == .mp3 }?.needs == .ffmpeg)
        #expect(options.first { $0.format == .gif }?.needs == .ffmpeg)
        #expect(options.first { $0.format == .mp4 }?.needs == nil)
        #expect(none.options(for: [URL(filePath: "/x/a.png")]).first { $0.format == .webp }?.needs == .cwebp)
        #expect(ConvertTool.ffmpeg.formula == "ffmpeg")
        #expect(ConvertTool.cwebp.formula == "webp")
        let source = try Fixture.audio(in: dir)
        await #expect(throws: ConvertError.needs(.ffmpeg)) { try await none.convert(source, to: .mp3) }
        let video = try await Fixture.video(in: dir, sound: source)
        await #expect(throws: ConvertError.needs(.ffmpeg)) { try await none.convert(video, to: .gif) }
        let png = try Fixture.png(in: dir)
        await #expect(throws: ConvertError.needs(.cwebp)) { try await none.convert(png, to: .webp) }
        #expect(String(describing: ConvertError.needs(.cwebp)) == "needs webp", "the formula, as the row says")
        #expect(try contents() == ["clip.mov", "pixel.png", "tone.wav"], "nothing written")
    }

    // MARK: naming

    @Test("The output is name.ext beside the original; the next is name 2.ext, never over an existing file")
    func naming() async throws {
        let png = try Fixture.png(in: dir)
        let none = Self.none
        let first = try await none.convert(png, to: .jpg)
        #expect(first == dir.appending(path: "pixel.jpg"))
        let firstData = try Data(contentsOf: first)
        let second = try await none.convert(png, to: .jpg)
        #expect(second == dir.appending(path: "pixel 2.jpg"))
        #expect(try Data(contentsOf: first) == firstData, "the first is untouched")
        let third = try await none.convert(png, to: .jpg)
        #expect(third.lastPathComponent == "pixel 3.jpg")
        #expect(Convert.freeName(for: URL(filePath: "/x/a.b.png"), as: .pdf) { _ in false }.path == "/x/a.b.pdf")
        #expect(try contents() == ["pixel 2.jpg", "pixel 3.jpg", "pixel.jpg", "pixel.png"], "no scratch left beside them")
    }

    @Test("A file already in the format is refused, not copied")
    func same() async throws {
        let png = try Fixture.png(in: dir)
        await #expect(throws: ConvertError.self) { try await Self.none.convert(png, to: .png) }
        #expect(try contents() == ["pixel.png"])
    }

    // MARK: cancel

    @Test("Cancelling a job stops its tool and leaves no output")
    func cancel() async throws {
        let fake = dir.appending(path: "tools/ffmpeg")
        try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Writes a partial output, as ffmpeg does, then hangs.
        try "#!/bin/sh\nfor a; do out=\"$a\"; done\necho partial > \"$out\"\nsleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let source = try Fixture.audio(in: dir)
        let converter = Converter(tools: [.ffmpeg: fake.path])
        let started = ContinuousClock.now
        let job = Task { try await converter.convert(source, to: .mp3) }
        try await Task.sleep(for: .milliseconds(500))
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(ContinuousClock.now - started < .seconds(10), "the tool was stopped, not waited out")
        #expect(try contents() == ["tone.wav", "tools"], "no partial output, no scratch")
    }

    // MARK: the format matrix

    @Test("Every image pair converts to a file that reads back as its format")
    func images() async throws {
        let sources = [try Fixture.png(in: dir), try Fixture.image(.jpeg, "photo.jpg", in: dir),
                       try Fixture.image(.heic, "photo.heic", in: dir), try Fixture.image(.gif, "still.gif", in: dir),
                       try Fixture.image(.pdf, "scan.pdf", in: dir)]
        try await matrix(sources, kinds: [.png, .jpg, .heic, .webp, .pdf])
    }

    @Test("A transparent PNG turns into a JPG on white, not black")
    func jpgOnWhite() async throws {
        let jpg = try await Self.none.convert(try Fixture.png(in: dir), to: .jpg)
        let image = try #require(CGImageSourceCreateWithURL(jpg as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let rep = NSBitmapImageRep(cgImage: image)
        let corner = try #require(rep.colorAt(x: rep.pixelsWide - 1, y: 0)?.usingColorSpace(.sRGB))
        #expect(corner.brightnessComponent > 0.9, "the transparent half is white")
    }

    @Test("A phone photo stored sideways comes out upright, as its EXIF orientation says")
    func upright() async throws {
        let url = dir.appending(path: "sideways.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, Fixture.picture(), [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let png = try await Self.none.convert(url, to: .png)
        let image = try #require(CGImageSourceCreateWithURL(png as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect((image.width, image.height) == (30, 40), "40 by 30 turned a quarter")
    }

    @Test("Every audio and video pair converts to a file that reads back as its format")
    func media() async throws {
        let audio = try Fixture.audio(in: dir)
        let video = try await Fixture.video(in: dir, sound: audio)
        try await matrix([video, audio], kinds: [.mp4, .mov, .m4a, .mp3, .gif])
        try await matrix([dir.appending(path: "clip.mp4")], kinds: [.mov])
    }

    @Test("Every document pair converts to a file that reads back as its format, the text kept")
    func documents() async throws {
        let text = "Pilot converts this line."
        let sources = [try Fixture.write(text, "note.txt", in: dir),
                       try Fixture.write("<html><body><p>\(text)</p></body></html>", "page.html", in: dir),
                       try Fixture.attributed(text, .rtf, "letter.rtf", in: dir),
                       try Fixture.attributed(text, .officeOpenXML, "report.docx", in: dir),
                       try Fixture.textPDF(text, in: dir)]
        try await matrix(sources, kinds: [.docx, .rtf, .txt, .html, .pdf], text: text)
    }

    /// Converts each source to each of its formats in `kinds` the installed tools allow, and reads each output back.
    func matrix(_ sources: [URL], kinds: Set<ConvertFormat>, text: String? = nil) async throws {
        let converter = Self.installed
        var done = 0
        for source in sources {
            for option in converter.options(for: [source]) where kinds.contains(option.format) && option.needs == nil {
                let out = try await converter.convert(source, to: option.format)
                #expect(out.pathExtension == option.format.rawValue)
                #expect(try await Fixture.reads(out, as: option.format, text: text), "\(source.lastPathComponent) → \(option.format.title)")
                done += 1
            }
        }
        #expect(done >= sources.count, "every source converted at least once")
    }

    func contents() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }
}

/// Small files made for the tests: a 40 by 30 picture half transparent, a second of tone, a second of video with it.
enum Fixture {
    static func picture() -> CGImage {
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        return ctx.makeImage()!
    }

    static func image(_ type: UTType, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, picture(), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    static func png(in dir: URL) throws -> URL { try image(.png, "pixel.png", in: dir) }

    static func write(_ text: String, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func attributed(_ text: String, _ type: NSAttributedString.DocumentType, _ name: String, in dir: URL) throws -> URL {
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let url = dir.appending(path: name)
        try string.data(from: NSRange(location: 0, length: string.length), documentAttributes: [.documentType: type]).write(to: url)
        return url
    }

    static func textPDF(_ text: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: "printed.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        ctx.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    /// A second of 440 Hz, 16-bit WAV.
    static func audio(in dir: URL) throws -> URL {
        let url = dir.appending(path: "tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
                                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        for i in 0..<44_100 { buffer.floatChannelData![0][i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / 44_100) }
        try file.write(from: buffer)
        return url
    }

    /// A second of 64 by 48 H.264 at 10 frames a second, the tone as its sound, in a MOV.
    static func video(in dir: URL, sound: URL) async throws -> URL {
        let silent = dir.appending(path: "silent.mov")
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32ARGB, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 25), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        // The picture and the tone side by side in one movie.
        let composition = AVMutableComposition()
        for (url, type) in [(silent, AVMediaType.video), (sound, .audio)] {
            // The asset held: a track whose asset is freed does not insert.
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: type).first)
            try composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
        }
        let url = dir.appending(path: "clip.mov")
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: url, as: .mov)
        try FileManager.default.removeItem(at: silent)
        return url
    }

    /// Whether `url` reads back as `format`: its type sniffed from the bytes, its tracks, its pages, its text.
    static func reads(_ url: URL, as format: ConvertFormat, text: String?) async throws -> Bool {
        let data = try Data(contentsOf: url)
        let picture = CGImageSourceCreateWithData(data as CFData, nil)
        func imageType() -> String? { picture.flatMap { CGImageSourceGetType($0) as String? } }
        func kept(_ string: String?) -> Bool { text.map { string?.contains($0) == true } ?? true }
        func attributed(_ type: NSAttributedString.DocumentType) -> String? {
            try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil).string
        }
        switch format {
        case .png: return imageType() == UTType.png.identifier
        case .jpg: return imageType() == UTType.jpeg.identifier
        case .heic: return imageType() == UTType.heic.identifier
        case .webp: return imageType() == UTType.webP.identifier
        case .gif: return imageType() == UTType.gif.identifier && (picture.map(CGImageSourceGetCount) ?? 0) > 1
        case .pdf:
            guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { return false }
            return kept(pdf.string)
        case .mp4, .mov, .m4a, .mp3:
            let asset = AVURLAsset(url: url)
            let sound = (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false
            let picture = (try? await asset.loadTracks(withMediaType: .video))?.isEmpty == false
            let brand = data.count > 12 ? String(decoding: data[4..<12], as: UTF8.self) : ""
            switch format {
            case .mp4: return picture && brand.hasPrefix("ftyp") && !brand.hasSuffix("qt  ")
            case .mov: return picture && brand == "ftypqt  "
            case .m4a: return sound && !picture && brand == "ftypM4A "
            default: return sound && !picture && (data.starts(with: Array("ID3".utf8)) || data.first == 0xFF)
            }
        case .txt: return String(data: data, encoding: .utf8).map { kept($0) } ?? false
        case .html: return String(data: data, encoding: .utf8).map { $0.lowercased().contains("<html") && kept($0) } ?? false
        case .rtf: return data.starts(with: Array("{\\rtf".utf8)) && kept(attributed(.rtf))
        case .docx: return data.starts(with: Array("PK".utf8)) && kept(attributed(.officeOpenXML))
        }
    }
}
