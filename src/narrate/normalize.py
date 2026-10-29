"""Turn book text into text a TTS engine reads correctly.

Rules are deterministic and conservative: anything that changes meaning belongs in the
per-book pronunciation lexicon (M3), not here.
"""

import re

from .numwords import number_to_words

# Titles before a capitalised name.
_TITLES = {
    "Dr": "Doctor", "Mr": "Mister", "Mrs": "Missus", "Messrs": "Messieurs", "Capt": "Captain",
    "Col": "Colonel", "Gen": "General", "Lt": "Lieutenant", "Sgt": "Sergeant", "Prof": "Professor",
    "Rev": "Reverend", "Hon": "Honourable", "St": "Saint", "Mt": "Mount", "Gov": "Governor",
}
_TITLE_RE = re.compile(r"\b(%s)\.(?=\s+[A-Z])" % "|".join(_TITLES))
_SUFFIX_RE = re.compile(r"\b(Jr|Sr)\.")
_LATIN = [
    (re.compile(r"\betc\.(?=\s+[A-Z“\"]|\s*$)"), "et cetera."),
    (re.compile(r"\betc\."), "et cetera"),
    (re.compile(r"\be\.\s?g\.,?"), "for example,"),
    (re.compile(r"\bi\.\s?e\.,?"), "that is,"),
    (re.compile(r"\bvs\."), "versus"),
    (re.compile(r"\bNo\.(?=\s*\d)"), "Number"),
]
# "the year of grace 17—": a deliberately redacted year.
_REDACTED_YEAR = re.compile(r"\b(1\d)(?:—|_{2,}|-{2,})(?=[\s,.;:!?”’\"]|$)")
_EDITORIAL = re.compile(r"\[(?:illustration|footnote|sidenote|transcriber)[^\]]*\]|\[\d+\]", re.IGNORECASE)
_SHOUTED = re.compile(r"\b[A-Z][A-Z’']{3,}\b")
# Road, vitamin and similar codes: "A337", "M27", "B12". Misaki reads a lone capital by its name.
_LETTER_CODE = re.compile(r"(?<![\w-])([A-Z])(\d{1,4})(?![\w-])")
_DIGIT_NAMES = ["oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]


def _letter_code(m: re.Match) -> str:
    """"M27" → "M twenty-seven"; three or more digits, or a leading zero, digit by digit: "B3056" → "B three oh five six"."""
    letter, digits = m.group(1), m.group(2)
    if len(digits) <= 2 and not digits.startswith("0"):
        return f"{letter} {number_to_words(int(digits))}"
    return f"{letter} " + " ".join(_DIGIT_NAMES[int(d)] for d in digits)


def _shouted(m: re.Match) -> str:
    word = m.group(0)
    return word[0] + word[1:].lower()


def normalize(text: str) -> str:
    text = _EDITORIAL.sub("", text)
    text = text.replace("--", "—").replace("...", "…").replace("&", " and ")
    text = re.sub(r"(?<=\d)\s*–\s*(?=\d)", " to ", text)
    text = _LETTER_CODE.sub(_letter_code, text)
    text = _REDACTED_YEAR.sub(lambda m: f"{number_to_words(int(m.group(1)))} hundred and blank", text)
    text = _TITLE_RE.sub(lambda m: _TITLES[m.group(1)], text)
    text = _SUFFIX_RE.sub(lambda m: "Junior" if m.group(1) == "Jr" else "Senior", text)
    for pattern, repl in _LATIN:
        text = pattern.sub(repl, text)
    text = _SHOUTED.sub(_shouted, text)
    text = re.sub(r"[*_#|<>{}\[\]]", " ", text)
    return " ".join(text.split())
