import Foundation
import KokoroTTS

/// A TTS engine. `engineID` becomes part of every chunk's cache key, so a new model or runtime
/// version re-renders everything.
public protocol SpeechEngine: Sendable {
    var engineID: String { get }
    var sampleRate: Int { get }
    /// Mono float PCM at `sampleRate`.
    func synthesize(_ text: String, voice: String, speed: Double) async throws -> [Float]
}

public enum EngineDefaults {
    public static let voice = "af_heart"
    public static let speed = 1.0
}

/// Kokoro-82M on Core ML via kokoro-coreml: Neural Engine, GPU and CPU, no Python.
/// The pinned starter bundle (~220 MB) downloads on first use into `cacheDirectory`.
public actor KokoroCoreMLEngine: SpeechEngine {
    public nonisolated let engineID = "kokoro-coreml@\(KokoroHostedModels.revision.prefix(12))"
    public nonisolated let sampleRate = 24000
    private let cacheDirectory: URL
    private var tts: KokoroTTS?

    public init(cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/narrate/kokoro-coreml")) {
        self.cacheDirectory = cacheDirectory
    }

    private func loaded() async throws -> KokoroTTS {
        if let tts { return tts }
        let resources = try await KokoroResourceProvider.huggingFace(cacheDirectory: cacheDirectory, progress: nil)
        let loaded = try await KokoroTTS.load(resources: resources)
        tts = loaded
        return loaded
    }

    public func synthesize(_ text: String, voice: String, speed: Double) async throws -> [Float] {
        let tts = try await loaded()
        let audio = try await tts.synthesize(text, voice: KokoroVoiceID(voice), options: KokoroSynthesisOptions(speed: Float(speed)))
        return audio.samples
    }
}
