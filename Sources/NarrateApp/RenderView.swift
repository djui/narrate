import NarrateCore
import SwiftUI

/// Step 4: render the missing chunks into the cache, resumable, pausable and cancellable.
struct RenderView: View {
    let book: BookModel
    @AppStorage("showRenderLog") private var showLog = false

    private struct Row: Identifiable {
        let id: Int
        let title: String
        let chunks: Int
        let cached: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status).font(.headline)
                    Text("\(book.cachedChunks.formatted()) of \(book.totalChunks.formatted()) chunks · voice \(book.voice) at \(String(format: "%.2f", book.speed))×")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if book.isRendering {
                    Button(book.paused ? "Resume" : "Pause") { book.togglePause() }
                    Button("Stop") { book.cancelRender() }
                } else {
                    Button(book.cachedChunks == 0 ? "Render" : "Render Missing") { book.startRender() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(book.isBusy || book.cachedChunks == book.totalChunks)
                }
            }
            ProgressView(value: Double(book.cachedChunks), total: Double(max(book.totalChunks, 1)))

            Table(rows) {
                TableColumn("Section", value: \.title)
                TableColumn("Progress") { row in
                    HStack {
                        ProgressView(value: Double(row.cached), total: Double(max(row.chunks, 1))).controlSize(.small)
                        Text(percent(row.cached, row.chunks)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
                TableColumn("Chunks") { row in Text("\(row.cached) / \(row.chunks)").monospacedDigit() }
                    .width(90).alignment(.trailing)
            }

            DisclosureGroup("Activity log", isExpanded: $showLog) {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(Array(book.renderLog.enumerated()), id: \.offset) { Text($0.element) }
                    }
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(height: 90)
                .defaultScrollAnchor(.bottom)
            }
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

    private func percent(_ done: Int, _ total: Int) -> String { "\(total == 0 ? 0 : done * 100 / total)%" }

    private var status: String {
        let done = percent(book.cachedChunks, book.totalChunks)
        guard book.isRendering else {
            return book.cachedChunks == book.totalChunks ? "Everything is rendered" : "\(done) rendered · \((book.totalChunks - book.cachedChunks).formatted()) chunks to go"
        }
        if let p = AppState.shared.modelProgress {
            return p.phase == .downloading ? "Downloading the voice model… \(Int(p.fraction * 100))%" : "Checking the voice model… \(Int(p.fraction * 100))%"
        }
        if book.paused { return "\(done) · paused" }
        guard let left = book.renderSecondsLeft else { return "Starting… (the model loads on first use)" }
        return "\(done) · about \(hoursMinutes(left / 60)) left"
    }
}
