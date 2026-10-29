import AVFoundation
import Foundation
import NarrateCore

/// Playback, flagged chunks (Review) and the pronunciation list (Words), mirroring `narrate review` and `narrate words`.
extension BookModel {
    // MARK: Playback

    func play(_ url: URL) {
        do {
            player?.stop()
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch {
            self.error = message(error)
        }
    }

    func stopPlaying() {
        player?.stop()
        player = nil
    }

    /// Synthesize a short text with the current voice, speed and lexicon, and play it.
    func speak(_ text: String) {
        guard !speaking, !isRendering else { return }
        if let other = otherHeavyJob() {
            error = "Another heavy job is running; wait for it to finish first:\n\(other)"
            return
        }
        let spoken: String
        do {
            spoken = try Renderer.resolveLexicon(project, phonemizer: phonemizer).apply(text)
        } catch {
            self.error = message(error)
            return
        }
        speaking = true
        let (engine, voice, speed) = (engine, voice, speed)
        Task {
            defer { speaking = false }
            do {
                let audio = Renderer.trimSilence(try await engine.synthesize(spoken, voice: voice, speed: speed), sampleRate: engine.sampleRate)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("narrate-preview.wav")
                try WAV.write(audio, sampleRate: engine.sampleRate, to: url)
                play(url)
            } catch {
                self.error = message(error)
            }
        }
    }

    // MARK: Review

    /// Flagged chunks of the current plan, in reading order.
    var flagged: [Renderer.Planned] { planned.filter { flags[$0.key] != nil } }

    func sectionLabel(_ index: Int) -> String {
        guard book.sections.indices.contains(index) else { return "§ \(index)" }
        let s = book.sections[index]
        return s.marker.isEmpty ? (s.title.isEmpty ? "§ \(index)" : s.title) : s.marker
    }

    /// The chunk with up to one chunk either side of it, joined with their planned pauses.
    func playInContext(_ item: Renderer.Planned) {
        guard let i = planned.firstIndex(where: { $0.key == item.key }) else { return }
        do {
            var audio: [Float] = []
            var rate = engine.sampleRate
            for j in max(0, i - 1)...min(planned.count - 1, i + 1) {
                let url = Renderer.cacheURL(project, key: planned[j].key)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let (samples, r) = try WAV.read(url)
                rate = r
                audio += samples + [Float](repeating: 0, count: Int(planned[j].chunk.pause * Double(r)))
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("narrate-context.wav")
            try WAV.write(audio, sampleRate: rate, to: url)
            play(url)
        } catch {
            self.error = message(error)
        }
    }

    /// Check all cached audio again against the book's median, without rendering (`narrate review --scan`).
    func scan() {
        guard !isBusy, !scanning else { return }
        scanning = true
        let (project, planned, previous) = (project, planned, flags)
        Task {
            defer { scanning = false }
            do {
                flags = try await Task.detached {
                    // Keep the record of earlier retries for chunks that still fail.
                    let flags = try Checks.scan(project, planned).flags.mapValues { flag in
                        var flag = flag
                        flag.retried = previous.values.contains { $0.text == flag.text && $0.retried }
                        return flag
                    }
                    try Checks.save(flags, to: project)
                    return flags
                }.value
            } catch {
                self.error = message(error)
            }
        }
    }

    /// Keep the chunk as it is. A later scan checks it again.
    func accept(_ item: Renderer.Planned) {
        flags[item.key] = nil
        saveFlags()
    }

    /// Drop the chunk from the cache and render its section's missing chunks, which re-checks it.
    func rerender(_ item: Renderer.Planned) {
        guard !isBusy else { return }
        try? FileManager.default.removeItem(at: Renderer.cacheURL(project, key: item.key))
        flags[item.key] = nil
        saveFlags()
        refreshCache()
        startRender(sections: [item.chunk.section])
    }

    private func saveFlags() {
        do { try Checks.save(flags, to: project) } catch { self.error = message(error) }
    }

    // MARK: Words

    /// List the words Kokoro's G2P has to guess, most frequent first (`narrate words`).
    func listWords() {
        let (planned, voice) = (planned, voice)
        Task {
            unknownWords = await Task.detached {
                Lexicon.unknownWords(planned, phonemizer: MisakiPhonemizer(voice: voice))
            }.value
        }
    }

    /// Set how a word sounds ("Liv-see" or "/lˈɪvsi/") in the book's or the global lexicon, or
    /// remove it with an empty `say`. Returns how many chunks now need rendering again.
    @discardableResult
    func setWord(_ word: String, say: String, global: Bool) -> Int {
        guard !isBusy else { return 0 }
        let before = planned.map(\.key)
        do {
            let url = global ? Lexicon.globalURL : project.lexiconURL
            var lexicon = try Lexicon.load(url)
            let say = say.trimmingCharacters(in: .whitespaces)
            lexicon.entries[word] = say.isEmpty ? nil : Lexicon.Entry(say: say)
            lexicon.resolve(with: phonemizer)
            try lexicon.save(url)
        } catch {
            self.error = message(error)
            return 0
        }
        refreshPlan()
        if !say.isEmpty { unknownWords?.removeAll { $0.word.lowercased() == word.lowercased() } }
        return zip(before, planned.map(\.key)).filter { $0 != $1 }.count
    }
}
