import AVFoundation
import CoreMedia
import CoreText
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The recording's file (spec `capture.html` CP13, risk set: a writer bug loses the recording), on made-up samples, no
/// screen: five seconds of 60 fps frames and sound around a two-second pause make a three-second .mp4 with both tracks.
@Suite("Recording writer")
struct RecordingWriterTests {
    static func frame(at time: Double) -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels!, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }

    /// 1024 frames of silence, 48 kHz stereo float, stamped `time`.
    static func sound(at time: Double) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
                                               mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &format)
        let frames = 1024, bytes = frames * 8
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
                                                             presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48_000),
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        return sample!
    }

    @Test("Five seconds with a two-second pause finish as a playable three-second file with picture and sound")
    func pauseLeavesNoHole() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "recording-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url, size: CGSize(width: 64, height: 48), fps: 60, system: true)
        let start = 1000.0
        var t = 0.0, a = 0.0
        while t < 5 {
            if abs(t - 1) < 0.001 { writer.pause(at: start + t) }
            if abs(t - 3) < 0.001 { writer.resume(at: start + t) }
            writer.append(Self.frame(at: start + t), .video)
            while a <= t { writer.append(Self.sound(at: start + a), .system); a += 1024 / 48_000 }
            t = (t * 60 + 1).rounded() / 60
            // The encoder is real time: give it room as a live stream would.
            try await Task.sleep(for: .microseconds(300))
        }
        let length = try await writer.finish()
        #expect(abs(length - 3) < 0.05)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3) < 0.1, "the file is \(duration) s")
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test("A still screen with narration keeps its last words: the file ends with the sound, not the last changed frame")
    func soundTail() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "recording-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url, size: CGSize(width: 64, height: 48), fps: 60, mic: true)
        let start = 2000.0
        for f in 0..<60 { writer.append(Self.frame(at: start + Double(f) / 60), .video) }
        var a = 0.0
        while a < 3 { writer.append(Self.sound(at: start + a), .mic); a += 1024 / 48_000; try await Task.sleep(for: .microseconds(200)) }
        let length = try await writer.finish()
        #expect(length > 2.9, "ends at \(length) s, not at the last frame's 1 s")
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(duration > 2.9, "the file is \(duration) s")
    }

    @Test("A crash mid-recording still leaves a file that plays: fragments are written every 2 s")
    func crashLeavesFragments() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "recording-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url, size: CGSize(width: 64, height: 48), fps: 60)
        for f in 0..<330 {
            writer.append(Self.frame(at: 3000 + Double(f) / 60), .video)
            try await Task.sleep(for: .milliseconds(1))
        }
        // Never finished, as when Pilot dies: what is on disk must already play.
        try await Task.sleep(for: .milliseconds(300))
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(duration >= 2, "an unfinished file plays \(duration) s")
        writer.cancel()
    }

    /// A screen-like frame, 960 × 600: light text lines over a dark gradient (Sven's build 53 recording), scrolled `n` × 6 px.
    static func screen(_ n: Int) -> CMSampleBuffer {
        let w = 960, h = 600
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        CVPixelBufferLockBaseAddress(pixels!, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixels!), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels!),
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(srgbRed: 0.28, green: 0.12, blue: 0.14, alpha: 1),
                                  CGColor(srgbRed: 0.10, green: 0.10, blue: 0.20, alpha: 1)] as CFArray, locations: nil)!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        for i in 0..<60 {
            let y = h + n * 6 - 20 * (i + 1)
            guard y > -20, y < h else { continue }
            let line = NSAttributedString(string: "Message \(i): plan card commit is made locally; a git lock interrupted the sync",
                                          attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                       NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.88, green: 0.88, blue: 0.9, alpha: 1)])
            ctx.textPosition = CGPoint(x: 24, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(line), ctx)
        }
        CVPixelBufferUnlockBaseAddress(pixels!, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels!, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(value: CMTimeValue(4000 * 60 + n), timescale: 60),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }

    @Test("Each recording quality encodes a scrolling screen for its level: Standard smallest, Best largest (build 53)")
    func quality() async throws {
        let keep = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("recording-quality") }
        if let keep { try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true) }
        var sizes: [Int] = []
        for level in CaptureSettings.RecordQuality.allCases {
            let url = (keep ?? FileManager.default.temporaryDirectory).appending(path: "quality-\(level.rawValue)-\(keep == nil ? UUID().uuidString : "pilot").mp4")
            try? FileManager.default.removeItem(at: url)
            defer { if keep == nil { try? FileManager.default.removeItem(at: url) } }
            let writer = try RecordingWriter(url: url, size: CGSize(width: 960, height: 600), fps: 60, quality: level.level)
            for n in 0..<120 {
                writer.append(Self.screen(n), .video)
                try await Task.sleep(for: .milliseconds(4))
            }
            _ = try await writer.finish()
            sizes.append((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
        #expect(sizes[0] < sizes[1] && sizes[1] < sizes[2], "standard, high, best: \(sizes)")
    }

    @Test("A recording that never got a frame leaves no file and says so")
    func empty() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "recording-\(UUID().uuidString).mp4")
        let writer = try RecordingWriter(url: url, size: CGSize(width: 64, height: 48))
        await #expect(throws: RecordingWriter.Problem.self) { try await writer.finish() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A 5K display is scaled to fit H.264, keeping its shape and even sides")
    func encodable() {
        #expect(RecordingWriter.encodable(CGSize(width: 5120, height: 2880)) == CGSize(width: 4096, height: 2304))
        #expect(RecordingWriter.encodable(CGSize(width: 3024, height: 1965)) == CGSize(width: 3024, height: 1964))
        #expect(RecordingWriter.encodable(CGSize(width: 1, height: 1)) == CGSize(width: 2, height: 2))
    }
}
