import Foundation
import XCTest
@testable import NarrateCore

let rate = 24000

func tone(_ seconds: Double, level: Double = 0.3) -> [Float] {
    (0..<Int(seconds * Double(rate))).map { Float(level * sin(2 * Double.pi * 220 * Double($0) / Double(rate))) }
}

func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(rate))) }

/// Speech at Kokoro's usual rate, fading out like a real word ending, unless `broken` returns
/// something else for that text.
actor RateEngine: SpeechEngine {
    nonisolated let engineID = "rate-v1"
    nonisolated let sampleRate = rate
    private let broken: @Sendable (String) -> [Float]?
    private(set) var texts: [String] = []

    init(broken: @escaping @Sendable (String) -> [Float]? = { _ in nil }) { self.broken = broken }

    static func speech(_ text: String) -> [Float] {
        let audio = tone(Double(Checks.speechChars(text)) / Checks.priorRate)
        let fade = min(audio.count, rate / 20)
        return silence(0.2) + audio.enumerated().map { i, s in
            i < audio.count - fade ? s : s * Float(audio.count - i) / Float(fade)
        } + silence(0.2)
    }

    func synthesize(_ text: String, voice: String, speed: Double) async throws -> [Float] {
        texts.append(text)
        return broken(text) ?? Self.speech(text)
    }
}

/// A Phonemizer that treats capitalised words as unknown.
final class FakePhonemizer: Phonemizer {
    func phonemes(_ text: String) -> String { text.lowercased().replacingOccurrences(of: "v", with: "β") }
    func unknownWords(_ text: String) -> [(word: String, guess: String)] {
        Lexicon.stripMarkup(text).split(whereSeparator: { !$0.isLetter && $0 != "’" && $0 != "'" })
            .map(String.init).filter { $0.first!.isUppercase }
            .map { ($0, $0.lowercased()) }
    }
}

/// Keep the user's own global lexicon out of every test in the process (suites run in name order,
/// so this is set before PipelineTests too).
let testGlobalLexicon: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("narrate-tests-\(UUID().uuidString)/lexicon.json")
    Lexicon.globalURL = url
    return url
}()

final class ChecksTests: XCTestCase {
    override class func setUp() { _ = testGlobalLexicon }
    let text = "Fifteen men on the dead man's chest, and a bottle of rum for them all."

    func reasons(_ audio: [Float], _ text: String? = nil) -> [String] {
        let text = text ?? self.text
        let trimmed = Renderer.trimSilence(audio, sampleRate: rate)
        return Checks.reasons(Checks.measure(trimmed, text: text, sampleRate: rate), text: text, medianRate: Checks.priorRate)
    }

    func testCleanSpeechPasses() {
        XCTAssertEqual(reasons(RateEngine.speech(text)), [])
        let m = Checks.measure(Renderer.trimSilence(RateEngine.speech(text), sampleRate: rate), text: text, sampleRate: rate)
        XCTAssertEqual(m.charsPerSecond, Checks.priorRate, accuracy: 1)
    }

    func testStretchedAndSkippedSpeech() {
        XCTAssertEqual(reasons(RateEngine.speech(text + " " + text)), ["slow"])
        XCTAssertEqual(reasons(RateEngine.speech(String(text.prefix(30)))), ["fast"])
        // Too few letters to judge the rate by.
        XCTAssertEqual(reasons(RateEngine.speech("Ten feet. And so on"), "Ten feet."), [])
    }

    func testLongSilenceClippingEmptyAndCutOff() {
        let speech = RateEngine.speech(text)
        let gap = speech.count / 2
        XCTAssertEqual(reasons(Array(speech[..<gap]) + silence(2) + Array(speech[gap...])), ["long silence"])
        XCTAssertEqual(reasons(Array(speech[..<gap]) + silence(1) + Array(speech[gap...])), [])
        XCTAssertEqual(reasons(speech.map { $0 * 4 }), ["clipping"])
        XCTAssertEqual(reasons([]), ["too short"])
        XCTAssertEqual(reasons(Array(speech.dropLast(rate / 2))), ["cut off"])
    }

    func testSplitForRetryPrefersStrongBreaksNearTheMiddle() {
        XCTAssertEqual(Checks.splitForRetry("“Ah,” said he, “this is the berth.” Then he went in, slowly."),
                       ["“Ah,” said he, “this is the berth.”", "Then he went in, slowly."])
        XCTAssertEqual(Checks.splitForRetry("One, two, three, four, five, six"), ["One, two, three,", "four, five, six"])
        // Never inside phoneme markup, though the space in it is nearest the middle.
        XCTAssertEqual(Checks.splitForRetry("Doctor [Livesey](/lˈɪv sˈi/) came late to the inn"),
                       ["Doctor [Livesey](/lˈɪv sˈi/)", "came late to the inn"])
        XCTAssertNil(Checks.splitForRetry("Rum!"))
    }

    func testMedianWaitsForEnoughSamples() {
        var m = Checks.Median((1...29).map(Double.init))
        XCTAssertEqual(m.value(prior: 99), 99)
        m.add(100)
        XCTAssertEqual(m.value(prior: 99), 16)
    }

    func testRenderRetriesFlaggedChunksInTwoHalves() async throws {
        let dir = try Fixture.tempDir()
        let project = try Project.ingest(epub: Fixture.epub(in: dir), root: dir.appendingPathComponent("book.narrate"))
        let target = "Next morning the fog had lifted."
        // The whole chunk comes out stretched; its halves are fine.
        let engine = RateEngine { $0 == target ? tone(6) : nil }
        let stats = try await Renderer.render(project, engine: engine, voice: "af_heart", speed: 1, log: { _ in })
        XCTAssertEqual(stats.flagged, 0)
        let texts = await engine.texts
        XCTAssertEqual(texts.count, stats.chunks + 2)
        XCTAssertEqual(Array(texts.drop { $0 != target }.dropFirst().prefix(2)).joined(separator: " "), target)
        XCTAssertEqual(try Checks.loadFlags(project), [:])
    }

    func testRenderRecordsChunksThatStillFail() async throws {
        let dir = try Fixture.tempDir()
        let project = try Project.ingest(epub: Fixture.epub(in: dir), root: dir.appendingPathComponent("book.narrate"))
        let engine = RateEngine { $0.contains("fog") || $0.contains("lifted") ? tone(0.5) + silence(2) + tone(0.5) : nil }
        let stats = try await Renderer.render(project, engine: engine, voice: "af_heart", speed: 1, log: { _ in })
        XCTAssertEqual(stats.flagged, 1)
        let (key, flag) = try XCTUnwrap(Checks.loadFlags(project).first)
        XCTAssertEqual(flag.text, "Next morning the fog had lifted.")
        XCTAssertTrue(flag.retried)
        XCTAssertTrue(flag.reasons.contains("long silence"))

        // Scanning the cache finds the same chunk and nothing else.
        let planned = try Renderer.planned(project, XCTUnwrap(project.loadSettings()))
        XCTAssertEqual(try Checks.scan(project, planned).flags.values.map(\.text), [flag.text])

        // Once the chunk renders clean, its flag goes.
        try FileManager.default.removeItem(at: Renderer.cacheURL(project, key: key))
        _ = try await Renderer.render(project, engine: RateEngine(), voice: "af_heart", speed: 1, log: { _ in })
        XCTAssertEqual(try Checks.loadFlags(project), [:])
    }
}

final class LexiconTests: XCTestCase {
    override func setUp() { try? FileManager.default.removeItem(at: testGlobalLexicon) }
    override func tearDown() { try? FileManager.default.removeItem(at: testGlobalLexicon) }

    func resolved(_ entries: [String: String]) -> Lexicon {
        var lexicon = Lexicon(entries.mapValues { Lexicon.Entry(say: $0) })
        lexicon.resolve(with: FakePhonemizer())
        return lexicon
    }

    func testApplyWrapsWholeWordsInPhonemeMarkup() throws {
        let lexicon = resolved(["Livesey": "Liv-see", "Long John": "/lɔŋ ʤɑn/", "Ben": "Benn"])
        XCTAssertEqual(lexicon.entries["Livesey"]?.phonemes, "liβsee")
        XCTAssertEqual(lexicon.entries["Long John"]?.phonemes, "lɔŋ ʤɑn")
        XCTAssertEqual(try lexicon.apply("Doctor Livesey’s horse, and LIVESEY. Bent Ben; Long John."),
                       "Doctor [Livesey](/liβsee/)’s horse, and [LIVESEY](/liβsee/). Bent [Ben](/benn/); [Long John](/lɔŋ ʤɑn/).")
        XCTAssertEqual(try lexicon.apply("Nothing to change."), "Nothing to change.")
        XCTAssertEqual(Lexicon.stripMarkup(try lexicon.apply("Ask Livesey.")), "Ask Livesey.")
        XCTAssertEqual(Checks.speechChars(try lexicon.apply("Ask Livesey.")), 10)
    }

    func testUnresolvedEntriesRefuseToPlan() {
        XCTAssertThrowsError(try Lexicon(["Gunn": .init(say: "Gun")]).apply("Ben Gunn"))
    }

    func testFileAcceptsPlainRespellings() throws {
        let project = Project(root: try Fixture.tempDir())
        try Data(#"{"Livesey": "Liv-see"}"#.utf8).write(to: project.lexiconURL)
        var lexicon = try Lexicon.load(project)
        XCTAssertEqual(lexicon.entries["Livesey"], .init(say: "Liv-see"))
        XCTAssertTrue(lexicon.resolve(with: FakePhonemizer()))
        try lexicon.save(project)
        XCTAssertEqual(try Lexicon.load(project).entries["Livesey"]?.phonemes, "liβsee")
        XCTAssertFalse(lexicon.resolve(with: FakePhonemizer()))
    }

    func testEditingAnEntryReRendersOnlyChunksWithTheWord() async throws {
        let dir = try Fixture.tempDir()
        let project = try Project.ingest(epub: Fixture.epub(in: dir), root: dir.appendingPathComponent("book.narrate"))
        let g2p = FakePhonemizer()
        let first = try await Renderer.render(project, engine: RateEngine(), voice: "af_heart", speed: 1, phonemizer: g2p, log: { _ in })
        let withWord = Chunker.plan(try project.loadBook()).filter { $0.text.contains("Livesey") }.count
        XCTAssertGreaterThan(withWord, 0)
        XCTAssertLessThan(withWord, first.chunks)

        try Data(#"{"Livesey": "Liv-see"}"#.utf8).write(to: project.lexiconURL)
        let engine = RateEngine()
        let second = try await Renderer.render(project, engine: engine, voice: "af_heart", speed: 1, phonemizer: g2p, log: { _ in })
        XCTAssertEqual(second.rendered, withWord)
        let texts = await engine.texts
        XCTAssertTrue(texts.allSatisfy { $0.contains("[Livesey](/liβsee/)") })

        try Data(#"{"Livesey": "Liv-sey"}"#.utf8).write(to: project.lexiconURL)
        let third = try await Renderer.render(project, engine: RateEngine(), voice: "af_heart", speed: 1, phonemizer: g2p, log: { _ in })
        XCTAssertEqual(third.rendered, withWord)
    }

    func testGlobalEntriesApplyUnlessTheBookHasItsOwn() async throws {
        let dir = try Fixture.tempDir()
        let project = try Project.ingest(epub: Fixture.epub(in: dir), root: dir.appendingPathComponent("book.narrate"))
        try Lexicon(["Livesey": .init(say: "Lie-vsey"), "Captain": .init(say: "Cap-n")]).save(testGlobalLexicon)
        try Data(#"{"livesey": "Liv-see"}"#.utf8).write(to: project.lexiconURL)

        let g2p = FakePhonemizer()
        let engine = RateEngine()
        _ = try await Renderer.render(project, engine: engine, voice: "af_heart", speed: 1, phonemizer: g2p, log: { _ in })
        // Both files got their phonemes filled in.
        XCTAssertEqual(try Lexicon.load(testGlobalLexicon).entries["Captain"]?.phonemes, "capn")
        XCTAssertEqual(try Lexicon.load(project).entries["livesey"]?.phonemes, "liβsee")
        let text = await engine.texts.joined(separator: " ")
        XCTAssertTrue(text.contains("[Livesey](/liβsee/)"))
        XCTAssertFalse(text.contains("lieβsey"))
        XCTAssertTrue(text.contains("[captain](/capn/)"))

        // A global edit re-renders the chunks that use it, in every book.
        try Lexicon(["Livesey": .init(say: "Lie-vsey"), "Captain": .init(say: "Cap-tin")]).save(testGlobalLexicon)
        let captain = Chunker.plan(try project.loadBook()).filter { $0.text.localizedCaseInsensitiveContains("captain") }.count
        let again = try await Renderer.render(project, engine: RateEngine(), voice: "af_heart", speed: 1, phonemizer: g2p, log: { _ in })
        XCTAssertEqual(again.rendered, captain)
    }

    func testUnknownWordsRankedByFrequencyWithFirstExample() throws {
        let planned = ["Gunn came. Then Ben Gunn left.", "Ben’s hat. Ben's coat.", "Gunn again."].enumerated().map { i, text in
            Renderer.Planned(chunk: Chunk(section: i, text: text, pause: 0), text: text, key: "\(i)")
        }
        let words = Lexicon.unknownWords(planned, phonemizer: FakePhonemizer())
        XCTAssertEqual(words.map(\.word), ["Gunn", "Ben", "Then"])
        XCTAssertEqual(words.map(\.count), [3, 3, 1])
        XCTAssertEqual(words[0].example, "Gunn came.")
        XCTAssertEqual(words[1].example, "Then Ben Gunn left.")
    }
}
