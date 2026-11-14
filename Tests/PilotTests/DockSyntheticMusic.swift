import Foundation
@testable import Pilot

/// A deterministic stand-in for music (rice round): the renders' spectrum and the sandbox's fake tap. Stereo at 48 kHz:
/// a kick on every beat at 124 bpm, a saw bass, a pad, a snare on two and four, hats on the eighths (panned right) and
/// an arpeggio (panned left).
enum DockSyntheticMusic {
    static let rate: Double = 48_000

    static func stereo(seconds: Double) -> (left: [Float], right: [Float]) {
        let n = Int(seconds * rate), beat = 60.0 / 124
        var left = [Float](repeating: 0, count: n), right = [Float](repeating: 0, count: n)
        var seed: UInt64 = 0x9E3779B97F4A7C15, bassLP: Double = 0, lastNoise: Double = 0
        let roots: [Double] = [55, 65.41, 43.65, 49]
        let chords: [[Double]] = [[220, 261.6, 329.6], [261.6, 329.6, 392], [174.6, 220, 261.6], [196, 246.9, 293.7]]
        for s in 0..<n {
            let t = Double(s) / rate
            let inBeat = t.truncatingRemainder(dividingBy: beat), bar = Int(t / (beat * 4)) % 4
            let beatIndex = Int(t / beat) % 4
            // Kick: a sine falling 120 to 45 Hz.
            let kf = 45 + 75 * exp(-inBeat * 30)
            let kick = sin(2 * .pi * kf * inBeat) * exp(-inBeat * 7) * 0.9
            // Bass: a saw on the bar's root, low-passed.
            let root = roots[bar], saw = 2 * (t * root - floor(t * root + 0.5))
            bassLP += (saw - bassLP) * 0.06
            let bass = bassLP * 0.45 * (0.6 + 0.4 * exp(-inBeat * 3))
            // Pad: the bar's chord with a soft second harmonic.
            var pad = 0.0
            for f in chords[bar] { pad += sin(2 * .pi * f * t) * 0.06 + sin(4 * .pi * f * t) * 0.02 }
            // Noise for hats and snare.
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(Int64(bitPattern: seed >> 11) % 1_000_000) / 1_000_000
            let hp = noise - lastNoise
            lastNoise = noise
            let eighth = t.truncatingRemainder(dividingBy: beat / 2)
            let hat = hp * exp(-eighth * 45) * 0.12
            let snare = (beatIndex == 1 || beatIndex == 3) ? (noise * 0.35 + sin(2 * .pi * 190 * inBeat) * 0.2) * exp(-inBeat * 14) : 0
            // Arpeggio: the chord two octaves up, a sixteenth each.
            let step = Int(t / (beat / 4)) % 3, sixteenth = t.truncatingRemainder(dividingBy: beat / 4)
            let arp = sin(2 * .pi * chords[bar][step] * 4 * t) * exp(-sixteenth * 18) * 0.12
            let centre = kick + bass + pad + snare
            left[s] = Float(centre + hat * 0.4 + arp)
            right[s] = Float(centre + hat + arp * 0.35)
        }
        return (left, right)
    }

    /// Both channels' bars after playing up to `at` seconds at `fps`, so the still carries the fall and the peaks.
    static func frame(at: Double, bands: Int = 96, fps: Double = 60, fall: Float = 2.4) -> (left: DockSpectrum, right: DockSpectrum) {
        let music = stereo(seconds: at + 0.05)
        let l = DockSpectrum(bands: bands, fall: fall), r = DockSpectrum(bands: bands, fall: fall)
        var t = 0.0
        while t <= at {
            let end = min(music.left.count, Int(t * rate))
            l.step(music.left[0..<end], dt: Float(1 / fps))
            r.step(music.right[0..<end], dt: Float(1 / fps))
            t += 1 / fps
        }
        return (l, r)
    }
}
