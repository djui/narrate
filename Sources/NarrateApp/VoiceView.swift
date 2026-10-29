import KokoroTTS
import NarrateCore
import SwiftUI

/// Step 3: voice and speed, auditioned on the book's own opening.
struct VoiceView: View {
    @Bindable var book: BookModel

    var body: some View {
        Form {
            Section {
                Picker("Voice", selection: $book.voice) {
                    ForEach(KokoroVoiceID.starterVoices.map(\.rawValue), id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $book.speed, in: 0.7...1.3, step: 0.05)
                        Text(String(format: "%.2f×", book.speed)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
            } footer: {
                Text("Voice and speed are part of every chunk's cache key: changing them renders the book again. Engine: \(book.engine.engineID) · \(book.engine.sampleRate / 1000) kHz.")
                    .foregroundStyle(.secondary)
            }
            .disabled(book.isBusy)

            Section("Preview passage") {
                Text(book.openingPassage.isEmpty ? "No text in the included sections." : book.openingPassage)
                    .foregroundStyle(.secondary)
                HStack {
                    // The first chunk or two of the opening: a few seconds of model time.
                    Button(book.speaking ? "Rendering…" : "Play Preview") { book.speak(Chunker.pack(book.openingPassage).prefix(2).joined(separator: " ")) }
                        .disabled(book.speaking || book.isBusy || book.openingPassage.isEmpty)
                    Button("Stop") { book.stopPlaying() }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: book.voice) { book.saveVoice() }
        .onChange(of: book.speed) { book.saveVoice() }
    }
}
