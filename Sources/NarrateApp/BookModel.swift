import AVFoundation
import AppKit
import Foundation
import KokoroTTS
import NarrateCore
import Observation

/// Speaking rate used for time estimates: Kokoro af_heart at 1.0×, measured in the bake-off.
let wordsPerMinute = 200.0

/// The six steps in the sidebar, in the order a book goes through them.
enum Step: String, CaseIterable, Identifiable, Hashable {
    case contents, pronunciation, voice, render, review, export

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .contents: "list.bullet.rectangle"
        case .pronunciation: "character.bubble"
        case .voice: "waveform"
        case .render: "gearshape.2"
        case .review: "checklist"
        case .export: "square.and.arrow.up"
        }
    }
}

struct AppError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func message(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}

/// Another narrate render, build or export in progress (the CLI, or a second app window), if any.
/// Two heavy jobs at once on a 16 GB base M2 slow both down and can run out of memory.
func otherHeavyJob() -> String? {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-fl", "narrate (render|build|export)"]
    let pipe = Pipe()
    pgrep.standardOutput = pipe
    guard (try? pgrep.run()) != nil else { return nil }
    pgrep.waitUntilExit()
    let own = String(ProcessInfo.processInfo.processIdentifier)
    let lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").filter { !$0.hasPrefix(own + " ") }
    return lines.first.map(String.init)
}

/// The speech engine. `NARRATE_ENGINE=tone` swaps Kokoro for a test tone, for trying the app
/// without loading a model; its cache keys differ, so it never mixes with real renders.
func makeEngine() -> SpeechEngine {
    ProcessInfo.processInfo.environment["NARRATE_ENGINE"] == "tone" ? ToneEngine() : KokoroCoreMLEngine()
}

/// A 220 Hz tone whose length follows the text, padded with silence (same as the tests' fake).
actor ToneEngine: SpeechEngine {
    nonisolated let engineID = "tone-v1"
    nonisolated let sampleRate = 24000

    func synthesize(_ text: String, voice: String, speed: Double) async throws -> [Float] {
        try await Task.sleep(for: .milliseconds(30))
        let n = Int(0.02 * Double(text.count) / speed * Double(sampleRate))
        let tone = (0..<n).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / Double(sampleRate))) }
        let silence = [Float](repeating: 0, count: sampleRate / 4)
        return silence + tone + silence
    }
}

/// One Misaki G2P for the whole app, used by one caller at a time. Misaki's fallback network runs
/// on MLX, which isn't safe to drive from two threads at once; listing words in the background while
/// the main thread resolved a lexicon entry could otherwise hang.
final class SharedPhonemizer: Phonemizer, @unchecked Sendable {
    private let lock = NSLock()
    private let base: MisakiPhonemizer

    init(voice: String) { base = MisakiPhonemizer(voice: voice) }

    func phonemes(_ text: String) -> String { lock.withLock { base.phonemes(text) } }
    func unknownWords(_ text: String) -> [(word: String, guess: String)] { lock.withLock { base.unknownWords(text) } }
}

/// Lets a render stop between chunks and reports each synthesized chunk.
struct ObservedEngine: SpeechEngine {
    let base: SpeechEngine
    let onChunk: @Sendable () -> Void

    var engineID: String { base.engineID }
    var sampleRate: Int { base.sampleRate }

    func synthesize(_ text: String, voice: String, speed: Double) async throws -> [Float] {
        try Task.checkCancellation()
        let audio = try await base.synthesize(text, voice: voice, speed: speed)
        onChunk()
        return audio
    }
}

/// Opens a book: an EPUB (ingested into BOOK.narrate next to it, or reopened if that exists) or a project folder.
@MainActor @Observable final class AppState {
    static let shared = AppState()

    var book: BookModel?
    var opening = false
    /// Opens (or brings back) the main window; set by the app's commands.
    @ObservationIgnored var showWindow: (() -> Void)?
    var error: String?
    let engine = makeEngine()

    /// The Kokoro model (~220 MB) downloads once, on first use; nil progress when not downloading.
    var modelReady = true
    var modelProgress: KokoroHydrationProgress?
    var preparingModel = false

    static func kokoro(_ engine: SpeechEngine) -> KokoroCoreMLEngine? { engine as? KokoroCoreMLEngine }

    init() { modelReady = Self.kokoro(engine)?.isDownloaded ?? true }

    /// Download (first run), verify and load the model, reporting progress.
    func prepareModel() async throws {
        guard let kokoro = Self.kokoro(engine), !preparingModel else { return }
        preparingModel = true
        defer { preparingModel = false; modelProgress = nil }
        try await kokoro.prepare { progress in Task { @MainActor in AppState.shared.modelProgress = progress } }
        modelReady = true
    }

    func downloadModel() {
        if let other = otherHeavyJob() {
            error = "Another heavy job is running; wait for it to finish first:\n\(other)"
            return
        }
        Task {
            do { try await prepareModel() } catch { self.error = message(error) }
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.message = "Choose an EPUB or a .narrate project folder"
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.init(filenameExtension: "epub")!, .folder]
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        guard book?.isBusy != true else { error = "Wait for the current render or export to finish."; return }
        opening = true
        error = nil
        Task {
            defer { opening = false }
            do {
                let project = try await Task.detached { () throws -> Project in
                    if url.pathExtension.lowercased() == "epub" {
                        let existing = Project(root: Project.defaultRoot(for: url))
                        return existing.exists ? existing : try Project.ingest(epub: url)
                    }
                    let project = Project(root: url)
                    guard project.exists else { throw AppError("\(url.lastPathComponent) has no book.json; open an EPUB instead.") }
                    return project
                }.value
                book = try BookModel(project: project, engine: engine)
                NSDocumentController.shared.noteNewRecentDocumentURL(project.root)
            } catch {
                self.error = message(error)
            }
        }
    }
}

/// One open book project and the state of its render and export.
@MainActor @Observable final class BookModel {
    let project: Project
    let engine: SpeechEngine
    var book: Book
    var voice: String
    var speed: Double
    var error: String?

    /// Every chunk as Kokoro is given it (lexicon applied), keyed for the current voice and speed.
    var planned: [Renderer.Planned] = []
    /// Chunks per section, and how many of them are in the cache.
    var plannedPerSection: [Int: Int] = [:]
    var cached: [Int: Int] = [:]
    /// Chunks that failed a signal check after their retry (flags.json), by cache key.
    var flags: [String: Checks.Flag] = [:]
    var scanning = false

    /// Words the G2P has to guess (nil until listed), and the lexicons that set how words sound.
    var unknownWords: [Lexicon.UnknownWord]?
    var listingWords = false
    var bookLexicon = Lexicon()
    var globalLexicon = Lexicon()

    /// Audio playing for a preview, a flagged chunk or a word.
    @ObservationIgnored var player: AVAudioPlayer?
    var speaking = false

    var renderTask: Task<Void, Never>?
    var renderLog: [String] = []
    var renderDone = 0
    var renderTodo = 0
    var renderStart: Date?
    @ObservationIgnored private var lastRefresh = Date.distantPast

    var exporting = false
    var exportLog: [String] = []
    var output: URL?
    var probe: Assembler.ProbeInfo?

    init(project: Project, engine: SpeechEngine) throws {
        self.project = project
        self.engine = engine
        book = try project.loadBook()
        let settings = try project.loadSettings()
        voice = settings?.voice ?? EngineDefaults.voice
        speed = settings?.speed ?? EngineDefaults.speed
        refreshPlan()
        loadExisting()
    }

    var isRendering: Bool { renderTask != nil }
    var isBusy: Bool { isRendering || exporting }

    // MARK: Contents

    func minutes(_ section: NarrateCore.Section) -> Double { Double(section.words) / (wordsPerMinute * speed) }

    var includedMinutes: Double {
        book.sections.filter(\.include).reduce(0) { $0 + minutes($1) }
    }

    func setInclude(_ index: Int, _ include: Bool) {
        guard !isBusy else { return }
        book.sections[index].include = include
        save()
    }

    /// Leave out everything that isn't a chapter or part (front and back matter, notes, TOC…).
    func onlyStory() {
        guard !isBusy else { return }
        for i in book.sections.indices {
            book.sections[i].include = ["chapter", "part"].contains(book.sections[i].kind)
        }
        save()
    }

    private func save() {
        do {
            try project.save(book)
            unknownWords = nil
            refreshPlan()
        } catch {
            self.error = message(error)
        }
    }

    // MARK: Voice

    /// Voice and speed are part of every chunk's cache key, so changing them means a fresh render.
    func saveVoice() {
        do {
            try project.save(settings)
            _phonemizer = nil  // British voices (b…) use British G2P
            refreshPlan()
        } catch {
            self.error = message(error)
        }
    }

    /// The book's own opening: the first included chapter's first paragraphs.
    var openingPassage: String {
        let section = book.sections.first { $0.include && $0.kind == "chapter" } ?? book.sections.first { $0.include }
        var text = ""
        for block in section?.blocks ?? [] where block.kind == .para || block.kind == .verse {
            text += (text.isEmpty ? "" : " ") + block.text
            if text.count > 400 { break }
        }
        return text
    }

    // MARK: Render

    var totalChunks: Int { planned.count }
    var cachedChunks: Int { cached.values.reduce(0, +) }

    var settings: Project.Settings {
        Project.Settings(voice: voice, speed: speed, engineID: engine.engineID, sampleRate: engine.sampleRate)
    }

    /// Re-plan after a change to contents, voice, speed or the lexicon. Lexicon entries without
    /// phonemes yet are resolved here, the same as `narrate render` does before planning.
    func refreshPlan() {
        do {
            let lexicon = try Renderer.resolveLexicon(project, phonemizer: phonemizer)
            planned = try Renderer.planned(project, settings, lexicon: lexicon)
            flags = try Checks.loadFlags(project)
            bookLexicon = try Lexicon.load(project)
            globalLexicon = try Lexicon.load(Lexicon.globalURL)
        } catch {
            self.error = message(error)
        }
        plannedPerSection = Dictionary(planned.map { ($0.chunk.section, 1) }, uniquingKeysWith: +)
        refreshCache()
    }

    func refreshCache() {
        let fm = FileManager.default
        var counts: [Int: Int] = [:]
        for item in planned where fm.fileExists(atPath: Renderer.cacheURL(project, key: item.key).path) {
            counts[item.chunk.section, default: 0] += 1
        }
        cached = counts
        lastRefresh = Date()
    }

    /// Misaki's G2P, loaded on first use and shared with background work.
    @ObservationIgnored private var _phonemizer: SharedPhonemizer?
    var phonemizer: SharedPhonemizer {
        if let _phonemizer { return _phonemizer }
        let made = SharedPhonemizer(voice: voice)
        _phonemizer = made
        return made
    }

    func startRender(sections: Set<Int>? = nil) {
        guard !isBusy else { return }
        if let other = otherHeavyJob() {
            error = "Another heavy job is running; wait for it to finish first:\n\(other)"
            return
        }
        error = nil
        saveVoice()
        renderLog = []
        renderDone = 0
        let fm = FileManager.default
        renderTodo = planned.filter {
            (sections?.contains($0.chunk.section) ?? true) && !fm.fileExists(atPath: Renderer.cacheURL(project, key: $0.key).path)
        }.count
        renderStart = Date()
        let engine = ObservedEngine(base: engine) { [weak self] in Task { @MainActor in self?.chunkFinished() } }
        let (project, voice, speed, phonemizer) = (project, voice, speed, phonemizer)
        let log: @Sendable (String) -> Void = { [weak self] line in Task { @MainActor in self?.renderLog.append(line) } }
        renderTask = Task {
            // Keep the Mac awake while rendering; the assertion ends with the task.
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Rendering audiobook")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                if !AppState.shared.modelReady { renderLog.append("Downloading the Kokoro model (~220 MB, first run only)") }
                try await AppState.shared.prepareModel()
                let stats = try await Self.render(project, engine: engine, voice: voice, speed: speed, sections: sections, phonemizer: phonemizer, log: log)
                renderLog.append(String(format: "Done: %d chunks rendered, %.1f min of audio in %.1f min; %d flagged for Review.",
                                        stats.rendered, stats.audioSeconds / 60, stats.elapsedSeconds / 60, stats.flagged))
            } catch is CancellationError {
                renderLog.append("Stopped. Rendered chunks are cached; Render picks up where it left off.")
            } catch {
                self.error = message(error)
            }
            renderTask = nil
            flags = (try? Checks.loadFlags(project)) ?? flags
            refreshCache()
        }
    }

    nonisolated private static func render(_ project: Project, engine: SpeechEngine, voice: String, speed: Double, sections: Set<Int>?,
                                           phonemizer: SharedPhonemizer, log: @escaping @Sendable (String) -> Void) async throws -> Renderer.Stats {
        try await Renderer.render(project, engine: engine, voice: voice, speed: speed, sections: sections,
                                  phonemizer: phonemizer, log: log)
    }

    func cancelRender() { renderTask?.cancel() }

    private func chunkFinished() {
        // A retried chunk is synthesized again in two halves; keep the count within the plan.
        renderDone = min(renderDone + 1, renderTodo)
        // The chunk's WAV is written right after synthesis; a rescan a second later picks it up.
        if Date().timeIntervalSince(lastRefresh) > 1 { refreshCache() }
    }

    // MARK: Export

    private func loadExisting() {
        let files = (try? FileManager.default.contentsOfDirectory(at: project.outDir, includingPropertiesForKeys: nil)) ?? []
        guard let existing = files.first(where: { $0.pathExtension == "m4b" && !$0.lastPathComponent.hasSuffix(".part.m4b") }) else { return }
        output = existing
        Task {
            probe = try? await Assembler.probe(existing)
        }
    }

    func startExport() {
        guard !isBusy else { return }
        if let other = otherHeavyJob() {
            error = "Another heavy job is running; wait for it to finish first:\n\(other)"
            return
        }
        error = nil
        exporting = true
        exportLog = []
        let project = project
        let log: @Sendable (String) -> Void = { [weak self] line in Task { @MainActor in self?.exportLog.append(line) } }
        Task {
            defer { exporting = false }
            do {
                let url = try await Task.detached { try Assembler.export(project, log: log) }.value
                let info = try await Assembler.probe(url)
                output = url
                probe = info
            } catch {
                self.error = message(error)
            }
        }
    }
}
