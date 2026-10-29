#!/bin/zsh
# Runs every remaining bake-off job one at a time so timings don't contend for the GPU/CPU.
set -e
cd "$(dirname "$0")"
while pgrep -f "qa.py" >/dev/null; do sleep 5; done   # let the in-flight listen-back finish first
echo "== qwen3 0.6b serena"; .venv/bin/python -I bench.py render ../passage.txt --model mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit --voice serena --instruct "Calm, warm audiobook narration. Restrained, steady pace, subtle expression." --out ../out/qwen3_0.6b_serena.wav 2>&1 | grep -v Warn | tail -1
echo "== supertonic F1"; .venv/bin/python -I bench.py render ../passage.txt --model supertonic-3 --voice F1 --out ../out/supertonic3_F1.wav 2>&1 | tail -1
echo "== listen-back"; .venv/bin/python -I qa.py ../passage.txt ../out/kokoro_af_heart.wav ../out/kokoro_af_bella.wav ../out/qwen3_0.6b_serena.wav ../out/supertonic3_F1.wav 2>&1 | grep -v Warn | tail -4
echo "== done"
