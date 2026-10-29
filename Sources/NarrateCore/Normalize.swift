/// Turn book text into text a TTS engine reads correctly.
///
/// Rules are deterministic and conservative: anything that changes meaning belongs in the
/// per-book pronunciation lexicon (M3), not here.
public enum Normalizer {
    // Titles before a capitalised name.
    private static let titles = [
        "Dr": "Doctor", "Mr": "Mister", "Mrs": "Missus", "Messrs": "Messieurs", "Capt": "Captain",
        "Col": "Colonel", "Gen": "General", "Lt": "Lieutenant", "Sgt": "Sergeant", "Prof": "Professor",
        "Rev": "Reverend", "Hon": "Honourable", "St": "Saint", "Mt": "Mount", "Gov": "Governor",
    ]
    private static let titleRe = Pattern("\\b(\(titles.keys.sorted().joined(separator: "|")))\\.(?=\\s+[A-Z])")
    private static let suffixRe = Pattern("\\b(Jr|Sr)\\.")
    private static let latin: [(Pattern, String)] = [
        (Pattern("\\betc\\.(?=\\s+[A-Z“\"]|\\s*$)"), "et cetera."),
        (Pattern("\\betc\\."), "et cetera"),
        (Pattern("\\be\\.\\s?g\\.,?"), "for example,"),
        (Pattern("\\bi\\.\\s?e\\.,?"), "that is,"),
        (Pattern("\\bvs\\."), "versus"),
        (Pattern("\\bNo\\.(?=\\s*\\d)"), "Number"),
    ]
    // "the year of grace 17—": a deliberately redacted year.
    private static let redactedYear = Pattern("\\b(1\\d)(?:—|_{2,}|-{2,})(?=[\\s,.;:!?”’\"]|$)")
    private static let editorial = Pattern("\\[(?:illustration|footnote|sidenote|transcriber)[^\\]]*\\]|\\[\\d+\\]", ignoreCase: true)
    private static let shouted = Pattern("\\b[A-Z][A-Z’']{3,}\\b")
    private static let numberRange = Pattern("(?<=\\d)\\s*–\\s*(?=\\d)")
    private static let markup = Pattern("[*_#|<>{}\\[\\]]")
    // Road, vitamin and similar codes: "A337", "M27", "B12". Misaki reads a lone capital by its name.
    private static let letterCode = Pattern("(?<![\\w-])([A-Z])(\\d{1,4})(?![\\w-])")
    private static let digitNames = ["oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    /// "M27" → "M twenty-seven"; three or more digits, or a leading zero, digit by digit: "B3056" → "B three oh five six".
    static func letterCode(_ letter: String, _ digits: String) -> String {
        let spoken = digits.count <= 2 && !digits.hasPrefix("0")
            ? NumberWords.words(Int(digits)!)
            : digits.map { digitNames[Int(String($0))!] }.joined(separator: " ")
        return "\(letter) \(spoken)"
    }

    public static func normalize(_ input: String) -> String {
        var text = editorial.replacing(in: input, with: "")
        text = text.replacingOccurrences(of: "--", with: "—")
            .replacingOccurrences(of: "...", with: "…")
            .replacingOccurrences(of: "&", with: " and ")
        text = numberRange.replacing(in: text, with: " to ")
        text = letterCode.replacing(in: text) { letterCode($0[1]!, $0[2]!) }
        text = redactedYear.replacing(in: text) { "\(NumberWords.words(Int($0[1]!)!)) hundred and blank" }
        text = titleRe.replacing(in: text) { titles[$0[1]!]! }
        text = suffixRe.replacing(in: text) { $0[1] == "Jr" ? "Junior" : "Senior" }
        for (pattern, replacement) in latin {
            text = pattern.replacing(in: text, with: replacement)
        }
        text = shouted.replacing(in: text) { m in
            let word = m.string
            return String(word.prefix(1)) + word.dropFirst().lowercased()
        }
        text = markup.replacing(in: text, with: " ")
        return text.collapsedWhitespace
    }
}
