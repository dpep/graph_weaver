#!/bin/bash
# A second, wider pass: -c 100 at three fresh seeds, plus a hostile pass at one.
REPO=/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e
BUNDLE=$HOME/.rvm/wrappers/ruby-3.4.9/bundle
OUT=/tmp/claude/graph_weaver/corpus/out-wide
mkdir -p "$OUT"
cd "$REPO" || exit 1

for SCHEMA in "$@"; do
  name=$(basename "$SCHEMA")
  for seed in 301 401 501; do
    log="$OUT/$name.s$seed.txt"
    [ -s "$log" ] && continue
    "$BUNDLE" exec ruby bin/round-trip "$SCHEMA" -c 100 -s "$seed" > "$log" 2>&1
    echo "$name seed=$seed exit=$?"
  done
  log="$OUT/$name.s301.hostile.txt"
  [ -s "$log" ] && continue
  "$BUNDLE" exec ruby bin/round-trip "$SCHEMA" -c 100 -s 301 --hostile > "$log" 2>&1
  echo "$name seed=301 hostile exit=$?"
done
