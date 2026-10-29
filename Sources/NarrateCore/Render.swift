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
        public let key: String
    }

    public static func planned(_ project: Project, _ settings: Project.Settings) throws -> [Planned] {
        try Chunker.plan(project.loadBook()).map {
            Planned(chunk: $0, key: key(engineID: settings.engineID, voice: settings.voice, speed: settings.speed, text: $0.text))
        }
    }

    public struct Stats: Sendable {
        public let chunks: Int
        public let rendered: Int
        public let audioSeconds: Double
        public let elapsedSeconds: Double
    }

    public static func render(
        _ project: Project,
        engine: SpeechEngine,
        voice: String,
        speed: Double,
        sections: Set<Int>? = nil,
        log: (String) -> Void = { print($0) }
    ) async throws -> Stats {
        let settings = Project.Settings(voice: voice, speed: speed, engineID: engine.engineID, sampleRate: engine.sampleRate)
        try project.save(settings)
        let planned = try planned(project, settings)
        struct Row: Encodable { let section: Int; let text: String; let pause: Double; let key: String }
        try writeJSON(planned.map { Row(section: $0.chunk.section, text: $0.chunk.text, pause: $0.chunk.pause, key: $0.key) }, to: project.root.appendingPathComponent("chunks.json"))

        let fm = FileManager.default
        let todo = planned.filter { !fm.fileExists(atPath: cacheURL(project, key: $0.key).path) && (sections?.contains($0.chunk.section) ?? true) }
        let totalChars = todo.reduce(0) { $0 + $1.chunk.text.count }
        log("\(planned.count) chunks planned, \(planned.count - todo.count) cached, \(todo.count) to render")

        let start = Date()
        var audioSeconds = 0.0, doneChars = 0, lastLog = 0.0
        for (i, item) in todo.enumerated() {
            let raw = try await engine.synthesize(item.chunk.text, voice: voice, speed: speed)
            let audio = trimSilence(raw, sampleRate: engine.sampleRate)
            guard !audio.isEmpty else { throw RenderError.noAudio(item.key, item.chunk.text) }
            let url = cacheURL(project, key: item.key)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try WAV.write(audio, sampleRate: engine.sampleRate, to: url)

            audioSeconds += Double(audio.count) / Double(engine.sampleRate)
            doneChars += item.chunk.text.count
            let elapsed = Date().timeIntervalSince(start)
            if elapsed - lastLog >= 30 || i + 1 == todo.count {
                lastLog = elapsed
                let eta = elapsed / Double(doneChars) * Double(totalChars - doneChars)
                log(String(format: "  %d/%d chunks · section %d · %.1f min audio in %.1f min (%.1f× real time) · ~%.0f min left",
                           i + 1, todo.count, item.chunk.section, audioSeconds / 60, elapsed / 60, audioSeconds / elapsed, eta / 60))
            }
        }
        return Stats(chunks: planned.count, rendered: todo.count, audioSeconds: audioSeconds, elapsedSeconds: Date().timeIntervalSince(start))
    }

    public enum RenderError: Error, CustomStringConvertible {
        case noAudio(String, String)
        public var description: String {
            switch self {
            case .noAudio(let key, let text): "engine returned no audio for chunk \(key): \(text)"
            }
        }
    }
}
