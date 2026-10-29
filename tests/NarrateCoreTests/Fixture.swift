import Foundation
import XCTest

/// The same synthetic EPUB3 as the Python tests (tests/conftest.py): two chapters in one file split by
/// TOC anchors, a copyright page, a figure, a poem, a scene break, a page number and a footnote.
enum Fixture {
    static let files: [String: String] = [
        "mimetype": "application/epub+zip",
        "META-INF/container.xml": """
            <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """,
        "OEBPS/content.opf": """
            <?xml version="1.0" encoding="utf-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="id">test-book</dc:identifier>
                <dc:title>The Test Voyage</dc:title>
                <dc:creator id="a1">Ann Author</dc:creator>
                <dc:creator id="a2">Ivy Illustrator</dc:creator>
                <meta refines="#a2" property="role">ill</meta>
                <dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="copy" href="text/copyright.xhtml" media-type="application/xhtml+xml"/>
                <item id="body" href="text/body.xhtml" media-type="application/xhtml+xml"/>
                <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
              </manifest>
              <spine><itemref idref="copy"/><itemref idref="body"/><itemref idref="notes"/></spine>
            </package>
            """,
        "OEBPS/nav.xhtml": """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
            <nav epub:type="toc"><ol>
              <li><a href="text/copyright.xhtml">Copyright</a></li>
              <li><a href="text/body.xhtml#part1">PART ONE—The Harbour</a></li>
              <li><a href="text/body.xhtml#ch1">I The Old Captain</a></li>
              <li><a href="text/body.xhtml#ch2">II A Black Spot</a></li>
              <li><a href="text/notes.xhtml">Notes</a></li>
            </ol></nav></body></html>
            """,
        "OEBPS/text/copyright.xhtml": """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <body epub:type="frontmatter copyright-page"><p>Copyright 2026 Ann Author. All rights reserved.</p></body></html>
            """,
        "OEBPS/text/body.xhtml": """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
            <h1 id="part1">PART ONE—The Harbour</h1>
            <div class="fig"><img src="../images/cover.jpg" alt="ship"/><p class="caption">The ship at anchor</p></div>
            <h2 id="ch1">I<br/>The Old Captain</h2>
            <p>Dr. Livesey came late one
            afternoon.<a epub:type="noteref" href="notes.xhtml#n1">1</a> He looked at the captain.</p>
            <p class="poem">Fifteen men on the dead man's chest—<br/>Yo-ho-ho, and a bottle of rum!</p>
            <hr/>
            <p>Next morning the fog had lifted.</p>
            <h2 id="ch2">II<br/>A Black Spot</h2>
            <p><span epub:type="pagebreak" id="p12">12</span>It was in the year of grace 17—, a cold winter.</p>
            </body></html>
            """,
        "OEBPS/text/notes.xhtml": """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
            <section epub:type="endnotes"><aside epub:type="footnote" id="n1"><p>1. Livesey is said “LIV-see”.</p></aside></section>
            </body></html>
            """,
    ]

    /// Builds the EPUB with /usr/bin/zip (deflated entries) and returns its URL inside `dir`.
    static func epub(in dir: URL, cover: Data? = nil) throws -> URL {
        let src = dir.appendingPathComponent("src")
        for (path, content) in files {
            let url = src.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let coverURL = src.appendingPathComponent("OEBPS/images/cover.jpg")
        try FileManager.default.createDirectory(at: coverURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (cover ?? Data([0xFF, 0xD8, 0xFF, 0xE0] + Array("fakejpeg".utf8))).write(to: coverURL)

        let out = dir.appendingPathComponent("test-voyage.epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = src
        zip.arguments = ["-q", "-X", "-r", out.path, "mimetype", "META-INF", "OEBPS"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return out
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("narrate-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
