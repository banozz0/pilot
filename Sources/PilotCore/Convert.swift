import AppKit
import AVFoundation
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A format Convert writes (card agent-bo-95423210, Sven 2026-10-08 "go", after convt, whose AGPL code is not used).
public enum ConvertFormat: String, CaseIterable, Sendable {
    case png, jpg, heic, webp, pdf, mp4, mov, m4a, mp3, gif, docx, rtf, txt, html

    public var title: String { self == .webp ? "WebP" : rawValue.uppercased() }

    /// The CLI the format needs beyond macOS: GIF is offered only from a video.
    public var tool: ConvertTool? {
        switch self {
        case .mp3, .gif: .ffmpeg
        case .webp: .cwebp
        default: nil
        }
    }

    /// The format a file is already in, by its extension: jpeg is JPG, htm is HTML.
    init?(of url: URL) {
        let ext = url.pathExtension.lowercased()
        self.init(rawValue: ["jpeg": "jpg", "htm": "html"][ext] ?? ext)
    }
}

/// A CLI a format needs beyond macOS, run only when Homebrew already has it: AVFoundation writes no MP3 and no GIF,
/// and ImageIO writes no WebP on macOS 26 (nor does Homebrew's ffmpeg, built without libwebp).
public enum ConvertTool: String, CaseIterable, Sendable {
    case ffmpeg, cwebp

    /// The Homebrew formula that installs it.
    public var formula: String { self == .cwebp ? "webp" : rawValue }

    /// That formula as Install takes it.
    public var package: Package? { Package(.formula, formula) }
}

/// One format a pick of files can go to; `needs` names the tool it waits for when that is missing.
public struct ConvertOption: Equatable, Sendable {
    public let format: ConvertFormat
    public let needs: ConvertTool?
}

public enum ConvertError: Error, Equatable, CustomStringConvertible {
    case unsupported(String), needs(ConvertTool), failed(String)

    public var description: String {
        switch self {
        case .unsupported(let why), .failed(let why): why
        case .needs(let tool): "needs \(tool.formula)"
        }
    }
}

/// What a file is, by its extension, and the names Convert writes.
public enum Convert {
    enum Kind { case image, pdf, video, audio, document }

    static func kind(of url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image), imageTypes.contains(type.identifier) { return .image }
        if type.conforms(to: .audiovisualContent), mediaTypes.contains(type.identifier) {
            return type.conforms(to: .audio) ? .audio : type.conforms(to: .movie) ? .video : nil
        }
        if documentTypes.contains(where: type.conforms(to:)) { return .document }
        return nil
    }

    private static let imageTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
    private static let mediaTypes = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))
    /// What textutil reads.
    private static let documentTypes: [UTType] = [.plainText, .html, .rtf, .webArchive]
        + ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "org.oasis-open.opendocument.text"].compactMap(UTType.init)

    static func formats(_ kind: Kind) -> [ConvertFormat] {
        switch kind {
        case .image: [.png, .jpg, .heic, .webp, .pdf]
        case .pdf: [.png, .jpg, .heic, .webp, .txt, .rtf, .docx, .html]
        case .video: [.mp4, .mov, .m4a, .mp3, .gif]
        case .audio: [.m4a, .mp3]
        case .document: [.docx, .rtf, .txt, .html, .pdf]
        }
    }

    /// What Convert takes and what each kind can become, as the Files page lists it (Sven 2026-10-10).
    public static let catalogue: [(kind: String, reads: String, to: [ConvertFormat])] = [
        ("Pictures", "PNG, JPG, HEIC, TIFF, GIF and more", formats(.image)),
        ("PDFs", "the first page as a picture, or the text", formats(.pdf)),
        ("Video", "MOV, MP4, M4V", formats(.video)),
        ("Sound", "M4A, MP3, WAV, AIFF", formats(.audio)),
        ("Documents", "TXT, RTF, HTML, Word and OpenDocument", formats(.document)),
    ]

    /// `name.ext` beside the original, or `name 2.ext`, `name 3.ext` when that is taken, as Finder names a copy.
    public static func freeName(for url: URL, as format: ConvertFormat,
                                exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let folder = url.deletingLastPathComponent(), name = url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let candidate = folder.appending(path: (n == 1 ? name : "\(name) \(n)") + "." + format.rawValue)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}

/// Converts files on the Mac, nothing uploaded: ImageIO for pictures, AVFoundation for sound and video, textutil and
/// CoreText for documents, PDFKit for a PDF's text, and ffmpeg or cwebp for what macOS cannot write. The output lands
/// beside the original under a free name, written to a hidden scratch name first, so a failed or cancelled job leaves
/// nothing and never touches an existing file. CLIs run through ChildProcess: cancelling the task stops them.
public struct Converter: Sendable {
    public let tools: [ConvertTool: String]

    public init(tools: [ConvertTool: String]) { self.tools = tools }

    /// The tools Homebrew has installed now.
    public static func installed() -> Converter {
        Converter(tools: Dictionary(uniqueKeysWithValues: ConvertTool.allCases.compactMap { tool in Homebrew.cli(tool.rawValue).map { (tool, $0) } }))
    }

    /// The formats every one of `urls` can go to, in order, less one they are all already in.
    public func options(for urls: [URL]) -> [ConvertOption] {
        let kinds = urls.compactMap(Convert.kind(of:))
        guard kinds.count == urls.count, let first = kinds.first else { return [] }
        let already = Set(urls.map(ConvertFormat.init(of:)))
        return Convert.formats(first).compactMap { format in
            guard kinds.allSatisfy({ Convert.formats($0).contains(format) }), already != [format] else { return nil }
            return ConvertOption(format: format, needs: format.tool.flatMap { tools[$0] == nil ? $0 : nil })
        }
    }

    /// Converts `url` to `format` and returns the file written.
    public func convert(_ url: URL, to format: ConvertFormat) async throws -> URL {
        guard let kind = Convert.kind(of: url), Convert.formats(kind).contains(format) else {
            throw ConvertError.unsupported("\(url.lastPathComponent) cannot become \(format.title)")
        }
        guard ConvertFormat(of: url) != format else { throw ConvertError.unsupported("\(url.lastPathComponent) is already \(format.title)") }
        if let tool = format.tool, tools[tool] == nil { throw ConvertError.needs(tool) }
        try Task.checkCancellation()
        let output = url.deletingLastPathComponent()
            .appending(path: ".\(url.deletingPathExtension().lastPathComponent).pilot-\(UUID().uuidString).\(format.rawValue)")
        defer { try? FileManager.default.removeItem(at: output) }
        try await write(url, kind, format, to: output)
        try Task.checkCancellation()
        return try place(output, for: url, as: format)
    }

    /// Moves the finished scratch file to the first free name; a move never replaces a file, so a name taken meanwhile
    /// moves on to the next.
    private func place(_ output: URL, for url: URL, as format: ConvertFormat) throws -> URL {
        while true {
            let name = Convert.freeName(for: url, as: format)
            do {
                try FileManager.default.moveItem(at: output, to: name)
                return name
            } catch CocoaError.fileWriteFileExists {}
        }
    }

    private func write(_ url: URL, _ kind: Convert.Kind, _ format: ConvertFormat, to output: URL) async throws {
        switch format {
        case .png, .jpg, .heic:
            try Images.write(try Images.read(url, kind), as: format, to: output)
        case .pdf where kind == .document:  // one pattern, so the where holds
            // textutil reads every document kind, HTML too, which AppKit reads only on the main thread.
            try await scratch { folder in
                let rtf = folder.appending(path: "text.rtf")
                try await textutil(url, "rtf", to: rtf)
                try Pages.write(try NSAttributedString(url: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil), to: output)
            }
        case .pdf:
            try Images.write(try Images.read(url, kind), as: .pdf, to: output)
        case .webp:
            try await scratch { folder in
                let png = folder.appending(path: "image.png")
                try Images.write(try Images.read(url, kind), as: .png, to: png)
                try await run(.cwebp, ["-quiet", "-q", "90", png.path, "-o", output.path])
            }
        case .mp4, .mov:
            try await export(url, format == .mp4 ? .mp4 : .mov, to: output)
        case .m4a:
            try await export(url, .m4a, to: output)
        case .mp3:
            try await run(.ffmpeg, ["-nostdin", "-loglevel", "error", "-i", url.path, "-vn", "-c:a", "libmp3lame", "-q:a", "2", output.path])
        case .gif:
            try await run(.ffmpeg, ["-nostdin", "-loglevel", "error", "-i", url.path, "-an", "-vf",
                                    "fps=12,scale='min(640,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                                    "-loop", "0", output.path])
        case .txt, .rtf, .docx, .html:
            guard kind == .pdf else { return try await textutil(url, format.rawValue, to: output) }
            // A PDF's text, written by AppKit, which needs no main thread to write.
            let types: [ConvertFormat: NSAttributedString.DocumentType] = [.txt: .plain, .rtf: .rtf, .docx: .officeOpenXML, .html: .html]
            let text = NSAttributedString(string: PDFDocument(url: url)?.string ?? "")
            try text.data(from: NSRange(location: 0, length: text.length),
                          documentAttributes: [.documentType: types[format]!, .characterEncoding: String.Encoding.utf8.rawValue]).write(to: output)
        }
    }

    /// A temporary folder for a step's in-between file, gone once the step ends.
    private func scratch(_ body: (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder)
    }

    private func run(_ tool: ConvertTool, _ arguments: [String]) async throws {
        guard let cli = tools[tool] else { throw ConvertError.needs(tool) }
        try await exec(cli, arguments)
    }

    private func exec(_ cli: String, _ arguments: [String]) async throws {
        do { _ = try await ChildProcess.run(cli, arguments) }
        catch let failure as ChildProcess.Failure { throw ConvertError.failed(failure.description) }
    }

    /// textutil's `-convert`; plain text and HTML written as UTF-8. `-noload`: an HTML page's linked pictures and
    /// stylesheets are never fetched, so nothing reaches the network (Moody VA-XHUBJFZo; textutil on macOS 26 fetched
    /// nothing from a loopback listener even without it).
    private func textutil(_ url: URL, _ format: String, to output: URL) async throws {
        let encoding = ["txt", "html"].contains(format) ? ["-encoding", "UTF-8"] : []
        try await exec("/usr/bin/textutil", ["-noload", "-convert", format] + encoding + ["-output", output.path, url.path])
    }

    /// AVFoundation's export: a movie's streams copied into the new container when it can hold them, else re-encoded;
    /// sound alone as AAC. A movie with no sound is refused for M4A in plain words.
    private func export(_ url: URL, _ type: AVFileType, to output: URL) async throws {
        let asset = AVURLAsset(url: url)
        let preset: String
        if type == .m4a {
            if try await asset.loadTracks(withMediaType: .audio).isEmpty { throw ConvertError.failed("\(url.lastPathComponent) has no sound") }
            preset = AVAssetExportPresetAppleM4A
        } else {
            let copies = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: type)
            preset = copies ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw ConvertError.failed("no \(preset) export") }
        // The async export stops when its task is cancelled.
        try await session.export(to: output, as: type)
    }
}

/// Pictures through ImageIO: the first frame, turned upright as its EXIF orientation says, or a PDF's first page drawn
/// at 144 dpi on white.
enum Images {
    static func read(_ url: URL, _ kind: Convert.Kind) throws -> CGImage {
        if kind == .pdf {
            guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { throw ConvertError.failed("\(url.lastPathComponent) has no page") }
            let box = page.getBoxRect(.cropBox), scale = 2.0
            let width = Int(box.width * scale), height = Int(box.height * scale)
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw ConvertError.failed("no \(width)×\(height) bitmap") }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            guard let image = ctx.makeImage() else { throw ConvertError.failed("\(url.lastPathComponent) not drawn") }
            return image
        }
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let size = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            .map { max($0[kCGImagePropertyPixelWidth] as? Int ?? 0, $0[kCGImagePropertyPixelHeight] as? Int ?? 0) } ?? 0
        // A thumbnail at full size is the one ImageIO call that applies the orientation.
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary
        guard let source, size > 0, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw ConvertError.failed("\(url.lastPathComponent) did not read as a picture")
        }
        return image
    }

    /// Writes `image`; a format without transparency gets it on white, where ImageIO would use black.
    static func write(_ image: CGImage, as format: ConvertFormat, to output: URL) throws {
        let types: [ConvertFormat: UTType] = [.png: .png, .jpg: .jpeg, .heic: .heic, .pdf: .pdf]
        guard let type = types[format], let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError.unsupported("ImageIO writes no \(format.title)")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1)] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConvertError.failed("\(format.title) not written") }
    }
}

/// A document's text laid out on A4 pages by CoreText, off the main thread.
enum Pages {
    static func write(_ text: NSAttributedString, to output: URL) throws {
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(output as CFURL, mediaBox: &page, nil) else { throw ConvertError.failed("PDF not started") }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: page.insetBy(dx: 56, dy: 56), transform: nil)
        var start = 0
        repeat {
            try Task.checkCancellation()
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let laid = CTFrameGetVisibleStringRange(frame).length
            guard laid > 0 else { break }
            start += laid
        } while start < text.length
        ctx.closePDF()
    }
}
