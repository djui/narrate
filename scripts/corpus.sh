#!/bin/sh
# Check ingest and chunking on a corpus of real EPUBs against snapshots (nothing is rendered).
# For every book in tests/corpus.txt: ingest it, then compare its section list, chunk count and a
# hash of the chunk plan with tests/corpus/NAME.txt. Downloads are cached in .build/corpus.
# Usage: swift build -c release --product narrate && scripts/corpus.sh [--update]
#   --update   rewrite the snapshots (after a deliberate change to the reader or chunker)
set -eu
cd "$(dirname "$0")/.."
narrate="${NARRATE:-.build/release/narrate}"
update="${1:-}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p .build/corpus tests/corpus
grep -v '^[[:space:]]*#' tests/corpus.txt | while read -r name url; do
  [ -n "$name" ] || continue
  epub=".build/corpus/$name.epub"
  if [ ! -f "$epub" ]; then
    curl -fsSL --http1.1 --retry 5 --retry-all-errors -A narrate-corpus-check -o "$tmp/download" "$url"
    mv "$tmp/download" "$epub"  # only a complete download lands in the cache
  fi
  "$narrate" ingest "$epub" --project "$tmp/$name.narrate" >/dev/null
  plan="$("$narrate" plan "$tmp/$name.narrate")"
  {
    "$narrate" contents "$tmp/$name.narrate"
    printf 'chunks %s\nplan %s\n' "$(printf '%s' "$plan" | grep -c '"text"')" "$(printf '%s' "$plan" | shasum -a 256 | cut -d' ' -f1)"
  } > "$tmp/$name.txt"
  if [ "$update" = "--update" ]; then
    cat "$tmp/$name.txt" > "tests/corpus/$name.txt"
    echo "updated $name"
  elif diff -u "tests/corpus/$name.txt" "$tmp/$name.txt"; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    touch "$tmp/failed"
  fi
done
[ ! -f "$tmp/failed" ]
