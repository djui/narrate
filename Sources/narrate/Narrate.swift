import ArgumentParser
import Foundation
import NarrateCore

@main
struct Narrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Turn a DRM-free EPUB into an M4B audiobook, offline, with Kokoro on Core ML.",
        subcommands: [Ingest.self, Contents.self, Plan.self, Render.self, Export.self, Build.self]
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

func render(_ project: Project, voice: VoiceOptions, sections: Set<Int>?) async throws {
    // Keep the Mac awake while rendering; the assertion ends with the activity.
    let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Rendering audiobook")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    _ = try await Renderer.render(project, engine: KokoroCoreMLEngine(), voice: voice.voice, speed: voice.speed, sections: sections)
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
    @OptionGroup var voice: VoiceOptions

    func run() async throws {
        try await render(try openProject(project), voice: voice, sections: sections == nil ? nil : try indices(sections))
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
