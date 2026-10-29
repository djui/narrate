import NarrateCore
import SwiftUI

/// Step 2: words Kokoro's G2P has to guess, ranked by count, and the sounds-like spellings that fix them.
struct WordsView: View {
    let book: BookModel
    @State private var global = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                Toggle("Save to global lexicon", isOn: $global)
                    .help("Global entries apply to every book; a book's own entry wins over a global one")
            }
            .padding(12)

            if let words = book.unknownWords {
                Table(words) {
                    TableColumn("Count") { w in Text("\(w.count)").monospacedDigit() }
                        .width(50).alignment(.trailing)
                    TableColumn("Word") { w in Text(w.word).fontWeight(.medium) }
                        .width(min: 90, ideal: 120)
                    TableColumn("Kokoro's guess") { w in Text(w.guess.isEmpty ? "dropped" : "/\(w.guess)/").foregroundStyle(w.guess.isEmpty ? .orange : .secondary) }
                        .width(min: 90, ideal: 120)
                    TableColumn("Sounds like") { w in
                        SoundsLike(word: w.word) { say in
                            let changed = book.setWord(w.word, say: say, global: global)
                            status = "\(w.word) saved; \(changed) chunks to re-render."
                        }
                    }
                    .width(min: 110, ideal: 140)
                    TableColumn("First use") { w in
                        HStack {
                            Button { book.speak(w.example) } label: { Image(systemName: "play.circle") }
                                .buttonStyle(.borderless)
                                .help("Hear this sentence with the current lexicon")
                                .disabled(book.speaking || book.isRendering)
                            Text(w.example).lineLimit(1).foregroundStyle(.secondary).help(w.example)
                        }
                    }
                }
            } else if book.isRendering {
                ContentUnavailableView("Rendering", systemImage: "hourglass",
                                       description: Text("The word list is made once the render finishes."))
            } else {
                ProgressView("Listing words…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            entries.padding(10)
        }
        .onAppear { if book.unknownWords == nil { book.listWords() } }
        .onChange(of: book.isRendering) { if !book.isRendering, book.unknownWords == nil { book.listWords() } }
    }

    private var summary: String {
        let guessed = book.unknownWords.map { "\($0.count) words guessed" } ?? "Listing words"
        return "\(guessed) · \(book.bookLexicon.entries.count) in this book's lexicon · \(book.globalLexicon.entries.count) global"
    }

    /// The entries already set, with a way to remove them.
    @ViewBuilder private var entries: some View {
        let rows = book.bookLexicon.entries.map { ($0.key, $0.value, false) } + book.globalLexicon.entries.map { ($0.key, $0.value, true) }
        VStack(alignment: .leading, spacing: 6) {
            if let status { Text(status).font(.callout) }
            if rows.isEmpty {
                Text("Type a sounds-like spelling (“Liv-see”) or IPA between slashes (“/lˈɪvsi/”) and press Return. Changing a word re-renders only the chunks that contain it.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(rows.sorted { $0.0.lowercased() < $1.0.lowercased() }, id: \.0) { word, entry, isGlobal in
                            HStack(spacing: 4) {
                                Text("\(word) → \(entry.say)\(isGlobal ? " (global)" : "")")
                                Button {
                                    let changed = book.setWord(word, say: "", global: isGlobal)
                                    status = "\(word) removed; \(changed) chunks to re-render."
                                } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .disabled(book.isBusy)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: .capsule)
                        }
                    }
                }
            }
        }
    }
}

private struct SoundsLike: View {
    let word: String
    let save: (String) -> Void
    @State private var text = ""

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespaces).isEmpty
        HStack(spacing: 4) {
            TextField("keep default", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !empty { save(text) } }
            Button("Set") { save(text) }.disabled(empty)
        }
    }
}

extension Lexicon.UnknownWord: Identifiable {
    public var id: String { word.lowercased() }
}
