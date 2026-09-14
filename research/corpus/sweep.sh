#!/bin/bash
# Sweep bin/round-trip over the corpus: -c 100 at seeds 1/101/201, then --hostile -c 100.
# usage: sweep.sh <outdir> <schema> [schema ...]
REPO=/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e
BUNDLE=$HOME/.rvm/wrappers/ruby-3.4.9/bundle
OUT="$1"; shift
mkdir -p "$OUT"
cd "$REPO" || exit 1

run() { # name seed label extra...
  local name="$1" seed="$2" label="$3"; shift 3
  local log="$OUT/$name.s$seed.$label.txt"
  [ -s "$log" ] && return
  local start=$SECONDS
  "$BUNDLE" exec ruby bin/round-trip "$SCHEMA" -c 100 -s "$seed" "$@" > "$log" 2>&1
  echo "$name seed=$seed $label exit=$? secs=$((SECONDS-start))"
}

for SCHEMA in "$@"; do
  name=$(basename "$SCHEMA")
  run "$name" 1 plain
  run "$name" 101 plain
  run "$name" 201 plain
  run "$name" 1 hostile --hostile
done
