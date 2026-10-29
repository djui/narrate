import AppKit
import NarrateCore
import SwiftUI

/// The details opened from the book window: sections, pronunciation and review.
enum Panel: String, Identifiable {
    case sections, pronunciation, review

    var id: Self { self }
    var title: String {
        switch self {
        case .sections: "Sections"
        case .pronunciation: "Pronunciation"
        case .review: "Review"
        }
    }
}

/// One window per book: the cover, one action that follows the book's state (render, pause, export),
/// and every section with its render progress. Everything else opens from the buttons under the title.
struct BookView: View {
    let book: BookModel
    /// `NARRATE_PANEL=review` (any panel's name) opens on that panel, for trying a screen quickly.
    @State private var panel: Panel? = Panel(rawValue: ProcessInfo.processInfo.environment["NARRATE_PANEL"] ?? "")
    @State private var showVoice = false
    @AppStorage("showRenderLog") private var showLog = false

    private struct Row: Identifiable {
        let id: Int
        let title: String
        let minutes: Double
        let chunks: Int
        let cached: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24).padding(.top, 36).padding(.bottom, 20)
                .background(.background.secondary)
            Divider()
            Table(rows) {
                TableColumn("Section", value: \.title)
                TableColumn("Time") { row in Text(clock(row.minutes * 60)).monospacedDigit().foregroundStyle(.secondary) }
                    .width(70).alignment(.trailing)
                TableColumn("Rendered") { row in
                    HStack {
                        Bar(fraction: Double(row.cached) / Double(max(row.chunks, 1)), height: 4)
                        Text(percent(row.cached, row.chunks)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
                .width(min: 140, ideal: 220)
                TableColumn("Chunks") { row in Text("\(row.cached) / \(row.chunks)").monospacedDigit().foregroundStyle(.secondary) }
                    .width(80).alignment(.trailing)
            }
            .tableStyle(.inset)
            if !log.isEmpty {
                Divider()
                DisclosureGroup("Activity log", isExpanded: $showLog) {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(Array(log.enumerated()), id: \.offset) { Text($0.element) }
                        }
                        .font(.callout.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .frame(height: 90)
                    .defaultScrollAnchor(.bottom)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .onAppear { if !book.isRendering { book.refreshCache() } }
        .sheet(item: $panel) { panel in
            NavigationStack {
                Group {
                    switch panel {
                    case .sections: ContentsView(book: book)
                    case .pronunciation: WordsView(book: book)
                    case .review: ReviewView(book: book) { self.panel = .pronunciation }
                    }
                }
                .navigationTitle(panel.title)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.panel = nil } } }
            }
            .frame(minWidth: 680, idealWidth: 880, minHeight: 420, idealHeight: 600)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 22) {
            cover
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.book.title).font(.largeTitle.weight(.bold))
                    Text(book.book.author).font(.title3).foregroundStyle(.secondary)
                    Text(meta).font(.callout).foregroundStyle(.tertiary)
                }
                HStack(spacing: 12) {
                    actions
                    Text(status).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                Bar(fraction: Double(book.cachedChunks) / Double(max(book.totalChunks, 1)), height: 6)
                HStack(spacing: 8) {
                    Button("\(included) of \(book.book.sections.count) sections", systemImage: "list.bullet") { panel = .sections }
                    Button(book.unknownWords.map { "\($0.count) words to check" } ?? "Pronunciation", systemImage: "character.bubble") { panel = .pronunciation }
                    Button(book.flagged.isEmpty ? "Nothing flagged" : "\(book.flagged.count) flagged",
                           systemImage: book.flagged.isEmpty ? "checkmark.seal" : "exclamationmark.triangle") { panel = .review }
                    Button("Voice", systemImage: "waveform") { showVoice.toggle() }
                        .popover(isPresented: $showVoice, arrowEdge: .bottom) { VoiceView(book: book).frame(width: 420, height: 340) }
                }
                .modernButtons()
                .buttonBorderShape(.capsule)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var cover: some View {
        Group {
            if let url = book.project.coverURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 128)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 128, height: 186)
                    .overlay(Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary))
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    /// The one action that moves the book on, plus the controls that go with it.
    @ViewBuilder private var actions: some View {
        let missing = book.totalChunks - book.cachedChunks
        if book.isRendering {
            Button(book.paused ? "Resume" : "Pause", systemImage: book.paused ? "play.fill" : "pause.fill") { book.togglePause() }
                .modernButtons(prominent: true)
            Button("Stop", systemImage: "stop.fill") { book.cancelRender() }.modernButtons()
        } else if book.exporting {
            Button("Exporting…", systemImage: "hourglass") {}.modernButtons(prominent: true).disabled(true)
        } else if missing > 0 {
            Button(book.cachedChunks == 0 ? "Render" : "Render Missing", systemImage: "waveform") { book.startRender() }
                .modernButtons(prominent: true).keyboardShortcut(.defaultAction)
        } else if let output = book.output {
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                .modernButtons(prominent: true)
            Button("Export Again", systemImage: "arrow.clockwise") { book.startExport() }.modernButtons()
        } else {
            Button("Export M4B", systemImage: "square.and.arrow.up") { book.startExport() }
                .modernButtons(prominent: true).keyboardShortcut(.defaultAction)
        }
    }

    private var included: Int { book.book.sections.filter(\.include).count }

    private var meta: String {
        var parts = ["\(included) sections", "≈ \(hoursMinutes(book.includedMinutes))", "\(book.voice) at \(String(format: "%.2f", book.speed))×"]
        if let probe = book.probe, !book.exporting {
            parts.append("M4B: \(probe.chapters.count) chapters, \(hoursMinutes(probe.duration / 60))" + (size.map { ", \($0)" } ?? ""))
        }
        return parts.joined(separator: " · ")
    }

    private var size: String? {
        guard let output = book.output, let bytes = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var status: String {
        let done = percent(book.cachedChunks, book.totalChunks)
        if book.exporting { return book.exportLog.last ?? "Exporting…" }
        guard book.isRendering else {
            if book.totalChunks > 0 && book.cachedChunks == book.totalChunks { return book.output == nil ? "Everything is rendered" : "Exported" }
            return "\(done) rendered · \((book.totalChunks - book.cachedChunks).formatted()) chunks to go"
        }
        if let p = AppState.shared.modelProgress {
            return p.phase == .downloading ? "Downloading the voice model… \(Int(p.fraction * 100))%" : "Checking the voice model… \(Int(p.fraction * 100))%"
        }
        if book.paused { return "\(done) · paused" }
        guard let left = book.renderSecondsLeft else { return "Starting… (the model loads on first use)" }
        return "\(done) · " + (left < 60 ? "under a minute left" : "about \(hoursMinutes(left / 60)) left")
    }

    private var log: [String] { book.renderLog + book.exportLog }

    private var rows: [Row] {
        book.book.sections.indices.compactMap { i in
            guard let chunks = book.plannedPerSection[i] else { return nil }
            let s = book.book.sections[i]
            return Row(id: i, title: s.marker.isEmpty ? s.title : s.marker, minutes: book.minutes(s), chunks: chunks, cached: book.cached[i] ?? 0)
        }
    }

    private func percent(_ done: Int, _ total: Int) -> String { "\(total == 0 ? 0 : done * 100 / total)%" }
}

/// A rounded progress bar, thicker than the system one.
struct Bar: View {
    let fraction: Double
    let height: CGFloat

    var body: some View {
        Capsule().fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { g in Capsule().fill(.tint).frame(width: g.size.width * min(max(fraction, 0), 1)) }
            }
            .frame(height: height)
            .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

extension View {
    /// Liquid Glass buttons on macOS 26 and later, bordered ones before.
    @ViewBuilder func modernButtons(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}
