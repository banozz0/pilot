// Written for Pilot (P72); Snapzy's Capture Subject (BSD-3) is the behaviour reference, none of its code is used.
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Cuts the subject out of a picture, its background made transparent: Vision in pilot-text, Vision here, a fake in tests.
public protocol SubjectCutting: Sendable {
    /// `png` with everything but its subjects transparent, cropped to them, as PNG; nil when it holds no subject or
    /// cannot be read.
    func subject(in png: Data) async -> Data?
}

/// Vision's foreground mask on the Mac, no network: every subject it finds, the rest of the picture clear.
public struct VisionSubject: SubjectCutting {
    public init() {}

    public func subject(in png: Data) async -> Data? {
        let handler = ImageRequestHandler(png)
        guard let observation = try? await handler.perform(GenerateForegroundInstanceMaskRequest()), !observation.allInstances.isEmpty,
              let masked = try? observation.generateMaskedImage(for: observation.allInstances, imageFrom: handler, croppedToInstancesExtent: true)
        else { return nil }
        let image = CIImage(cvPixelBuffer: masked)
        guard let cut = CIContext().createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cut, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
