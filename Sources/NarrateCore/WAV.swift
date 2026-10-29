import Foundation

/// 16-bit mono PCM WAV, the format of every cached chunk and of the joined book.
public enum WAV {
    public enum Failure: Error { case notPCM16Mono(URL) }

    static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(truncatingIfNeeded: 36 + dataBytes))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(UInt32(truncatingIfNeeded: dataBytes))
        return d
    }

    static func pcm16(_ samples: [Float]) -> Data {
        var d = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767).littleEndian
            withUnsafeBytes(of: v) { d.append(contentsOf: $0) }
        }
        return d
    }

    public static func write(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        try (header(sampleRate: sampleRate, dataBytes: samples.count * 2) + pcm16(samples)).write(to: url, options: .atomic)
    }

    /// Reads a WAV this module wrote: returns samples and sample rate.
    public static func read(_ url: URL) throws -> ([Float], Int) {
        let d = try Data(contentsOf: url)
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        guard d.count >= 44, u16(20) == 1, u16(22) == 1, u16(34) == 16 else { throw Failure.notPCM16Mono(url) }
        let rate = u32(24)
        var offset = 12
        while offset + 8 <= d.count {
            let size = u32(offset + 4)
            if d[offset..<offset + 4].elementsEqual("data".utf8) {
                let start = offset + 8
                let end = min(d.count, start + size)
                let samples = d[start..<end].withUnsafeBytes { raw in
                    raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32767 }
                }
                return (samples, rate)
            }
            offset += 8 + size
        }
        throw Failure.notPCM16Mono(url)
    }

    /// Streams samples into a WAV file whose size isn't known up front (the joined book).
    public final class Writer {
        private let handle: FileHandle
        private let sampleRate: Int
        public private(set) var samplesWritten = 0

        public init(url: URL, sampleRate: Int) throws {
            FileManager.default.createFile(atPath: url.path, contents: header(sampleRate: sampleRate, dataBytes: 0))
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            self.sampleRate = sampleRate
        }

        public func write(_ samples: [Float]) throws {
            try handle.write(contentsOf: pcm16(samples))
            samplesWritten += samples.count
        }

        public func writeSilence(seconds: Double) throws {
            try write([Float](repeating: 0, count: Int((seconds * Double(sampleRate)).rounded())))
        }

        public func close() throws {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(sampleRate: sampleRate, dataBytes: samplesWritten * 2))
            try handle.close()
        }
    }
}
