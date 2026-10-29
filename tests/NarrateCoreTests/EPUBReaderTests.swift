import XCTest
@testable import NarrateCore

final class EPUBReaderTests: XCTestCase {
    var book: Book!
    var cover: Cover?

    override func setUpWithError() throws {
        (book, cover) = try EPUBReader.read(Fixture.epub(in: Fixture.tempDir()))
    }

    func testSpaceBetweenTwoInlineElementsIsKept() throws {
        // Gutenberg page markers: "the<span …><a …/></span> <i>appearance</i>"; Foundation alone reads "theappearance".
        let xml = #"<html xmlns="http://www.w3.org/1999/xhtml"><body><p>even the<span class="x"><a id="p"></a></span> <i>appearance</i> of <b>this</b>\#n<i>one</i></p></body></html>"#
        let p = try EPUBReader.Package.parse(Data(xml.utf8))
        XCTAssertEqual(EPUBReader.clean(p.stringValue ?? ""), "even the appearance of this one")
    }

    func testUntitledChapterIsAChapterButABareNumberIsNot() {
        func classify(_ title: String) -> Section {
            var s = Section(title: title, blocks: [Block(.para, String(repeating: "word ", count: 40))])
            EPUBReader.classify(&s, types: [], text: "", bookTitle: "Book", seenChapter: false, tocTitles: [])
            return s
        }
        let untitled = classify("Chapter 12")
        XCTAssertEqual([untitled.kind, untitled.marker, untitled.spoken], ["chapter", "Chapter 12", "Chapter Twelve."])
        XCTAssertEqual(untitled.number, 12)
        XCTAssertEqual(classify("12. The Storm").marker, "12 · The Storm")
        XCTAssertEqual(classify("12").kind, "front")
    }

    func testMetadataAndCover() {
        XCTAssertEqual([book.title, book.author, book.language], ["The Test Voyage", "Ann Author", "en"])
        XCTAssertEqual(cover?.fileExtension, "jpg")
    }

    func testSectionsFollowTOCAnchorsNotFiles() {
        XCTAssertEqual(book.sections.map(\.kind), ["copyright", "part", "chapter", "chapter"])
        XCTAssertEqual(book.sections.map(\.include), [false, true, true, true])
        XCTAssertEqual(book.sections.map(\.marker), ["", "Part One — The Harbour", "1 · The Old Captain", "2 · A Black Spot"])
    }

    func testChapterAnnouncementReplacesHeading() {
        let ch1 = book.sections[2]
        XCTAssertEqual(ch1.spoken, "Chapter One. The Old Captain.")
        XCTAssertFalse(ch1.blocks.contains { $0.kind == .heading })
    }

    func testBlocksFootnoteVerseSceneBreak() {
        let ch1 = book.sections[2]
        XCTAssertEqual(ch1.blocks.map(\.kind), [.para, .note, .verse, .sceneBreak, .para])
        XCTAssertEqual(ch1.blocks[0].text, "Dr. Livesey came late one afternoon. He looked at the captain.")
        XCTAssertEqual(ch1.blocks[1].text, "Livesey is said “LIV-see”.")
        XCTAssertEqual(ch1.blocks[2].text, "Fifteen men on the dead man's chest—\nYo-ho-ho, and a bottle of rum!")
    }

    func testFiguresAndPageNumbersAreNotRead() {
        let text = book.sections.flatMap(\.blocks).map(\.text).joined(separator: " ")
        XCTAssertFalse(text.contains("ship at anchor"))
        XCTAssertFalse(text.contains("12It"))
        XCTAssertTrue(text.contains("It was in the year"))
    }

    func testJSONRoundTrip() throws {
        let again = try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(again, book)
    }

    /// Projects written by the earlier Python implementation have nulls and snake_case block kinds.
    func testBookJSONWithNullsDecodes() throws {
        let json = #"{"title":"T","author":"A","language":"en","sections":[{"title":"I X","kind":"chapter","include":true,"blocks":[{"kind":"scene_break","text":""}],"number":null,"marker":"1 · X","spoken":"Chapter One. X."}]}"#
        let decoded = try JSONDecoder().decode(Book.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.sections[0].blocks[0].kind, .sceneBreak)
        XCTAssertNil(decoded.sections[0].number)
    }
}
