import Foundation

/// A rectangle of whole pixels, origin top left.
public struct PixelRect: Equatable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// How an image is cut for a model that takes one square tile (Q248): each tile owns a core of the source and reads `pad`
/// pixels round it as context, so no seam shows where two cores meet; at the image's edge the context repeats the edge
/// pixel. Memory is one tile's in and out at a time, whatever the image's size.
public struct TilePlan: Equatable, Sendable {
    public struct Tile: Equatable, Sendable {
        /// The source pixels this tile's output keeps.
        public let core: PixelRect
        /// The tile's top left in the source: the core less the pad, so it may sit off the image.
        public let originX: Int, originY: Int
    }

    public let width: Int, height: Int, size: Int, pad: Int
    public let tiles: [Tile]

    public init(width: Int, height: Int, size: Int, pad: Int) {
        precondition(size > 2 * pad, "a tile must be bigger than its context")
        self.width = width
        self.height = height
        self.size = size
        self.pad = pad
        let step = size - 2 * pad
        var tiles: [Tile] = []
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                tiles.append(Tile(core: PixelRect(x: x, y: y, width: min(step, width - x), height: min(step, height - y)), originX: x - pad, originY: y - pad))
            }
        }
        self.tiles = tiles
    }
}

/// The upscaler's driver: cuts the image by its plan, hands each tile to the model as planar RGB in 0 to 1, keeps each
/// tile's core of the answer, and for 2x averages the model's 4x down in 2 × 2 blocks (Real-ESRGAN's own outscale, and
/// exact per tile, so no seam). Alpha never goes through the model: it is resampled once at the end.
public enum Upscale {
    /// What every model here does: Real-ESRGAN's x4 networks.
    public static let modelScale = 4

    /// The model: `size` × `size` × 3 floats in, `size × modelScale` squared × 3 out, planar R, G, B.
    public typealias Model = (_ input: UnsafeBufferPointer<Float>, _ output: UnsafeMutableBufferPointer<Float>) throws -> Void

    public static func run(_ source: PixelBuffer, tile size: Int, pad: Int = 16, scale: Int,
                           model: Model, progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }) throws -> PixelBuffer {
        precondition(modelScale % scale == 0, "the scale must divide the model's")
        let plan = TilePlan(width: source.width, height: source.height, size: size, pad: pad)
        let W = source.width, H = source.height, outW = W * scale, outH = H * scale, k = modelScale / scale, O = size * modelScale
        let result = PixelBuffer(width: outW, height: outH, space: source.space, hasAlpha: source.hasAlpha)
        let input = UnsafeMutableBufferPointer<Float>.allocate(capacity: 3 * size * size)
        let output = UnsafeMutableBufferPointer<Float>.allocate(capacity: 3 * O * O)
        defer { input.deallocate(); output.deallocate() }
        let src = source.bytes, dst = result.bytes, plane = size * size, outPlane = O * O, norm = 1 / Float(k * k)
        for (n, tile) in plan.tiles.enumerated() {
            for yy in 0..<size {
                let sy = min(H - 1, max(0, tile.originY + yy))
                for xx in 0..<size {
                    let sx = min(W - 1, max(0, tile.originX + xx)), i = (sy * W + sx) * 4, j = yy * size + xx
                    input[j] = Float(src[i]) / 255
                    input[plane + j] = Float(src[i + 1]) / 255
                    input[2 * plane + j] = Float(src[i + 2]) / 255
                }
            }
            try model(UnsafeBufferPointer(input), output)
            // The core's place in the model's answer, in its 4x pixels.
            let ox = (tile.core.x - tile.originX) * modelScale, oy = (tile.core.y - tile.originY) * modelScale
            for y in 0..<(tile.core.height * scale) {
                let row = ((tile.core.y * scale + y) * outW + tile.core.x * scale) * 4
                for x in 0..<(tile.core.width * scale) {
                    for c in 0..<3 {
                        var sum: Float = 0
                        for dy in 0..<k {
                            let base = c * outPlane + (oy + y * k + dy) * O + ox + x * k
                            for dx in 0..<k { sum += output[base + dx] }
                        }
                        dst[row + x * 4 + c] = UInt8(min(255, max(0, (sum * norm * 255).rounded())))
                    }
                }
            }
            progress(n + 1, plan.tiles.count)
        }
        if source.hasAlpha { try scaleAlpha(source, into: result) }
        return result
    }

    private static func scaleAlpha(_ source: PixelBuffer, into result: PixelBuffer) throws {
        let alpha = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: source.width * source.height)
        defer { alpha.deallocate() }
        for i in 0..<alpha.count { alpha[i] = source.bytes[i * 4 + 3] }
        guard let scaled = Resample.plane(alpha, width: source.width, height: source.height, to: result.width, result.height) else {
            throw CocoaError(.featureUnsupported)
        }
        defer { scaled.deallocate() }
        for i in 0..<scaled.count { result.bytes[i * 4 + 3] = scaled[i] }
    }
}

/// The upscaler's models (Q248): General is built in; Max quality is fetched once, on Sven's pick, from a pinned commit
/// and checked against its hash before it is used.
public enum UpscaleModel: String, CaseIterable, Sendable {
    case general, max

    public var title: String { self == .general ? "General" : "Max quality" }
    /// The compiled model's folder name, in the bundle's Resources/Upscale or Application Support/Pilot/Upscale.
    public var compiledName: String { self == .general ? "realesr-general-x4v3.mlmodelc" : "RealESRGAN-x4plus.mlmodelc" }

    public struct Download: Sendable {
        public let url: URL
        public let bytes: Int
        public let sha256: String
        /// The package inside the zip.
        public let package: String
    }

    /// Real-ESRGAN's RealESRGAN_x4plus (RRDBNet, BSD-3, Xintao Wang) as Core ML fp16, 256 px tiles, converted by
    /// VincentGOURBIN/RealESRGAN-CoreML (BSD-3), at its commit da0d01ce, never its moving main.
    public var download: Download? {
        guard self == .max else { return nil }
        return Download(url: URL(string: "https://huggingface.co/VincentGOURBIN/RealESRGAN-CoreML/resolve/da0d01ce79946e6a62563eaf900ff9844af1f67f/RealESRGAN-x4plus.mlpackage.zip")!,
                        bytes: 30_996_079, sha256: "61d44a58bb8549a0c0485c95d2b384c598b48a648231206b3e7c2ac221e64599",
                        package: "RealESRGAN-x4plus.mlpackage")
    }
}
