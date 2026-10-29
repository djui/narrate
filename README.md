# Narrate

Turn a DRM-free EPUB into a chaptered M4B audiobook, rendered offline on Apple Silicon with
[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) on Core ML via
[kokoro-coreml](https://github.com/mattmireles/kokoro-coreml) (Neural Engine, GPU and CPU; no Python).

Status: M2, Swift command-line core. Design, bake-offs and roadmap: [docs/report.html](docs/report.html).

Requires macOS 15+, Xcode 26+ and `ffmpeg` on `PATH` (Homebrew's build includes the AudioToolbox AAC
encoder). The ~220 MB Kokoro model downloads on first render into `~/Library/Caches/narrate`.

```bash
swift build -c release
.build/release/narrate build treasure-island.epub          # ingest, render, export in one go
```

Or step by step, with a chance to pick chapters:

```bash
.build/release/narrate ingest treasure-island.epub         # -> treasure-island.narrate/
.build/release/narrate contents treasure-island.narrate    # list sections; --include/--exclude to toggle
.build/release/narrate render treasure-island.narrate --voice af_heart --speed 1.0
.build/release/narrate export treasure-island.narrate      # -> treasure-island.narrate/out/*.m4b
```

Rendering is resumable: every chunk is cached by a hash of its text, voice, speed and engine,
so re-running only renders what changed. The Mac is kept awake while rendering.

## Python reference implementation

`src/narrate` is the M1 implementation on mlx-audio. It produces the same `book.json` and the
same chunk plan as the Swift core, and is kept as the reference for checking it.

```bash
uv sync
uv run narrate build treasure-island.epub
uv run pytest
```
