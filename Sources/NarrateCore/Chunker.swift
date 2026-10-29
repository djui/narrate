import Foundation

/// A TTS-sized piece of text and the silence that follows it.
public struct Chunk: Codable, Equatable, Sendable {
    public var section: Int
    public var text: String
    public var pause: Double
}

/// Split sections into chunks; pauses come from the book's structure and are inserted as exact
/// silence at assembly time, so the model never has to guess where a paragraph or scene ends.
public enum Chunker {
    /// Kokoro truncates past ~510 phoneme tokens; 300 characters stays well under.
    public static let maxChars = 300

    public static let pauseSentence = 0.25
    public static let pauseLine = 0.35
    public static let pauseParagraph = 0.6
    public static let pauseHeading = 1.0
    public static let pauseAnnouncement = 1.2
    public static let pauseScene = 1.4
    public static let pauseSection = 2.0

    // A sentence ends at . ! ? … plus closing quotes, before whitespace and a capital or opening quote.
    private static let sentenceEnd = Pattern("([.!?…]+[”\"’'»)\\]]*)\\s+(?=[“\"‘'«(\\[]?[A-Z0-9])")
    private static let softBreaks = ["; ", ": ", " — ", "— ", ", "]

    public static func sentences(_ text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = []
        var last = 0
        for m in sentenceEnd.matches(in: text) {
            let end = m.result.range(at: 1)
            out.append(ns.substring(with: NSRange(location: last, length: end.location + end.length - last)).trimmingCharacters(in: .whitespaces))
            last = m.range.location + m.range.length
        }
        out.append(ns.substring(from: last).trimmingCharacters(in: .whitespaces))
        return out.filter { !$0.isEmpty }
    }

    static func splitLong(_ input: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var text = Array(input)
        while text.count > maxChars {
            let window = String(text[0...maxChars])
            var cut = -1
            for sep in softBreaks {
                if let r = window.range(of: sep, options: .backwards) {
                    let pos = window.distance(from: window.startIndex, to: r.lowerBound)
                    if Double(pos) > Double(maxChars) * 0.4 {
                        cut = pos + sep.trimmingCharacters(in: .whitespaces).count + (sep.hasPrefix(" ") ? 1 : 0)
                        break
                    }
                }
            }
            if cut < 0, let r = window.range(of: " ", options: .backwards) {
                cut = window.distance(from: window.startIndex, to: r.lowerBound)
            }
            if cut <= 0 { cut = maxChars }
            pieces.append(String(text[..<cut]).trimmingCharacters(in: .whitespaces))
            text = Array(String(text[cut...]).trimmingCharacters(in: .whitespaces))
        }
        if !text.isEmpty { pieces.append(String(text)) }
        return pieces
    }

    /// Greedily pack whole sentences into chunks of at most maxChars.
    public static func pack(_ text: String, maxChars: Int = maxChars) -> [String] {
        var chunks: [String] = []
        var current = ""
        for sentence in sentences(text) {
            for piece in splitLong(sentence, maxChars: maxChars) {
                if !current.isEmpty, current.count + 1 + piece.count > maxChars {
                    chunks.append(current)
                    current = piece
                } else {
                    current = current.isEmpty ? piece : current + " " + piece
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// All chunks for the included sections, in reading order.
    public static func plan(_ book: Book, maxChars: Int = maxChars) -> [Chunk] {
        var chunks: [Chunk] = []

        func add(_ section: Int, _ text: String, _ pause: Double) {
            let speech = Normalizer.normalize(text)
            if speech.hasAlphanumeric { chunks.append(Chunk(section: section, text: speech, pause: pause)) }
        }
        func bump(_ pause: Double) {
            if !chunks.isEmpty { chunks[chunks.count - 1].pause = max(chunks[chunks.count - 1].pause, pause) }
        }

        for (idx, section) in book.sections.enumerated() where section.include {
            if !section.spoken.isEmpty { add(idx, section.spoken, pauseAnnouncement) }
            for block in section.blocks {
                switch block.kind {
                case .sceneBreak:
                    bump(pauseScene)
                case .heading:
                    add(idx, EPUBReader.titlecase(block.text), pauseHeading)  // all-caps would be read as shouting
                case .verse:
                    for line in block.text.split(separator: "\n") {
                        for piece in pack(String(line), maxChars: maxChars) { add(idx, piece, pauseLine) }
                    }
                    bump(pauseParagraph)
                case .para, .note:
                    let text = block.kind == .note ? "Note: \(block.text)" : block.text
                    for piece in pack(text, maxChars: maxChars) { add(idx, piece, pauseSentence) }
                    bump(pauseParagraph)
                }
            }
            if let last = chunks.last, last.section == idx { chunks[chunks.count - 1].pause = pauseSection }
        }
        return chunks
    }
}
