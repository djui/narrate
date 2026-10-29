import AppKit
import NarrateCore
import SwiftUI

/// Step 6: assemble the cached chunks into a chaptered M4B and show what ffprobe sees in it.
struct ExportView: View {
    let book: BookModel

    var body: some View {
        let missing = book.totalChunks - book.cachedChunks
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                cover
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    row("Title", book.book.title)
                    row("Author", book.book.author)
                    row("Narrator", "Synthetic voice (Kokoro \(book.voice))")
                    row("Rendered", missing == 0 ? "all \(book.totalChunks) chunks" : "\(book.cachedChunks) of \(book.totalChunks) chunks; render the rest first")
                    if let probe = book.probe {
                        row("Chapters", "\(probe.chapters.count) markers (QuickTime chapter track)")
                        row("Audio", probe.audio)
                        row("Length", hoursMinutes(probe.duration / 60) + (size.map { " · \($0)" } ?? ""))
                        row("Cover", probe.cover ? "attached" : "none")
                    }
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Button("Build M4B") { book.startExport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(book.isBusy || book.cachedChunks == 0 || missing > 0)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([book.output!]) }
                        .disabled(book.output == nil)
                }
            }

            if book.exporting || !book.exportLog.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if book.exporting { ProgressView().progressViewStyle(.linear) }
                    ForEach(Array(book.exportLog.enumerated()), id: \.offset) { Text($0.element).font(.callout.monospaced()) }
                }
            }

            if let probe = book.probe {
                List(Array(probe.chapters.enumerated()), id: \.offset) { item in
                    Text(item.element)
                }
                .listStyle(.bordered)
                if let output = book.output {
                    Text(output.lastPathComponent).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                Spacer()
            }
        }
        .padding(16)
    }

    @ViewBuilder private var cover: some View {
        if let url = book.project.coverURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 110).clipShape(.rect(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 110, height: 160)
                .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
        }
    }

    private var size: String? {
        guard let output = book.output, let bytes = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
