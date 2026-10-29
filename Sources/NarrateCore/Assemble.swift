import AVFoundation
import Foundation

/// Join cached chunks with structural pauses, normalise loudness once, encode once to a chaptered M4B.
///
/// Encoding happens a single time from uncompressed PCM, so AAC priming silence never lands at chunk
/// joins. Chapters go in as a QuickTime chapter track, the one Apple Books reads.
///
/// Loudness: pass 1 measures integrated loudness (BS.1770) at the source rate; pass 2 applies a fixed
/// gain to the target and a light lookahead limiter, then AVFoundation resamples and encodes AAC.
/// All of it is native, so nothing outside the app is needed.
public enum Assembler {
    static let leadIn = 0.5
    static let targetLUFS = -18.0
    /// Limiter ceiling, linear (-3.3 dBFS sample peak). Resampling and AAC add ~2 dB of overshoot;
    /// measured on Treasure Island, -2 dBFS still ended at -0.1 dBTP, this lands under -1 dBTP.
    static let limiterCeiling: Float = 0.68
    static let outputRate = 44100
    static let bitrate = 64000
    static let block = 1 << 16  // samples per read in both passes

    public struct Marker: Equatable, Sendable {
        public var title: String
        public var start: Int  // samples
        public var end: Int
    }

    public enum Failure: Error, CustomStringConvertible {
        case notRendered(missing: Int, total: Int)
        case nothingRendered

        public var description: String {
            switch self {
            case .notRendered(let missing, let total): "\(missing) of \(total) chunks are not rendered yet; run `narrate render` first"
            case .nothingRendered: "nothing rendered yet; run `narrate render` first"
            }
        }
    }

    /// Concatenate all included chunks into one WAV and return its chapter markers.
    public static func writePCM(_ project: Project, log: (String) -> Void = { print($0) }) throws -> (URL, [Marker], Int) {
        guard let settings = try project.loadSettings() else { throw Failure.nothingRendered }
        let planned = try Renderer.planned(project, settings)
        let missing = planned.filter { !FileManager.default.fileExists(atPath: Renderer.cacheURL(project, key: $0.key).path) }.count
        if missing > 0 { throw Failure.notRendered(missing: missing, total: planned.count) }

        let book = try project.loadBook()
        try FileManager.default.createDirectory(at: project.workDir, withIntermediateDirectories: true)
        let wav = project.workDir.appendingPathComponent("book.wav")
        let rate = settings.sampleRate
        let writer = try WAV.Writer(url: wav, sampleRate: rate)
        try writer.writeSilence(seconds: leadIn)
        var markers: [Marker] = []
        var section: Int?
        for item in planned {
            if item.chunk.section != section {
                section = item.chunk.section
                let s = book.sections[item.chunk.section]
                markers.append(Marker(title: s.marker.isEmpty ? s.title : s.marker, start: writer.samplesWritten, end: writer.samplesWritten))
            }
            let (audio, fileRate) = try WAV.read(Renderer.cacheURL(project, key: item.key))
            precondition(fileRate == rate, "chunk \(item.key) is \(fileRate) Hz, expected \(rate) Hz")
            try writer.write(audio)
            try writer.writeSilence(seconds: item.chunk.pause)
            markers[markers.count - 1].end = writer.samplesWritten
        }
        try writer.close()
        if !markers.isEmpty { markers[0].start = 0 }  // the lead-in belongs to the first chapter
        log(String(format: "joined %d chunks into %.2f h of audio, %d chapters", planned.count, Double(writer.samplesWritten) / Double(rate) / 3600, markers.count))
        return (wav, markers, rate)
    }

    /// Integrated loudness (EBU R128 / BS.1770) of a WAV, in LUFS; -infinity for silence.
    static func measureLoudness(_ wav: URL) throws -> Double {
        let reader = try WAV.Reader(url: wav)
        defer { try? reader.close() }
        var meter = LoudnessMeter(sampleRate: reader.sampleRate)
        while case let samples = try reader.read(max: block), !samples.isEmpty { meter.add(samples) }
        return meter.integrated
    }

    /// Fixed gain to the target, in dB; none for silence (below -70 LUFS, the absolute gate).
    static func gain(measured: Double) -> Double { measured > -70 ? targetLUFS - measured : 0 }

    static func safeFilename(_ text: String) -> String {
        let cleaned = Pattern("[\\\\/:*?\"<>|]+").replacing(in: text, with: "").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "audiobook" : cleaned
    }

    @discardableResult
    public static func export(_ project: Project, log: (String) -> Void = { print($0) }) throws -> URL {
        let book = try project.loadBook()
        guard let settings = try project.loadSettings() else { throw Failure.nothingRendered }
        let (wav, markers, rate) = try writePCM(project, log: log)

        log("measuring loudness (pass 1 of 2)")
        let measured = try measureLoudness(wav)
        let gainDB = gain(measured: measured)
        let narrator = "Synthetic voice (Kokoro \(settings.voice))"
        let tags: [(AVMetadataIdentifier, String)] = [
            (.iTunesMetadataSongName, book.title), (.iTunesMetadataAlbum, book.title), (.iTunesMetadataArtist, book.author),
            (.iTunesMetadataAlbumArtist, book.author), (.iTunesMetadataComposer, narrator), (.iTunesMetadataUserGenre, "Audiobook"),
            (.iTunesMetadataUserComment, "Narrated by a synthetic voice (Kokoro \(settings.voice)) with Narrate."),
        ]
        let cover = project.coverURL
        if let cover, M4BWriter.coverArt(cover) == nil { log("cover \(cover.lastPathComponent) is not a readable image; leaving it out") }

        try FileManager.default.createDirectory(at: project.outDir, withIntermediateDirectories: true)
        let name = "\(safeFilename(book.title)) - \(safeFilename(book.author))"
        let out = project.outDir.appendingPathComponent("\(name).m4b")
        let tmp = project.outDir.appendingPathComponent("\(name).part.m4b")
        _ = try? FileManager.default.removeItem(at: tmp)
        log(String(format: "measured %.1f LUFS; normalizing and encoding (pass 2 of 2)", measured))
        let writer = try M4BWriter(url: tmp, sampleRate: rate, outputRate: outputRate, bitrate: bitrate,
                                   chapters: markers.map { .init(title: $0.title, start: $0.start, end: $0.end) },
                                   metadata: M4BWriter.metadata(tags: tags, cover: cover))
        let reader = try WAV.Reader(url: wav)
        defer { try? reader.close() }
        let linear = Float(pow(10, gainDB / 20))
        var limiter = Limiter(ceiling: limiterCeiling, sampleRate: rate)
        while case let samples = try reader.read(max: block), !samples.isEmpty {
            try writer.append(limiter.process(samples.map { $0 * linear }))
        }
        try writer.append(limiter.flush())
        try writer.finish()
        _ = try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        log("wrote \(out.path)")
        return out
    }

    public struct ProbeInfo: Sendable {
        public let duration: Double
        public let chapters: [String]
        public let cover: Bool
        public let audio: String
        public let tags: [String: String]
    }

    /// Duration, chapter titles, cover and tags, as AVFoundation (and so Apple Books) reads them.
    public static func probe(_ url: URL) async throws -> ProbeInfo {
        let asset = AVURLAsset(url: url)
        let (duration, metadata, tracks, locales) = try await asset.load(.duration, .metadata, .tracks, .availableChapterLocales)
        var chapters: [String] = []
        for group in try await asset.loadChapterMetadataGroups(withTitleLocale: locales.first ?? .current, containingItemsWithCommonKeys: []) {
            let title = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            chapters.append(try await title?.load(.stringValue) ?? "")
        }
        var audio = "no audio"
        if let track = tracks.first(where: { $0.mediaType == .audio }),
           let format = try await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            let codec = asbd.mFormatID == kAudioFormatMPEG4AAC ? "aac" : "\(asbd.mFormatID)"
            audio = "\(codec) \(Int(asbd.mSampleRate)) Hz \(asbd.mChannelsPerFrame)ch"
        }
        let names: [AVMetadataIdentifier: String] = [
            .iTunesMetadataSongName: "title", .iTunesMetadataAlbum: "album", .iTunesMetadataArtist: "artist",
            .iTunesMetadataAlbumArtist: "album_artist", .iTunesMetadataComposer: "composer", .iTunesMetadataUserGenre: "genre",
            .iTunesMetadataUserComment: "comment",
        ]
        var tags: [String: String] = [:]
        var cover = false
        for item in metadata {
            guard let id = item.identifier else { continue }
            if id == .iTunesMetadataCoverArt { cover = true }
            if let name = names[id], let value = try await item.load(.stringValue) { tags[name] = value }
        }
        return ProbeInfo(duration: duration.seconds, chapters: chapters, cover: cover, audio: audio, tags: tags)
    }
}
