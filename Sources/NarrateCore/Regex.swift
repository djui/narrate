import Foundation

/// A thin wrapper over NSRegularExpression (ICU), chosen over Swift Regex for lookbehind.
struct Pattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, ignoreCase: Bool = false) {
        regex = try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }

    struct Match {
        let result: NSTextCheckingResult
        let source: NSString

        var range: NSRange { result.range }
        var string: String { source.substring(with: result.range) }

        subscript(_ group: Int) -> String? {
            let r = result.range(at: group)
            return r.location == NSNotFound ? nil : source.substring(with: r)
        }

        subscript(_ name: String) -> String? {
            let r = result.range(withName: name)
            return r.location == NSNotFound ? nil : source.substring(with: r)
        }
    }

    func matches(in text: String) -> [Match] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { Match(result: $0, source: ns) }
    }

    /// Anchored at the start, like Python's `re.match`.
    func prefixMatch(_ text: String) -> Match? {
        let ns = text as NSString
        guard let r = regex.firstMatch(in: text, options: [.anchored], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Match(result: r, source: ns)
    }

    func fullMatch(_ text: String) -> Bool {
        guard let m = prefixMatch(text) else { return false }
        return m.range.length == (text as NSString).length
    }

    func replacing(in text: String, _ transform: (Match) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in matches(in: text) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += transform(m)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    func replacing(in text: String, with literal: String) -> String {
        replacing(in: text) { _ in literal }
    }
}

extension String {
    /// Python's `" ".join(s.split())`: collapse every run of whitespace (including NBSP) to one space.
    var collapsedWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Python's `str.isupper()`: at least one cased character and none lowercase.
    var isAllUppercase: Bool {
        contains { $0.isLetter && $0.isCased } && !contains { $0.isLowercase }
    }

    var hasAlphanumeric: Bool { contains { $0.isLetter || $0.isNumber } }
}
