"""M0 bake-off: transcribe rendered audio with Parakeet and compare it with the source text.

Usage:
  python -I qa.py PASSAGE_TXT OUT1.wav [OUT2.wav ...]
"""

import difflib
import json
import re
import sys
import time
from pathlib import Path

import soundfile as sf

ASR_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"


def words(text):
    text = text.lower().replace("’", "'").replace("‘", "'")
    text = re.sub(r"[^a-z0-9' ]+", " ", text)
    return [w.strip("'") for w in text.split() if w.strip("'")]


def compare(ref, hyp):
    sm = difflib.SequenceMatcher(a=ref, b=hyp, autojunk=False)
    errors, diffs = 0, []
    for op, a0, a1, b0, b1 in sm.get_opcodes():
        if op == "equal":
            continue
        errors += max(a1 - a0, b1 - b0)
        diffs.append({"op": op, "book": " ".join(ref[a0:a1]), "heard": " ".join(hyp[b0:b1])})
    return errors / max(len(ref), 1), diffs


def main():
    from parakeet_mlx import from_pretrained

    ref = words(Path(sys.argv[1]).read_text(encoding="utf-8"))
    t0 = time.perf_counter()
    model = from_pretrained(ASR_MODEL)
    print(f"loaded {ASR_MODEL} in {time.perf_counter() - t0:.1f}s", file=sys.stderr)
    for wav in sys.argv[2:]:
        dur = sf.info(wav).duration
        t0 = time.perf_counter()
        text = model.transcribe(wav).text
        asr_s = time.perf_counter() - t0
        wer, diffs = compare(ref, words(text))
        out = {
            "wav": Path(wav).name,
            "audio_s": round(dur, 1),
            "asr_s": round(asr_s, 1),
            "asr_rtf": round(asr_s / dur, 4),
            "wer": round(wer, 4),
            "diffs": diffs,
            "transcript": text,
        }
        Path(wav).with_suffix(".qa.json").write_text(json.dumps(out, indent=2))
        print(json.dumps({k: out[k] for k in ("wav", "audio_s", "asr_s", "asr_rtf", "wer")}), f"{len(diffs)} diffs")


if __name__ == "__main__":
    main()
