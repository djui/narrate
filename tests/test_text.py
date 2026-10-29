import pytest

from narrate.chunk import MAX_CHARS, PAUSE_ANNOUNCEMENT, PAUSE_SCENE, PAUSE_SECTION, pack, plan, split_sentences
from narrate.epub import read_epub
from narrate.normalize import normalize
from narrate.numwords import number_to_words, roman_to_int


@pytest.mark.parametrize(
    "n, words",
    [(0, "zero"), (17, "seventeen"), (21, "twenty-one"), (100, "one hundred"), (1883, "one thousand eight hundred and eighty-three")],
)
def test_number_to_words(n, words):
    assert number_to_words(n) == words


def test_roman():
    assert [roman_to_int(r) for r in ("I", "IV", "XIX", "XXXIV")] == [1, 4, 19, 34]
    assert roman_to_int("IIII") is None and roman_to_int("Ix") is None


@pytest.mark.parametrize(
    "raw, spoken",
    [
        ("Dr. Livesey and Mr. Trelawney", "Doctor Livesey and Mister Trelawney"),
        ("the year of grace 17—, and", "the year of grace seventeen hundred and blank, and"),
        ("SQUIRE TRELAWNEY said", "Squire Trelawney said"),
        ("pages 10–12", "pages 10 to 12"),
        ("rum, gold, etc. Then", "rum, gold, et cetera. Then"),
        ("a--b", "a—b"),
        ("[Illustration: the ship] It sailed.", "It sailed."),
    ],
)
def test_normalize(raw, spoken):
    assert normalize(raw) == spoken


def test_dialogue_tag_stays_with_its_quote():
    text = "“Ah,” said he, “this is the berth for me.” Then he went in. “Is it?” asked I."
    assert split_sentences(text) == ["“Ah,” said he, “this is the berth for me.”", "Then he went in.", "“Is it?” asked I."]


def test_pack_respects_limit_and_keeps_every_word():
    text = " ".join(f"Sentence number {i} goes on, and on, and on for a while." for i in range(40))
    chunks = pack(text)
    assert all(len(c) <= MAX_CHARS for c in chunks)
    assert " ".join(chunks).split() == text.split()


def test_pack_splits_one_overlong_sentence_at_soft_breaks():
    text = "; ".join(["the wind was rising over the black water"] * 20) + "."
    chunks = pack(text, max_chars=120)
    assert all(len(c) <= 120 for c in chunks) and len(chunks) > 1


def test_plan_pauses_follow_structure(epub_path):
    chunks = plan(read_epub(str(epub_path)))
    texts = [c.text for c in chunks]
    assert "Copyright" not in " ".join(texts)
    first_ch = texts.index("Chapter One. The Old Captain.")
    assert chunks[first_ch].pause == PAUSE_ANNOUNCEMENT
    assert chunks[first_ch + 1].text.startswith("Doctor Livesey came late")
    assert chunks[texts.index("Yo-ho-ho, and a bottle of rum!")].pause == PAUSE_SCENE
    assert chunks[-1].pause == PAUSE_SECTION
    assert "seventeen hundred and blank" in texts[-1]
