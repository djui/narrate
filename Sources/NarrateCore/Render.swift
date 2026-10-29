import CryptoKit
import Foundation

/// Render every chunk of the included sections into a content-addressed WAV cache.
public enum Renderer {
    static let silenceThreshold: Float = 0.004  // about -48 dBFS
    static let leadPad = 0.04
    static let tailPad = 0.06

    public static func key(engineID: String, voice: String, speed: Double, text: String) -> String {
        let payload = [engineID, voice, String(format: "%.3f", speed), text].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    public static func cacheURL(_ project: Project, key: String) -> URL {
        project.cacheDir.appendingPathComponent(String(key.prefix(2))).appendingPathComponent("\(key).wav")
    }

    /// Cut the model's own leading/trailing silence; assembly inserts exact pauses instead.
    public static func trimSilence(_ audio: [Float], sampleRate: Int) -> [Float] {
        let frame = max(1, sampleRate / 100)
        let n = audio.count / frame
        guard n > 0 else { return audio }
        var first = -1, last = -1
        for f in 0..<n {
            var sum: Float = 0
            for i in (f * frame)..<((f + 1) * frame) { sum += audio[i] * audio[i] }
            if (sum / Float(frame)).squareRoot() > silenceThreshold {
                if first < 0 { first = f }
                last = f
            }
        }
        guard first >= 0 else { return audio }
        let start = max(0, first * frame - Int(leadPad * Double(sampleRate)))
        let end = min(audio.count, (last + 1) * frame + Int(tailPad * Double(sampleRate)))
        return Array(audio[start..<end])
    }

    public struct Planned: Sendable {
        public let chunk: Chunk
        /// What Kokoro is given: the chunk text with lexicon markup.
        public let text: String
        public let key: String
    }

    public static func planned(_ project: Project, _ settings: Project.Settings, lexicon: Lexicon? = nil) throws -> [Planned] {
        let lexicon = try lexicon ?? Lexicon.merged(project)
        return try Chunker.plan(project.loadBook()).map {
            let text = try lexicon.apply($0.text)
            return Planned(chunk: $0, text: text, key: key(engineID: settings.engineID, voice: settings.voice, speed: settings.speed, text: text))
        }
    }

    public struct Stats: Sendable {
        public let chunks: Int
        public let rendered: Int
        public let flagged: Int
        public let audioSeconds: Double
        public let elapsedSeconds: Double
    }

    /// Pause between the two halves of a retried chunk.
    static let retryGap = 0.2

    /// Check one chunk's audio; on a flag, render it again in two halves and keep whichever
    /// version fails fewer checks. Records what still fails in `flags`.
    static func checked(
        _ item: Planned, audio first: [Float], engine: SpeechEngine, voice: String, speed: Double,
        rates: inout Checks.Median, flags: inout [String: Checks.Flag]
    ) async throws -> (audio: [Float], retried: Bool) {
        let rate = engine.sampleRate
        let median = rates.value(prior: Checks.priorRate * speed)
        var audio = first
        var metrics = Checks.measure(audio, text: item.text, sampleRate: rate)
        var reasons = Checks.reasons(metrics, text: item.text, medianRate: median)
        var retried = false
        if !reasons.isEmpty, let parts = Checks.splitForRetry(item.text) {
            retried = true
            var joined: [Float] = []
            for (i, part) in parts.enumerated() {
                if i > 0 { joined += [Float](repeating: 0, count: Int(retryGap * Double(rate))) }
                joined += trimSilence(try await engine.synthesize(part, voice: voice, speed: speed), sampleRate: rate)
            }
            let m = Checks.measure(joined, text: item.text, sampleRate: rate)
            let r = Checks.reasons(m, text: item.text, medianRate: median)
            if r.count <= reasons.count { (audio, metrics, reasons) = (joined, m, r) }
        }
        if reasons.isEmpty {
            flags[item.key] = nil
            if Checks.speechChars(item.text) >= Checks.minRateChars { rates.add(metrics.charsPerSecond) }
        } else {
            flags[item.key] = Checks.Flag(section: item.chunk.section, text: item.chunk.text, reasons: reasons, metrics: metrics, medianRate: median, retried: retried)
        }
        return (audio, retried)
    }

    /// Speaking rates of up to 200 chunks already in the cache, to seed the running median.
    static func cachedRates(_ project: Project, _ items: [Planned]) -> [Double] {
        let eligible = items.filter { Checks.speechChars($0.text) >= Checks.minRateChars }
        let step = max(1, eligible.count / 200)
        return stride(from: 0, to: eligible.count, by: step).compactMap { i in
            guard let (audio, rate) = try? WAV.read(cacheURL(project, key: eligible[i].key)) else { return nil }
            return Checks.measure(audio, text: eligible[i].text, sampleRate: rate).charsPerSecond
        }
    }

    /// Fill in phonemes for new entries in the book's and the global lexicon, so planning can apply them.
    public static func resolveLexicon(_ project: Project, phonemizer: Phonemizer) throws -> Lexicon {
        for url in [Lexicon.globalURL, project.lexiconURL] {
            var lexicon = try Lexicon.load(url)
            if lexicon.resolve(with: phonemizer) { try lexicon.save(url) }
        }
        return try Lexicon.merged(project)
    }

    /// Render missing chunks. With `recheck`, chunks already in the cache are checked too, and
    /// flagged ones not yet retried get their retry.
    public static func render(
        _ project: Project,
        engine: SpeechEngine,
        voice: String,
        speed: Double,
        sections: Set<Int>? = nil,
        phonemizer: Phonemizer? = nil,
        recheck: Bool = false,
        log: (String) -> Void = { print($0) }
    ) async throws -> Stats {
        let settings = Project.Settings(voice: voice, speed: speed, engineID: engine.engineID, sampleRate: engine.sampleRate)
        try project.save(settings)
        let lexicon = try phonemizer.map { try resolveLexicon(project, phonemizer: $0) }
        let planned = try planned(project, settings, lexicon: lexicon)
        struct Row: Encodable { let section: Int; let text: String; let pause: Double; let key: String }
        try writeJSON(planned.map { Row(section: $0.chunk.section, text: $0.chunk.text, pause: $0.chunk.pause, key: $0.key) }, to: project.root.appendingPathComponent("chunks.json"))

        let fm = FileManager.default
        let inScope = planned.filter { sections?.contains($0.chunk.section) ?? true }
        let isCached = { (item: Planned) in fm.fileExists(atPath: cacheURL(project, key: item.key).path) }
        let todo = inScope.filter { !isCached($0) }
        let totalChars = todo.reduce(0) { $0 + $1.chunk.text.count }
        log("\(planned.count) chunks planned, \(planned.count - todo.count) cached, \(todo.count) to render")

        var flags = try Checks.loadFlags(project)
        var rates = Checks.Median(cachedRates(project, planned.filter(isCached)))
        var retries = 0

        if recheck {
            var flaggedBefore = 0
            for item in inScope where isCached(item) && flags[item.key]?.retried != true {
                let url = cacheURL(project, key: item.key)
                let (audio, _) = try WAV.read(url)
                let result = try await checked(item, audio: audio, engine: engine, voice: voice, speed: speed, rates: &rates, flags: &flags)
                if result.retried {
                    flaggedBefore += 1
                    try WAV.write(result.audio, sampleRate: engine.sampleRate, to: url)
                    try Checks.save(flags, to: project)
                }
            }
            try Checks.save(flags, to: project)
            log("rechecked the cache: \(flaggedBefore) chunks retried")
        }

        let start = Date()
        var audioSeconds = 0.0, doneChars = 0, lastLog = 0.0
        for (i, item) in todo.enumerated() {
            let raw = try await engine.synthesize(item.text, voice: voice, speed: speed)
            let result = try await checked(item, audio: trimSilence(raw, sampleRate: engine.sampleRate), engine: engine, voice: voice, speed: speed, rates: &rates, flags: &flags)
            if result.retried {
                retries += 1
                try Checks.save(flags, to: project)
            }
            let url = cacheURL(project, key: item.key)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try WAV.write(result.audio, sampleRate: engine.sampleRate, to: url)

            audioSeconds += Double(result.audio.count) / Double(engine.sampleRate)
            doneChars += item.chunk.text.count
            let elapsed = Date().timeIntervalSince(start)
            if elapsed - lastLog >= 30 || i + 1 == todo.count {
                lastLog = elapsed
                let eta = elapsed / Double(doneChars) * Double(totalChars - doneChars)
                log(String(format: "  %d/%d chunks · section %d · %.1f min audio in %.1f min (%.1f× real time) · ~%.0f min left",
                           i + 1, todo.count, item.chunk.section, audioSeconds / 60, elapsed / 60, audioSeconds / elapsed, eta / 60))
            }
        }
        try Checks.save(flags, to: project)
        let keys = Set(planned.map(\.key))
        let flagged = flags.keys.filter(keys.contains).count
        if retries > 0 { log("\(retries) chunks failed a check and were retried") }
        if flagged > 0 { log("\(flagged) chunks flagged; list them with `narrate review \(project.root.path)`") }
        return Stats(chunks: planned.count, rendered: todo.count, flagged: flagged, audioSeconds: audioSeconds, elapsedSeconds: Date().timeIntervalSince(start))
    }
}
