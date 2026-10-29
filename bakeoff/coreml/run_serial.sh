#!/bin/zsh
# MLX vs Core ML Kokoro, one job at a time: build, then each engine alone, then listen-back.
set -e
cd "$(dirname "$0")"
ROOT=../..
MANIFEST=https://huggingface.co/mattmireles/kokoro-coreml/resolve/main/HostedManifest.json
SHA=$(curl -sL "$MANIFEST" | shasum -a 256 | cut -d' ' -f1)
while pgrep -f "narrate (render|export)" >/dev/null; do sleep 10; done   # never overlap the book render
echo "== build"; (cd bench && swift build -c release 2>&1 | tail -2)
echo "== core ml: download + warm-up run (not timed)"; bench/.build/release/coreml-bench chunks.json out/warmup.wav --manifest-url $MANIFEST --manifest-sha256 $SHA 2>/dev/null | tail -1
for run in 1 2; do
  echo "== mlx run $run"; (cd $ROOT && uv run python -I bakeoff/coreml/mlx_bench.py render bakeoff/coreml/chunks.json bakeoff/coreml/out/mlx_$run.wav 2>/dev/null | tail -1)
  echo "== core ml run $run"; bench/.build/release/coreml-bench chunks.json out/coreml_$run.wav --manifest-url $MANIFEST --manifest-sha256 $SHA 2>/dev/null | tail -1
done
echo "== listen-back"; ../bench/.venv/bin/python -I ../bench/qa.py ../passage.txt out/mlx_2.wav out/coreml_2.wav 2>&1 | grep -v Warn | tail -2
echo "== done"
