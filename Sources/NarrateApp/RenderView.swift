import NarrateCore
import SwiftUI

/// Step 4: render the missing chunks into the cache, resumable and cancellable.
struct RenderView: View {
    let book: BookModel

    private struct Row: Identifiable {
        let id: Int
        let title: String
        let chunks: Int
        let cached: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status).font(.headline)
                    Text("Rendered \(book.cachedChunks.formatted()) / \(book.totalChunks.formatted()) chunks · voice \(book.voice) at \(String(format: "%.2f", book.speed))×")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if book.isRendering {
                    Button("Stop") { book.cancelRender() }
                } else {
                    Button(book.cachedChunks == 0 ? "Render" : "Render Missing") { book.startRender() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(book.isBusy || book.cachedChunks == book.totalChunks)
                }
            }
            if book.isRendering {
                ProgressView(value: Double(book.renderDone), total: Double(max(book.renderTodo, 1)))
            }

            Table(rows) {
                TableColumn("Section", value: \.title)
                TableColumn("Progress") { row in
                    ProgressView(value: Double(row.cached), total: Double(max(row.chunks, 1))).controlSize(.small)
                }
                TableColumn("Chunks") { row in Text("\(row.cached) / \(row.chunks)").monospacedDigit() }
                    .width(90).alignment(.trailing)
            }

            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(Array(book.renderLog.enumerated()), id: \.offset) { Text($0.element) }
                }
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 70)
            .defaultScrollAnchor(.bottom)

            Text("The Mac stays awake while rendering. Stopping keeps every finished chunk; a cached chunk is never rendered twice.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .onAppear { if !book.isRendering { book.refreshCache() } }
    }

    private var rows: [Row] {
        book.book.sections.indices.compactMap { i in
            guard let chunks = book.plannedPerSection[i] else { return nil }
            let s = book.book.sections[i]
            return Row(id: i, title: s.marker.isEmpty ? s.title : s.marker, chunks: chunks, cached: book.cached[i] ?? 0)
        }
    }

    private var status: String {
        guard book.isRendering else {
            return book.cachedChunks == book.totalChunks ? "Everything is rendered" : "\((book.totalChunks - book.cachedChunks).formatted()) chunks to render"
        }
        if let p = AppState.shared.modelProgress {
            return p.phase == .downloading ? "Downloading the voice model… \(Int(p.fraction * 100))%" : "Checking the voice model… \(Int(p.fraction * 100))%"
        }
        guard let start = book.renderStart, book.renderDone > 0 else { return "Starting… (the model loads on first use)" }
        let elapsed = Date().timeIntervalSince(start)
        let left = elapsed / Double(book.renderDone) * Double(book.renderTodo - book.renderDone)
        return "\(book.renderDone) of \(book.renderTodo) chunks · about \(hoursMinutes(left / 60)) left"
    }
}
