# Narrate

Turn a DRM-free EPUB into a chaptered M4B audiobook, rendered offline on Apple Silicon with
[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) on Core ML via
[kokoro-coreml](https://github.com/mattmireles/kokoro-coreml) (Neural Engine, GPU and CPU; no Python).

Status: M5, a notarized Mac app with its own command-line tool. Website: [djui.github.io/narrate](https://djui.github.io/narrate/). Design, bake-offs and roadmap: [docs/report.html](docs/report.html).

Requires macOS 15+ and Xcode 26+; nothing else. Loudness normalisation, AAC encoding and the
chaptered M4B are done natively (AVFoundation). The ~220 MB Kokoro model downloads on first render
into `~/Library/Caches/narrate`.

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

### Review

Every rendered chunk is checked from its audio alone: speaking rate far from the book's running
median (stretched, rushed or skipped speech), a pause over 1.5 s inside the chunk, clipping,
near-empty audio and an end cut off mid-sound. A chunk that fails is rendered once more, split
in two at its strongest punctuation; if that fails too, the audio is kept and the chunk is
recorded in `flags.json`. On Treasure Island none of the 2,172 chunks are flagged.

```bash
.build/release/narrate review treasure-island.narrate          # flagged chunks: section, reason, numbers, text, WAV
.build/release/narrate review treasure-island.narrate --scan   # check the cached audio again
.build/release/narrate render treasure-island.narrate --recheck  # check the cache and retry what fails
.build/release/narrate review treasure-island.narrate --accept KEY  # keep a flagged chunk as it is
```

To redo a chunk by hand, delete its WAV and run `render` again. Accepted chunks are listed in
`accepted.json` and stay unflagged until their text, voice or speed changes.

### Words

`words` lists the words Kokoro's English G2P (Misaki) has no entry for and has to guess, most
frequent first, with its guess and the first sentence each appears in. Tell it how a word sounds
with a respelling, or IPA between slashes:

```bash
.build/release/narrate words treasure-island.narrate --limit 30
.build/release/narrate words treasure-island.narrate --set Livesey=Liv-see --set "Gunn=/ɡˈʌn/"
.build/release/narrate words treasure-island.narrate --remove Gunn
.build/release/narrate words treasure-island.narrate --global --set Smollett=Smaw-let  # for every book
.build/release/narrate render treasure-island.narrate          # re-renders only chunks with those words
```

Entries are kept in `lexicon.json` (word → respelling, plus the phonemes made from it; a plain
`"Livesey": "Liv-see"` written by hand is filled in on the next `words` or `render`). Entries
for every book go in `~/Library/Application Support/narrate/lexicon.json` (`--global`); a book's
own entry for the same word wins. They match
whole words in any case and are spoken through Misaki's `[word](/phonemes/)` markup, so only
chunks containing the word get a new cache key.

## The app

A SwiftUI Mac app with one window per book: the cover, every section with its render progress, and
one button for the next step (Render, Pause/Resume, Export M4B, Show in Finder). Buttons under the
title open **Sections** (pick what's read: Default, All, None, Chapters and Parts), **Pronunciation**
(the `words` list; type a sounds-like spelling and press Set), **Review** (flagged chunks with Play,
Play in Context, Re-render and Accept) and **Voice** (speed, and a preview read from the book's
opening). It works on the same project folder as the command-line tool.

```bash
swift run NarrateApp treasure-island.epub      # or a .narrate folder; or drop one on the window
scripts/bundle-app.sh                          # -> .build/Narrate.app (unsigned), then: open .build/Narrate.app
```

`NARRATE_ENGINE=tone` swaps Kokoro for a test tone (its own cache keys) to try the app without the model.
The app refuses to start a render, preview or export while a `narrate render`, `build` or `export` is running.

## Releases

Download the notarized app from [Releases](https://github.com/djui/narrate/releases/latest), or:

```bash
brew install --cask https://raw.githubusercontent.com/djui/narrate/main/packaging/narrate.rb
```

To cut a release (needs a Developer ID Application certificate and a notarytool keychain profile,
`xcrun notarytool store-credentials <name>`):

```bash
NOTARY_PROFILE=<name> scripts/release.sh 0.5.0 --publish   # build, sign, notarize, staple, zip, GitHub release
swift scripts/make-icon.swift packaging/AppIcon.icns       # redraw the app icon
```

Then update `version` and `sha256` in `packaging/narrate.rb` from the script's output, and commit
`docs/appcast.xml`: the script signs the zip with the Sparkle EdDSA key in your keychain (account
`narrate`, made once with `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account narrate`) and
adds the release to the feed the app checks daily (Narrate → Check for Updates…). Losing that key
means existing installs can't verify updates; export it with `generate_keys --account narrate -x key.txt`
and keep it somewhere safe.

## EPUB corpus

`tests/corpus.txt` lists ten public-domain Gutenberg books; `scripts/corpus.py` ingests each with
both implementations and compares `book.json` and the chunk plan (no rendering). CI runs it.

```bash
swift build -c release && uv run python scripts/corpus.py
```

## Python reference implementation

`src/narrate` is the M1 implementation on mlx-audio. It produces the same `book.json` and the
same chunk plan as the Swift core, and is kept as the reference for checking it.

```bash
uv sync
uv run narrate build treasure-island.epub
uv run pytest
```
