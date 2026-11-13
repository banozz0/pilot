import Accelerate
import Foundation

/// The visualizer's analysis (rice round, Sven 2026-11-13, Q220 A): what plays as bar heights, cava-style. One
/// channel's samples in, `bands` levels out (bass first, 0 to 1), each rising at once and falling under gravity,
/// neighbours lifted a little so the row reads as a wave (cava's "monstercat" smoothing). A 2048-point FFT with a Hann
/// window, log-spaced bands from 40 Hz to 16 kHz, a +2 dB per octave tilt so the highs are not lost, -54 to 0 dB mapped
/// to 0 to 1. Round 1's prototype measured two channels of it at 60 fps at 0.9 to 1.0 % of an M4.
final class DockSpectrum {
    let bands: Int
    let size: Int
    /// How fast a bar falls, in full heights per second.
    var fall: Float
    /// The bars now, bass first.
    private(set) var heights: [Float]
    /// Each bar's peak cap and how long it has held.
    private(set) var peaks: [Float]
    private var held: [Float]
    private let dft: vDSP.DiscreteFourierTransform<Float>
    private let window: [Float]
    private let edges: [Int]
    private let tilt: [Float]
    private let zeros: [Float]

    init(bands: Int = 96, size: Int = 2048, sampleRate: Float = 48_000, low: Float = 40, high: Float = 16_000, fall: Float = 2.4) {
        self.bands = bands
        self.size = size
        self.fall = fall
        heights = Array(repeating: 0, count: bands)
        peaks = Array(repeating: 0, count: bands)
        held = Array(repeating: 0, count: bands)
        dft = try! vDSP.DiscreteFourierTransform(count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        zeros = Array(repeating: 0, count: size)
        let binHz = sampleRate / Float(size), top = size / 2 - 1
        var edges: [Int] = []
        for i in 0...bands {
            let f = low * pow(high / low, Float(i) / Float(bands))
            let bin = min(top, max(1, Int((f / binHz).rounded())))
            edges.append(max(bin, (edges.last ?? 0) + (i == 0 ? 0 : 1)))
        }
        self.edges = edges.map { min($0, top) }
        tilt = (0..<bands).map { i in
            let f = low * pow(high / low, (Float(i) + 0.5) / Float(bands))
            return 2 * log2(f / 1000)
        }
    }

    /// The raw levels of the last `size` samples, 0 to 1, bass first.
    func levels(_ samples: ArraySlice<Float>) -> [Float] {
        var input = Array(samples.suffix(size))
        if input.count < size { input = Array(repeating: 0, count: size - input.count) + input }
        vDSP.multiply(input, window, result: &input)
        var re = [Float](repeating: 0, count: size), im = [Float](repeating: 0, count: size)
        dft.transform(inputReal: input, inputImaginary: zeros, outputReal: &re, outputImaginary: &im)
        let half = size / 2
        var mags = [Float](repeating: 0, count: half)
        vDSP.hypot(re[0..<half], im[0..<half], result: &mags)
        let scale = 4 / Float(size)
        return (0..<bands).map { b in
            let lo = edges[b], hi = max(lo + 1, edges[b + 1])
            let peak = mags[lo..<min(hi, half)].max() ?? 0
            let db = 20 * log10(max(peak * scale, 1e-9)) + tilt[b]
            return min(1, max(0, (db + 54) / 54))
        }
    }

    /// One frame: the bars rise to `samples`' levels at once and fall at `fall`; peaks hold 0.3 s, then fall at a third
    /// of that. Silence (nil) lets every bar fall to nothing.
    @discardableResult
    func step(_ samples: ArraySlice<Float>?, dt: Float) -> [Float] {
        var target = samples.map(levels) ?? Array(repeating: 0, count: bands)
        // Monstercat: each bar at least its neighbours' less a step per bar, so the row reads as one wave.
        for i in 0..<bands {
            for j in max(0, i - 4)..<min(bands, i + 5) where j != i {
                target[i] = max(target[i], target[j] / pow(1.6, Float(abs(i - j))))
            }
        }
        for i in 0..<bands {
            heights[i] = target[i] >= heights[i] ? target[i] : max(target[i], heights[i] - fall * dt)
            if heights[i] >= peaks[i] {
                peaks[i] = heights[i]
                held[i] = 0
            } else {
                held[i] += dt
                if held[i] > 0.3 { peaks[i] = max(heights[i], peaks[i] - fall / 3 * dt) }
            }
        }
        return heights
    }

    /// `levels` read at `t` from 0 (bass) to 1 (highs), between bands, so any bar count draws from one analysis.
    static func sample(_ levels: [Float], at t: Double) -> Float {
        guard levels.count > 1 else { return levels.first ?? 0 }
        let x = min(max(t, 0), 1) * Double(levels.count - 1), i = Int(x), f = Float(x - Double(i))
        return i + 1 < levels.count ? levels[i] * (1 - f) + levels[i + 1] * f : levels[i]
    }
}
