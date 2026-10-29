// Same chunks, same voice and speed as narrate's MLX path, timed end to end (raw text in, audio out).
//
//   coreml-bench CHUNKS.json OUT.wav --manifest-url URL --manifest-sha256 SHA [--speed 0.94] [--voice af_heart]

import Darwin
import Foundation
import KokoroTTS

struct Chunk: Decodable {
    let text: String
    let pause: Double
}

func option(_ name: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func peakRSSGB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1e9  // bytes on macOS
}

/// The same trim narrate applies: drop leading/trailing frames under -48 dBFS, keep 40/60 ms pads.
func trimSilence(_ s: [Float], rate: Int) -> [Float] {
    let frame = rate / 100
    let n = s.count / frame
    guard n > 0 else { return s }
    var loud: [Int] = []
    for f in 0..<n {
        var sum: Float = 0
        for i in (f * frame)..<((f + 1) * frame) { sum += s[i] * s[i] }
        if (sum / Float(frame)).squareRoot() > 0.004 { loud.append(f) }
    }
    guard let first = loud.first, let last = loud.last else { return s }
    let start = max(0, first * frame - Int(0.04 * Double(rate)))
    let end = min(s.count, (last + 1) * frame + Int(0.06 * Double(rate)))
    return Array(s[start..<end])
}

func writeWAV(_ samples: [Float], rate: Int, to url: URL) throws {
    var data = Data()
    func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = samples.count * 2
    data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
    data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
    put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
    for s in samples { put(Int16(max(-1, min(1, s)) * 32767)) }
    try data.write(to: url)
}

let args = Array(CommandLine.arguments.dropFirst())
let chunks = try JSONDecoder().decode([Chunk].self, from: Data(contentsOf: URL(fileURLWithPath: args[0])))
let out = URL(fileURLWithPath: args[1])
let speed = Float(option("--speed", args) ?? "0.94")!
let voice = KokoroVoiceID(option("--voice", args) ?? "af_heart")
let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/kokoro-coreml-bench")

var t0 = Date()
let resources = try await KokoroDownloadedModelStore(
    manifestURL: URL(string: option("--manifest-url", args)!)!,
    expectedManifestSHA256: option("--manifest-sha256", args)!,
    cacheDirectory: cache
).hydrate(phaseProgress: nil)
let tts = try await KokoroTTS.load(resources: resources)
let options = KokoroSynthesisOptions(speed: speed)
_ = try await tts.synthesize("Warm up.", voice: voice, options: options)  // first call compiles/specializes Core ML models
let loadS = Date().timeIntervalSince(t0)

var samples: [Float] = []
var synthS = 0.0, speechS = 0.0
let rate = 24000
for (i, chunk) in chunks.enumerated() {
    t0 = Date()
    let audio = try await tts.synthesize(chunk.text, voice: voice, options: options)
    synthS += Date().timeIntervalSince(t0)
    speechS += audio.durationSeconds
    samples += trimSilence(audio.samples, rate: audio.sampleRate)
    samples += [Float](repeating: 0, count: Int((chunk.pause * Double(rate)).rounded()))
    if (i + 1) % 10 == 0 { FileHandle.standardError.write("  \(i + 1)/\(chunks.count)\n".data(using: .utf8)!) }
}
try writeWAV(samples, rate: rate, to: out)

let result: [String: Any] = [
    "engine": "kokoro-coreml (ANE/GPU/CPU)", "voice": voice.rawValue, "speed": speed, "chunks": chunks.count,
    "load_s": (loadS * 10).rounded() / 10, "synth_s": (synthS * 10).rounded() / 10,
    "speech_s": (speechS * 10).rounded() / 10, "rtf": (synthS / speechS * 1000).rounded() / 1000,
    "peak_rss_gb": (peakRSSGB() * 100).rounded() / 100,
]
let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
try json.write(to: out.deletingPathExtension().appendingPathExtension("json"))
print(String(data: json, encoding: .utf8)!)
