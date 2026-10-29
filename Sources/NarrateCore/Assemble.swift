import Foundation

/// Join cached chunks with structural pauses, normalise loudness once, encode once to a chaptered M4B.
///
/// Encoding happens a single time from uncompressed PCM, so AAC priming silence never lands at chunk
/// joins. Chapters go in as ffmetadata, which ffmpeg's MP4 muxer writes as a QuickTime chapter track,
/// the one Apple Books reads.
///
/// Loudness: `ebur128` measures integrated loudness at the source rate, then a fixed gain and a light
/// lookahead limiter bring it to the target. ffmpeg's `loudnorm` does the same job but processes at
/// 192 kHz in both passes; on a 6 h book that was ~13 of the export's ~15 minutes.
public enum Assembler {
    static let leadIn = 0.5
    static let targetLUFS = -18.0
    /// Limiter ceiling, linear (-3.3 dBFS sample peak). Resampling and AAC add ~2 dB of overshoot;
    /// measured on Treasure Island, -2 dBFS still ended at -0.1 dBTP, this lands under -1 dBTP.
    static let limiterCeiling = 0.68
    static let outputRate = 44100
    static let bitrate = "64k"

    public struct Marker: Equatable, Sendable {
        public var title: String
        public var start: Int  // samples
        public var end: Int
    }

    public enum Failure: Error, CustomStringConvertible {
        case notRendered(missing: Int, total: Int)
        case nothingRendered
        case tool(String, String)

        public var description: String {
            switch self {
            case .notRendered(let missing, let total): "\(missing) of \(total) chunks are not rendered yet; run `narrate render` first"
            case .nothingRendered: "nothing rendered yet; run `narrate render` first"
            case .tool(let name, let stderr): "\(name) failed: \(stderr.suffix(800))"
            }
        }
    }

    static func escape(_ value: String) -> String {
        var out = ""
        for ch in value {
            if "=;#\\\n".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    public static func ffmetadata(tags: [(String, String)], markers: [Marker], sampleRate: Int) -> String {
        var lines = [";FFMETADATA1"]
        lines += tags.filter { !$0.1.isEmpty }.map { "\($0.0)=\(escape($0.1))" }
        for m in markers {
            let start = Int((Double(m.start) * 1000 / Double(sampleRate)).rounded())
            let end = Int((Double(m.end) * 1000 / Double(sampleRate)).rounded())
            lines += ["", "[CHAPTER]", "TIMEBASE=1/1000", "START=\(start)", "END=\(end)", "title=\(escape(m.title))"]
        }
        return lines.joined(separator: "\n") + "\n"
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

    /// Runs a command-line tool; returns (stdout, stderr). Throws with stderr on a non-zero exit.
    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> (out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + args
        let stderr = Pipe()
        let stdout = Pipe()
        process.standardError = stderr
        process.standardOutput = stdout
        try process.run()
        // Drain both pipes concurrently so a chatty tool can't fill one and block.
        nonisolated(unsafe) var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        let err = String(decoding: errData, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw Failure.tool(tool, err) }
        return (String(decoding: outData, as: UTF8.self), err)
    }

    static func aacEncoder() -> String {
        let encoders = (try? run("ffmpeg", ["-hide_banner", "-encoders"]).out) ?? ""
        return Pattern("\\baac_at\\b").matches(in: encoders).isEmpty ? "aac" : "aac_at"
    }

    /// Integrated loudness (EBU R128 / BS.1770) of a WAV, in LUFS.
    static func measureLoudness(_ wav: URL) throws -> Double {
        let stderr = try run("ffmpeg", ["-hide_banner", "-nostdin", "-i", wav.path, "-af", "ebur128=framelog=quiet", "-f", "null", "-"]).err
        guard let value = Pattern("\\bI:\\s+(-?[0-9.]+) LUFS").matches(in: stderr).last?[1], let lufs = Double(value) else {
            throw Failure.tool("ffmpeg ebur128", stderr)
        }
        return lufs
    }

    /// Fixed gain to the target, then a lookahead limiter that only touches the rare peaks the gain pushes too high.
    static func loudnessFilter(measured: Double) -> String {
        let gain = measured > -70 ? targetLUFS - measured : 0  // -70 LUFS is ebur128's floor: silence
        return String(format: "volume=%.2fdB,alimiter=limit=%.2f:attack=5:release=50:level=0", gain, limiterCeiling)
    }

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
        let loudness = loudnessFilter(measured: measured)
        let tags = [
            ("title", book.title), ("album", book.title), ("artist", book.author), ("album_artist", book.author),
            ("composer", "Synthetic voice (Kokoro \(settings.voice))"), ("genre", "Audiobook"),
            ("comment", "Narrated by a synthetic voice (Kokoro \(settings.voice)) with Narrate."), ("media_type", "2"),
        ]
        let meta = project.workDir.appendingPathComponent("ffmetadata.txt")
        try ffmetadata(tags: tags, markers: markers, sampleRate: rate).write(to: meta, atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: project.outDir, withIntermediateDirectories: true)
        let name = "\(safeFilename(book.title)) - \(safeFilename(book.author))"
        let out = project.outDir.appendingPathComponent("\(name).m4b")
        let tmp = project.outDir.appendingPathComponent("\(name).part.m4b")
        var args = ["-hide_banner", "-nostdin", "-y", "-i", wav.path, "-i", meta.path]
        let cover = project.coverURL
        if let cover { args += ["-i", cover.path] }
        args += ["-map", "0:a", "-map_metadata", "1", "-map_chapters", "1"]
        if let cover {
            let codec = ["jpg", "jpeg", "png"].contains(cover.pathExtension.lowercased()) ? "copy" : "mjpeg"
            args += ["-map", "2:v", "-c:v", codec, "-disposition:v:0", "attached_pic"]
        }
        args += ["-af", "\(loudness),aresample=\(outputRate)", "-c:a", aacEncoder(), "-b:a", bitrate, "-ac", "1",
                 "-movflags", "+faststart", "-f", "ipod", tmp.path]
        log(String(format: "measured %.1f LUFS; normalizing and encoding (pass 2 of 2)", measured))
        try run("ffmpeg", args)
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

    /// Duration, chapter titles and whether a cover is attached, as ffprobe sees them.
    public static func probe(_ url: URL) throws -> ProbeInfo {
        let json = try run("ffprobe", ["-v", "error", "-print_format", "json", "-show_format", "-show_chapters", "-show_streams", url.path]).out
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let format = root["format"] as? [String: Any] ?? [:]
        let streams = root["streams"] as? [[String: Any]] ?? []
        let chapters = (root["chapters"] as? [[String: Any]] ?? []).map { (($0["tags"] as? [String: String])?["title"]) ?? "" }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }.map {
            "\($0["codec_name"] ?? "?") \($0["sample_rate"] ?? "?") Hz \($0["channels"] ?? "?")ch"
        } ?? "no audio"
        let cover = streams.contains { (($0["disposition"] as? [String: Int])?["attached_pic"] ?? 0) == 1 }
        return ProbeInfo(duration: Double(format["duration"] as? String ?? "0") ?? 0, chapters: chapters, cover: cover, audio: audio,
                         tags: format["tags"] as? [String: String] ?? [:])
    }
}
