/// Numbers to English words, and Roman numerals to integers.
public enum NumberWords {
    private static let ones = """
        zero one two three four five six seven eight nine ten eleven twelve thirteen \
        fourteen fifteen sixteen seventeen eighteen nineteen
        """.split(separator: " ").map(String.init)
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let scales: [(Int, String)] = [(1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand")]
    private static let roman = Pattern("M{0,4}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})")
    private static let romanValues: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]

    public static func words(_ n: Int) -> String {
        if n < 0 { return "minus " + words(-n) }
        if n < 20 { return ones[n] }
        if n < 100 { return tens[n / 10] + (n % 10 > 0 ? "-" + ones[n % 10] : "") }
        if n < 1000 { return "\(ones[n / 100]) hundred" + (n % 100 > 0 ? " and " + words(n % 100) : "") }
        for (size, name) in scales where n >= size {
            let rest = n % size
            var out = "\(words(n / size)) \(name)"
            if rest > 0 { out += (rest < 100 ? " and " : " ") + words(rest) }
            return out
        }
        fatalError("unreachable")
    }

    /// Value of a well-formed uppercase Roman numeral, else nil.
    public static func romanValue(_ text: String) -> Int? {
        guard !text.isEmpty, roman.fullMatch(text) else { return nil }
        let chars = Array(text)
        var total = 0
        for (i, ch) in chars.enumerated() {
            let value = romanValues[ch]!
            if i + 1 < chars.count, romanValues[chars[i + 1]]! > value { total -= value } else { total += value }
        }
        return total
    }

    /// "three" -> 3, "Twenty-One" -> 21; up to ninety-nine, as used in part titles.
    public static func wordValue(_ word: String) -> Int? {
        let w = word.lowercased()
        return (0..<100).first { words($0) == w }
    }
}
