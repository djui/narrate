"""Check the Swift core against the Python reference on a corpus of real EPUBs.

For every book in tests/corpus.txt: ingest it with both implementations and compare book.json and
the chunk plan. Nothing is rendered. Downloads are cached in .build/corpus.

Usage: swift build -c release && uv run python scripts/corpus.py [--swift .build/release/narrate]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import urllib.request
from dataclasses import asdict
from pathlib import Path

from narrate.chunk import plan
from narrate.project import ingest

ROOT = Path(__file__).resolve().parent.parent


def books() -> list[tuple[str, str]]:
    out = []
    for line in (ROOT / "tests" / "corpus.txt").read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            name, url = line.split(None, 1)
            out.append((name, url))
    return out


def without_nulls(value):
    """Swift leaves out nil fields; Python writes them as null."""
    if isinstance(value, dict):
        return {k: without_nulls(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [without_nulls(v) for v in value]
    return value


def fetch(name: str, url: str) -> Path:
    path = ROOT / ".build" / "corpus" / f"{name}.epub"
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        request = urllib.request.Request(url, headers={"User-Agent": "narrate-corpus-check"})
        with urllib.request.urlopen(request, timeout=60) as response:
            path.write_bytes(response.read())
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift", default=str(ROOT / ".build" / "release" / "narrate"))
    args = parser.parse_args()
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        for name, url in books():
            epub = fetch(name, url)
            swift_root, py_root = Path(tmp) / f"{name}-swift.narrate", Path(tmp) / f"{name}-py.narrate"
            subprocess.run([args.swift, "ingest", str(epub), "--project", str(swift_root)], check=True, capture_output=True)
            swift_plan = json.loads(subprocess.run([args.swift, "plan", str(swift_root)], check=True, capture_output=True, text=True).stdout)
            py_project = ingest(epub, py_root)
            py_plan = [asdict(c) for c in plan(py_project.load_book())]

            problems = []
            if without_nulls(json.loads((swift_root / "book.json").read_text())) != without_nulls(json.loads(py_project.book_path.read_text())):
                problems.append("book.json differs")
            if len(swift_plan) != len(py_plan):
                problems.append(f"{len(swift_plan)} chunks in Swift, {len(py_plan)} in Python")
            else:
                diffs = [i for i, (s, p) in enumerate(zip(swift_plan, py_plan)) if s["text"] != p["text"] or s["section"] != p["section"] or abs(s["pause"] - p["pause"]) > 1e-9]
                if diffs:
                    first = diffs[0]
                    at = next((i for i, (a, b) in enumerate(zip(swift_plan[first]["text"], py_plan[first]["text"])) if a != b), 0)
                    problems.append(f"{len(diffs)} chunks differ, first #{first}: Swift …{swift_plan[first]['text'][max(0, at - 30):at + 30]!r}… Python …{py_plan[first]['text'][max(0, at - 30):at + 30]!r}…")
            sections = len(json.loads((swift_root / "book.json").read_text())["sections"])
            print(f"{'FAIL' if problems else 'ok  '} {name}: {sections} sections, {len(swift_plan)} chunks" + "".join(f"\n     {p}" for p in problems))
            failures += bool(problems)
    print(f"{len(books()) - failures} of {len(books())} books match")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
