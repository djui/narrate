from narrate.epub import Book, read_epub


def test_metadata_and_cover(epub_path):
    book = read_epub(str(epub_path))
    assert (book.title, book.author, book.language) == ("The Test Voyage", "Ann Author", "en")
    assert book.cover[0] == "jpg"


def test_sections_follow_toc_anchors_not_files(epub_path):
    book = read_epub(str(epub_path))
    kinds = [(s.kind, s.include, s.marker) for s in book.sections]
    assert kinds == [
        ("copyright", False, ""),
        ("part", True, "Part One — The Harbour"),
        ("chapter", True, "1 · The Old Captain"),
        ("chapter", True, "2 · A Black Spot"),
    ]


def test_chapter_announcement_replaces_heading(epub_path):
    ch1 = read_epub(str(epub_path)).sections[2]
    assert ch1.spoken == "Chapter One. The Old Captain."
    assert all(b.kind != "heading" for b in ch1.blocks)


def test_blocks_footnote_verse_scene_break(epub_path):
    ch1 = read_epub(str(epub_path)).sections[2]
    assert [b.kind for b in ch1.blocks] == ["para", "note", "verse", "scene_break", "para"]
    assert ch1.blocks[0].text == "Dr. Livesey came late one afternoon. He looked at the captain."
    assert ch1.blocks[1].text == "Livesey is said “LIV-see”."
    assert ch1.blocks[2].text == "Fifteen men on the dead man's chest—\nYo-ho-ho, and a bottle of rum!"


def test_figures_and_page_numbers_are_not_read(epub_path):
    book = read_epub(str(epub_path))
    text = " ".join(b.text for s in book.sections for b in s.blocks)
    assert "ship at anchor" not in text
    assert "12It" not in text and "It was in the year" in text


def test_json_round_trip(epub_path):
    book = read_epub(str(epub_path))
    again = Book.from_json(book.to_json())
    assert again.sections == book.sections
