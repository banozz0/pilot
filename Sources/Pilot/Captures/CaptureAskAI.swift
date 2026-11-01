import AppKit
import ImageIO
import PilotCore
import UniformTypeIdentifiers

/// Ask AI about a capture (story 191, Sven Q189): the thumbnail's and the editor's Ask AI send the picture, the editor's
/// marked up so a blurred secret stays blurred, to the AI chat, which starts a new chat with it attached and offers
/// starters (AIChat.Starter). It goes through the AI page's provider as a chat turn, never the agent: no `pilot` tools.
@MainActor
enum CaptureAskAI {
    /// The longest side sent, in pixels: what the Messages API reads before it shrinks a picture itself (claude-api
    /// skill, vision), and within every route's limits.
    nonisolated static let longest: CGFloat = 1568
    /// Past this a PNG goes as a JPEG: under the Messages API's 5 MB a picture, base64 included.
    nonisolated static let most = 3_500_000

    /// Sizes the capture off the main thread, then opens the chat with it.
    static func ask(_ image: CGImage) {
        let still = Unchecked(image)
        Task {
            let picture = await Task.detached(priority: .userInitiated) { Self.picture(still.value) }.value
            guard let picture else { return ailog.error("ask AI: the capture could not be encoded") }
            ailog.notice("ask AI: \(picture.data.count) bytes, \(picture.mediaType, privacy: .public)")
            AIChatPanel.shared.ask(about: picture)
        }
    }

    /// A picture pasted or dropped on the AI chat (Q693): a picture file, or a picture's bytes.
    enum Source: Sendable { case file(URL), data(Data) }

    /// A pasted or dropped picture decoded no larger than it is sent, never whole, then encoded as a capture is; nil when it
    /// is no picture.
    nonisolated static func picture(_ source: Source) -> AIChat.Image? {
        let image: CGImage? = switch source {
        case .file(let url): NoteAttachments.picture(at: url, pixels: Int(longest))
        case .data(let data): CGImageSourceCreateWithData(data as CFData, nil).flatMap {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                        kCGImageSourceThumbnailMaxPixelSize: Int(longest)] as CFDictionary)
        }
        }
        return image.flatMap(picture)
    }

    /// The picture as it is sent: its pixels, shrunk to `longest` on its longer side when bigger.
    nonisolated static func size(_ width: Int, _ height: Int) -> CGSize {
        let w = CGFloat(width), h = CGFloat(height), fit = min(1, longest / max(w, h, 1))
        return CGSize(width: max(1, (w * fit).rounded()), height: max(1, (h * fit).rounded()))
    }

    /// The capture sized (`size`) and encoded: PNG, or JPEG when the PNG is past `most`.
    nonisolated static func picture(_ image: CGImage) -> AIChat.Image? {
        let fitted = size(image.width, image.height)
        var sized = image
        if fitted != CGSize(width: image.width, height: image.height) {
            guard let context = CGContext(data: nil, width: Int(fitted.width), height: Int(fitted.height), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: fitted))
            guard let drawn = context.makeImage() else { return nil }
            sized = drawn
        }
        if let png = encode(sized, as: .png), png.count <= most { return AIChat.Image(png) }
        return encode(sized, as: .jpeg, quality: 0.85).map { AIChat.Image($0, mediaType: "image/jpeg") }
    }

    nonisolated static func encode(_ image: CGImage, as type: UTType, quality: CGFloat? = nil) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary })
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
