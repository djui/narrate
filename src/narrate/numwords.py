"""Numbers to English words, and Roman numerals to integers."""

import re

_ONES = (
    "zero one two three four five six seven eight nine ten eleven twelve thirteen "
    "fourteen fifteen sixteen seventeen eighteen nineteen"
).split()
_TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
_SCALES = ((10**9, "billion"), (10**6, "million"), (1000, "thousand"))
_ROMAN = re.compile(r"M{0,4}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})")
_ROMAN_VALUES = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000}


def number_to_words(n: int) -> str:
    if n < 0:
        return "minus " + number_to_words(-n)
    if n < 20:
        return _ONES[n]
    if n < 100:
        tens, ones = divmod(n, 10)
        return _TENS[tens] + (f"-{_ONES[ones]}" if ones else "")
    if n < 1000:
        hundreds, rest = divmod(n, 100)
        return f"{_ONES[hundreds]} hundred" + (f" and {number_to_words(rest)}" if rest else "")
    for size, name in _SCALES:
        if n >= size:
            head, rest = divmod(n, size)
            words = f"{number_to_words(head)} {name}"
            if rest:
                words += (" and " if rest < 100 else " ") + number_to_words(rest)
            return words
    raise AssertionError("unreachable")


def roman_to_int(text: str) -> int | None:
    """Return the value of a well-formed uppercase Roman numeral, else None."""
    if not text or not _ROMAN.fullmatch(text):
        return None
    total = 0
    for i, ch in enumerate(text):
        value = _ROMAN_VALUES[ch]
        if i + 1 < len(text) and _ROMAN_VALUES[text[i + 1]] > value:
            total -= value
        else:
            total += value
    return total


def word_to_int(word: str) -> int | None:
    """'three' -> 3, 'Twenty-One' -> 21; only up to ninety-nine, as used in part titles."""
    word = word.lower()
    for n in range(100):
        if number_to_words(n) == word:
            return n
    return None
