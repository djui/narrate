# Narrate

Turn a DRM-free EPUB into a chaptered M4B audiobook, rendered offline on Apple Silicon with
[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) via [mlx-audio](https://github.com/Blaizzy/mlx-audio).

Status: M1, command-line core. Design and bake-off: [docs/report.html](docs/report.html).

```bash
uv sync
uv run narrate build treasure-island.epub          # ingest, render, export in one go
```

Or step by step, with a chance to pick chapters:

```bash
uv run narrate ingest treasure-island.epub         # -> treasure-island.narrate/
uv run narrate contents treasure-island.narrate    # list sections, --include/--exclude to toggle
uv run narrate render treasure-island.narrate --voice af_heart --speed 1.0
uv run narrate export treasure-island.narrate      # -> treasure-island.narrate/out/*.m4b
```

Rendering is resumable: every chunk is cached by a hash of its text, voice, speed and engine,
so re-running only renders what changed.

Requires `ffmpeg` on `PATH` (Homebrew's build includes the AudioToolbox AAC encoder).
