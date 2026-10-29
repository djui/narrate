import Foundation

/// Reads an EPUB 2/3 into sections (chapters, parts, front matter) made of speakable blocks.
///
/// Chapters are cut at table-of-contents anchors, not at spine files, because one XHTML file
/// can hold several chapters and one chapter can span several files.
public enum EPUBReader {
    public enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case invalid(String)

        public var description: String {
            switch self {
            case .missing(let path): "EPUB is missing \(path)"
            case .invalid(let what): "EPUB is invalid: \(what)"
            }
        }
    }

    public static func read(_ url: URL) throws -> (Book, Cover?) {
        let package = try Package(url: url)
        let (title, author, language) = package.metadata()
        let lin = Linearizer(package: package)
        try lin.run()

        let toc = try package.toc()
        let tocTitles = Set(toc.map { norm($0.title) }).subtracting([""])
        var starts: [(Int, String)] = []
        for entry in toc {
            guard let docStart = lin.docStart[entry.doc] else { continue }
            let idx = entry.anchor.flatMap { lin.anchors[AnchorKey(doc: entry.doc, id: $0)] } ?? docStart
            if let last = starts.last, idx <= last.0 { continue }  // an anchor that doesn't advance adds no section
            starts.append((idx, entry.title))
        }
        if starts.isEmpty { starts = Set(lin.docStart.values).sorted().map { ($0, "") } }
        if let first = starts.first, first.0 > 0 { starts.insert((0, ""), at: 0) }

        var sections: [Section] = []
        var seenChapter = false
        for (n, (start, tocTitle)) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].0 : lin.blocks.count
            let blocks = Array(lin.blocks[start..<end])
            guard blocks.contains(where: { !$0.text.isEmpty }) else { continue }
            let types = start < lin.blockTypes.count ? lin.blockTypes[start] : []
            let sectionTitle = tocTitle.isEmpty ? (blocks.first { $0.kind == .heading }?.text ?? "") : tocTitle
            var section = Section(title: sectionTitle, blocks: blocks)
            classify(&section, types: types, text: blocks.map(\.text).joined(separator: " "), bookTitle: title, seenChapter: seenChapter, tocTitles: tocTitles)
            seenChapter = seenChapter || section.kind == "chapter"
            dropTitleHeadings(&section, bookTitle: title)
            if !section.blocks.isEmpty || section.kind == "part" { sections.append(section) }
        }
        return (Book(title: title, author: author, language: language, sections: sections), try package.cover())
    }

    // MARK: - Package (container, OPF, TOC)

    struct TocEntry {
        let title: String
        let doc: String
        let anchor: String?
    }

    struct ManifestItem {
        let href: String
        let type: String
        let props: Set<String>
    }

    final class Package {
        let archive: ZipArchive
        let opf: XMLElement
        let opfDir: String
        var manifest: [String: ManifestItem] = [:]
        var manifestOrder: [String] = []
        var spine: [String] = []
        private var docs: [String: XMLElement] = [:]

        init(url: URL) throws {
            archive = try ZipArchive(url: url)
            let container = try Package.parse(Package.read(archive, "META-INF/container.xml"))
            guard let rootfile = descendants(container, "rootfile").first, let opfPath = rootfile.attribute(forName: "full-path")?.stringValue else {
                throw Failure.invalid("container.xml has no rootfile")
            }
            opf = try Package.parse(Package.read(archive, opfPath))
            opfDir = (opfPath as NSString).deletingLastPathComponent
            for item in descendants(opf, "item") {
                guard let id = attr(item, "id"), let href = attr(item, "href") else { continue }
                manifest[id] = ManifestItem(
                    href: resolve(opfDir, href),
                    type: attr(item, "media-type") ?? "",
                    props: Set((attr(item, "properties") ?? "").split(separator: " ").map(String.init))
                )
                manifestOrder.append(id)
            }
            for ref in descendants(opf, "itemref") {
                guard let item = attr(ref, "idref").flatMap({ manifest[$0] }), item.type.contains("html"), attr(ref, "linear") != "no" else { continue }
                spine.append(item.href)
            }
        }

        static func read(_ archive: ZipArchive, _ path: String) throws -> Data {
            guard let data = try archive.read(path) else { throw Failure.missing(path) }
            return data
        }

        /// Foundation's XMLDocument drops a whitespace-only text node between two elements, even with
        /// `.nodePreserveWhitespace`: `<b>to</b> <i>be</i>` reads "tobe". Inside `<body>` such gaps
        /// become a no-break space, which `clean` reads as a space.
        static let elementGap = Pattern("(?<=>)[ \\t\\r\\n]+(?=<)")

        static func protectingGaps(_ data: Data) -> Data {
            guard let text = String(data: data, encoding: .utf8), let body = text.range(of: "<body") else { return data }
            return Data((text[..<body.lowerBound] + elementGap.replacing(in: String(text[body.lowerBound...]), with: "\u{00A0}")).utf8)
        }

        static func parse(_ data: Data) throws -> XMLElement {
            let options: XMLNode.Options = [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever]
            let data = protectingGaps(data)
            let doc = try (try? XMLDocument(data: data, options: options)) ?? XMLDocument(data: data, options: options.union(.documentTidyXML))
            guard let root = doc.rootElement() else { throw Failure.invalid("empty XML document") }
            return root
        }

        func data(_ path: String) throws -> Data { try Package.read(archive, path) }

        func doc(_ path: String) throws -> XMLElement {
            if let cached = docs[path] { return cached }
            let root = try Package.parse(data(path))
            docs[path] = root
            return root
        }

        func metadata() -> (String, String, String) {
            func first(_ name: String) -> String {
                descendants(opf, name).first.map { ($0.stringValue ?? "").collapsedWhitespace } ?? ""
            }
            let metas = descendants(opf, "meta")
            var authors: [String] = []
            for creator in descendants(opf, "creator") {
                let id = attr(creator, "id")
                let role = metas.first { attr($0, "refines") == "#\(id ?? "")" && attr($0, "property") == "role" }
                let roleText = (role?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if id == nil || role == nil || roleText == "aut" || roleText.isEmpty {
                    let name = (creator.stringValue ?? "").collapsedWhitespace
                    if !name.isEmpty { authors.append(name) }
                }
            }
            let language = first("language")
            return (first("title"), authors.joined(separator: ", "), language.isEmpty ? "en" : language)
        }

        func cover() throws -> Cover? {
            var href = manifestOrder.compactMap { manifest[$0] }.last { $0.props.contains("cover-image") }?.href
            if href == nil, let meta = descendants(opf, "meta").first(where: { attr($0, "name") == "cover" }),
               let item = attr(meta, "content").flatMap({ manifest[$0] }), item.type.hasPrefix("image/") {
                href = item.href
            }
            guard let href else { return nil }
            var ext = (href as NSString).pathExtension.lowercased()
            if ext.isEmpty || ext == "jpeg" { ext = "jpg" }
            return Cover(fileExtension: ext, data: try data(href))
        }

        func toc() throws -> [TocEntry] {
            if let nav = manifestOrder.compactMap({ manifest[$0] }).first(where: { $0.props.contains("nav") }) {
                let entries = try tocFromNav(nav.href)
                if !entries.isEmpty { return entries }
            }
            if let ncx = manifestOrder.compactMap({ manifest[$0] }).first(where: { $0.type == "application/x-dtbncx+xml" }) {
                return try tocFromNCX(ncx.href)
            }
            return []
        }

        private func entry(base: String, title: String, href: String) -> TocEntry? {
            let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let path = parts[0]
            let anchor = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            let doc = path.isEmpty ? base : resolve((base as NSString).deletingLastPathComponent, path)
            let clean = title.collapsedWhitespace
            return clean.isEmpty ? nil : TocEntry(title: clean, doc: doc, anchor: anchor)
        }

        private func tocFromNav(_ href: String) throws -> [TocEntry] {
            let root = try doc(href)
            let navs = descendants(root, "nav")
            guard let nav = navs.first(where: { epubTypes($0).contains("toc") }) ?? navs.first else { return [] }
            return descendants(nav, "a").compactMap { entry(base: href, title: $0.stringValue ?? "", href: attr($0, "href") ?? "") }
        }

        private func tocFromNCX(_ href: String) throws -> [TocEntry] {
            let root = try Package.parse(data(href))
            return descendants(root, "navPoint").compactMap { point in
                guard let label = point.elements(forLocalName: "navLabel", uri: nil).first.flatMap({ descendants($0, "text").first }) ?? descendants(point, "text").first,
                      let content = descendants(point, "content").first else { return nil }
                return entry(base: href, title: label.stringValue ?? "", href: attr(content, "src") ?? "")
            }
        }
    }

    // MARK: - Linearizer

    struct AnchorKey: Hashable {
        let doc: String
        let id: String
    }

    static let blockTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "pre", "dt", "dd", "td", "th", "blockquote", "div"]
    static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    static let skipTags: Set<String> = ["script", "style", "head", "nav", "svg", "math", "figure", "img", "audio", "video", "object", "iframe"]
    static let skipClasses: Set<String> = ["fig", "figure", "caption", "pagenum", "pageno", "page-number", "pagebreak", "illustration", "image"]
    static let skipTypes: Set<String> = ["pagebreak", "toc", "landmarks", "loi", "lot"]
    static let noteTypes: Set<String> = ["footnote", "endnote", "rearnote", "note"]
    static let verseClasses: Set<String> = ["poem", "verse", "stanza", "poetry", "song"]
    static let sceneClasses: Set<String> = ["tb", "scene", "scenebreak", "scene-break", "break", "transition", "dinkus", "section-break"]
    static let sceneText = Pattern("^[\\s*⁂•·~#—–\\-◆◇❧]{1,24}$")
    static let containerTags: Set<String> = ["section", "article", "ul", "ol", "dl", "table", "hr"]
    /// Stands in for <br/>; source newlines are just whitespace.
    static let br = "\u{2028}"

    final class Linearizer {
        let package: Package
        var blocks: [Block] = []
        var blockTypes: [Set<String>] = []
        var anchors: [AnchorKey: Int] = [:]
        var docStart: [String: Int] = [:]
        var notes: [AnchorKey: String] = [:]
        private var doc = ""

        init(package: Package) { self.package = package }

        func run() throws {
            for path in package.spine { try collectNotes(path) }
            for path in package.spine {
                docStart[path] = blocks.count
                doc = path
                if let body = descendants(try package.doc(path), "body").first {
                    walk(body, inherited: epubTypes(body))
                }
            }
        }

        private func collectNotes(_ path: String) throws {
            doc = path
            for el in descendants(try package.doc(path), nil) {
                guard let id = attr(el, "id"), !epubTypes(el).isDisjoint(with: noteTypes) else { continue }
                var refs: [AnchorKey] = []
                var text = clean(inlineText(el, &refs))
                text = Pattern("^\\W*\\d+\\W*\\s*").replacing(in: text, with: "")
                if !text.isEmpty { notes[AnchorKey(doc: path, id: id)] = text }
            }
        }

        private func mark(_ el: XMLElement) {
            for sub in [el] + descendants(el, nil) {
                if let id = attr(sub, "id") { anchors[AnchorKey(doc: doc, id: id)] = anchors[AnchorKey(doc: doc, id: id)] ?? blocks.count }
            }
        }

        private func shouldSkip(_ el: XMLElement) -> Bool {
            let name = el.localName ?? ""
            return skipTags.contains(name)
                || !classes(el).isDisjoint(with: skipClasses)
                || !epubTypes(el).isDisjoint(with: skipTypes.union(noteTypes))
                || (name == "aside" && attr(el, "id") != nil)
        }

        private func hasBlockChildren(_ el: XMLElement) -> Bool {
            childElements(el).contains { blockTags.contains($0.localName ?? "") || containerTags.contains($0.localName ?? "") }
        }

        private func walk(_ el: XMLElement, inherited: Set<String>) {
            let name = el.localName ?? ""
            let types = inherited.union(epubTypes(el))
            if shouldSkip(el) {
                mark(el)
                return
            }
            if name == "hr" || (!classes(el).isDisjoint(with: sceneClasses) && (el.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                mark(el)
                add(Block(.sceneBreak, ""), types)
                return
            }
            if blockTags.contains(name) && !(["div", "blockquote", "li"].contains(name) && hasBlockChildren(el)) {
                mark(el)
                block(el, name: name, types: types)
                return
            }
            if let id = attr(el, "id") { anchors[AnchorKey(doc: doc, id: id)] = anchors[AnchorKey(doc: doc, id: id)] ?? blocks.count }
            for child in childElements(el) { walk(child, inherited: types) }
        }

        private func block(_ el: XMLElement, name: String, types: Set<String>) {
            var refs: [AnchorKey] = []
            let raw = inlineText(el, &refs)
            let isVerse = !classes(el).isDisjoint(with: verseClasses) || (name == "p" && raw.components(separatedBy: br).count - 1 >= 2)
            var text = clean(raw, keepNewlines: isVerse)
            if !text.isEmpty, sceneText.fullMatch(text), !text.hasAlphanumeric {
                add(Block(.sceneBreak, ""), types)
            } else if !text.isEmpty, headingTags.contains(name) {
                let heading = raw.contains(br)
                    ? clean(raw.replacingOccurrences(of: br, with: ". ")).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                    : text
                add(Block(.heading, heading), types)
            } else if !text.isEmpty, isVerse {
                let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[0].isAllUppercase {  // "TO THE HESITATING PURCHASER" opening a poem
                    add(Block(.heading, parts[0]), types)
                    text = parts[1]
                }
                add(Block(.verse, text), types)
            } else if !text.isEmpty {
                add(Block(.para, text), types)
            }
            for ref in refs {
                if let note = notes[ref] { add(Block(.note, note), types) }
            }
        }

        private func add(_ block: Block, _ types: Set<String>) {
            if block.kind == .sceneBreak, blocks.last?.kind == .sceneBreak || blocks.isEmpty { return }
            blocks.append(block)
            blockTypes.append(types)
        }

        private func inlineText(_ el: XMLElement, _ refs: inout [AnchorKey]) -> String {
            var out = ""
            for node in el.children ?? [] {
                switch node.kind {
                case .text:
                    out += node.stringValue ?? ""
                case .element:
                    guard let child = node as? XMLElement else { continue }
                    let name = child.localName ?? ""
                    if name == "br" {
                        out += br
                    } else if epubTypes(child).contains("noteref") {
                        let href = attr(child, "href") ?? ""
                        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                        let target = parts[0].isEmpty ? doc : resolve((doc as NSString).deletingLastPathComponent, parts[0])
                        refs.append(AnchorKey(doc: target, id: parts.count > 1 ? parts[1] : ""))
                    } else if skipTags.contains(name) || epubTypes(child).contains("pagebreak") || !classes(child).isDisjoint(with: ["pagenum", "pageno"]) {
                        continue
                    } else {
                        out += inlineText(child, &refs)
                    }
                default:
                    continue
                }
            }
            return out
        }
    }

    // MARK: - Classification

    static let chapterRe = Pattern("^(?<label>chapter\\s+)?(?<num>[IVXLCDM]+|\\d+)\\b[.:]?\\s*(?<rest>.*)$", ignoreCase: true)
    static let partRe = Pattern("^(?<label>part|book|volume)\\s+(?<num>[\\w-]+)\\b\\s*[—–:.\\-]*\\s*(?<rest>.*)$", ignoreCase: true)
    static let namedRe = Pattern("^(prologue|epilogue|preface|foreword|introduction|afterword|interlude|postscript)\\b", ignoreCase: true)
    static let skipSectionTypes: Set<String> = [
        "copyright-page", "colophon", "imprint", "toc", "index", "landmarks", "loi", "lot",
        "titlepage", "halftitlepage", "seriespage", "errata", "endnotes", "rearnotes", "footnotes",
    ]
    static let smallWords: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "nor", "of", "on", "or", "the", "to", "up", "via"]

    static func parseNumber(_ token: String) -> Int? {
        if let n = Int(token) { return n }
        return NumberWords.romanValue(token) ?? NumberWords.wordValue(token)
    }

    static func withPeriod(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?".contains(last) ? text : text + "."
    }

    static func isInlineTOC(_ section: Section, _ tocTitles: Set<String>) -> Bool {
        let lines = section.blocks.filter { $0.kind == .para || $0.kind == .heading }
        let hits = lines.filter { tocTitles.contains(norm($0.text)) }.count
        return lines.count >= 5 && Double(hits) >= 0.6 * Double(lines.count)
    }

    static func classify(_ section: inout Section, types: Set<String>, text: String, bookTitle: String, seenChapter: Bool, tocTitles: Set<String>) {
        let title = section.title
        let low = title.lowercased()
        let head = String(text.prefix(600)).lowercased()
        if let type = types.intersection(skipSectionTypes).sorted().first {
            section.kind = ["copyright-page": "copyright", "colophon": "copyright", "imprint": "copyright"][type] ?? type
            section.include = false
        } else if low.contains("gutenberg") || low.contains("license") || (head.contains("project gutenberg") && head.contains("ebook")) {
            (section.kind, section.include) = ("boilerplate", false)
        } else if Pattern("(table of )?contents").fullMatch(low) || isInlineTOC(section, tocTitles) {
            (section.kind, section.include) = ("toc", false)
        } else if low.hasPrefix("copyright") {
            (section.kind, section.include) = ("copyright", false)
        } else if low == "index" {
            (section.kind, section.include) = ("index", false)
        } else if let m = partRe.prefixMatch(title) {
            let n = parseNumber(m["num"]!)
            let rest = titlecase(m["rest"] ?? "")
            let label = m["label"]!.capitalized
            let num = n.map { NumberWords.words($0).capitalized } ?? m["num"]!.capitalized
            (section.kind, section.include, section.number) = ("part", true, n)
            section.marker = "\(label) \(num)" + (rest.isEmpty ? "" : " — \(rest)")
            section.spoken = "\(label) \(num)." + (rest.isEmpty ? "" : " \(rest).")
        } else if let m = chapterRe.prefixMatch(title), let n = parseNumber(m["num"]!), !(m["rest"] ?? "").isEmpty || m["label"] != nil {
            // A bare number needs a title after it; "Chapter 12" on its own is a chapter too.
            let rest = titlecase(m["rest"] ?? "")
            (section.kind, section.include, section.number) = ("chapter", true, n)
            section.marker = rest.isEmpty ? "Chapter \(n)" : "\(n) · \(rest)"
            section.spoken = "Chapter \(NumberWords.words(n).capitalized)." + (rest.isEmpty ? "" : " " + withPeriod(rest))
        } else if section.words <= 15 {
            (section.kind, section.include) = ("titlepage", false)
        } else if namedRe.prefixMatch(title) != nil {
            (section.kind, section.include) = (seenChapter ? "back" : "front", true)
            section.marker = titlecase(title)
            section.spoken = withPeriod(section.marker)
        } else {
            (section.kind, section.include) = (seenChapter ? "back" : "front", true)
            if !norm(title).isEmpty, norm(title) != norm(bookTitle) {
                section.marker = titlecase(title)
                section.spoken = withPeriod(section.marker)
            } else {
                let heading = section.blocks.first { $0.kind == .heading && norm($0.text) != norm(bookTitle) }?.text ?? ""
                section.marker = heading.isEmpty ? (seenChapter ? "Afterword" : "Opening") : titlecase(heading)
            }
        }
    }

    /// The announcement replaces the section's own heading, so don't read it twice.
    static func dropTitleHeadings(_ section: inout Section, bookTitle: String) {
        var dupes: Set<String> = [norm(bookTitle), norm(section.title), norm(section.spoken)]
        if !section.spoken.isEmpty { dupes.insert(norm(section.marker)) }
        if let n = section.number { dupes.insert(norm(String(n))) }
        dupes.remove("")
        var kept: [Block] = []
        for (i, b) in section.blocks.enumerated() {
            if b.kind == .heading, dupes.contains(norm(b.text)) || (i < 3 && NumberWords.romanValue(b.text.trimmingCharacters(in: CharacterSet(charactersIn: " ."))) != nil) {
                continue
            }
            kept.append(b)
        }
        while kept.first?.kind == .sceneBreak { kept.removeFirst() }
        while kept.last?.kind == .sceneBreak { kept.removeLast() }
        section.blocks = kept
    }

    /// Title-case an ALL-CAPS heading; leave mixed-case text alone.
    static func titlecase(_ text: String) -> String {
        guard text.isAllUppercase else { return text }
        let words = text.lowercased().split(separator: " ").map(String.init)
        return words.enumerated().map { i, w in
            if i > 0 && smallWords.contains(w) { return w }
            return w.split(separator: "-", omittingEmptySubsequences: false).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
        }.joined(separator: " ")
    }

    static func norm(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { $0.value >= 97 && $0.value <= 122 }.map(Character.init))
    }

    static func clean(_ text: String, keepNewlines: Bool = false) -> String {
        let t = text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{00AD}", with: "")
        if keepNewlines {
            return t.components(separatedBy: br).map(\.collapsedWhitespace).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return t.replacingOccurrences(of: br, with: " ").collapsedWhitespace
    }
}

// MARK: - XML helpers

private func childElements(_ el: XMLElement) -> [XMLElement] {
    (el.children ?? []).compactMap { $0 as? XMLElement }
}

/// All descendant elements in document order, optionally filtered by local name.
private func descendants(_ el: XMLElement, _ localName: String?) -> [XMLElement] {
    var out: [XMLElement] = []
    func visit(_ node: XMLElement) {
        for child in childElements(node) {
            if localName == nil || child.localName == localName { out.append(child) }
            visit(child)
        }
    }
    visit(el)
    return out
}

private func attr(_ el: XMLElement, _ name: String) -> String? {
    el.attribute(forName: name)?.stringValue ?? el.attribute(forLocalName: name, uri: nil)?.stringValue
}

private func epubTypes(_ el: XMLElement) -> Set<String> {
    let value = el.attribute(forLocalName: "type", uri: "http://www.idpf.org/2007/ops")?.stringValue
        ?? el.attribute(forName: "epub:type")?.stringValue ?? ""
    return Set(value.split(separator: " ").map(String.init))
}

private func classes(_ el: XMLElement) -> Set<String> {
    Set((attr(el, "class") ?? "").lowercased().split(separator: " ").map(String.init))
}

/// posixpath.normpath(join(base, unquote(href)))
private func resolve(_ base: String, _ href: String) -> String {
    let decoded = href.removingPercentEncoding ?? href
    let joined = base.isEmpty ? decoded : base + "/" + decoded
    var parts: [String] = []
    for part in joined.split(separator: "/") {
        if part == "." || part.isEmpty { continue }
        if part == "..", !parts.isEmpty { parts.removeLast() } else { parts.append(String(part)) }
    }
    return parts.joined(separator: "/")
}
