"""M0 bake-off: render the same Treasure Island passage with one engine and measure it.

Usage:
  python -I bench.py passage SOURCE_TXT OUT_TXT [--words 750]
  python -I bench.py render --model REPO --voice NAME --out OUT.wav [--speed 0.94]
                            [--instruct TEXT] [--max-paras N] PASSAGE_TXT
"""

import argparse
import json
import re
import resource
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf

PARA_GAP_S = 0.6
SAMPLE_RATE = 24000


def cmd_passage(args):
    lines = Path(args.source).read_text(encoding="utf-8").splitlines()
    start = lines.index("The Black Spot") + 1
    paras, cur = [], []
    for line in lines[start:]:
        if line.strip() == "IV":
            break
        if line.strip():
            cur.append(line.strip())
        elif cur:
            paras.append(" ".join(cur))
            cur = []
    out, words = [], 0
    for p in paras:
        # Gutenberg uses "--" for em dashes.
        p = re.sub(r"\s*--\s*", " — ", p)
        out.append(p)
        words += len(p.split())
        if words >= args.words:
            break
    Path(args.out).write_text("\n\n".join(out) + "\n", encoding="utf-8")
    print(f"{len(out)} paragraphs, {words} words -> {args.out}")


def peak_rss_mb():
    # macOS reports ru_maxrss in bytes.
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6


def cmd_render(args):
    import mlx.core as mx
    from mlx_audio.tts.utils import load_model

    paras = [p for p in Path(args.passage).read_text(encoding="utf-8").split("\n\n") if p.strip()]
    if args.max_paras:
        paras = paras[: args.max_paras]

    t0 = time.perf_counter()
    if args.model.startswith("supertonic"):
        # ONNX Runtime on CPU, not MLX: peak_mlx_gb stays ~0 for this engine.
        from supertonic import TTS

        model = TTS(model=args.model)
        style = model.get_voice_style(args.voice)

        def synth(text):
            wav, _ = model.synthesize(text, voice_style=style, speed=args.speed, lang="en")
            return np.asarray(wav, dtype=np.float32).reshape(-1)

    else:
        model = load_model(args.model)
    load_s = time.perf_counter() - t0

    def mlx_synth(text):
        kw = dict(text=text, voice=args.voice, speed=args.speed)
        if args.instruct:
            kw["instruct"] = args.instruct
        if "qwen3" in args.model.lower():
            kw["lang_code"] = "english"
        else:
            kw["lang_code"] = "a"
        parts = [np.asarray(r.audio, dtype=np.float32) for r in model.generate(**kw)]
        return np.concatenate(parts) if parts else np.zeros(0, np.float32)

    if not args.model.startswith("supertonic"):
        synth = mlx_synth
    synth("Warm up.")
    mx.reset_peak_memory()

    sr = getattr(getattr(model, "config", None), "sample_rate", None) or getattr(model, "sample_rate", SAMPLE_RATE)
    gap = np.zeros(int(PARA_GAP_S * sr), np.float32)
    chunks, per = [], []
    t0 = time.perf_counter()
    for i, p in enumerate(paras):
        c0 = time.perf_counter()
        audio = synth(p)
        per.append({"para": i, "chars": len(p), "audio_s": round(len(audio) / sr, 2), "synth_s": round(time.perf_counter() - c0, 2)})
        chunks += [audio, gap]
        print(f"  para {i + 1}/{len(paras)}  {per[-1]['audio_s']:6.1f}s audio  {per[-1]['synth_s']:5.1f}s", file=sys.stderr)
    synth_s = time.perf_counter() - t0

    audio = np.concatenate(chunks[:-1])
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    sf.write(args.out, audio, sr)
    speech_s = sum(x["audio_s"] for x in per)
    result = {
        "model": args.model,
        "voice": args.voice,
        "speed": args.speed,
        "instruct": args.instruct,
        "paragraphs": len(paras),
        "chars": sum(len(p) for p in paras),
        "sample_rate": sr,
        "load_s": round(load_s, 1),
        "synth_s": round(synth_s, 1),
        "speech_s": round(speech_s, 1),
        "rtf": round(synth_s / speech_s, 3),
        "peak_mlx_gb": round(mx.get_peak_memory() / 1e9, 2),
        "peak_rss_gb": round(peak_rss_mb() / 1e3, 2),
        "per_paragraph": per,
    }
    Path(args.out).with_suffix(".json").write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k != "per_paragraph"}))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("passage")
    p.add_argument("source")
    p.add_argument("out")
    p.add_argument("--words", type=int, default=750)
    r = sub.add_parser("render")
    r.add_argument("passage")
    r.add_argument("--model", required=True)
    r.add_argument("--voice", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--speed", type=float, default=1.0)
    r.add_argument("--instruct")
    r.add_argument("--max-paras", type=int)
    args = ap.parse_args()
    {"passage": cmd_passage, "render": cmd_render}[args.cmd](args)


if __name__ == "__main__":
    main()
