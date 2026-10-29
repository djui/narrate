import Foundation
import ImageIO
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

    func sine(_ amplitude: Double, seconds: Double, rate: Int = 24000, hz: Double = 997) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / Double(rate))) }
    }

    func testLoudnessMatchesBS1770Reference() {
        // BS.1770: a 997 Hz sine at 0 dBFS in one channel reads -3.01 LUFS, so -20 dBFS reads -23.01.
        for rate in [24000, 48000] {
            var meter = LoudnessMeter(sampleRate: rate)
            meter.add(sine(0.1, seconds: 5, rate: rate))
            XCTAssertEqual(meter.integrated, -23.01, accuracy: 0.05, "\(rate) Hz")
        }
        // Silence is gated out; only the few blocks straddling the edge to the tone count, a little.
        var meter = LoudnessMeter(sampleRate: 24000)
        meter.add([Float](repeating: 0, count: 24000 * 5))
        XCTAssertEqual(meter.integrated, -.infinity)
        meter.add(sine(0.1, seconds: 5))
        XCTAssertEqual(meter.integrated, -23.01, accuracy: 0.2)
    }

    func testGainToTargetAndNoneForSilence() {
        XCTAssertEqual(Assembler.gain(measured: -25.64), 7.64, accuracy: 0.001)
        XCTAssertEqual(Assembler.gain(measured: -.infinity), 0)
    }

    func testLimiterHoldsCeilingAndPassesQuietAudio() {
        var limiter = Limiter(ceiling: 0.68, sampleRate: 24000)
        let quiet = sine(0.5, seconds: 0.5)
        let loud = sine(2, seconds: 0.5)
        let out = limiter.process(quiet + loud + quiet) + limiter.flush()
        let lag = limiter.lookahead
        XCTAssertEqual(out.count, quiet.count * 2 + loud.count + lag)
        XCTAssertLessThanOrEqual(out.map(abs).max()!, 0.68 + 1e-6)
        // Before the loud part arrives the signal passes untouched (after the lookahead delay).
        for i in 0..<quiet.count - lag { XCTAssertEqual(out[i + lag], quiet[i], accuracy: 1e-6) }
        // Once released, the quiet tail is back at unity gain.
        let tail = out[(out.count - lag - 2400)..<(out.count - lag)].map(abs).max()!
        XCTAssertEqual(tail, 0.5, accuracy: 0.01)
    }

    func testBuildM4BWithChaptersAndCover() async throws {
        let dir = try Fixture.tempDir()
        let project = try Project.ingest(epub: Fixture.epub(in: dir), root: dir.appendingPathComponent("book.narrate"))
        // Replace the fake cover bytes with a real image so it can be attached.
        try Self.png(width: 64, height: 96).write(to: project.coverURL!)

        let engine = ToneEngine()
        let stats = try await Renderer.render(project, engine: engine, voice: "af_heart", speed: 1, log: { _ in })
        XCTAssertTrue(stats.chunks > 0)
        XCTAssertEqual(stats.rendered, stats.chunks)
        let again = try await Renderer.render(project, engine: engine, voice: "af_heart", speed: 1, log: { _ in })
        XCTAssertEqual(again.rendered, 0)  // everything comes from the cache

        let info = try await Assembler.probe(Assembler.export(project, log: { _ in }))
        XCTAssertEqual(info.chapters, ["Part One — The Harbour", "1 · The Old Captain", "2 · A Black Spot"])
        XCTAssertTrue(info.cover)
        XCTAssertEqual(info.tags["title"], "The Test Voyage")
        XCTAssertEqual(info.tags["artist"], "Ann Author")
        XCTAssertEqual(info.tags["genre"], "Audiobook")
        XCTAssertEqual(info.audio, "aac 44100 Hz 1ch")
        XCTAssertGreaterThan(info.duration, 5)
    }

    static func png(width: Int, height: Int) throws -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }
}
