#!/bin/bash
# Download a sample of GitLab's own .query.graphql files (and any fragment a
# file #imports, one level) into a flat directory.
OUT=/tmp/claude/graph_weaver/corpus/q-gitlab
RAW=https://raw.githubusercontent.com/gitlabhq/gitlabhq/master
mkdir -p "$OUT"

gh api "repos/gitlabhq/gitlabhq/git/trees/HEAD?recursive=1" \
  --jq '[.tree[].path | select(test("\\.query\\.graphql$"))] | .[0:120][]' > "$OUT/.paths"

while read -r path; do
  name=$(echo "$path" | tr '/' '_')
  [ -s "$OUT/$name" ] && continue
  curl -sSL --max-time 30 -o "$OUT/$name" "$RAW/$path"
done < "$OUT/.paths"

echo "downloaded $(ls "$OUT" | grep -c graphql) files"
grep -l "^#import" "$OUT"/*.graphql 2>/dev/null | wc -l | xargs echo "with #import:"
