"""Render every chunk of the included sections into a content-addressed WAV cache."""

from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path
from typing import Callable

import numpy as np
import soundfile as sf

from .chunk import Chunk, plan
from .engine import Engine
from .project import Project

SILENCE_THRESHOLD = 0.004  # about -48 dBFS
LEAD_PAD_S = 0.04
TAIL_PAD_S = 0.06


def chunk_key(engine_id: str, voice: str, speed: float, text: str) -> str:
    payload = json.dumps([engine_id, voice, round(speed, 3), text], ensure_ascii=False)
    return hashlib.sha256(payload.encode()).hexdigest()[:24]


def cache_path(project: Project, key: str) -> Path:
    return project.cache_dir / key[:2] / f"{key}.wav"


def trim_silence(audio: np.ndarray, sample_rate: int) -> np.ndarray:
    """Cut the model's own leading/trailing silence; assembly inserts exact pauses instead."""
    frame = max(1, sample_rate // 100)
    n = len(audio) // frame
    if n == 0:
        return audio
    rms = np.sqrt(np.mean(audio[: n * frame].reshape(n, frame) ** 2, axis=1))
    loud = np.flatnonzero(rms > SILENCE_THRESHOLD)
    if len(loud) == 0:
        return audio
    start = max(0, loud[0] * frame - int(LEAD_PAD_S * sample_rate))
    end = min(len(audio), (loud[-1] + 1) * frame + int(TAIL_PAD_S * sample_rate))
    return audio[start:end]


def planned_chunks(project: Project, settings: dict) -> list[tuple[Chunk, str]]:
    book = project.load_book()
    return [
        (c, chunk_key(settings["engine_id"], settings["voice"], settings["speed"], c.text))
        for c in plan(book)
    ]


def render(
    project: Project,
    engine: Engine,
    voice: str,
    speed: float,
    sections: set[int] | None = None,
    log: Callable[[str], None] = print,
) -> dict:
    settings = {"voice": voice, "speed": speed, "engine_id": engine.engine_id, "sample_rate": engine.sample_rate}
    project.save_settings(settings)
    chunks = planned_chunks(project, settings)
    (project.root / "chunks.json").write_text(
        json.dumps([{"section": c.section, "text": c.text, "pause": c.pause, "key": k} for c, k in chunks], indent=1, ensure_ascii=False),
        encoding="utf-8",
    )
    todo = [(c, k) for c, k in chunks if not cache_path(project, k).exists() and (sections is None or c.section in sections)]
    total_chars = sum(len(c.text) for c, _ in todo)
    log(f"{len(chunks)} chunks planned, {len(chunks) - len(todo)} cached, {len(todo)} to render")

    t0 = time.perf_counter()
    audio_s = done_chars = 0.0
    last_log = 0.0
    for i, (chunk, key) in enumerate(todo, 1):
        audio = trim_silence(engine.synthesize(chunk.text, voice, speed), engine.sample_rate)
        if len(audio) == 0:
            raise RuntimeError(f"engine returned no audio for chunk {key}: {chunk.text!r}")
        path = cache_path(project, key)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.stem + ".part.wav")
        sf.write(tmp, audio, engine.sample_rate, subtype="PCM_16")
        tmp.replace(path)

        audio_s += len(audio) / engine.sample_rate
        done_chars += len(chunk.text)
        elapsed = time.perf_counter() - t0
        if elapsed - last_log >= 30 or i == len(todo):
            last_log = elapsed
            eta = elapsed / done_chars * (total_chars - done_chars)
            log(
                f"  {i}/{len(todo)} chunks · section {chunk.section} · {audio_s / 60:.1f} min audio in "
                f"{elapsed / 60:.1f} min ({audio_s / elapsed:.1f}× real time) · ~{eta / 60:.0f} min left"
            )
    return {"chunks": len(chunks), "rendered": len(todo), "audio_s": audio_s, "elapsed_s": time.perf_counter() - t0}
