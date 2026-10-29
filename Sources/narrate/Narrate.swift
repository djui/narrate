import ArgumentParser
import Foundation
import NarrateCore

@main
struct Narrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Turn a DRM-free EPUB into an M4B audiobook, offline, with Kokoro on Core ML.",
        subcommands: [Ingest.self, Contents.self, Plan.self, Render.self, Review.self, Words.self, Export.self, Build.self]
    )
}

/// Speaking rate used for time estimates: Kokoro af_heart at 1.0×, measured in the bake-off.
let wordsPerMinute = 200.0

func openProject(_ path: String) throws -> Project {
    var url = URL(fileURLWithPath: path)
    if url.pathExtension == "epub" { url = Project.defaultRoot(for: url) }
    let project = Project(root: url)
    guard project.exists else { throw ValidationError("no project at \(url.path); run `narrate ingest` first") }
    return project
}

func indices(_ spec: String?) throws -> Set<Int> {
    var out = Set<Int>()
    for part in (spec ?? "").split(separator: ",") {
        let bounds = part.split(separator: "-").compactMap { Int($0) }
        guard let lo = bounds.first else { throw ValidationError("bad section list: \(part)") }
        out.formUnion(lo...(bounds.count > 1 ? bounds[1] : lo))
    }
    return out
}

func printContents(_ project: Project, speed: Double) throws {
    let book = try project.loadBook()
    print("\(book.title) — \(book.author)")
    var total = 0.0
    for (i, s) in book.sections.enumerated() {
        let minutes = Double(s.words) / (wordsPerMinute * speed)
        if s.include { total += minutes }
        let label = s.marker.isEmpty ? (s.title.isEmpty ? "(untitled)" : s.title) : s.marker
        let kind = s.kind.padding(toLength: 11, withPad: " ", startingAt: 0)
        print("\(String(format: "%3d", i)) [\(s.include ? "✓" : " ")] \(kind) \(String(format: "%6d words %6.1f min", s.words, minutes))  \(label)")
    }
    print(String(format: "included: ≈ %.1f h at speed %.2f", total / 60, speed))
}

func render(_ project: Project, voice: VoiceOptions, sections: Set<Int>?, recheck: Bool = false) async throws {
    // Keep the Mac awake while rendering; the assertion ends with the activity.
    let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Rendering audiobook")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    _ = try await Renderer.render(project, engine: KokoroCoreMLEngine(), voice: voice.voice, speed: voice.speed, sections: sections,
                                  phonemizer: MisakiPhonemizer(voice: voice.voice), recheck: recheck)
}

func export(_ project: Project) throws {
    let out = try Assembler.export(project)
    let info = try Assembler.probe(out)
    print(String(format: "%.2f h · %d chapters · ", info.duration / 3600, info.chapters.count) + "\(info.audio) · cover: \(info.cover ? "yes" : "no")")
}

struct VoiceOptions: ParsableArguments {
    @Option(help: "Kokoro voice") var voice = EngineDefaults.voice
    @Option(help: "Speaking speed") var speed = EngineDefaults.speed
}

struct Ingest: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Parse an EPUB into a project folder.")
    @Argument var epub: String
    @Option(help: "Project folder (default: BOOK.narrate next to the EPUB)") var project: String?
    @Flag(help: "Re-ingest an existing project; the audio cache is kept") var force = false

    func run() throws {
        let p = try Project.ingest(epub: URL(fileURLWithPath: epub), root: project.map { URL(fileURLWithPath: $0) }, force: force)
        print("ingested into \(p.root.path)")
        try printContents(p, speed: EngineDefaults.speed)
    }
}

struct Contents: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List sections and choose which to include.")
    @Argument var project: String
    @Option(help: "Section numbers to include, e.g. 2,4-6") var include: String?
    @Option(help: "Section numbers to leave out") var exclude: String?

    func run() throws {
        let p = try openProject(project)
        if include != nil || exclude != nil {
            var book = try p.loadBook()
            for i in try indices(include) { book.sections[i].include = true }
            for i in try indices(exclude) { book.sections[i].include = false }
            try p.save(book)
        }
        try printContents(p, speed: try p.loadSettings()?.speed ?? EngineDefaults.speed)
    }
}

struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the chunk plan as JSON (for comparing implementations).")
    @Argument var project: String

    func run() throws {
        let chunks = Chunker.plan(try openProject(project).loadBook())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(chunks), as: UTF8.self))
    }
}

struct Render: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render missing chunks (resumable).")
    @Argument var project: String
    @Option(help: "Only render these section numbers, e.g. 5-7") var sections: String?
    @Flag(help: "Also check chunks already in the cache and retry flagged ones") var recheck = false
    @OptionGroup var voice: VoiceOptions

    func run() async throws {
        try await render(try openProject(project), voice: voice, sections: sections == nil ? nil : try indices(sections), recheck: recheck)
    }
}

func sectionLabel(_ book: Book, _ i: Int) -> String {
    let s = book.sections[i]
    return s.marker.isEmpty ? (s.title.isEmpty ? "section \(i)" : s.title) : s.marker
}

func plannedChunks(_ project: Project) throws -> [Renderer.Planned] {
    guard let settings = try project.loadSettings() else { throw ValidationError("nothing rendered yet; run `narrate render` first") }
    return try Renderer.planned(project, settings)
}

struct Review: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List chunks that failed a signal check, to listen to.")
    @Argument var project: String
    @Flag(help: "Check the cached audio again without re-rendering (`render --recheck` also retries)") var scan = false
    @Option(help: "Keep a flagged chunk as it is, by key or WAV path (repeatable)") var accept: [String] = []
    @Option(help: .hidden) var metrics: String?

    func run() throws {
        let p = try openProject(project)
        let planned = try plannedChunks(p)
        var flags = try Checks.loadFlags(p)
        if !accept.isEmpty {
            let keys = Set(accept.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
            for key in keys where flags[key] == nil { throw ValidationError("\(key) is not flagged") }
            try Checks.accept(keys, in: p)
            flags = try Checks.loadFlags(p)
        }
        if scan || metrics != nil {
            let result = try Checks.scan(p, planned)
            if let metrics {
                struct Row: Encodable { let key: String; let section: Int; let text: String; let speech_chars: Int; let metrics: Checks.Metrics }
                let rows = planned.compactMap { item in result.metrics[item.key].map { Row(key: item.key, section: item.chunk.section, text: item.chunk.text, speech_chars: Checks.speechChars(item.text), metrics: $0) } }
                try JSONEncoder().encode(rows).write(to: URL(fileURLWithPath: metrics))
            }
            if scan {
                // Keep the record of earlier retries for chunks that still fail.
                flags = result.flags.mapValues { flag in
                    var flag = flag
                    flag.retried = flags.values.contains { $0.text == flag.text && $0.retried }
                    return flag
                }
                try Checks.save(flags, to: p)
            }
        }
        let book = try p.loadBook()
        let flagged = planned.filter { flags[$0.key] != nil }
        for item in flagged {
            let f = flags[item.key]!
            let m = f.metrics
            var numbers = [String(format: "%.1f s", m.seconds), String(format: "%.1f chars/s (median %.1f)", m.charsPerSecond, f.medianRate)]
            if m.longestSilence > 0.5 { numbers.append(String(format: "silence %.1f s", m.longestSilence)) }
            if m.clipped > 0 { numbers.append(String(format: "%.2f%% clipped", m.clipped * 100)) }
            if f.reasons.contains("cut off") { numbers.append(String(format: "ends at %.2f", m.tailLevel)) }
            print("\(String(format: "%3d", f.section)) \(sectionLabel(book, f.section)) · \(f.reasons.joined(separator: ", ")) · \(numbers.joined(separator: " · "))\(f.retried ? " · retried" : "")")
            print("    \(f.text)")
            print("    \(Renderer.cacheURL(p, key: item.key).path)")
        }
        print(String(format: "%d of %d chunks flagged (%.2f%%)", flagged.count, planned.count, 100 * Double(flagged.count) / Double(max(1, planned.count)))
              + " · \(try Checks.loadAccepted(p).count) accepted")
    }
}

/// About `width` characters of `text` around the first `word`.
func excerpt(_ text: String, around word: String, width: Int = 90) -> String {
    guard text.count > width, let r = text.range(of: word) else { return text }
    let at = text.distance(from: text.startIndex, to: r.lowerBound)
    let start = max(0, min(at - width / 3, text.count - width))
    let piece = String(Array(text)[start..<min(text.count, start + width)])
    return (start > 0 ? "…" : "") + piece + (start + width < text.count ? "…" : "")
}

struct Words: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List words Kokoro's G2P has to guess, and set how they sound.",
        discussion: """
            Entries live in PROJECT/lexicon.json, or with --global in \(Lexicon.globalURL.path) for every book, as \
            word → sounds-like spelling ("Liv-see") or IPA between slashes ("/lˈɪvsi/"). A book's entry wins over a \
            global one. Changing one re-renders only the chunks that contain the word.
            """
    )
    @Argument var project: String
    @Option(help: "How many words to list") var limit = 50
    @Option(name: .customLong("set"), help: "WORD=SOUNDS-LIKE, e.g. Livesey=Liv-see (repeatable)") var entries: [String] = []
    @Option(help: "Remove a lexicon entry (repeatable)") var remove: [String] = []
    @Flag(help: "Edit the global lexicon instead of the book's") var global = false

    func run() throws {
        let p = try openProject(project)
        let voice = try p.loadSettings()?.voice ?? EngineDefaults.voice
        let settings = try p.loadSettings() ?? Project.Settings(voice: voice, speed: EngineDefaults.speed, engineID: "", sampleRate: 24000)
        let g2p = MisakiPhonemizer(voice: voice)
        let book = try p.loadBook()

        if !remove.isEmpty || !entries.isEmpty {
            let before = try Renderer.planned(p, settings, lexicon: Renderer.resolveLexicon(p, phonemizer: g2p))
            let url = global ? Lexicon.globalURL : p.lexiconURL
            var lexicon = try Lexicon.load(url)
            for word in remove {
                guard lexicon.entries.removeValue(forKey: word) != nil else { throw ValidationError("\(word) is not in \(url.path)") }
            }
            for entry in entries {
                let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw ValidationError("expected WORD=SOUNDS-LIKE, got \(entry)") }
                lexicon.entries[parts[0]] = Lexicon.Entry(say: parts[1])
            }
            lexicon.resolve(with: g2p)
            try lexicon.save(url)
            for word in remove { print("\(word) removed") }
            for entry in entries {
                let word = String(entry.split(separator: "=")[0]).trimmingCharacters(in: .whitespaces)
                print("\(word) → /\(lexicon.entries[word]?.phonemes ?? "")/")
            }
            let after = try Renderer.planned(p, settings)
            print("\(zip(before, after).filter { $0.key != $1.key }.count) chunks to re-render in \(book.title)")
            return
        }

        let words = Lexicon.unknownWords(try Renderer.planned(p, settings, lexicon: Renderer.resolveLexicon(p, phonemizer: g2p)), phonemizer: g2p)
        for w in words.prefix(limit) {
            print("\(String(format: "%4d", w.count))  \(w.word.padding(toLength: 16, withPad: " ", startingAt: 0)) /\(w.guess)/  § \(w.section): \(excerpt(w.example, around: w.word))")
        }
        print("\(words.count) words guessed; \(try Lexicon.load(p).entries.count) in the book's lexicon, \(try Lexicon.load(Lexicon.globalURL).entries.count) global")
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build the M4B from rendered audio.")
    @Argument var project: String

    func run() throws { try export(try openProject(project)) }
}

struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Ingest, render and export in one go.")
    @Argument var epub: String
    @Option(help: "Project folder (default: BOOK.narrate next to the EPUB)") var project: String?
    @OptionGroup var voice: VoiceOptions

    func run() async throws {
        let epubURL = URL(fileURLWithPath: epub)
        let root = project.map { URL(fileURLWithPath: $0) } ?? Project.defaultRoot(for: epubURL)
        var p = Project(root: root)
        if !p.exists { p = try Project.ingest(epub: epubURL, root: root) }
        try await render(p, voice: voice, sections: nil)
        try export(p)
    }
}
