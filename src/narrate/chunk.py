"""Split sections into TTS-sized chunks, each carrying the pause that follows it.

Pauses come from the book's structure and are inserted as exact silence at assembly time,
so the model never has to guess where a paragraph or scene ends.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from .epub import Book
from .normalize import normalize

MAX_CHARS = 300  # Kokoro truncates past ~510 phoneme tokens; 300 characters stays well under.

PAUSE_SENTENCE = 0.25
PAUSE_LINE = 0.35
PAUSE_PARAGRAPH = 0.6
PAUSE_HEADING = 1.0
PAUSE_ANNOUNCEMENT = 1.2
PAUSE_SCENE = 1.4
PAUSE_SECTION = 2.0

# A sentence ends at . ! ? … plus closing quotes, before whitespace and a capital or opening quote.
_SENTENCE_END = re.compile(r"([.!?…]+[”\"’'»)\]]*)\s+(?=[“\"‘'«(\[]?[A-Z0-9])")
_SOFT_BREAKS = ("; ", ": ", " — ", "— ", ", ")


@dataclass
class Chunk:
    section: int
    text: str
    pause: float


def split_sentences(text: str) -> list[str]:
    out, last = [], 0
    for m in _SENTENCE_END.finditer(text):
        out.append(text[last : m.end(1)].strip())
        last = m.end()
    out.append(text[last:].strip())
    return [s for s in out if s]


def _split_long(text: str, max_chars: int) -> list[str]:
    pieces = []
    while len(text) > max_chars:
        window = text[: max_chars + 1]
        cut = -1
        for sep in _SOFT_BREAKS:
            pos = window.rfind(sep)
            if pos > max_chars * 0.4:
                cut = pos + len(sep.rstrip())
                break
        if cut < 0:
            cut = window.rfind(" ")
        if cut <= 0:
            cut = max_chars
        pieces.append(text[:cut].strip())
        text = text[cut:].strip()
    if text:
        pieces.append(text)
    return pieces


def pack(text: str, max_chars: int = MAX_CHARS) -> list[str]:
    """Greedily pack whole sentences into chunks of at most max_chars."""
    chunks, current = [], ""
    for sentence in split_sentences(text):
        for piece in _split_long(sentence, max_chars):
            if current and len(current) + 1 + len(piece) > max_chars:
                chunks.append(current)
                current = piece
            else:
                current = f"{current} {piece}" if current else piece
    if current:
        chunks.append(current)
    return chunks


def _speakable(text: str) -> bool:
    return any(ch.isalnum() for ch in text)


def plan(book: Book, max_chars: int = MAX_CHARS) -> list[Chunk]:
    """All chunks for the included sections, in reading order."""
    chunks: list[Chunk] = []

    def add(section: int, text: str, pause: float) -> None:
        text = normalize(text)
        if _speakable(text):
            chunks.append(Chunk(section, text, pause))

    def bump(pause: float) -> None:
        if chunks:
            chunks[-1].pause = max(chunks[-1].pause, pause)

    for idx, section in enumerate(book.sections):
        if not section.include:
            continue
        if section.spoken:
            add(idx, section.spoken, PAUSE_ANNOUNCEMENT)
        for block in section.blocks:
            if block.kind == "scene_break":
                bump(PAUSE_SCENE)
            elif block.kind == "heading":
                add(idx, block.text, PAUSE_HEADING)
            elif block.kind == "verse":
                for line in block.text.split("\n"):
                    for piece in pack(line, max_chars):
                        add(idx, piece, PAUSE_LINE)
                bump(PAUSE_PARAGRAPH)
            else:
                text = f"Note: {block.text}" if block.kind == "note" else block.text
                for piece in pack(text, max_chars):
                    add(idx, piece, PAUSE_SENTENCE)
                bump(PAUSE_PARAGRAPH)
        if chunks and chunks[-1].section == idx:
            chunks[-1].pause = PAUSE_SECTION
    return chunks
