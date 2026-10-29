import Foundation

/// The parsed book, stored as `book.json` in the project folder.
public struct Block: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case para, verse, heading, note, sceneBreak = "scene_break" }

    public var kind: Kind
    public var text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct Section: Codable, Equatable, Sendable {
    /// chapter | part | front | back | titlepage | toc | copyright | boilerplate | index | notes | …
    public var title: String
    public var kind: String
    public var include: Bool
    public var blocks: [Block]
    public var number: Int?
    /// Chapter marker title in the M4B.
    public var marker: String
    /// Announcement read before the section, if any.
    public var spoken: String

    public init(title: String, kind: String = "", include: Bool = true, blocks: [Block] = [], number: Int? = nil, marker: String = "", spoken: String = "") {
        self.title = title
        self.kind = kind
        self.include = include
        self.blocks = blocks
        self.number = number
        self.marker = marker
        self.spoken = spoken
    }

    public var words: Int {
        blocks.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }
}

public struct Book: Codable, Equatable, Sendable {
    public var title: String
    public var author: String
    public var language: String
    public var sections: [Section]

    public init(title: String, author: String, language: String, sections: [Section]) {
        self.title = title
        self.author = author
        self.language = language
        self.sections = sections
    }
}

/// Cover image bytes and their file extension, kept out of `book.json`.
public struct Cover: Sendable {
    public var fileExtension: String
    public var data: Data
}
