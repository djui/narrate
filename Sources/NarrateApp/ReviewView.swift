import NarrateCore
import SwiftUI

/// Step 5: the chunks that still failed a signal check after their retry. The only screen where you have to listen.
struct ReviewView: View {
    let book: BookModel
    var addPronunciation: () -> Void
    @State private var selection: String?

    var body: some View {
        let flagged = book.flagged
        VStack(spacing: 0) {
            HStack {
                Text(String(format: "%d of %d chunks flagged · %.2f%%", flagged.count, book.totalChunks,
                            100 * Double(flagged.count) / Double(max(1, book.totalChunks))))
                    .foregroundStyle(.secondary)
                Spacer()
                if book.scanning { ProgressView().controlSize(.small) }
                Button("Scan Again") { book.scan() }
                    .help("Check all rendered audio against the book's median speaking rate, without rendering")
                    .disabled(book.isBusy || book.scanning || book.cachedChunks == 0)
            }
            .padding(12)
            Divider()
            if flagged.isEmpty {
                ContentUnavailableView("Nothing flagged", systemImage: "checkmark.seal",
                                       description: Text(book.cachedChunks == 0 ? "Render the book first; every chunk is checked as it renders." : "Every rendered chunk passed the signal checks."))
            } else {
                HSplitView {
                    List(flagged, id: \.key, selection: $selection) { item in
                        FlagRow(book: book, item: item, flag: book.flags[item.key]!)
                    }
                    .frame(minWidth: 280)
                    Group {
                        if let item = flagged.first(where: { $0.key == selection }), let flag = book.flags[item.key] {
                            FlagDetail(book: book, item: item, flag: flag, addPronunciation: addPronunciation)
                        } else {
                            Text("Select a flagged chunk").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 320)
                }
            }
        }
        .onAppear { if selection == nil { selection = flagged.first?.key } }
    }
}

private struct FlagRow: View {
    let book: BookModel
    let item: Renderer.Planned
    let flag: Checks.Flag

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(flag.reasons.joined(separator: ", ")).font(.callout.weight(.semibold)).foregroundStyle(.orange)
                Spacer()
                Text(book.sectionLabel(flag.section)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(flag.text).lineLimit(2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct FlagDetail: View {
    let book: BookModel
    let item: Renderer.Planned
    let flag: Checks.Flag
    var addPronunciation: () -> Void

    var body: some View {
        let m = flag.metrics
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(book.sectionLabel(flag.section)) · \(String(format: "%.1f s", m.seconds))\(flag.retried ? " · retry used" : "")")
                    .font(.headline)
                GroupBox("Book text") {
                    Text(flag.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow { Text("Flagged").foregroundStyle(.secondary); Text(flag.reasons.joined(separator: ", ")) }
                    GridRow { Text("Rate").foregroundStyle(.secondary); Text(String(format: "%.1f chars/s (book median %.1f)", m.charsPerSecond, flag.medianRate)) }
                    GridRow { Text("Longest silence").foregroundStyle(.secondary); Text(String(format: "%.1f s", m.longestSilence)) }
                    if m.clipped > 0 { GridRow { Text("Clipped").foregroundStyle(.secondary); Text(String(format: "%.2f%%", m.clipped * 100)) } }
                    if flag.reasons.contains("cut off") { GridRow { Text("Ends at").foregroundStyle(.secondary); Text(String(format: "%.2f", m.tailLevel)) } }
                }
                HStack {
                    Button("Play") { book.play(Renderer.cacheURL(book.project, key: item.key)) }
                        .keyboardShortcut(.space, modifiers: [])
                    Button("Play in Context") { book.playInContext(item) }
                    Button("Stop") { book.stopPlaying() }
                }
                HStack {
                    Button("Re-render") { book.rerender(item) }.disabled(book.isBusy)
                    Button("Add Pronunciation…") { addPronunciation() }
                    Button("Accept as Is") { book.accept(item) }
                }
                Text("Some flags are false alarms; listening settles it. Re-render drops this chunk from the cache and renders it again, with its checks.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}
