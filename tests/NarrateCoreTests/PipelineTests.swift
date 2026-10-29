import Foundation
import XCTest
@testable import NarrateCore

/// A deterministic stand-in for Kokoro: a 220 Hz tone whose length follows the text, padded with silence.
actor ToneEngine: SpeechEngine {
    nonisolated let engineID = "tone-v1"
    nonisolated let sampleRate = 24000
    private(set) var calls = 0

    func synthesize(_ text: String, voice: String, speed: Double) async throws -> [Float] {
        calls += 1
        let n = Int(0.02 * Double(text.count) * Double(sampleRate))
        let tone = (0..<n).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / Double(sampleRate))) }
        let silence = [Float](repeating: 0, count: sampleRate / 4)
        return silence + tone + silence
    }
}

final class PipelineTests: XCTestCase {
    func testTrimSilenceKeepsSpeechAndSmallPads() async throws {
        let audio = try await ToneEngine().synthesize(String(repeating: "x", count: 50), voice: "v", speed: 1)
        let seconds = Double(Renderer.trimSilence(audio, sampleRate: 24000).count) / 24000
        XCTAssertTrue(seconds > 1.0 && seconds < 1.2, "\(seconds)")
    }

    func testWAVRoundTrip() throws {
        let url = try Fixture.tempDir().appendingPathComponent("a.wav")
        try WAV.write([0, 0.5, -0.5, 1], sampleRate: 24000, to: url)
        let (samples, rate) = try WAV.read(url)
        XCTAssertEqual(rate, 24000)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[1], 0.5, accuracy: 0.001)
    }

    func testFFMetadataEscapesAndConvertsToMilliseconds() {
        let meta = Assembler.ffmetadata(tags: [("title", "A=B; C")], markers: [.init(title: "1 · X#", start: 0, end: 24000)], sampleRate: 24000)
        XCTAssertTrue(meta.contains("title=A\\=B\\; C"))
        XCTAssertTrue(meta.contains("START=0\nEND=1000\ntitle=1 · X\\#"))
    }

    func testBuildM4BWithChaptersAndCover() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg") else {
            throw XCTSkip("needs ffmpeg")
        }
        let dir = try Fixture.tempDir()
        let project = try Project.ingest(epub: Fixture.epub(in: dir), root: dir.appendingPathComponent("book.narrate"))
        // Replace the fake cover bytes with a real JPEG so ffmpeg can attach it.
        try Assembler.run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=brown:s=64x96", "-frames:v", "1", project.coverURL!.path])

        let engine = ToneEngine()
        let stats = try await Renderer.render(project, engine: engine, voice: "af_heart", speed: 1, log: { _ in })
        XCTAssertTrue(stats.chunks > 0)
        XCTAssertEqual(stats.rendered, stats.chunks)
        let again = try await Renderer.render(project, engine: engine, voice: "af_heart", speed: 1, log: { _ in })
        XCTAssertEqual(again.rendered, 0)  // everything comes from the cache

        let info = try Assembler.probe(Assembler.export(project, log: { _ in }))
        XCTAssertEqual(info.chapters, ["Part One — The Harbour", "1 · The Old Captain", "2 · A Black Spot"])
        XCTAssertTrue(info.cover)
        XCTAssertEqual(info.tags["title"], "The Test Voyage")
        XCTAssertEqual(info.tags["artist"], "Ann Author")
        XCTAssertGreaterThan(info.duration, 5)
    }
}
