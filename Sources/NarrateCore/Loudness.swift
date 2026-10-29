import Foundation

/// Integrated loudness after ITU-R BS.1770-4 (EBU R128): K-weighting, 400 ms blocks every 100 ms,
/// an absolute gate at -70 LUFS and a relative gate 10 LU below the ungated level. Mono only.
public struct LoudnessMeter {
    private var shelf: Biquad
    private var highpass: Biquad
    private let step: Int  // samples per 100 ms
    private var energy = 0.0
    private var filled = 0
    private var steps: [Double] = []  // mean square of each 100 ms step

    public init(sampleRate: Int) {
        let rate = Double(sampleRate)
        // Coefficients for any rate, from the filters' analog prototypes (as libebur128 derives them).
        var k = tan(Double.pi * 1681.974450955533 / rate)
        var q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                       a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        k = tan(Double.pi * 38.13547087602444 / rate)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        highpass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        step = sampleRate / 10
    }

    public mutating func add(_ samples: [Float]) {
        for s in samples {
            let y = highpass.process(shelf.process(Double(s)))
            energy += y * y
            filled += 1
            if filled == step {
                steps.append(energy / Double(step))
                energy = 0
                filled = 0
            }
        }
    }

    /// Integrated loudness in LUFS; -infinity when nothing passes the absolute gate (silence).
    public var integrated: Double {
        guard steps.count >= 4 else { return -.infinity }
        let blocks = (0...steps.count - 4).map { (steps[$0] + steps[$0 + 1] + steps[$0 + 2] + steps[$0 + 3]) / 4 }
        func lufs(_ e: Double) -> Double { -0.691 + 10 * log10(e) }
        func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }
        let loud = blocks.filter { lufs($0) > -70 }
        guard !loud.isEmpty else { return -.infinity }
        let relative = lufs(mean(loud)) - 10
        return lufs(mean(loud.filter { lufs($0) > relative }))
    }

    struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
}

/// Lookahead peak limiter: no output sample exceeds `ceiling`. The gain ramps down over the lookahead
/// window before a peak and recovers with an exponential release. Output lags input by `lookahead`
/// samples; `flush()` returns the tail.
public struct Limiter {
    let ceiling: Float
    let lookahead: Int
    private let release: Float
    private var delay: [Float]
    private var box: [Float]
    private var boxSum: Double
    private var pos = 0
    private var envelope: Float = 1
    // Monotonic deque (a ring) of (sample index, needed gain) for the sliding minimum.
    private var minIndex: [Int]
    private var minValue: [Float]
    private var head = 0, count = 0
    private var n = 0

    public init(ceiling: Float, sampleRate: Int, attack: Double = 0.005, release: Double = 0.05) {
        self.ceiling = ceiling
        lookahead = max(1, Int(attack * Double(sampleRate)))
        self.release = 1 - Float(exp(-1 / (release * Double(sampleRate))))
        delay = [Float](repeating: 0, count: lookahead)
        box = [Float](repeating: 1, count: lookahead)
        boxSum = Double(lookahead)
        minIndex = [Int](repeating: 0, count: lookahead + 2)
        minValue = [Float](repeating: 1, count: lookahead + 2)
    }

    public mutating func process(_ input: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: input.count)
        for i in input.indices { out[i] = step(input[i]) }
        return out
    }

    public mutating func flush() -> [Float] { process([Float](repeating: 0, count: lookahead)) }

    private mutating func step(_ x: Float) -> Float {
        let a = abs(x)
        let needed = a > ceiling ? ceiling / a : 1
        // Minimum needed gain over the last lookahead + 1 samples.
        let cap = minIndex.count
        while count > 0 && minValue[(head + count - 1) % cap] >= needed { count -= 1 }
        minIndex[(head + count) % cap] = n
        minValue[(head + count) % cap] = needed
        count += 1
        if minIndex[head] < n - lookahead { head = (head + 1) % cap; count -= 1 }
        let held = minValue[head]
        envelope = held < envelope ? held : envelope + (held - envelope) * release
        // Averaging the held envelope over the lookahead turns its steps into ramps that still reach
        // the needed gain by the time the peak leaves the delay line.
        boxSum += Double(envelope - box[pos])
        box[pos] = envelope
        let gain = Float(boxSum / Double(lookahead))
        let delayed = delay[pos]
        delay[pos] = x
        pos = (pos + 1) % lookahead
        n += 1
        return max(-ceiling, min(ceiling, delayed * gain))  // guards only against float rounding
    }
}
