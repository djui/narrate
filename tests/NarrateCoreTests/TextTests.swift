import XCTest
@testable import NarrateCore

final class TextTests: XCTestCase {
    func testNumberWords() {
        XCTAssertEqual([0, 17, 21, 100, 1883].map(NumberWords.words),
                       ["zero", "seventeen", "twenty-one", "one hundred", "one thousand eight hundred and eighty-three"])
    }

    func testRoman() {
        XCTAssertEqual(["I", "IV", "XIX", "XXXIV"].map(NumberWords.romanValue), [1, 4, 19, 34])
        XCTAssertNil(NumberWords.romanValue("IIII"))
        XCTAssertNil(NumberWords.romanValue("Ix"))
    }

    func testNormalize() {
        let cases = [
            ("Dr. Livesey and Mr. Trelawney", "Doctor Livesey and Mister Trelawney"),
            ("the year of grace 17—, and", "the year of grace seventeen hundred and blank, and"),
            ("SQUIRE TRELAWNEY said", "Squire Trelawney said"),
            ("pages 10–12", "pages 10 to 12"),
            ("rum, gold, etc. Then", "rum, gold, et cetera. Then"),
            ("a--b", "a—b"),
            ("[Illustration: the ship] It sailed.", "It sailed."),
            ("‘B3056,’ says Steve. ‘Through Lyndhurst, A337, M27, A31.’", "‘B three oh five six,’ says Steve. ‘Through Lyndhurst, A three three seven, M twenty-seven, A thirty-one.’"),
            ("B12 and C3PO and X-15", "B twelve and C3PO and X-15"),
        ]
        for (raw, spoken) in cases { XCTAssertEqual(Normalizer.normalize(raw), spoken, raw) }
    }

    func testDialogueTagStaysWithItsQuote() {
        let text = "“Ah,” said he, “this is the berth for me.” Then he went in. “Is it?” asked I."
        XCTAssertEqual(Chunker.sentences(text), ["“Ah,” said he, “this is the berth for me.”", "Then he went in.", "“Is it?” asked I."])
    }

    func testPackRespectsLimitAndKeepsEveryWord() {
        let text = (0..<40).map { "Sentence number \($0) goes on, and on, and on for a while." }.joined(separator: " ")
        let chunks = Chunker.pack(text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= Chunker.maxChars })
        XCTAssertEqual(chunks.joined(separator: " ").split(separator: " "), text.split(separator: " "))
    }

    func testPackSplitsOneOverlongSentenceAtSoftBreaks() {
        let text = Array(repeating: "the wind was rising over the black water", count: 20).joined(separator: "; ") + "."
        let chunks = Chunker.pack(text, maxChars: 120)
        XCTAssertTrue(chunks.count > 1 && chunks.allSatisfy { $0.count <= 120 })
    }

    func testPlanPausesFollowStructure() throws {
        let (book, _) = try EPUBReader.read(Fixture.epub(in: Fixture.tempDir()))
        let chunks = Chunker.plan(book)
        let texts = chunks.map(\.text)
        XCTAssertFalse(texts.joined().contains("Copyright"))
        let first = try XCTUnwrap(texts.firstIndex(of: "Chapter One. The Old Captain."))
        XCTAssertEqual(chunks[first].pause, Chunker.pauseAnnouncement)
        XCTAssertTrue(texts[first + 1].hasPrefix("Doctor Livesey came late"))
        XCTAssertEqual(chunks[try XCTUnwrap(texts.firstIndex(of: "Yo-ho-ho, and a bottle of rum!"))].pause, Chunker.pauseScene)
        XCTAssertEqual(chunks.last?.pause, Chunker.pauseSection)
        XCTAssertTrue(texts.last!.contains("seventeen hundred and blank"))
    }
}
