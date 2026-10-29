"""A book project is one folder: source EPUB, parsed structure, settings, audio cache, output."""

from __future__ import annotations

import json
import shutil
from dataclasses import dataclass
from pathlib import Path

from .epub import Book, read_epub


@dataclass
class Project:
    root: Path

    @property
    def book_path(self) -> Path:
        return self.root / "book.json"

    @property
    def settings_path(self) -> Path:
        return self.root / "settings.json"

    @property
    def cache_dir(self) -> Path:
        return self.root / "cache"

    @property
    def out_dir(self) -> Path:
        return self.root / "out"

    @property
    def work_dir(self) -> Path:
        return self.root / "work"

    def cover_path(self) -> Path | None:
        return next(iter(sorted(self.root.glob("cover.*"))), None)

    def load_book(self) -> Book:
        return Book.from_json(json.loads(self.book_path.read_text(encoding="utf-8")))

    def save_book(self, book: Book) -> None:
        _write_json(self.book_path, book.to_json())

    def load_settings(self) -> dict:
        return json.loads(self.settings_path.read_text()) if self.settings_path.exists() else {}

    def save_settings(self, settings: dict) -> None:
        _write_json(self.settings_path, settings)


def default_root(epub: Path) -> Path:
    return epub.with_suffix(".narrate")


def ingest(epub: Path, root: Path | None = None, force: bool = False) -> Project:
    project = Project(root or default_root(epub))
    if project.book_path.exists() and not force:
        raise FileExistsError(f"{project.root} already exists; pass --force to re-ingest (keeps the audio cache)")
    book = read_epub(str(epub))
    project.root.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(epub, project.root / "source.epub")
    for old in project.root.glob("cover.*"):
        old.unlink()
    if book.cover:
        ext, data = book.cover
        (project.root / f"cover.{ext}").write_bytes(data)
    project.save_book(book)
    return project


def _write_json(path: Path, data: dict) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.replace(path)
