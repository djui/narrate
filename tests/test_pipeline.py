"""End to end with a fake engine: ingest, render, export a real M4B, then probe it."""

import shutil

import numpy as np
import pytest
from PIL import Image

from narrate.assemble import export, probe
from narrate.project import ingest
from narrate.render import render, trim_silence


class ToneEngine:
    engine_id = "tone-v1"
    sample_rate = 24000

    def __init__(self):
        self.calls = 0

    def synthesize(self, text, voice, speed):
        self.calls += 1
        t = np.arange(int(0.02 * len(text) * self.sample_rate)) / self.sample_rate
        tone = 0.3 * np.sin(2 * np.pi * 220 * t).astype(np.float32)
        silence = np.zeros(self.sample_rate // 4, np.float32)
        return np.concatenate([silence, tone, silence])


def test_trim_silence_keeps_speech_and_small_pads():
    engine = ToneEngine()
    audio = engine.synthesize("x" * 50, "v", 1.0)
    trimmed = trim_silence(audio, engine.sample_rate)
    assert 1.0 < len(trimmed) / engine.sample_rate < 1.2


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="needs ffmpeg")
def test_build_m4b_with_chapters_and_cover(epub_path, tmp_path):
    project = ingest(epub_path, tmp_path / "book.narrate")
    # Replace the fake cover bytes with a real JPEG so ffmpeg can attach it.
    Image.new("RGB", (64, 96), (120, 40, 30)).save(project.cover_path(), "JPEG")

    engine = ToneEngine()
    stats = render(project, engine, "af_heart", 1.0, log=lambda _: None)
    assert stats["rendered"] == stats["chunks"] > 0

    again = render(project, engine, "af_heart", 1.0, log=lambda _: None)
    assert again["rendered"] == 0  # everything comes from the cache

    out = export(project, log=lambda _: None)
    info = probe(out)
    assert info["chapters"] == ["Part One — The Harbour", "1 · The Old Captain", "2 · A Black Spot"]
    assert info["cover"]
    assert info["tags"]["title"] == "The Test Voyage"
    assert info["tags"]["artist"] == "Ann Author"
    assert info["duration_s"] > 5
