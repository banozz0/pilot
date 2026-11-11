// pilot-upscale: Real-ESRGAN in a process of its own (Q248). Core ML's model, its Neural Engine buffers and a 4x image's
// pixels go with it when it exits, so Pilot's idle cost stays zero; Cancel stops it; nothing it does can stall the tap.
//   pilot-upscale upscale <model> <width> <height> <png|jpeg|heic> <image> <folder> <stem> [fill]
//       runs the model 2x or 4x (UpscaleTarget.pass), resamples down to <width> x <height> when that is smaller, and writes
//       "<stem> 4x.png" or "<stem> 2560x1440.png" (or the next free name) in <folder>, printing "progress <done> <total>"
//       a tile and then "wrote <path>"
//   pilot-upscale compile <package.mlpackage> <out.mlmodelc>
//       compiles a downloaded package once, so later runs load it at once
// <model> is a compiled .mlmodelc, or a .mlpackage compiled for this run (a swift build without the bundle).
import CoreGraphics
import CoreML
import Foundation
import ImageScale

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// One model loaded for every tile of a run.
struct CoreMLTiles {
    let model: MLModel
    let input: String, output: String
    let size: Int

    init(_ url: URL) async throws {
        let compiled = url.pathExtension == "mlpackage" ? try await MLModel.compileModel(at: url) : url
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try await MLModel.load(contentsOf: compiled, configuration: config)
        // The names and the tile's side come from the model: the built-in and the downloaded one name them apart.
        guard let (name, description) = model.modelDescription.inputDescriptionsByName.first,
              let shape = description.multiArrayConstraint?.shape.map(\.intValue), shape.count == 4,
              let out = model.modelDescription.outputDescriptionsByName.keys.first else { throw CocoaError(.featureUnsupported) }
        input = name
        output = out
        size = shape[3]
    }

    func run(_ pixels: UnsafeBufferPointer<Float>, _ into: UnsafeMutableBufferPointer<Float>) throws {
        // The driver's tile buffer as the input, no copy: it lives for the whole run.
        let n = NSNumber(value: size)
        let array = try MLMultiArray(dataPointer: UnsafeMutableRawPointer(mutating: pixels.baseAddress!), shape: [1, 3, n, n], dataType: .float32,
                                     strides: [NSNumber(value: 3 * size * size), NSNumber(value: size * size), n, 1])
        let answer = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input: MLFeatureValue(multiArray: array)]))
        guard let out = answer.featureValue(for: output)?.multiArrayValue else { throw CocoaError(.featureUnsupported) }
        // The Neural Engine pads its rows: read by the strides, never as one run.
        let strides = out.strides.map(\.intValue), side = size * Upscale.modelScale
        func copy<T>(_ type: T.Type, _ value: (T) -> Float) {
            out.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: T.self)
                for c in 0..<3 {
                    for y in 0..<side {
                        let from = c * strides[1] + y * strides[2], to = (c * side + y) * side
                        for x in 0..<side { into[to + x] = value(p[from + x * strides[3]]) }
                    }
                }
            }
        }
        switch out.dataType {
        case .float32: copy(Float.self) { $0 }
        case .float16: copy(Float16.self) { Float($0) }
        case .double: copy(Double.self) { Float($0) }
        default: throw CocoaError(.featureUnsupported)
        }
    }
}

/// The upscaled image at `width` x `height`, and the source's size, in a function of its own so the decoded source and
/// the model's pass are freed before the result is encoded.
func upscale(_ image: String, model: String, width: Int, height: Int, fill: Bool) async -> (CGImage, source: (Int, Int)) {
    guard let cg = ImageFiles.load(URL(filePath: image)), let source = PixelBuffer(cg) else { fail("upscale: cannot read \(image)") }
    let factor = max(Double(width) / Double(source.width), Double(height) / Double(source.height))
    guard factor <= 4, !fill || (Double(source.width) * factor <= Double(ResizeTarget.limit) &&
          Double(source.height) * factor <= Double(ResizeTarget.limit)) else { fail("upscale: the target exceeds the 4x or 16,384 px limit", 2) }
    let tiles: CoreMLTiles
    do { tiles = try await CoreMLTiles(URL(filePath: model)) } catch { fail("upscale: cannot load the model: \(error)") }
    let pass = UpscaleTarget.pass(factor)
    let result: PixelBuffer
    do {
        result = try Upscale.run(source, tile: tiles.size, scale: pass, model: tiles.run) { done, total in print("progress \(done) \(total)"); fflush(stdout) }
    } catch { fail("upscale: \(error)") }
    guard let out = result.image() else { fail("upscale: cannot make the result") }
    guard (out.width, out.height) != (width, height) else { return (out, (source.width, source.height)) }
    guard let sized = Resample.image(out, width: width, height: height, fill: fill) else { fail("upscale: cannot size the result") }
    return (sized, (source.width, source.height))
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "upscale" where arguments.count == 8 || (arguments.count == 9 && arguments[8] == "fill"):
    let (model, width, height, format) = (arguments[1], Int(arguments[2]) ?? 0, Int(arguments[3]) ?? 0, ImageFormat(rawValue: arguments[4]))
    let (image, folder, stem) = (arguments[5], arguments[6], arguments[7])
    guard (1...ResizeTarget.limit).contains(width), (1...ResizeTarget.limit).contains(height), let format else {
        fail("upscale: the size is 1 to \(ResizeTarget.limit) a side, the format png, jpeg or heic", 2)
    }
    let (out, source) = await upscale(image, model: model, width: width, height: height, fill: arguments.count == 9)
    guard let data = format.encode(out) else { fail("upscale: cannot encode the result") }
    let suffix = UpscaleTarget.suffix(from: source.0, source.1, to: out.width, out.height)
    guard let url = ImageFiles.write(data, in: URL(filePath: folder), stem: stem, suffix: suffix, ext: format.fileExtension) else {
        fail("upscale: cannot write in \(folder)")
    }
    print("wrote \(url.path)")
case "compile" where arguments.count == 3:
    do {
        let compiled = try await MLModel.compileModel(at: URL(filePath: arguments[1]))
        let target = URL(filePath: arguments[2])
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: compiled, to: target)
    } catch { fail("compile: \(error)") }
default:
    fail("usage: pilot-upscale upscale <model> <width> <height> <png|jpeg|heic> <image> <folder> <stem> [fill] | compile <package> <out.mlmodelc>", 2)
}
