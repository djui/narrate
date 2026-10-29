import NarrateCore
import SwiftUI

/// Step 1: what the EPUB contains and which sections go into the audiobook.
struct ContentsView: View {
    let book: BookModel
    @State private var selection: Int?

    private struct Row: Identifiable {
        let id: Int
        let section: NarrateCore.Section
    }

    var body: some View {
        let sections = book.book.sections
        let included = sections.filter(\.include)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(included.count) of \(sections.count) sections · \(included.reduce(0) { $0 + $1.words }.formatted()) words · ≈ \(hoursMinutes(book.includedMinutes))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Only Chapters and Parts") { book.onlyStory() }
                    .help("Leave out front matter, back matter, notes and the table of contents")
            }
            .padding(12)

            Table(sections.indices.map { Row(id: $0, section: sections[$0]) }, selection: $selection) {
                TableColumn("") { row in
                    Toggle("", isOn: Binding(get: { row.section.include }, set: { book.setInclude(row.id, $0) }))
                        .labelsHidden()
                        .disabled(book.isBusy)
                }
                .width(24)
                TableColumn("Section") { row in
                    Text(label(row.section))
                        .foregroundStyle(row.section.include ? .primary : .secondary)
                        .padding(.leading, row.section.kind == "chapter" ? 14 : 0)
                }
                TableColumn("Detected as") { row in Text(row.section.kind).foregroundStyle(.secondary) }
                    .width(110)
                TableColumn("Words") { row in Text(row.section.words.formatted()).monospacedDigit() }
                    .width(70).alignment(.trailing)
                TableColumn("Est. time") { row in
                    Text(row.section.include ? clock(book.minutes(row.section) * 60) : "—").monospacedDigit()
                }
                .width(70).alignment(.trailing)
            }

            Divider()
            footer.padding(10)
        }
    }

    @ViewBuilder private var footer: some View {
        if let selection, book.book.sections.indices.contains(selection) {
            let section = book.book.sections[selection]
            Text(section.spoken.isEmpty ? "No spoken announcement" : "Spoken: “\(section.spoken)”")
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else {
            Text("Unticked sections are left out of the audio. Times assume \(Int(wordsPerMinute)) words a minute at speed \(String(format: "%.2f", book.speed)).")
                .foregroundStyle(.secondary)
        }
    }

    private func label(_ section: NarrateCore.Section) -> String {
        section.marker.isEmpty ? (section.title.isEmpty ? "(untitled)" : section.title) : section.marker
    }
}
