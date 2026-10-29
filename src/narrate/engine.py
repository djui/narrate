"""TTS engines. Every engine is identified by an engine_id that becomes part of each chunk's cache key."""

from __future__ import annotations

from importlib.metadata import version
from typing import Protocol

import numpy as np

DEFAULT_VOICE = "af_heart"
DEFAULT_SPEED = 1.0


class Engine(Protocol):
    engine_id: str
    sample_rate: int

    def synthesize(self, text: str, voice: str, speed: float) -> np.ndarray:
        """Return mono float32 PCM at sample_rate."""
        ...


class KokoroEngine:
    """Kokoro-82M through mlx-audio on Apple Silicon. The model loads on first use."""

    def __init__(self, repo: str = "mlx-community/Kokoro-82M-bf16"):
        mlx_audio = ".".join(version("mlx-audio").split(".")[:2])
        self.repo = repo
        self.engine_id = f"{repo}+mlx-audio-{mlx_audio}"
        self.sample_rate = 24000
        self._model = None

    def synthesize(self, text: str, voice: str, speed: float) -> np.ndarray:
        if self._model is None:
            from mlx_audio.tts.utils import load_model

            self._model = load_model(self.repo)
        parts = [
            np.asarray(r.audio, dtype=np.float32)
            for r in self._model.generate(text=text, voice=voice, speed=speed, lang_code="a")
        ]
        return np.concatenate(parts) if parts else np.zeros(0, np.float32)
