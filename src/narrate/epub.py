"""Read an EPUB 2/3 into sections (chapters, parts, front matter) made of speakable blocks.

Chapters are cut at table-of-contents anchors, not at spine files, because one XHTML file
can hold several chapters and one chapter can span several files.
"""

from __future__ import annotations

import posixpath
import re
import string
import zipfile
from dataclasses import asdict, dataclass, field
from urllib.parse import unquote

from lxml import etree

from .numwords import number_to_words, roman_to_int, word_to_int

NS = {
    "c": "urn:oasis:names:tc:opendocument:xmlns:container",
    "opf": "http://www.idpf.org/2007/opf",
    "dc": "http://purl.org/dc/elements/1.1/",
    "ncx": "http://www.daisy.org/z3986/2005/ncx/",
    "x": "http://www.w3.org/1999/xhtml",
}
EPUB_TYPE = "{http://www.idpf.org/2007/ops}type"

BLOCK_TAGS = {"p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "pre", "dt", "dd", "td", "th", "blockquote", "div"}
HEADING_TAGS = {"h1", "h2", "h3", "h4", "h5", "h6"}
SKIP_TAGS = {"script", "style", "head", "nav", "svg", "math", "figure", "img", "audio", "video", "object", "iframe"}
SKIP_CLASSES = {"fig", "figure", "caption", "pagenum", "pageno", "page-number", "pagebreak", "illustration", "image"}
SKIP_TYPES = {"pagebreak", "toc", "landmarks", "loi", "lot"}
NOTE_TYPES = {"footnote", "endnote", "rearnote", "note"}
VERSE_CLASSES = {"poem", "verse", "stanza", "poetry", "song"}
SCENE_CLASSES = {"tb", "scene", "scenebreak", "scene-break", "break", "transition", "dinkus", "section-break"}
SCENE_TEXT = re.compile(r"^[\s*⁂•·~#—–\-◆◇❧]{1,24}$")

SKIP_SECTION_TYPES = {
    "copyright-page", "colophon", "imprint", "toc", "index", "landmarks", "loi", "lot",
    "titlepage", "halftitlepage", "seriespage", "errata", "endnotes", "rearnotes", "footnotes",
}
SMALL_WORDS = {"a", "an", "and", "as", "at", "but", "by", "for", "in", "nor", "of", "on", "or", "the", "to", "up", "via"}


@dataclass
class Block:
    kind: str  # para | verse | heading | scene_break | note
    text: str


@dataclass
class Section:
    title: str  # as written in the table of contents
    kind: str  # chapter | part | front | back | titlepage | toc | copyright | boilerplate | index | notes
    include: bool
    blocks: list[Block] = field(default_factory=list)
    number: int | None = None
    marker: str = ""  # chapter marker title in the M4B
    spoken: str = ""  # announcement read before the section, if any

    @property
    def words(self) -> int:
        return sum(len(b.text.split()) for b in self.blocks)


@dataclass
class Book:
    title: str
    author: str
    language: str
    sections: list[Section]
    cover: tuple[str, bytes] | None = None  # (file extension, image bytes)

    def to_json(self) -> dict:
        return {
            "title": self.title,
            "author": self.author,
            "language": self.language,
            "sections": [asdict(s) for s in self.sections],
        }

    @classmethod
    def from_json(cls, data: dict) -> Book:
        sections = []
        for s in data["sections"]:
            blocks = [Block(**b) for b in s.pop("blocks")]
            sections.append(Section(blocks=blocks, **s))
        return cls(data["title"], data["author"], data["language"], sections)


@dataclass
class _TocEntry:
    title: str
    doc: str
    anchor: str | None


def _local(el) -> str:
    return etree.QName(el).localname if isinstance(el.tag, str) else ""


def _classes(el) -> set[str]:
    return set((el.get("class") or "").lower().split())


def _types(el) -> set[str]:
    return set((el.get(EPUB_TYPE) or "").split())


BR = " "  # stands in for <br/>; source newlines are just whitespace


def _clean(text: str, keep_newlines: bool = False) -> str:
    """Collapse whitespace; with keep_newlines, <br/> line breaks survive as "\\n"."""
    text = text.replace(" ", " ").replace("­", "")
    if keep_newlines:
        lines = [" ".join(line.split()) for line in text.split(BR)]
        return "\n".join(line for line in lines if line)
    return " ".join(text.replace(BR, " ").split())


def titlecase(text: str) -> str:
    """Title-case an ALL-CAPS heading; leave mixed-case text alone."""
    if not text.isupper():
        return text
    words = text.lower().split()
    out = []
    for i, w in enumerate(words):
        if i and w in SMALL_WORDS:
            out.append(w)
        else:
            out.append(string.capwords(w, "-") if "-" in w else w[:1].upper() + w[1:])
    return " ".join(out)


def _norm(text: str) -> str:
    return re.sub(r"[^a-z]", "", text.lower())


class _Reader:
    def __init__(self, path: str):
        self.zip = zipfile.ZipFile(path)
        container = etree.fromstring(self.zip.read("META-INF/container.xml"))
        self.opf_path = container.find(".//c:rootfile", NS).get("full-path")
        self.opf_dir = posixpath.dirname(self.opf_path)
        self.opf = etree.fromstring(self.zip.read(self.opf_path))
        self.manifest = {}
        for item in self.opf.iterfind(".//opf:manifest/opf:item", NS):
            self.manifest[item.get("id")] = {
                "href": self._resolve(self.opf_dir, item.get("href")),
                "type": item.get("media-type", ""),
                "props": set((item.get("properties") or "").split()),
            }
        self.spine = []
        for ref in self.opf.iterfind(".//opf:spine/opf:itemref", NS):
            item = self.manifest.get(ref.get("idref"))
            if item and "html" in item["type"] and ref.get("linear", "yes") != "no":
                self.spine.append(item["href"])
        self._docs: dict[str, etree._Element] = {}

    @staticmethod
    def _resolve(base: str, href: str) -> str:
        return posixpath.normpath(posixpath.join(base, unquote(href)))

    def doc(self, path: str):
        if path not in self._docs:
            parser = etree.XMLParser(recover=True, resolve_entities=False, no_network=True, huge_tree=True)
            self._docs[path] = etree.fromstring(self.zip.read(path), parser)
        return self._docs[path]

    def metadata(self) -> tuple[str, str, str]:
        def first(xpath: str) -> str:
            el = self.opf.find(xpath, NS)
            return _clean(el.text or "") if el is not None else ""

        creators = self.opf.findall(".//dc:creator", NS)
        authors = []
        for c in creators:
            role = self.opf.find(f".//opf:meta[@refines='#{c.get('id')}'][@property='role']", NS)
            if role is None or (role.text or "").strip() in ("aut", ""):
                authors.append(_clean(c.text or ""))
        return first(".//dc:title"), ", ".join(a for a in authors if a), first(".//dc:language") or "en"

    def cover(self) -> tuple[str, bytes] | None:
        href = None
        for item in self.manifest.values():
            if "cover-image" in item["props"]:
                href = item["href"]
        if href is None:
            meta = self.opf.find(".//opf:meta[@name='cover']", NS)
            item = self.manifest.get(meta.get("content")) if meta is not None else None
            href = item["href"] if item and item["type"].startswith("image/") else None
        if href is None:
            return None
        ext = posixpath.splitext(href)[1].lower().lstrip(".") or "jpg"
        return ("jpg" if ext == "jpeg" else ext), self.zip.read(href)

    def toc(self) -> list[_TocEntry]:
        nav = next((i for i in self.manifest.values() if "nav" in i["props"]), None)
        if nav:
            entries = self._toc_from_nav(nav["href"])
            if entries:
                return entries
        ncx = next((i for i in self.manifest.values() if i["type"] == "application/x-dtbncx+xml"), None)
        return self._toc_from_ncx(ncx["href"]) if ncx else []

    def _entry(self, base: str, title: str, href: str) -> _TocEntry | None:
        path, _, anchor = href.partition("#")
        doc = self._resolve(posixpath.dirname(base), path) if path else base
        title = _clean(title)
        return _TocEntry(title, doc, anchor or None) if title else None

    def _toc_from_nav(self, href: str) -> list[_TocEntry]:
        root = self.doc(href)
        navs = [n for n in root.iter("{*}nav") if "toc" in _types(n)] or list(root.iter("{*}nav"))[:1]
        out = []
        for a in navs[0].iter("{*}a") if navs else []:
            entry = self._entry(href, "".join(a.itertext()), a.get("href") or "")
            if entry:
                out.append(entry)
        return out

    def _toc_from_ncx(self, href: str) -> list[_TocEntry]:
        root = etree.fromstring(self.zip.read(href))
        out = []
        for point in root.iter("{%s}navPoint" % NS["ncx"]):
            label = point.find("ncx:navLabel/ncx:text", NS)
            content = point.find("ncx:content", NS)
            if label is not None and content is not None:
                entry = self._entry(href, label.text or "", content.get("src") or "")
                if entry:
                    out.append(entry)
        return out


class _Linearizer:
    """Flattens spine documents into one list of blocks and remembers where every id lands."""

    def __init__(self, reader: _Reader):
        self.reader = reader
        self.blocks: list[Block] = []
        self.block_types: list[set[str]] = []
        self.anchors: dict[tuple[str, str], int] = {}
        self.doc_start: dict[str, int] = {}
        self.notes: dict[tuple[str, str], str] = {}

    def run(self) -> None:
        for path in self.reader.spine:
            self._collect_notes(path)
        for path in self.reader.spine:
            self.doc_start[path] = len(self.blocks)
            body = next(self.reader.doc(path).iter("{*}body"), None)
            if body is not None:
                self.doc = path
                self._walk(body, _types(body))

    def _collect_notes(self, path: str) -> None:
        for el in self.reader.doc(path).iter():
            if isinstance(el.tag, str) and el.get("id") and (_types(el) & NOTE_TYPES):
                text = _clean(self._text(el, []))
                text = re.sub(r"^\W*\d+\W*\s*", "", text)  # drop the leading note number
                if text:
                    self.notes[(path, el.get("id"))] = text

    def _mark(self, el) -> None:
        for sub in el.iter():
            if isinstance(sub.tag, str) and sub.get("id"):
                self.anchors.setdefault((self.doc, sub.get("id")), len(self.blocks))

    def _skip(self, el) -> bool:
        name = _local(el)
        return (
            name in SKIP_TAGS
            or bool(_classes(el) & SKIP_CLASSES)
            or bool(_types(el) & (SKIP_TYPES | NOTE_TYPES))
            or (name == "aside" and bool(el.get("id")))
        )

    def _has_block_children(self, el) -> bool:
        return any(_local(c) in BLOCK_TAGS or _local(c) in {"section", "article", "ul", "ol", "dl", "table", "hr"} for c in el)

    def _walk(self, el, inherited: set[str]) -> None:
        if not isinstance(el.tag, str):
            return
        name = _local(el)
        types = inherited | _types(el)
        if self._skip(el):
            self._mark(el)
            return
        if name == "hr" or (_classes(el) & SCENE_CLASSES and not "".join(el.itertext()).strip()):
            self._mark(el)
            self._add(Block("scene_break", ""), types)
            return
        if name in BLOCK_TAGS and not (name in {"div", "blockquote", "li"} and self._has_block_children(el)):
            self._mark(el)
            self._block(el, name, types)
            return
        if el.get("id"):
            self.anchors.setdefault((self.doc, el.get("id")), len(self.blocks))
        for child in el:
            self._walk(child, types)

    def _block(self, el, name: str, types: set[str]) -> None:
        refs: list[str] = []
        raw = self._text(el, refs)
        verse = bool(_classes(el) & VERSE_CLASSES) or (name == "p" and raw.count(BR) >= 2)
        text = _clean(raw, keep_newlines=verse)
        if text and SCENE_TEXT.match(text) and not any(ch.isalnum() for ch in text):
            self._add(Block("scene_break", ""), types)
        elif text and name in HEADING_TAGS:
            self._add(Block("heading", _clean(raw.replace(BR, ". ")).strip(". ") if BR in raw else text), types)
        elif text and verse:
            first, _, rest = text.partition("\n")
            if rest and first.isupper():  # "TO THE HESITATING PURCHASER" opening a poem
                self._add(Block("heading", first), types)
                text = rest
            self._add(Block("verse", text), types)
        elif text:
            self._add(Block("para", text), types)
        for ref in refs:
            note = self.notes.get(ref)
            if note:
                self._add(Block("note", note), types)

    def _add(self, block: Block, types: set[str]) -> None:
        if block.kind == "scene_break" and (not self.blocks or self.blocks[-1].kind == "scene_break"):
            return
        self.blocks.append(block)
        self.block_types.append(types)

    def _text(self, el, refs: list[str]) -> str:
        out: list[str] = [el.text or ""] if isinstance(el.tag, str) else []
        for child in el:
            self._inline(child, out, refs)
        return "".join(out)

    def _inline(self, el, out: list[str], refs: list[str]) -> None:
        name = _local(el)
        if not name:
            out.append(el.tail or "")
            return
        if name == "br":
            out.append(BR)
        elif "noteref" in _types(el):
            href = el.get("href") or ""
            path, _, anchor = href.partition("#")
            doc = _Reader._resolve(posixpath.dirname(self.doc), path) if path else self.doc
            refs.append((doc, anchor))
        elif name in SKIP_TAGS or _types(el) & {"pagebreak"} or _classes(el) & {"pagenum", "pageno"}:
            pass
        else:
            out.append(el.text or "")
            for child in el:
                self._inline(child, out, refs)
        out.append(el.tail or "")


_CHAPTER = re.compile(r"^(?P<label>chapter\s+)?(?P<num>[IVXLCDM]+|\d+)\b[.:]?\s*(?P<rest>.*)$", re.IGNORECASE)
_PART = re.compile(r"^(?P<label>part|book|volume)\s+(?P<num>[\w-]+)\b\s*[—–:.\-]*\s*(?P<rest>.*)$", re.IGNORECASE)
_NAMED = re.compile(r"^(prologue|epilogue|preface|foreword|introduction|afterword|interlude|postscript)\b", re.IGNORECASE)


def _parse_number(token: str) -> int | None:
    if token.isdigit():
        return int(token)
    return roman_to_int(token) or word_to_int(token)


def _is_inline_toc(section: Section, toc_titles: set[str]) -> bool:
    """A printed table of contents: most of its lines are titles from the real TOC."""
    lines = [b for b in section.blocks if b.kind in ("para", "heading")]
    hits = sum(1 for b in lines if _norm(b.text) in toc_titles)
    return len(lines) >= 5 and hits >= 0.6 * len(lines)


def _classify(section: Section, types: set[str], text: str, book_title: str, seen_chapter: bool, toc_titles: set[str]) -> None:
    title = section.title
    low = title.lower()
    head = text[:600].lower()
    if types & SKIP_SECTION_TYPES:
        kind = sorted(types & SKIP_SECTION_TYPES)[0]
        section.kind = {"copyright-page": "copyright", "colophon": "copyright", "imprint": "copyright"}.get(kind, kind)
        section.include = False
    elif "gutenberg" in low or "license" in low or ("project gutenberg" in head and "ebook" in head):
        section.kind, section.include = "boilerplate", False
    elif re.fullmatch(r"(table of )?contents", low) or _is_inline_toc(section, toc_titles):
        section.kind, section.include = "toc", False
    elif low.startswith("copyright"):
        section.kind, section.include = "copyright", False
    elif re.fullmatch(r"index", low):
        section.kind, section.include = "index", False
    elif m := _PART.match(title):
        n = _parse_number(m["num"])
        rest = titlecase(m["rest"])
        section.kind, section.include, section.number = "part", True, n
        label = m["label"].capitalize()
        num = number_to_words(n).title() if n is not None else m["num"].title()
        section.marker = f"{label} {num}" + (f" — {rest}" if rest else "")
        section.spoken = f"{label} {num}." + (f" {rest}." if rest else "")
    elif (m := _CHAPTER.match(title)) and (n := _parse_number(m["num"])) is not None and (m["rest"] or m["label"]):
        # A bare number needs a title after it; "Chapter 12" on its own is a chapter too.
        rest = titlecase(m["rest"])
        section.kind, section.include, section.number = "chapter", True, n
        section.marker = f"{n} · {rest}" if rest else f"Chapter {n}"
        section.spoken = f"Chapter {number_to_words(n).title()}." + (f" {rest}" + ("" if rest[-1] in ".!?" else ".") if rest else "")
    elif section.words <= 15:
        section.kind, section.include = "titlepage", False
    elif _NAMED.match(title):
        section.kind, section.include = ("back" if seen_chapter else "front"), True
        section.marker = titlecase(title)
        section.spoken = section.marker + ("" if section.marker[-1] in ".!?" else ".")
    else:
        section.kind = "back" if seen_chapter else "front"
        section.include = True
        if _norm(title) and _norm(title) != _norm(book_title):
            section.marker = titlecase(title)
            section.spoken = section.marker + ("" if section.marker[-1] in ".!?" else ".")
        else:
            heading = next((b.text for b in section.blocks if b.kind == "heading" and _norm(b.text) != _norm(book_title)), "")
            section.marker = titlecase(heading) if heading else ("Afterword" if seen_chapter else "Opening")


def _drop_title_headings(section: Section, book_title: str) -> None:
    """The announcement replaces the section's own heading, so don't read it twice."""
    dupes = {_norm(book_title), _norm(section.title), _norm(section.spoken)}
    if section.spoken:
        dupes.add(_norm(section.marker))
    if section.number is not None:
        dupes.add(_norm(str(section.number)))
    dupes.discard("")
    blocks = []
    for i, b in enumerate(section.blocks):
        if b.kind == "heading" and (_norm(b.text) in dupes or (i < 3 and roman_to_int(b.text.strip(" .")) is not None)):
            continue
        blocks.append(b)
    while blocks and blocks[0].kind == "scene_break":
        blocks.pop(0)
    while blocks and blocks[-1].kind == "scene_break":
        blocks.pop()
    section.blocks = blocks


def read_epub(path: str) -> Book:
    reader = _Reader(path)
    title, author, language = reader.metadata()
    lin = _Linearizer(reader)
    lin.run()

    toc = reader.toc()
    toc_titles = {_norm(e.title) for e in toc} - {""}
    starts: list[tuple[int, str]] = []
    for entry in toc:
        if entry.doc not in lin.doc_start:
            continue
        idx = lin.anchors.get((entry.doc, entry.anchor), lin.doc_start[entry.doc]) if entry.anchor else lin.doc_start[entry.doc]
        if starts and idx <= starts[-1][0]:
            continue  # an anchor that doesn't advance (duplicate or out of order) adds no section
        starts.append((idx, entry.title))
    if not starts:  # no usable TOC: one section per spine document
        starts = [(i, "") for i in sorted(set(lin.doc_start.values()))]
    if starts[0][0] > 0:
        starts.insert(0, (0, ""))

    sections: list[Section] = []
    seen_chapter = False
    for n, (start, toc_title) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(lin.blocks)
        blocks = lin.blocks[start:end]
        if not any(b.text for b in blocks):
            continue
        types = lin.block_types[start] if start < len(lin.block_types) else set()
        if not toc_title:
            toc_title = next((b.text for b in blocks if b.kind == "heading"), "")
        section = Section(title=toc_title, kind="", include=True, blocks=list(blocks))
        _classify(section, types, " ".join(b.text for b in blocks), title, seen_chapter, toc_titles)
        seen_chapter = seen_chapter or section.kind == "chapter"
        _drop_title_headings(section, title)
        if section.blocks or section.kind == "part":
            sections.append(section)
    return Book(title=title, author=author, language=language, sections=sections, cover=reader.cover())
