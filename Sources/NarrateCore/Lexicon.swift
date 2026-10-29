import Foundation
import MisakiSwift

/// English grapheme-to-phoneme conversion, as Kokoro hears it.
public protocol Phonemizer: AnyObject {
    func phonemes(_ text: String) -> String
    /// Words the G2P has no lexicon entry for, in order, with its guess at them.
    func unknownWords(_ text: String) -> [(word: String, guess: String)]
}

/// MisakiSwift's English G2P, the same one kokoro-coreml runs before synthesis.
public final class MisakiPhonemizer: Phonemizer {
    private let british: Bool
    private lazy var g2p = EnglishG2P(british: british)

    public init(voice: String = EngineDefaults.voice) { british = voice.hasPrefix("b") }

    public func phonemes(_ text: String) -> String { g2p.phonemize(text: text).0 }

    public func unknownWords(_ text: String) -> [(word: String, guess: String)] {
        // Rating 1 is the fallback network's guess; nil phonemes is a word Misaki dropped.
        g2p.phonemize(text: text).1.compactMap { token in
            guard token.text.contains(where: \.isLetter), token.phonemes == nil || token.`_`.rating == 1 else { return nil }
            return (token.text, token.phonemes ?? "")
        }
    }
}

/// Per-book pronunciations in `lexicon.json`: word → "sounds like" respelling (`"Liv-see"`), or
/// IPA between slashes (`"/lˈɪvsi/"`). Each entry is spoken through Misaki's
/// `[word](/phonemes/)` markup, so the chunk text, and with it the cache key, changes only for
/// chunks that contain the word.
public struct Lexicon: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var say: String
        /// The respelling's phonemes, filled in by `resolve`.
        public var phonemes: String?

        public init(say: String, phonemes: String? = nil) {
            self.say = say
            self.phonemes = phonemes
        }

        public init(from decoder: Decoder) throws {
            if let say = try? decoder.singleValueContainer().decode(String.self) {
                self.init(say: say)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(say: try c.decode(String.self, forKey: .say), phonemes: try c.decodeIfPresent(String.self, forKey: .phonemes))
        }
    }

    public var entries: [String: Entry]

    public init(_ entries: [String: Entry] = [:]) { self.entries = entries }

    public static func load(_ project: Project) throws -> Lexicon {
        guard FileManager.default.fileExists(atPath: project.lexiconURL.path) else { return Lexicon() }
        return Lexicon(try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: project.lexiconURL)))
    }

    public func save(_ project: Project) throws {
        try writeJSON(entries, to: project.lexiconURL)
    }

    public enum Failure: Error, CustomStringConvertible {
        case unresolved([String])
        public var description: String {
            switch self {
            case .unresolved(let words): "lexicon entries without phonemes: \(words.joined(separator: ", ")); run `narrate words PROJECT` or `narrate render` to resolve them"
            }
        }
    }

    /// Fill in phonemes for new or edited entries. Returns whether anything changed.
    @discardableResult
    public mutating func resolve(with g2p: Phonemizer) -> Bool {
        var changed = false
        for (word, entry) in entries where entry.phonemes == nil {
            let say = entry.say.trimmingCharacters(in: .whitespaces)
            let phonemes = say.count > 2 && say.hasPrefix("/") && say.hasSuffix("/")
                ? String(say.dropFirst().dropLast())
                // Syllables are read as words ("Liv see") and joined back into one word.
                : g2p.phonemes(say.replacingOccurrences(of: "-", with: " ")).filter { !$0.isWhitespace }
            entries[word] = Entry(say: entry.say, phonemes: phonemes.trimmingCharacters(in: .whitespaces))
            changed = true
        }
        return changed
    }

    private var pattern: Pattern? {
        guard !entries.isEmpty else { return nil }
        // Longest first so "Long John" wins over "John".
        let words = entries.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        let alternation = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return Pattern("(?<![\\p{L}\\p{N}])(?:\(alternation))(?![\\p{L}\\p{N}])", ignoreCase: true)
    }

    /// The text Kokoro is given: every entry's word wrapped in phoneme markup.
    public func apply(_ text: String) throws -> String {
        guard let pattern else { return text }
        let missing = entries.filter { $0.value.phonemes == nil }.keys.sorted()
        if !missing.isEmpty { throw Failure.unresolved(missing) }
        let byWord = Dictionary(entries.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        return pattern.replacing(in: text) { m in
            guard let phonemes = byWord[m.string.lowercased()]?.phonemes else { return m.string }
            return "[\(m.string)](/\(phonemes)/)"
        }
    }

    public struct UnknownWord: Sendable {
        public var word: String
        public var count: Int
        public var guess: String
        public var section: Int
        public var example: String
    }

    /// Words in the planned chunks the G2P has to guess, most frequent first. Words with a
    /// lexicon entry are spoken through markup and so never appear.
    public static func unknownWords(_ planned: [Renderer.Planned], phonemizer: Phonemizer) -> [UnknownWord] {
        var found: [String: UnknownWord] = [:]
        var order: [String] = []
        for item in planned {
            for (word, guess) in phonemizer.unknownWords(item.text) {
                // "Livesey's" is "Livesey".
                var bare = word
                for suffix in ["'s", "’s"] where bare.hasSuffix(suffix) { bare = String(bare.dropLast(suffix.count)) }
                let id = bare.lowercased()
                if found[id] != nil {
                    found[id]!.count += 1
                    continue
                }
                let example = Chunker.sentences(stripMarkup(item.text)).first { $0.contains(bare) } ?? item.chunk.text
                found[id] = UnknownWord(word: bare, count: 1, guess: guess, section: item.chunk.section, example: example)
                order.append(id)
            }
        }
        return order.compactMap { found[$0] }.enumerated().sorted { a, b in
            a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
        }.map(\.element)
    }

    private static let markup = Pattern(#"\[([^\]]+)\]\(/[^)]*/\)"#)

    /// Back to the words as printed, for display and rate checks.
    public static func stripMarkup(_ text: String) -> String {
        text.contains("](/") ? markup.replacing(in: text) { $0[1] ?? "" } : text
    }
}
