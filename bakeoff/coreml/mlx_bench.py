"""MLX side of the Core ML comparison, and the shared chunk list both engines read.

  uv run python -I mlx_bench.py chunks PASSAGE_TXT CHUNKS_JSON
  uv run python -I mlx_bench.py render CHUNKS_JSON OUT.wav [--speed 0.94] [--voice af_heart]
"""

import argparse
import json
import resource
import time
from pathlib import Path

import numpy as np
import soundfile as sf

from narrate.chunk import PAUSE_PARAGRAPH, PAUSE_SENTENCE, pack
from narrate.engine import KokoroEngine
from narrate.normalize import normalize
from narrate.render import trim_silence


def cmd_chunks(args):
    paras = [p for p in Path(args.passage).read_text(encoding="utf-8").split("\n\n") if p.strip()]
    chunks = []
    for para in paras:
        pieces = pack(normalize(para))
        chunks += [{"text": t, "pause": PAUSE_SENTENCE} for t in pieces]
        chunks[-1]["pause"] = PAUSE_PARAGRAPH
    Path(args.out).write_text(json.dumps(chunks, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"{len(chunks)} chunks from {len(paras)} paragraphs -> {args.out}")


def cmd_render(args):
    chunks = json.loads(Path(args.chunks).read_text(encoding="utf-8"))
    engine = KokoroEngine()
    t0 = time.perf_counter()
    engine.synthesize("Warm up.", args.voice, args.speed)  # loads the model
    load_s = time.perf_counter() - t0

    out, synth_s, speech_s = [], 0.0, 0.0
    sr = engine.sample_rate
    for c in chunks:
        t0 = time.perf_counter()
        audio = engine.synthesize(c["text"], args.voice, args.speed)
        synth_s += time.perf_counter() - t0
        speech_s += len(audio) / sr
        out += [trim_silence(audio, sr), np.zeros(int(round(c["pause"] * sr)), np.float32)]
    sf.write(args.out, np.concatenate(out), sr, subtype="PCM_16")

    import mlx.core as mx

    result = {
        "engine": "mlx-audio (GPU)", "voice": args.voice, "speed": args.speed, "chunks": len(chunks),
        "load_s": round(load_s, 1), "synth_s": round(synth_s, 1), "speech_s": round(speech_s, 1),
        "rtf": round(synth_s / speech_s, 3),
        "peak_rss_gb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9, 2),
        "peak_mlx_gb": round(mx.get_peak_memory() / 1e9, 2),
    }
    Path(args.out).with_suffix(".json").write_text(json.dumps(result, indent=1))
    print(json.dumps(result))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("chunks")
    c.add_argument("passage")
    c.add_argument("out")
    r = sub.add_parser("render")
    r.add_argument("chunks")
    r.add_argument("out")
    r.add_argument("--speed", type=float, default=0.94)
    r.add_argument("--voice", default="af_heart")
    args = ap.parse_args()
    {"chunks": cmd_chunks, "render": cmd_render}[args.cmd](args)


if __name__ == "__main__":
    main()
