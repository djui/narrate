import Foundation

/// Signal checks on a rendered chunk: no extra model, only the audio and the text it should say.
/// A flag means "listen to this one", not "this is wrong".
public enum Checks {
    /// Speaking rate outside these multiples of the book's running median: stretched, rushed or skipped speech.
    public static let slowRate = 0.55
    public static let fastRate = 1.5
    /// Rates of very short chunks ("Chapter One") are too noisy to judge.
    public static let minRateChars = 20
    /// The model's own pause inside a chunk; assembly inserts the real pauses between chunks.
    public static let maxSilence = 1.5
    public static let minSeconds = 0.25
    /// Samples at or above this level count as clipped; a few are harmless.
    public static let clipLevel: Float = 0.99
    public static let maxClipped = 0.001
    /// The last 10 ms of trimmed audio still at speech level: the model stopped mid-sound.
    public static let maxTailLevel = 0.02
    /// Kokoro af_heart at 1.0× (voiced letters per second), used until the book has its own median.
    public static let priorRate = 18.0
    static let silenceLevel: Float = 0.004  // about -48 dBFS, as in trimming

    public struct Metrics: Codable, Equatable, Sendable {
        public var seconds: Double
        /// Letters and digits per second of voiced audio: the model's own pauses at commas and
        /// quotes vary a lot between chunks, the speaking rate itself much less.
        public var charsPerSecond: Double
        public var longestSilence: Double
        public var clipped: Double
        public var tailLevel: Double

        enum CodingKeys: String, CodingKey {
            case seconds
            case charsPerSecond = "chars_per_second"
            case longestSilence = "longest_silence"
            case clipped
            case tailLevel = "tail_level"
        }
    }

    /// Letters and digits take speaking time; spaces and punctuation mostly don't. Phoneme markup
    /// from the lexicon counts as the word it replaces.
    public static func speechChars(_ text: String) -> Int {
        Lexicon.stripMarkup(text).reduce(0) { $0 + (($1.isLetter || $1.isNumber) ? 1 : 0) }
    }

    public static func measure(_ audio: [Float], text: String, sampleRate: Int) -> Metrics {
        let seconds = Double(audio.count) / Double(sampleRate)
        let frame = max(1, sampleRate / 100)
        var run = 0, longest = 0, clipped = 0, voiced = 0
        for f in 0..<(audio.count / frame) {
            var sum: Float = 0
            for i in (f * frame)..<((f + 1) * frame) {
                let s = audio[i]
                sum += s * s
                if abs(s) >= clipLevel { clipped += 1 }
            }
            if (sum / Float(frame)).squareRoot() <= silenceLevel { run += 1; longest = max(longest, run) } else { run = 0; voiced += 1 }
        }
        let tailStart = max(0, audio.count - frame)
        var tail: Float = 0
        for i in tailStart..<audio.count { tail += audio[i] * audio[i] }
        let tailLevel = audio.count > tailStart ? (tail / Float(audio.count - tailStart)).squareRoot() : 0
        return Metrics(
            seconds: seconds,
            charsPerSecond: voiced > 0 ? Double(speechChars(text)) / (Double(voiced * frame) / Double(sampleRate)) : 0,
            longestSilence: Double(longest * frame) / Double(sampleRate),
            clipped: audio.isEmpty ? 0 : Double(clipped) / Double(audio.count),
            tailLevel: Double(tailLevel)
        )
    }

    /// Reasons this chunk needs a listen, empty if none.
    public static func reasons(_ m: Metrics, text: String, medianRate: Double) -> [String] {
        var out: [String] = []
        if m.seconds < minSeconds {
            out.append("too short")
        } else if speechChars(text) >= minRateChars {
            if m.charsPerSecond < medianRate * slowRate { out.append("slow") }
            if m.charsPerSecond > medianRate * fastRate { out.append("fast") }
        }
        if m.longestSilence > maxSilence { out.append("long silence") }
        if m.clipped > maxClipped { out.append("clipping") }
        if m.tailLevel > maxTailLevel { out.append("cut off") }
        return out
    }

    /// Split for the retry: at the strongest punctuation nearest the middle, never inside phoneme
    /// markup. Nil if the text has no usable break.
    public static func splitForRetry(_ text: String) -> [String]? {
        let chars = Array(text)
        let ranks: [Character: Int] = [".": 4, "!": 4, "?": 4, "…": 4, ";": 3, ":": 3, "—": 3, ",": 2]
        var best: (rank: Int, distance: Int, cut: Int)?
        var depth = 0
        for (i, c) in chars.enumerated() {
            if c == "[" || c == "(" { depth += 1 }
            if c == "]" || c == ")" { depth = max(0, depth - 1) }
            // Skip slivers at either end.
            guard depth == 0, c == " ", i >= chars.count / 5, i <= chars.count * 4 / 5 else { continue }
            // A space after punctuation (and closing quotes) is a break of that strength.
            var j = i - 1
            while j > 0, "”\"’'»".contains(chars[j]) { j -= 1 }
            let rank = ranks[chars[j]] ?? 1
            let distance = abs(i - chars.count / 2)
            if best == nil || rank > best!.rank || (rank == best!.rank && distance < best!.distance) {
                best = (rank, distance, i)
            }
        }
        guard let cut = best?.cut else { return nil }
        let parts = [String(chars[..<cut]), String(chars[(cut + 1)...])].map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.allSatisfy({ speechChars($0) > 0 }) ? parts : nil
    }

    /// Running median of speaking rates.
    public struct Median: Sendable {
        private var sorted: [Double]
        public init(_ values: [Double] = []) { sorted = values.sorted() }
        public var count: Int { sorted.count }
        public mutating func add(_ v: Double) {
            var lo = 0, hi = sorted.count
            while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < v { lo = mid + 1 } else { hi = mid } }
            sorted.insert(v, at: lo)
        }
        /// Falls back to `prior` until there are enough samples to trust.
        public func value(prior: Double) -> Double {
            sorted.count < 30 ? prior : sorted[sorted.count / 2]
        }
    }

    /// A chunk that still failed a check after its retry.
    public struct Flag: Codable, Equatable, Sendable {
        public var section: Int
        public var text: String
        public var reasons: [String]
        public var metrics: Metrics
        public var medianRate: Double
        public var retried: Bool

        enum CodingKeys: String, CodingKey {
            case section, text, reasons, metrics, retried
            case medianRate = "median_rate"
        }
    }

    /// Check the cached audio of every planned chunk against the book's overall median, without
    /// re-rendering anything. Returns the metrics of every chunk and the flags.
    public static func scan(_ project: Project, _ planned: [Renderer.Planned]) throws -> (metrics: [String: Metrics], flags: [String: Flag]) {
        var metrics: [String: Metrics] = [:]
        for item in planned {
            let url = Renderer.cacheURL(project, key: item.key)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let (audio, rate) = try WAV.read(url)
            metrics[item.key] = measure(audio, text: item.text, sampleRate: rate)
        }
        let median = Median(planned.compactMap { speechChars($0.text) >= minRateChars ? metrics[$0.key]?.charsPerSecond : nil }).value(prior: priorRate)
        var flags: [String: Flag] = [:]
        for item in planned {
            guard let m = metrics[item.key] else { continue }
            let r = reasons(m, text: item.text, medianRate: median)
            if !r.isEmpty { flags[item.key] = Flag(section: item.chunk.section, text: item.chunk.text, reasons: r, metrics: m, medianRate: median, retried: false) }
        }
        return (metrics, flags)
    }

    public static func loadFlags(_ project: Project) throws -> [String: Flag] {
        guard FileManager.default.fileExists(atPath: project.flagsURL.path) else { return [:] }
        return try JSONDecoder().decode([String: Flag].self, from: Data(contentsOf: project.flagsURL))
    }

    public static func save(_ flags: [String: Flag], to project: Project) throws {
        try writeJSON(flags, to: project.flagsURL)
    }
}
