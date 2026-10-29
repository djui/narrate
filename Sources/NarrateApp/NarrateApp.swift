import AppKit
import SwiftUI

@main
struct NarrateApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Narrate", id: "main") {
            RootView(app: AppState.shared)
                .frame(minWidth: 860, minHeight: 520)
        }
        // Always open the window at launch. Without this, a launch that macOS treats as a
        // restore (after a crash or kill, or from a background `open`) can come up with no window.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open EPUB or Project…") { AppState.shared.choose() }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run from `swift run` (no bundle), the process starts as a background tool; make it a normal app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // `NarrateApp path/to/book.epub` (or a .narrate folder) opens it straight away.
        if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            MainActor.assumeIsolated { AppState.shared.open(URL(fileURLWithPath: path)) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @Bindable var app: AppState
    /// `NARRATE_STEP=review` (any step's name) opens on that step, for trying a screen quickly.
    @State private var step: Step = Step(rawValue: ProcessInfo.processInfo.environment["NARRATE_STEP"] ?? "") ?? .contents

    var body: some View {
        Group {
            if let book = app.book {
                NavigationSplitView {
                    Sidebar(book: book, step: $step)
                } detail: {
                    detail(book)
                        .navigationTitle(book.book.title)
                        .navigationSubtitle(book.book.author)
                }
            } else {
                Welcome(app: app)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            app.open(url)
            return true
        }
        .alert("Can't open book", isPresented: .constant(app.error != nil), presenting: app.error) { _ in
            Button("OK") { app.error = nil }
        } message: { Text($0) }
    }

    @ViewBuilder private func detail(_ book: BookModel) -> some View {
        VStack(spacing: 0) {
            if let error = book.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { book.error = nil }
                }
                .padding(10)
                .background(.orange.opacity(0.12))
            }
            switch step {
            case .contents: ContentsView(book: book)
            case .pronunciation: WordsView(book: book)
            case .voice: VoiceView(book: book)
            case .render: RenderView(book: book)
            case .review: ReviewView(book: book) { step = .pronunciation }
            case .export: ExportView(book: book)
            }
        }
    }
}

struct Sidebar: View {
    let book: BookModel
    @Binding var step: Step

    var body: some View {
        List(selection: $step) {
            Section(book.book.title) {
                ForEach(Step.allCases) { step in
                    Label(step.title, systemImage: step.symbol)
                        .badge(badge(step))
                        .tag(step)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    }

    private func badge(_ step: Step) -> Text? {
        switch step {
        case .contents: Text("\(book.book.sections.filter(\.include).count)")
        case .pronunciation: book.unknownWords.map { Text("\($0.count)") }
        case .review where !book.flagged.isEmpty: Text("\(book.flagged.count)")
        case .render where book.isRendering && book.renderTodo > 0: Text("\(100 * book.renderDone / book.renderTodo)%")
        case .render where book.totalChunks > 0 && book.cachedChunks == book.totalChunks: Text("✓")
        case .export where book.exporting: Text("…")
        case .export where book.output != nil: Text("✓")
        default: nil
        }
    }
}

struct Welcome: View {
    let app: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Drop a DRM-free EPUB here").font(.title2)
            Text("or a .narrate project folder. Narrate keeps everything for a book in BOOK.narrate next to the EPUB.")
                .foregroundStyle(.secondary)
            if app.opening {
                ProgressView("Reading the book…")
            } else {
                Button("Open…") { app.choose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "1:05:09" or "18:30", the way the report's sketches show durations.
func clock(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// "7 h 29 min" or "18 min".
func hoursMinutes(_ minutes: Double) -> String {
    let m = Int(minutes.rounded())
    return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
}
