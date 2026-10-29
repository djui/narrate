import AppKit
import SwiftUI

@main
struct NarrateApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Narrate", id: "main") {
            RootView(app: AppState.shared)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 760)
        .restorationBehavior(.disabled)
        .commands { FileCommands() }
    }
}

struct FileCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Commands exist from launch, before any window: the delegate opens the window through this.
        let _ = AppState.shared.showWindow = { openWindow(id: "main") }
        CommandGroup(replacing: .newItem) {
            Button("Open EPUB or Project…") { AppState.shared.choose() }
                .keyboardShortcut("o")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run from `swift run` (no bundle), the process starts as a background tool; make it a normal app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // A book to open at launch (`NarrateApp book.epub`, Finder, the Dock icon) arrives through
        // application(_:open:), and SwiftUI then skips its own window, so make sure there is one.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // AppKit hands file arguments to application(_:open:), but not folders such as BOOK.narrate.
                let app = AppState.shared
                if app.book == nil, !app.opening, let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                    app.open(URL(fileURLWithPath: path))
                }
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { AppState.shared.showWindow?() }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated {
            AppState.shared.open(url)
            AppState.shared.showWindow?()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @Bindable var app: AppState

    var body: some View {
        Group {
            if let book = app.book {
                VStack(spacing: 0) {
                    banners(book)
                    BookView(book: book)
                }
                .navigationTitle(book.book.title)
                .navigationSubtitle(book.book.author)
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

    @ViewBuilder private func banners(_ book: BookModel) -> some View {
        if !app.modelReady {
            HStack {
                Image(systemName: "arrow.down.circle")
                if let p = app.modelProgress {
                    Text(p.phase == .downloading ? "Downloading the Kokoro voice model" : "Checking the Kokoro voice model")
                    ProgressView(value: p.fraction).frame(maxWidth: 200)
                } else {
                    Text("The Kokoro voice model (~220 MB) downloads once, the first time you render or preview.")
                    Spacer()
                    Button("Download Now") { app.downloadModel() }.disabled(app.preparingModel)
                }
                Spacer()
            }
            .padding(10)
            .background(.blue.opacity(0.08))
        }
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
