"""Join cached chunks with structural pauses, normalise loudness once, encode once to a chaptered M4B.

Encoding happens a single time from uncompressed PCM, so AAC priming silence never lands at chunk
joins. Chapters go in as ffmetadata, which ffmpeg's MP4 muxer writes as a QuickTime chapter track,
the one Apple Books reads.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import numpy as np
import soundfile as sf

from .project import Project
from .render import cache_path, planned_chunks

LEAD_IN_S = 0.5
TARGET_LUFS = -18
TARGET_TP = -1.5
TARGET_LRA = 11
OUTPUT_RATE = 44100
BITRATE = "64k"


@dataclass
class Marker:
    title: str
    start: int  # samples
    end: int


def _escape(value: str) -> str:
    return re.sub(r"([=;#\\\n])", r"\\\1", value)


def ffmetadata(tags: dict[str, str], markers: list[Marker], sample_rate: int) -> str:
    lines = [";FFMETADATA1"]
    lines += [f"{k}={_escape(v)}" for k, v in tags.items() if v]
    for m in markers:
        start = round(m.start * 1000 / sample_rate)
        end = round(m.end * 1000 / sample_rate)
        lines += ["", "[CHAPTER]", "TIMEBASE=1/1000", f"START={start}", f"END={end}", f"title={_escape(m.title)}"]
    return "\n".join(lines) + "\n"


def _ffmpeg(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", *args], capture_output=True, text=True, check=True)


def _aac_encoder() -> str:
    encoders = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
    return "aac_at" if re.search(r"\baac_at\b", encoders) else "aac"


def _measure_loudness(wav: Path) -> dict:
    args = ["-i", str(wav), "-af", f"loudnorm=I={TARGET_LUFS}:TP={TARGET_TP}:LRA={TARGET_LRA}:print_format=json", "-f", "null", "-"]
    stderr = _ffmpeg(args).stderr
    return json.loads(stderr[stderr.rindex("{") : stderr.rindex("}") + 1])


def _safe_filename(text: str) -> str:
    return re.sub(r'[\\/:*?"<>|]+', "", text).strip() or "audiobook"


def write_pcm(project: Project, log: Callable[[str], None] = print) -> tuple[Path, list[Marker], int]:
    """Concatenate all included chunks into one WAV and return its chapter markers."""
    settings = project.load_settings()
    if not settings:
        raise RuntimeError("nothing rendered yet; run `narrate render` first")
    sr = settings["sample_rate"]
    chunks = planned_chunks(project, settings)
    missing = [k for _, k in chunks if not cache_path(project, k).exists()]
    if missing:
        raise RuntimeError(f"{len(missing)} of {len(chunks)} chunks are not rendered yet; run `narrate render` first")

    book = project.load_book()
    project.work_dir.mkdir(parents=True, exist_ok=True)
    wav = project.work_dir / "book.wav"
    markers: list[Marker] = []
    section = None
    pos = 0
    with sf.SoundFile(wav, "w", samplerate=sr, channels=1, subtype="PCM_16") as out:
        lead = np.zeros(int(LEAD_IN_S * sr), np.float32)
        out.write(lead)
        pos += len(lead)
        for chunk, key in chunks:
            if chunk.section != section:
                section = chunk.section
                s = book.sections[section]
                markers.append(Marker(s.marker or s.title, pos, pos))
            audio, file_sr = sf.read(cache_path(project, key), dtype="float32")
            if file_sr != sr:
                raise RuntimeError(f"chunk {key} is {file_sr} Hz, expected {sr} Hz")
            gap = np.zeros(int(round(chunk.pause * sr)), np.float32)
            out.write(audio)
            out.write(gap)
            pos += len(audio) + len(gap)
            markers[-1].end = pos
    markers[0].start = 0  # the lead-in belongs to the first chapter
    log(f"joined {len(chunks)} chunks into {pos / sr / 3600:.2f} h of audio, {len(markers)} chapters")
    return wav, markers, sr


def export(project: Project, log: Callable[[str], None] = print) -> Path:
    if not shutil.which("ffmpeg"):
        raise RuntimeError("ffmpeg not found on PATH")
    book = project.load_book()
    settings = project.load_settings()
    wav, markers, sr = write_pcm(project, log)

    log("measuring loudness (pass 1 of 2)")
    m = _measure_loudness(wav)
    loudnorm = (
        f"loudnorm=I={TARGET_LUFS}:TP={TARGET_TP}:LRA={TARGET_LRA}"
        f":measured_I={m['input_i']}:measured_TP={m['input_tp']}:measured_LRA={m['input_lra']}"
        f":measured_thresh={m['input_thresh']}:offset={m['target_offset']}:linear=true"
    )
    narrator = f"Synthetic voice (Kokoro {settings['voice']})"
    tags = {
        "title": book.title,
        "album": book.title,
        "artist": book.author,
        "album_artist": book.author,
        "composer": narrator,
        "genre": "Audiobook",
        "comment": f"Narrated by a synthetic voice (Kokoro {settings['voice']}) with Narrate.",
        "media_type": "2",
    }
    meta = project.work_dir / "ffmetadata.txt"
    meta.write_text(ffmetadata(tags, markers, sr), encoding="utf-8")

    project.out_dir.mkdir(parents=True, exist_ok=True)
    out = project.out_dir / f"{_safe_filename(book.title)} - {_safe_filename(book.author)}.m4b"
    tmp = out.with_name(out.stem + ".part.m4b")
    args = ["-y", "-i", str(wav), "-i", str(meta)]
    cover = project.cover_path()
    if cover:
        args += ["-i", str(cover)]
    args += ["-map", "0:a", "-map_metadata", "1", "-map_chapters", "1"]
    if cover:
        codec = "copy" if cover.suffix.lower() in (".jpg", ".jpeg", ".png") else "mjpeg"
        args += ["-map", "2:v", "-c:v", codec, "-disposition:v:0", "attached_pic"]
    args += [
        "-af", f"{loudnorm},aresample={OUTPUT_RATE}",
        "-c:a", _aac_encoder(), "-b:a", BITRATE, "-ac", "1",
        "-movflags", "+faststart", "-f", "ipod", str(tmp),
    ]
    log("normalizing and encoding (pass 2 of 2)")
    _ffmpeg(args)
    tmp.replace(out)
    log(f"wrote {out}")
    return out


def probe(path: Path) -> dict:
    """Duration, chapter titles and whether a cover is attached, as ffprobe sees them."""
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_chapters", "-show_streams", str(path)],
        capture_output=True, text=True, check=True,
    )
    data = json.loads(result.stdout)
    return {
        "duration_s": float(data["format"]["duration"]),
        "chapters": [c["tags"].get("title", "") for c in data.get("chapters", [])],
        "cover": any(s.get("disposition", {}).get("attached_pic") for s in data["streams"]),
        "audio": next(f"{s['codec_name']} {s.get('sample_rate')} Hz {s.get('channels')}ch" for s in data["streams"] if s["codec_type"] == "audio"),
        "tags": data["format"].get("tags", {}),
    }
