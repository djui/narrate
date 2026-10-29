import Foundation

/// Minimal read-only ZIP reader: enough for EPUB (stored and deflated entries, no ZIP64, no encryption).
/// Written in-house because ZIPFoundation is already linked statically by kokoro-coreml's dependencies,
/// and linking it twice is rejected by SwiftPM.
struct ZipArchive {
    enum Failure: Error, CustomStringConvertible {
        case notZip
        case unsupported(String)
        case corrupt(String)

        var description: String {
            switch self {
            case .notZip: "not a ZIP file"
            case .unsupported(let what): "unsupported ZIP feature: \(what)"
            case .corrupt(let name): "corrupt ZIP entry: \(name)"
            }
        }
    }

    private struct Entry {
        let method: Int
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private var entries: [String: Entry] = [:]

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22 else { throw Failure.notZip }
        // The end-of-central-directory record sits in the last 64 KB + 22 bytes.
        var eocd = -1
        for i in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) where u32(i) == 0x0605_4B50 {
            eocd = i
            break
        }
        guard eocd >= 0 else { throw Failure.notZip }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        if count == 0xFFFF || p == 0xFFFF_FFFF { throw Failure.unsupported("ZIP64") }
        for _ in 0..<count {
            guard p + 46 <= data.count, u32(p) == 0x0201_4B50 else { throw Failure.corrupt("central directory") }
            let flags = u16(p + 8)
            let nameLength = u16(p + 28), extraLength = u16(p + 30), commentLength = u16(p + 32)
            let name = String(decoding: data[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            if flags & 1 != 0 { throw Failure.unsupported("encrypted entry \(name)") }
            entries[name] = Entry(method: u16(p + 10), compressedSize: u32(p + 20), size: u32(p + 24), localHeaderOffset: u32(p + 42))
            p += 46 + nameLength + extraLength + commentLength
        }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    func read(_ name: String) throws -> Data? {
        guard let e = entries[name] else { return nil }
        let h = e.localHeaderOffset
        guard h + 30 <= data.count, u32(h) == 0x0403_4B50 else { throw Failure.corrupt(name) }
        let start = h + 30 + u16(h + 26) + u16(h + 28)
        guard start + e.compressedSize <= data.count else { throw Failure.corrupt(name) }
        let raw = data[start..<(start + e.compressedSize)]
        switch e.method {
        case 0:
            return Data(raw)
        case 8:
            // Foundation's .zlib algorithm is raw DEFLATE (RFC 1951), which is what ZIP stores.
            let out = try (Data(raw) as NSData).decompressed(using: .zlib) as Data
            guard out.count == e.size else { throw Failure.corrupt(name) }
            return out
        default:
            throw Failure.unsupported("compression method \(e.method) in \(name)")
        }
    }

    private func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
    private func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
}
