import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

/// Writes mono float PCM as an AAC M4B with iTunes tags, cover art and a QuickTime chapter track
/// (a text track the audio track references as its chapter list, the one Apple Books reads).
/// AVAssetWriter resamples to the output rate and encodes with Apple's AAC encoder.
final class M4BWriter {
    struct Chapter {
        var title: String
        var start: Int  // samples at the input rate
        var end: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case writer(String)
        var description: String { switch self { case .writer(let m): "M4B writer failed: \(m)" } }
    }

    private let writer: AVAssetWriter
    private let audio: AVAssetWriterInput
    private let text: AVAssetWriterInput
    private let audioFormat: CMAudioFormatDescription
    private let textFormat: CMFormatDescription
    private let sampleRate: Int
    private let chapters: [Chapter]
    private var nextChapter = 0
    private var written = 0

    init(url: URL, sampleRate: Int, outputRate: Int, bitrate: Int, chapters: [Chapter], metadata: [AVMetadataItem]) throws {
        self.sampleRate = sampleRate
        self.chapters = chapters
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        writer.shouldOptimizeForNetworkUse = true  // moov first, so players can start before the whole file is read
        writer.metadata = metadata

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var af: CMAudioFormatDescription?
        try Self.check(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                      magicCookie: nil, extensions: nil, formatDescriptionOut: &af), "audio format")
        audioFormat = af!
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: outputRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: bitrate,
        ], sourceFormatHint: audioFormat)
        audio.expectsMediaDataInRealTime = false

        // A minimal QuickTime 'text' sample description: size, type, reserved, data reference 1, zeroed style.
        var desc = [UInt8](repeating: 0, count: 60)
        desc[3] = 60
        desc.replaceSubrange(4..<8, with: Array("text".utf8))
        desc[15] = 1
        var tf: CMFormatDescription?
        try Self.check(desc.withUnsafeBufferPointer {
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: nil, bigEndianTextDescriptionData: $0.baseAddress!, size: $0.count, flavor: nil, mediaType: kCMMediaType_Text,
                formatDescriptionOut: &tf)
        }, "text format")
        textFormat = tf!
        text = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
        text.expectsMediaDataInRealTime = false
        text.marksOutputTrackAsEnabled = false

        writer.add(audio)
        writer.add(text)
        audio.addTrackAssociation(withTrackOf: text, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        guard writer.startWriting() else { throw Failure.writer(writer.error.map { "\($0)" } ?? "could not start") }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let buffer = try audioBuffer(samples)
        try wait(for: audio)
        guard audio.append(buffer) else { throw failure("audio append") }
        written += samples.count
    }

    func finish() throws {
        while nextChapter <= chapters.count { try wait(for: text) }
        audio.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw failure("finish") }
    }

    private func appendChapter() throws {
        let c = chapters[nextChapter]
        nextChapter += 1
        // Sample: 16-bit length, UTF-8 text, then an 'encd' atom declaring UTF-8.
        let utf8 = Array(c.title.utf8.prefix(0xFFFF))
        var bytes = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)] + utf8
        bytes += [0, 0, 0, 12] + Array("encd".utf8) + [0, 0, 1, 0]
        let block = try blockBuffer(bytes)
        var timing = CMSampleTimingInfo(duration: time(max(1, c.end - c.start)), presentationTimeStamp: time(c.start), decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        try Self.check(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: textFormat, sampleCount: 1,
                                                 sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                                 sampleSizeArray: &size, sampleBufferOut: &sample), "chapter sample")
        guard text.append(sample!) else { throw failure("chapter append") }
    }

    private func audioBuffer(_ samples: [Float]) throws -> CMSampleBuffer {
        let block = try samples.withUnsafeBytes { try blockBuffer($0) }
        var sample: CMSampleBuffer?
        try Self.check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: samples.count,
            presentationTimeStamp: time(written), packetDescriptions: nil, sampleBufferOut: &sample), "audio sample")
        return sample!
    }

    private func blockBuffer(_ bytes: some ContiguousBytes) throws -> CMBlockBuffer {
        try bytes.withUnsafeBytes { raw in
            var block: CMBlockBuffer?
            try Self.check(CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: raw.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                dataLength: raw.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block), "block buffer")
            try Self.check(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
                                                         dataLength: raw.count), "block copy")
            return block!
        }
    }

    private func time(_ samples: Int) -> CMTime { CMTime(value: CMTimeValue(samples), timescale: CMTimeScale(sampleRate)) }

    /// The writer interleaves its tracks and holds back one that runs ahead, so chapters are fed whenever
    /// the text track will take them, and the track is finished right after the last one; otherwise the
    /// audio stalls waiting for more text.
    private func wait(for input: AVAssetWriterInput) throws {
        while true {
            while nextChapter <= chapters.count && text.isReadyForMoreMediaData {
                if nextChapter == chapters.count {
                    text.markAsFinished()
                    nextChapter += 1
                } else {
                    try appendChapter()
                }
            }
            if input === text ? nextChapter > chapters.count : input.isReadyForMoreMediaData { return }
            guard writer.status == .writing else { throw failure("wait") }
            usleep(1000)
        }
    }

    private func failure(_ step: String) -> Failure { .writer("\(step): \(writer.error.map { "\($0)" } ?? "status \(writer.status.rawValue)")") }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw Failure.writer("\(step): OSStatus \(status)") }
    }

    // MARK: Metadata

    /// iTunes tags; `stik` (media type) 2 marks an audiobook.
    static func metadata(tags: [(AVMetadataIdentifier, String)], cover: URL?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = tags.filter { !$0.1.isEmpty }.map { id, value in
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value as NSString
            return item
        }
        let stik = AVMutableMetadataItem()
        stik.keySpace = .iTunes
        stik.key = "stik" as NSString
        stik.value = NSNumber(value: 2)
        stik.dataType = kCMMetadataBaseDataType_SInt8 as String
        items.append(stik)
        if let cover, let (data, type) = coverArt(cover) {
            let art = AVMutableMetadataItem()
            art.identifier = .iTunesMetadataCoverArt
            art.value = data as NSData
            art.dataType = type as String
            items.append(art)
        }
        return items
    }

    /// JPEG and PNG go in as they are; anything else ImageIO can read is converted to JPEG.
    static func coverArt(_ url: URL) -> (Data, CFString)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return (data, kCMMetadataBaseDataType_JPEG) }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return (data, kCMMetadataBaseDataType_PNG) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, kCMMetadataBaseDataType_JPEG)
    }
}
