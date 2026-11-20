import Foundation
import ImageIO
import UniformTypeIdentifiers

// A row's picture (ADR 0017, T5): an extension's asset or a remote image, read here because the prelude has no binary
// data. Answered to `__pilotImaged(id, …)` as `{"image": <base64>}`, at most `largest` bytes of PNG or JPEG, or
// `{"error": …}`. A picture past the cap is drawn again at `side` pixels as PNG; one still past it is no picture.
// A download is bounded in time and bytes, so a large or slow URL never holds the run or grows the host.

extension Host {
    /// Pilot's own cap on a row's picture (Extension.Item.largestImage), in bytes.
    nonisolated static let largest = 64 * 1024
    /// The longest side a picture past the cap is drawn again at: twice a row's largest icon.
    nonisolated static let side = 128
    /// The most a remote picture may weigh, and how long its download may take.
    nonisolated static let mostDownload = 4 * 1024 * 1024, downloadSeconds = 1.0

    /// Reads `source` off the main queue and answers it on a later turn, so the prelude's cache is set before the answer
    /// lands; the run stays alive until then.
    func image(_ id: Int, _ source: String, _ assets: String) {
        pending += 1
        Task { @MainActor in
            let answer = await Host.load(source, assets)
            pending -= 1
            call("__pilotImaged", [id, answer.value])
            settle()
        }
    }

    /// An http(s) URL's picture, else a file's under `assets` (no `..`, never absolute).
    nonisolated static func load(_ source: String, _ assets: String) async -> Handed {
        if let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return await download(url) }
        let parts = source.split(separator: "/")
        guard !source.hasPrefix("/"), !parts.contains(".."), !parts.isEmpty else {
            return Handed(value: ["error": "an asset is a file under assets/: \(source)"])
        }
        let file = URL(filePath: assets).appending(path: source)
        return Handed(value: (try? Data(contentsOf: file)).map(picture) ?? ["error": "no asset \(source)"])
    }

    /// Why a download gave no picture.
    struct Refusal: Error { let text: String }

    /// The picture at `url`, read as it streams: stopped past `mostDownload` bytes or `downloadSeconds` in all.
    nonisolated static func download(_ url: URL) async -> Handed {
        /// The bytes, or why there are none.
        let reading = Task.detached { () async throws -> Result<Data, Refusal> in
            let (bytes, response) = try await session.bytes(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .failure(Refusal(text: "HTTP \(status)")) }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > mostDownload { return .failure(Refusal(text: "larger than \(mostDownload / 1024 / 1024) MB")) }
            }
            return .success(data)
        }
        let clock = Task.detached { try await Task.sleep(for: .seconds(downloadSeconds)); reading.cancel() }
        defer { clock.cancel() }
        do {
            switch try await reading.value {
            case .success(let data): return Handed(value: picture(data))
            case .failure(let refusal): return Handed(value: ["error": refusal.text])
            }
        } catch {
            return Handed(value: ["error": reading.isCancelled ? "no answer in \(downloadSeconds) s" : error.localizedDescription])
        }
    }

    /// The picture in `data` as base64 within `largest`: PNG or JPEG as it is, else drawn again at `side` as PNG.
    nonisolated static func picture(_ data: Data) -> [String: Any] {
        guard data.count <= mostDownload, let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
              let kind = UTType(type as String), kind.conforms(to: .image) else { return ["error": "not a picture"] }
        if data.count <= largest, kind.conforms(to: .png) || kind.conforms(to: .jpeg) { return ["image": data.base64EncodedString()] }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return ["error": "not a picture"] }
        let out = NSMutableData()
        guard let png = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return ["error": "not drawn"] }
        CGImageDestinationAddImage(png, small, nil)
        guard CGImageDestinationFinalize(png), out.length <= largest else { return ["error": "larger than 64 KB at \(side) px"] }
        return ["image": (out as Data).base64EncodedString()]
    }
}
