import Foundation

/// A book project is one folder: source EPUB, parsed structure, settings, audio cache, output.
public struct Project: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var bookURL: URL { root.appendingPathComponent("book.json") }
    public var settingsURL: URL { root.appendingPathComponent("settings.json") }
    /// Chunks that failed a signal check after their retry (`narrate review`).
    public var flagsURL: URL { root.appendingPathComponent("flags.json") }
    /// Cache keys of flagged chunks you listened to and kept (`narrate review --accept`).
    public var acceptedURL: URL { root.appendingPathComponent("accepted.json") }
    /// Per-book pronunciations (`narrate words`).
    public var lexiconURL: URL { root.appendingPathComponent("lexicon.json") }
    public var cacheDir: URL { root.appendingPathComponent("cache") }
    public var outDir: URL { root.appendingPathComponent("out") }
    public var workDir: URL { root.appendingPathComponent("work") }
    public var exists: Bool { FileManager.default.fileExists(atPath: bookURL.path) }

    public struct Settings: Codable, Sendable {
        public var voice: String
        public var speed: Double
        public var engineID: String
        public var sampleRate: Int

        public init(voice: String, speed: Double, engineID: String, sampleRate: Int) {
            self.voice = voice
            self.speed = speed
            self.engineID = engineID
            self.sampleRate = sampleRate
        }

        enum CodingKeys: String, CodingKey {
            case voice, speed
            case engineID = "engine_id"
            case sampleRate = "sample_rate"
        }
    }

    public var coverURL: URL? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return files.sorted().first { $0.hasPrefix("cover.") }.map { root.appendingPathComponent($0) }
    }

    public func loadBook() throws -> Book {
        try JSONDecoder().decode(Book.self, from: Data(contentsOf: bookURL))
    }

    public func save(_ book: Book) throws {
        try writeJSON(book, to: bookURL)
    }

    public func loadSettings() throws -> Settings? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL))
    }

    public func save(_ settings: Settings) throws {
        try writeJSON(settings, to: settingsURL)
    }

    public static func defaultRoot(for epub: URL) -> URL {
        epub.deletingPathExtension().appendingPathExtension("narrate")
    }

    public enum Failure: Error, CustomStringConvertible {
        case exists(URL)
        public var description: String {
            switch self {
            case .exists(let url): "\(url.path) already exists; pass --force to re-ingest (keeps the audio cache)"
            }
        }
    }

    /// Parse an EPUB into a project folder.
    public static func ingest(epub: URL, root: URL? = nil, force: Bool = false) throws -> Project {
        let project = Project(root: root ?? defaultRoot(for: epub))
        if project.exists && !force { throw Failure.exists(project.root) }
        let (book, cover) = try EPUBReader.read(epub)
        let fm = FileManager.default
        try fm.createDirectory(at: project.root, withIntermediateDirectories: true)
        let source = project.root.appendingPathComponent("source.epub")
        try? fm.removeItem(at: source)
        try fm.copyItem(at: epub, to: source)
        if let old = project.coverURL { try fm.removeItem(at: old) }
        if let cover { try cover.data.write(to: project.root.appendingPathComponent("cover.\(cover.fileExtension)")) }
        try project.save(book)
        return project
    }
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try (encoder.encode(value) + Data("\n".utf8)).write(to: url, options: .atomic)
}
