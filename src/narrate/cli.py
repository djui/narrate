"""narrate: EPUB to M4B audiobook.

  narrate ingest BOOK.epub            parse into BOOK.narrate/
  narrate contents PROJECT            list sections; --include/--exclude to toggle
  narrate render PROJECT              render missing chunks (resumable)
  narrate export PROJECT              build the M4B
  narrate build BOOK.epub             all of the above with defaults
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .engine import DEFAULT_SPEED, DEFAULT_VOICE

WORDS_PER_MINUTE = 200  # Kokoro af_heart at 1.0×, measured in the M0 bake-off


def _indices(spec: str) -> set[int]:
    out: set[int] = set()
    for part in filter(None, spec.split(",")):
        lo, _, hi = part.partition("-")
        out.update(range(int(lo), int(hi or lo) + 1))
    return out


def _project(path: str):
    from .project import Project

    root = Path(path)
    if root.suffix == ".epub":
        root = root.with_suffix(".narrate")
    project = Project(root)
    if not project.book_path.exists():
        sys.exit(f"no project at {root}; run `narrate ingest` first")
    return project


def cmd_ingest(args) -> None:
    from .project import ingest

    project = ingest(Path(args.epub), Path(args.project) if args.project else None, force=args.force)
    print(f"ingested into {project.root}")
    _print_contents(project, DEFAULT_SPEED)


def _print_contents(project, speed: float) -> None:
    book = project.load_book()
    print(f"{book.title} — {book.author}")
    total = 0
    for i, s in enumerate(book.sections):
        minutes = s.words / (WORDS_PER_MINUTE * speed)
        total += minutes if s.include else 0
        mark = "✓" if s.include else " "
        label = s.marker or s.title or "(untitled)"
        print(f"{i:3} [{mark}] {s.kind:<11} {s.words:>6} words {minutes:6.1f} min  {label}")
    print(f"included: ≈ {total / 60:.1f} h at speed {speed}")


def cmd_contents(args) -> None:
    project = _project(args.project)
    if args.include or args.exclude:
        book = project.load_book()
        for i in _indices(args.include or ""):
            book.sections[i].include = True
        for i in _indices(args.exclude or ""):
            book.sections[i].include = False
        project.save_book(book)
    _print_contents(project, project.load_settings().get("speed", DEFAULT_SPEED))


def cmd_render(args) -> None:
    from .engine import KokoroEngine
    from .render import render

    project = _project(args.project)
    sections = _indices(args.sections) if args.sections else None
    render(project, KokoroEngine(), args.voice, args.speed, sections)


def cmd_export(args) -> None:
    from .assemble import export, probe

    out = export(_project(args.project))
    info = probe(out)
    print(f"{info['duration_s'] / 3600:.2f} h · {len(info['chapters'])} chapters · {info['audio']} · cover: {'yes' if info['cover'] else 'no'}")


def cmd_build(args) -> None:
    from .project import Project, default_root, ingest

    epub = Path(args.epub)
    root = Path(args.project) if args.project else default_root(epub)
    if not Project(root).book_path.exists():
        ingest(epub, root)
    args.project = str(root)
    args.sections = None
    cmd_render(args)
    cmd_export(args)


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="narrate", description="Turn a DRM-free EPUB into an M4B audiobook.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("ingest", help="parse an EPUB into a project folder")
    p.add_argument("epub")
    p.add_argument("--project", help="project folder (default: BOOK.narrate next to the EPUB)")
    p.add_argument("--force", action="store_true", help="re-ingest an existing project; the audio cache is kept")
    p.set_defaults(func=cmd_ingest)

    p = sub.add_parser("contents", help="list sections and choose which to include")
    p.add_argument("project")
    p.add_argument("--include", help="section numbers to include, e.g. 2,4-6")
    p.add_argument("--exclude", help="section numbers to leave out")
    p.set_defaults(func=cmd_contents)

    for name, func, help_ in (("render", cmd_render, "render audio for all included sections"), ("build", cmd_build, "ingest, render and export")):
        p = sub.add_parser(name, help=help_)
        p.add_argument("epub" if name == "build" else "project")
        if name == "build":
            p.add_argument("--project")
        else:
            p.add_argument("--sections", help="only render these section numbers, e.g. 5-7")
        p.add_argument("--voice", default=DEFAULT_VOICE)
        p.add_argument("--speed", type=float, default=DEFAULT_SPEED)
        p.set_defaults(func=func)

    p = sub.add_parser("export", help="build the M4B from rendered audio")
    p.add_argument("project")
    p.set_defaults(func=cmd_export)

    args = ap.parse_args(argv)
    try:
        args.func(args)
    except (FileExistsError, RuntimeError) as e:
        sys.exit(f"narrate: {e}")


if __name__ == "__main__":
    main()
